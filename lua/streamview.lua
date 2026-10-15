-- Read-only paged viewer for files too big to load into a buffer.
-- The file is never read whole: a window of lines is rebuilt from fixed-size blocks at a byte
-- offset, so memory use does not depend on the file size.
local uv = vim.uv
local save = require("streamview_save")
local M = {}

M.opts = {
  block = 256 * 1024, -- read unit; at most two blocks of file data are held at a time
  yank_max = 64 * 1024 * 1024, -- bytes an operator copies into a register
  slice = 2 * 1024 * 1024, -- bytes of a line in the buffer around the cursor; a longer line slides through it
  slice_hyst = 0.2, -- the slice moves when the cursor gets this close to an edge that is not the line's
  head = 64 * 1024, -- bytes shown of the lines the cursor is not on, when the window would be too big
  window_budget = 16 * 1024 * 1024, -- bytes of text in all the rows of the window
  sync_scan = 32 * 1024 * 1024, -- bytes scanned for a line end before the scan goes to a job with progress
  scan_chunk = 4 * 1024 * 1024, -- bytes read at a time when scanning for newlines
  checkpoint_gap = 8 * 1024 * 1024, -- bytes between the checkpoints of the line index
  fact_min = 64 * 1024, -- scanned stretches shorter than this are not remembered
  max_facts = 4096, -- remembered stretches per file
  -- may the window be edited (changes are held as pieces until saved)
  editable = not (vim.g.stream_viewer_readonly == true or vim.g.stream_viewer_readonly == 1),
  edit_warn = 256 * 1024 * 1024, -- bytes of edit text held in memory before a warning
  edit_max = 1024 * 1024 * 1024, -- bytes of edit text held in memory before edits are refused
  -- how a save is written: "auto" picks the cheapest safe way, "atomic" always writes a full copy
  -- and renames it, "inplace" patches the file where it is (behind a journal), "reflink" clones the
  -- file and writes the changes
  save_strategy = "auto",
  follow_ms = 500, -- how often follow mode polls the file size
  min_bytes = 256 * 1024 * 1024, -- floor of the size at which a file opens in the viewer
  cgroup_root = "/sys/fs/cgroup", -- where the memory limit of the process's cgroup is read
  proc_cgroup = "/proc/self/cgroup",
}

local NS = vim.api.nvim_create_namespace("streamview")
local ELLIPSIS = "\226\128\166"
local NUL_SYMBOL = "\226\144\128"

---------------------------------------------------------------------------------------------------
-- Reader: block-cached random access, line boundaries found by scanning
---------------------------------------------------------------------------------------------------

local Reader = {}
Reader.__index = Reader

local function file_pieces(size)
  return size > 0 and { { off = 0, len = size } } or {}
end

local function mtime_of(st) return st.mtime.sec * 1e9 + st.mtime.nsec end

function M.open_reader(path)
  local fd, err = uv.fs_open(path, "r", 0)
  if not fd then return nil, err end
  local st = uv.fs_fstat(fd)
  if not st or st.type ~= "file" then
    uv.fs_close(fd)
    return nil, path .. ": not a regular file"
  end
  return setmetatable({
    fd = fd,
    path = path,
    stat = st, -- of the file as opened; a save compares it to the file on disk
    file_size = st.size,
    size = st.size, -- logical size: the file with the edits applied
    mtime = mtime_of(st),
    bs = M.opts.block,
    cache = {}, -- most recent first: { index, data }
    free = {}, -- stretches known to hold no "\n" (see streamview_nav)
    lidx = { { off = 0, line = 1 } }, -- checkpoints of the line index
    gen = 0, -- changes with every edit, so a scan that outlives one can tell
    -- The logical file is these pieces in order. A piece is bytes of the file ({ off, len }) or of
    -- an edit's text ({ str, off, len }); unedited regions are never copied into memory.
    pieces = file_pieces(st.size),
    starts = { 0 }, -- logical offset of each piece
    log = {}, -- applied edits, then undone ones: { at, ops = { { i, old, new } } }
    log_pos = 0,
    added = 0, -- bytes of edit text held
  }, Reader)
end

function Reader:close()
  if self.fd then uv.fs_close(self.fd) end
  self.fd, self.cache = nil, {}
end

-- A private copy of the reader as it is now, for a job that outlives the next edit. The pieces are
-- never changed in place, so copying the lists is enough; the file is re-opened for its own fd.
function Reader:snapshot()
  local fd, err = uv.fs_open("/proc/self/fd/" .. self.fd, "r", 0)
  if not fd then return nil, err end
  local snap = setmetatable({}, Reader)
  for k, v in pairs(self) do
    snap[k] = v
  end
  snap.fd = fd
  snap.pieces, snap.starts = { unpack(self.pieces) }, { unpack(self.starts) }
  snap.cache, snap.free, snap.log, snap.log_pos = {}, {}, {}, 0
  snap.lidx = { { off = 0, line = 1 } }
  return snap
end

-- True when no edit is applied, so the logical file is the file on disk.
function Reader:pristine() return self.log_pos == 0 end

-- Compares the file on disk with the one that was opened.
function Reader:changed_on_disk()
  local st = uv.fs_stat(self.path)
  if not st then return true end
  return st.size ~= self.stat.size or mtime_of(st) ~= self.mtime or st.ino ~= self.stat.ino or st.dev ~= self.stat.dev
end

function Reader:rebuild()
  local pos = 0
  for i, piece in ipairs(self.pieces) do
    self.starts[i] = pos
    pos = pos + piece.len
  end
  for i = #self.pieces + 1, #self.starts do
    self.starts[i] = nil
  end
  self.size = pos
  self.cache = {}
  self.free = {}
  self.lidx, self.nlines, self.lidx_loaded = { { off = 0, line = 1 } }, nil, true
  self.gen = (self.gen or 0) + 1
end

-- Follows the file as it grows: appended bytes become a piece after the logical end, so edits made
-- so far, and the ones that can still be redone, stay valid. A file changed any other way cannot be
-- followed while there are edits; it is then reported by changed_on_disk and left alone.
function Reader:refresh()
  local st = self.fd and uv.fs_fstat(self.fd)
  if not st then return self.size end
  local mtime = mtime_of(st)
  if st.size == self.file_size and mtime == self.mtime then return self.size end
  local clean = self:pristine() and #self.log == 0
  if st.size > self.file_size and not clean then
    self.pieces[#self.pieces + 1] = { off = self.file_size, len = st.size - self.file_size }
  elseif clean then
    self.pieces = file_pieces(st.size)
  else
    return self.size
  end
  self.file_size, self.mtime, self.stat = st.size, mtime, st
  self:rebuild()
  return self.size
end

-- Index of the piece holding logical offset `pos` and the offset inside it; #pieces + 1 at the end.
function Reader:locate(pos)
  local lo, hi = 1, #self.pieces
  if pos >= self.size then return #self.pieces + 1, 0 end
  while lo < hi do
    local mid = math.ceil((lo + hi) / 2)
    if self.starts[mid] <= pos then lo = mid else hi = mid - 1 end
  end
  return lo, pos - self.starts[lo]
end

local function sub_piece(piece, from, len)
  return { str = piece.str, off = piece.off + from, len = len }
end

local function splice(self, at, count, list)
  local pieces = self.pieces
  local tail = {}
  for i = at + count, #pieces do
    tail[#tail + 1] = pieces[i]
  end
  for i = at, #pieces do
    pieces[i] = nil
  end
  for _, piece in ipairs(list) do
    pieces[#pieces + 1] = piece
  end
  for _, piece in ipairs(tail) do
    pieces[#pieces + 1] = piece
  end
  self:rebuild()
end

-- Replaces logical bytes [start, stop) by `text`. Returns an op that undo_op reverses: the pieces
-- the change touched are kept whole, so ops undo in reverse order whatever was split since.
function Reader:replace(start, stop, text)
  local a, a_off = self:locate(start)
  local b, b_off = self:locate(stop)
  local last = b_off > 0 and b or b - 1
  local old = {}
  for i = a, last do
    old[#old + 1] = self.pieces[i]
  end
  local new = {}
  if a_off > 0 then new[#new + 1] = sub_piece(self.pieces[a], 0, a_off) end
  if text ~= "" then new[#new + 1] = { str = text, off = 0, len = #text } end
  if b_off > 0 then new[#new + 1] = sub_piece(self.pieces[b], b_off, self.pieces[b].len - b_off) end
  splice(self, a, #old, new)
  self.added = self.added + #text
  return { i = a, old = old, new = new, added = #text }
end

-- `added` counts the edit text of the edits that are applied, so an undone edit no longer counts
function Reader:undo_op(op)
  splice(self, op.i, #op.new, op.old)
  self.added = self.added - op.added
end

function Reader:redo_op(op)
  splice(self, op.i, #op.old, op.new)
  self.added = self.added + op.added
end

-- Applies edits ({ start, stop, text }, in descending offset order so none shifts another) as one
-- undoable step. Returns the logical offset of the first change.
function Reader:apply(edits)
  local group = { ops = {}, at = math.huge }
  for _, e in ipairs(edits) do
    group.ops[#group.ops + 1] = self:replace(e.start, e.stop, e.text)
    group.at = math.min(group.at, e.start)
  end
  for i = #self.log, self.log_pos + 1, -1 do
    self.log[i] = nil
  end
  self.log[#self.log + 1] = group
  self.log_pos = #self.log
  return group.at
end

-- Each returns the offset to show, or nil when there is nothing to undo or redo.
function Reader:undo()
  local group = self.log[self.log_pos]
  if not group then return nil end
  for i = #group.ops, 1, -1 do
    self:undo_op(group.ops[i])
  end
  self.log_pos = self.log_pos - 1
  return group.at
end

function Reader:redo()
  local group = self.log[self.log_pos + 1]
  if not group then return nil end
  for _, op in ipairs(group.ops) do
    self:redo_op(op)
  end
  self.log_pos = self.log_pos + 1
  return group.at
end

-- Reads the logical bytes [lo, hi) from the pieces (fewer if the file turns out shorter).
function Reader:raw(lo, hi)
  hi = math.min(self.size, hi)
  if hi <= lo or not self.fd then return "" end
  local pieces = self.pieces
  if #pieces == 1 and not pieces[1].str then return uv.fs_read(self.fd, hi - lo, pieces[1].off + lo) or "" end
  local parts, pos = {}, lo
  local i = self:locate(lo)
  while pos < hi do
    local piece, start = pieces[i], self.starts[i]
    local take = math.min(hi, start + piece.len) - pos
    local from = piece.off + pos - start
    local data
    if piece.str then
      data = piece.str:sub(from + 1, from + take)
    else
      data = uv.fs_read(self.fd, take, from) or ""
    end
    parts[#parts + 1] = data
    if #data < take then break end
    pos = pos + take
    i = i + 1
  end
  return table.concat(parts)
end

function Reader:load(index)
  return self:raw(index * self.bs, index * self.bs + self.bs)
end

function Reader:block(index)
  for i, hit in ipairs(self.cache) do
    if hit[1] == index then
      if i > 1 then table.insert(self.cache, 1, table.remove(self.cache, i)) end
      return hit[2]
    end
  end
  local data = self:load(index)
  table.insert(self.cache, 1, { index, data })
  self.cache[3] = nil
  return data
end

function Reader:get(off, len)
  len = math.min(len, self.size - off)
  if len <= 0 then return "" end
  if len > self.bs then return self:raw(off, off + len) end
  local parts, pos, stop = {}, off, off + len
  while pos < stop do
    local index = math.floor(pos / self.bs)
    local base = index * self.bs
    local data = self:block(index)
    if data == "" then break end
    parts[#parts + 1] = data:sub(pos - base + 1, stop - base)
    if #data < self.bs then break end
    pos = base + self.bs
  end
  return table.concat(parts)
end

-- Offset of the first "\n" in [from, limit), or nil.
function Reader:find_nl(from, limit)
  local pos = from
  while pos < limit do
    local index = math.floor(pos / self.bs)
    local base = index * self.bs
    local data = self:block(index)
    local last = math.min(#data, limit - base)
    if last < pos - base + 1 then return nil end
    local i = data:find("\n", pos - base + 1, true)
    if i and i <= last then return base + i - 1 end
    pos = base + self.bs
  end
end

-- Offset of the last "\n" in [low, before), or nil.
function Reader:find_nl_back(before, low)
  local hi = before
  while hi > low do
    local index = math.floor((hi - 1) / self.bs)
    local base = index * self.bs
    local data = self:block(index)
    local from_rel = math.max(low - base, 0) + 1
    local to_rel = math.min(hi - base, #data)
    if to_rel >= from_rel then
      local i = data:sub(from_rel, to_rel):reverse():find("\n", 1, true)
      if i then return base + to_rel - i end
    end
    hi = base
  end
end

local Nav = require("streamview_nav")
Nav.setup(M.opts)
Nav.install(Reader)
Nav.install_lines(Reader)

local function human(n)
  local units = { "B", "KiB", "MiB", "GiB", "TiB", "PiB" }
  local i = 1
  while n >= 1024 and i < #units do
    n, i = n / 1024, i + 1
  end
  return i == 1 and string.format("%d B", n) or string.format("%.1f %s", n, units[i])
end

---------------------------------------------------------------------------------------------------
-- Viewer
---------------------------------------------------------------------------------------------------

local states = {} -- buffer -> state

function M.state(buf) return states[buf or vim.api.nvim_get_current_buf()] end

local function win_of(S)
  local win = vim.fn.bufwinid(S.buf)
  return win ~= -1 and win or nil
end

local function height_of(S)
  local win = win_of(S)
  return win and vim.api.nvim_win_get_height(win) or math.max(vim.o.lines - 3, 1)
end

local function stop_bg(S)
  if S.bg then S.bg.cancelled = true end
  S.bg = nil
end

-- Rows of the window from S.offset: each a line, or the part of it that is in the buffer.
-- row: off/e/term/nxt describe the line (e is nil while its end is not found), from/to the bytes
-- in the buffer, lopen/ropen whether the line goes on before/after them.
local function compose(S)
  local r = S.r
  local size = r.size
  local rows, pos = {}, S.offset
  local h = height_of(S)
  local so = { budget = M.opts.sync_scan }
  local slice = M.opts.slice
  local over = slice * h > M.opts.window_budget
  S.row = math.max(1, S.row)
  while #rows < h and pos < size do
    local row = { off = pos, e = r:line_end(pos, so) }
    rows[#rows + 1] = row
    local cursor_row = #rows == S.row
    local cap = (cursor_row or not over) and slice or math.min(slice, M.opts.head)
    local from = row.off
    if cursor_row and S.slice_rel > 0 then
      from = r:align_down(row.off + math.min(S.slice_rel, (row.e or size) - row.off))
    end
    -- a line too long to scan whole can still end near the slice
    if not row.e and from > row.off then row.e = r:line_end(from, { budget = cap + r.bs }) end
    local limit = row.e or size
    local to = math.min(from + cap, limit)
    if to < limit then to = math.max(r:align_down(to), math.min(from + 1, limit)) end
    row.from, row.to = from, to
    row.lopen, row.ropen = from > row.off, row.e == nil or to < row.e
    if not row.e then break end
    row.term = row.e < size
    row.nxt = row.term and row.e + 1 or size
    pos = row.nxt
  end
  S.row = math.min(S.row, math.max(#rows, 1))
  return rows
end

-- Finds the end of a line that is too long to scan while drawing, a bit at a time in the background,
-- so that it is known (and the rows after it can be drawn) soon after.
local function start_bg(S, row, redraw)
  if S.bg and S.bg.off == row.off then return end
  stop_bg(S)
  local job = { off = row.off }
  S.bg = job
  local r, gen = S.r, S.r.gen
  local co = coroutine.create(function()
    return r:line_end(row.off, {
      tick = function()
        if uv.hrtime() > job.deadline then coroutine.yield() end
      end,
    })
  end)
  local function step()
    if job.cancelled or S.closed or r ~= S.r or r.gen ~= gen then return end
    job.deadline = uv.hrtime() + 5e6
    local ok, e = coroutine.resume(co)
    if ok and coroutine.status(co) ~= "dead" then return vim.defer_fn(step, 5) end
    S.bg = nil
    if ok and e then redraw(S) end
  end
  vim.defer_fn(step, 1)
end

local function draw(S)
  S.r:refresh()
  S.slice_rel, S.col = S.slice_rel or 0, S.col or 0
  local rows = compose(S)
  S.entries = rows
  local lines, cr, eols = {}, {}, {}
  for i, row in ipairs(rows) do
    local text = S.r:raw(row.from, row.to)
    if not row.ropen and row.term and text:sub(-1) == "\r" then text, cr[i] = text:sub(1, -2), true end
    lines[i] = text
    eols[i] = row.ropen and "" or (row.term and (cr[i] and "\r\n" or "\n") or "")
  end
  if #lines == 0 then lines[1] = "" end
  S.shown, S.eol = lines, eols

  -- Setting the lines is not an edit: drop the buffer's own undo history with it
  vim.bo[S.buf].undolevels = -1
  vim.bo[S.buf].modifiable = true
  vim.api.nvim_buf_set_lines(S.buf, 0, -1, false, lines)
  vim.bo[S.buf].modifiable = S.editable
  vim.bo[S.buf].undolevels = S.editable and 1000 or -1
  vim.bo[S.buf].modified = S.r.log_pos > 0
  S.tick = vim.b[S.buf].changedtick

  vim.api.nvim_buf_clear_namespace(S.buf, NS, 0, -1)
  local m = S.match
  if m then
    for i, row in ipairs(rows) do
      local col = m.pos - row.from
      if m.pos >= row.from and m.pos < row.to then
        vim.api.nvim_buf_set_extmark(S.buf, NS, i - 1, col, {
          end_col = math.min(col + m.len, #lines[i]),
          hl_group = "Search",
        })
      end
    end
  end

  if S.goal_abs and rows[S.row] then
    S.col = S.goal_abs - rows[S.row].from
    S.goal_abs = nil
  end
  local win = win_of(S)
  if win then
    local line = lines[S.row] or ""
    vim.api.nvim_win_set_cursor(win, { S.row, math.max(0, math.min(S.col, #line - 1)) })
    vim.cmd.redrawstatus()
  end
  -- the number of the first line: exact when a checkpoint is near, else estimated from the lines shown
  if S.line_for ~= S.offset or S.line_gen ~= S.r.gen then
    S.line_for, S.line_gen = S.offset, S.r.gen
    S.line_top = S.r:line_number(S.offset, { budget = 1024 * 1024 })
    S.line_exact = S.line_top ~= nil
    if not S.line_top then
      local sum, count = 0, 0
      for _, row in ipairs(rows) do
        if row.nxt then
          sum, count = sum + (row.nxt - row.off), count + 1
        end
      end
      if count > 0 and sum > 0 then S.line_top = math.floor(S.offset / (sum / count)) + 1 end
    end
  end
  local last = rows[#rows]
  if last and not last.e then
    start_bg(S, last, function(again)
      -- the end was found: draw the rows that follow, if nothing is being typed
      if again.closed or again.job or vim.api.nvim_get_mode().mode:find("^[iR]") then return end
      if again.tick == vim.b[again.buf].changedtick or not again.editable then draw(again) end
    end)
  else
    stop_bg(S)
  end
end

---------------------------------------------------------------------------------------------------
-- Editing: the window's lines are diffed against what was shown and become piece table edits
---------------------------------------------------------------------------------------------------

local function saving(S) return S.saving == true end

local function sync_row(S)
  local win = win_of(S)
  if win then
    local cur = vim.api.nvim_win_get_cursor(win)
    S.row, S.col = cur[1], cur[2]
  end
end

local function joined(lines)
  return #lines == 0 and "" or table.concat(lines, "\n") .. "\n"
end

local function raw_end(row) return row.ropen and row.to or row.nxt end

-- Piece table edits for the lines in the buffer, or nil and the reason they cannot be made.
-- A row is a line, or the part of it that is in the buffer (a slice of a long line): replacing a
-- slice replaces just its bytes, with no line ending added. Every whole line keeps its own ending
-- (LF, CRLF, none at the end of the file). A line added, or replacing more lines than there were,
-- takes the ending of the nearest terminated line above it, else below, else the line just above
-- the window, else LF.
local function pending_edits(S, cur)
  local ents, r = S.entries, S.r
  if #ents == 0 then
    if #cur == 1 and cur[1] == "" then return {} end
    return { { start = 0, stop = 0, text = joined(cur) } }
  end
  -- Deleting every line leaves Neovim one empty line, which is not a line to add (unless it could
  -- as well be one of the empty lines that were shown, or the only line was emptied)
  if #cur == 1 and cur[1] == "" and #S.shown > 1 then
    local all_text = true
    for _, l in ipairs(S.shown) do
      all_text = all_text and l ~= ""
    end
    if all_text then cur = {} end
  end
  local hunks = vim.diff(joined(S.shown), joined(cur), { result_type = "indices" })
  local eol = S.eol
  local function neighbor(i)
    for k = math.min(i, #ents), 1, -1 do
      if eol[k] ~= "" then return eol[k] end
    end
    for k = i + 1, #ents do
      if eol[k] ~= "" then return eol[k] end
    end
    -- nothing terminated in the window: the line just above it
    local top = ents[1].off
    local above = top > 0 and r:get(math.max(0, top - 2), math.min(2, top)) or ""
    return above == "\r\n" and "\r\n" or "\n"
  end
  local last = ents[#ents]
  local no_final_newline = not last.ropen and not last.term
  local edits = {}
  for h = #hunks, 1, -1 do
    local sa, ca, sb, cb = unpack(hunks[h])
    local start, stop
    if ca > 0 then
      start, stop = ents[sa].from, raw_end(ents[sa + ca - 1])
    elseif sa == 0 then
      start = ents[1].from
      stop = start
      if ents[1].lopen then return nil, "a line cannot be added inside a long line" end
    else
      start = raw_end(ents[sa])
      stop = start
      if ents[sa].ropen then return nil, "a line cannot be added inside a long line" end
    end
    local at_end = no_final_newline and stop >= r.size
    local raw_tail = ca > 0 and ents[sa + ca - 1].ropen
    local text = ""
    for k = 1, cb do
      local e = k <= ca and eol[sa + k - 1] or nil
      if k == cb and (at_end or raw_tail) then
        e = ""
      elseif e == nil or e == "" then
        e = neighbor(ca > 0 and sa or math.max(sa, 1))
      end
      text = text .. cur[sb + k - 1] .. e
    end
    if ca == 0 and at_end and cb > 0 then text = neighbor(sa) .. text end
    if cb == 0 and at_end and start > 0 and not ents[sa].lopen then
      -- the file did not end with a newline and must not start to: the line before loses its ending
      local before = r:get(math.max(0, start - 2), math.min(2, start))
      start = start - (before == "\r\n" and 2 or before:sub(-1) == "\n" and 1 or 0)
    end
    edits[#edits + 1] = { start = start, stop = stop, text = text }
  end
  return edits
end

local function window_lines(S) return vim.api.nvim_buf_get_lines(S.buf, 0, -1, false) end

local function is_pending(S)
  if not S.editable or S.shown == nil then return false end
  if S.tick == vim.b[S.buf].changedtick then return false end -- nothing changed since it was drawn
  return not vim.deep_equal(window_lines(S), S.shown)
end

-- Turns the changes made in the window into one undoable edit. Returns true when the window
-- must be drawn again (an edit was made, or a change was discarded).
local function apply_pending(S)
  if not is_pending(S) then return false end
  local edits, err = pending_edits(S, window_lines(S))
  if edits then
    local bytes = 0
    for _, e in ipairs(edits) do
      bytes = bytes + #e.text
    end
    if S.r.added + bytes > M.opts.edit_max then
      err = string.format("more than %s of edits are held in memory, save first", human(M.opts.edit_max))
    end
  end
  if err then
    vim.notify("Stream view: " .. err .. "; the change was discarded", vim.log.levels.ERROR)
    return true
  end
  if #edits == 0 then return false end
  S.r:apply(edits)
  S.match = nil
  if S.r.added >= M.opts.edit_warn and not S.warned then
    S.warned = true
    vim.notify(string.format("Stream view: %s of edits are held in memory, save soon", human(S.r.added)), vim.log.levels.WARN)
  end
  return true
end

-- While a save streams the snapshot out, the text the user sees must not change under it.
local function refuse_while_saving(S)
  if S.saving then
    error({ blocked = "Stream view: a save is running; wait for it or press <C-c> to cancel it" }, 0)
  end
end

-- Wraps an entry point of the user (a key, a command): a refusal to act during a save becomes a
-- message, any other error is raised as it is.
local function guarded(fn)
  return function(...)
    local ok, err = pcall(fn, ...)
    if ok then return end
    if type(err) ~= "table" or not err.blocked then error(err, 0) end
    vim.notify(err.blocked, vim.log.levels.WARN)
  end
end

function M.render(S)
  if S.saving then return end
  apply_pending(S)
  draw(S)
end

-- Runs first in every movement: the edits made in the window must be in the piece table before
-- offsets are computed from it.
local function before_move(S)
  refuse_while_saving(S)
  sync_row(S)
  if apply_pending(S) then draw(S) end
  return true
end

-- Keeps the modified flag right and takes back an edit to a line that is not shown whole.
local function check_pending(S)
  if not S.editable or S.closed then return end
  if is_pending(S) then
    local edits, err = pending_edits(S, window_lines(S))
    if not edits then
      pcall(vim.cmd, "silent undo")
      if not pending_edits(S, window_lines(S)) and not saving(S) then draw(S) end
      vim.notify("Stream view: " .. err .. "; the change was undone", vim.log.levels.ERROR)
    end
  end
  vim.bo[S.buf].modified = is_pending(S) or S.r.log_pos > 0
end

-- Shows the window at a logical offset, e.g. where an undo changed the text.
local function show_at(S, at)
  M.goto_abs(S, at)
end

-- Undo first takes back what is typed in the window, then the edits made earlier wherever they are.
function M.undo(S)
  refuse_while_saving(S)
  sync_row(S)
  if is_pending(S) then
    pcall(vim.cmd, "silent undo")
    return check_pending(S)
  end
  local at = S.r:undo()
  if not at then return vim.notify("Already at the oldest change", vim.log.levels.INFO) end
  show_at(S, at)
end

function M.redo(S)
  refuse_while_saving(S)
  sync_row(S)
  local tree = vim.api.nvim_buf_call(S.buf, vim.fn.undotree)
  if tree.seq_cur < tree.seq_last then
    pcall(vim.cmd, "silent redo")
    return check_pending(S)
  end
  local at = S.r:redo()
  if not at then return vim.notify("Already at the newest change", vim.log.levels.INFO) end
  show_at(S, at)
end

local function stop_follow(S)
  if not S.follow then return end
  S.follow:stop()
  S.follow:close()
  S.follow, S.follow_paused = nil, nil
  vim.cmd.redrawstatus()
end

-- True while the user types into the viewer's buffer (Insert or Replace mode, also from i_CTRL-O, or
-- the command line): replacing its lines then would eat what is being typed. A prompt such as
-- hit-enter ("r?") does not count: nothing is being typed into the buffer.
local function typing(S)
  if vim.api.nvim_get_current_buf() ~= S.buf then return false end
  local mode = vim.api.nvim_get_mode().mode
  return mode:find("^[iRc]") ~= nil or mode:find("^ni") ~= nil
end

-- Like tail -F: a file that was replaced (log rotation) or truncated is read again from its start.
-- Returns true when the reader was replaced. A file that is gone is waited for. With edits the
-- window cannot move to the new file without losing them, so follow stops and says so.
local function follow_rotated(S)
  local st = uv.fs_stat(S.path)
  if not st or st.type ~= "file" then return false end
  local r = S.r
  local replaced = st.ino ~= r.stat.ino or st.dev ~= r.stat.dev
  if not replaced and st.size >= r.file_size then return false end
  local what = replaced and "was replaced" or "was truncated"
  if not r:pristine() then
    stop_follow(S)
    vim.notify(
      string.format("Stream view: %s %s on disk; your edits are kept, so follow stopped (save with ! to overwrite, or :edit! to reload)", S.path, what),
      vim.log.levels.WARN
    )
    return false
  end
  local nr = M.open_reader(S.path)
  if not nr then return false end -- raced with another rotation: try again on the next poll
  r:close()
  S.r, S.offset, S.row, S.slice_rel, S.col, S.match, S.line_for = nr, 0, 1, 0, 0, nil, nil
  vim.notify(string.format("Stream view: %s %s on disk; reading it again from the start", S.path, what), vim.log.levels.INFO)
  return true
end

-- Like tail -f: polls the size and keeps the end of the file in view. Any other movement stops it.
-- The window is only redrawn when nothing is being typed, no typed change waits to be applied and no
-- save is running; until then the update is held back and the next poll tries again.
function M.toggle_follow(S, on)
  if on == nil then on = not S.follow end
  if not on then return stop_follow(S) end
  if S.follow then return end
  M.tail(S) -- also puts pending edits in the piece table
  local last = S.r.size
  local timer = assert(uv.new_timer())
  S.follow = timer
  timer:start(
    M.opts.follow_ms,
    M.opts.follow_ms,
    vim.schedule_wrap(function()
      if S.closed or S.follow ~= timer then return end
      S.follow_paused = typing(S) or is_pending(S) or saving(S)
      if S.follow_paused then return end
      local rotated = follow_rotated(S)
      if S.follow ~= timer then return end
      local size = S.r:refresh()
      if rotated or size ~= last then
        last = size
        M.tail(S)
      end
    end)
  )
  vim.cmd.redrawstatus()
end

function M.lines(S) return vim.api.nvim_buf_get_lines(S.buf, 0, -1, false) end

local function grouped(n)
  local s = string.format("%d", n)
  return (s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

function M.winbar()
  local winid = vim.g.statusline_winid or 0
  if not vim.api.nvim_win_is_valid(winid) then return "" end
  local S = states[vim.api.nvim_win_get_buf(winid)]
  if not S then return "" end
  local size = S.r.size
  local row = S.entries[vim.api.nvim_win_get_cursor(winid)[1]]
  local abs = row and row.from + vim.api.nvim_win_get_cursor(winid)[2] or S.offset
  local parts = {
    " STREAM",
    vim.fn.fnamemodify(S.path, ":t"):gsub("%%", "%%%%"),
    string.format("%s / %s (%s)", grouped(abs), grouped(size), human(size)),
    string.format("%.1f%%", size > 0 and abs / size * 100 or 100),
  }
  if S.line_top then
    local at = vim.api.nvim_win_get_cursor(winid)[1]
    parts[#parts + 1] = string.format("%sline %s", S.line_exact and "" or "~", grouped(S.line_top + at - 1))
  end
  if vim.bo[S.buf].modified then parts[#parts + 1] = "[+]" end
  if row and (row.lopen or row.ropen) then
    -- inside a line too long for the buffer: where in the line the cursor is
    local col = abs - row.off
    if row.e then
      local len = row.e - row.off
      parts[#parts + 1] = string.format("col %s / %s (%d%%)", grouped(col), grouped(len), len > 0 and col / len * 100 or 100)
    else
      parts[#parts + 1] = string.format("col %s / ?", grouped(col))
    end
  end
  if S.follow then parts[#parts + 1] = S.follow_paused and "FOLLOW (paused)" or "FOLLOW" end
  local job = S.job
  if job then
    local pct = job.span > 0 and job.done_bytes / job.span * 100 or 100
    local elapsed = job.started and string.format(" %.1fs", (uv.hrtime() - job.started) / 1e9) or ""
    parts[#parts + 1] = string.format("%s %d%%%s (<C-c> cancels)", job.label, pct, elapsed)
  end
  return table.concat(parts, "  ")
end

---------------------------------------------------------------------------------------------------
-- Search: literal text, scanned block by block from the cursor line
---------------------------------------------------------------------------------------------------

function M.cancel(S)
  local job = S.job
  if not job then return end
  job.cancelled = true
  S.job = nil
  if job.kill then job.kill() end
  vim.cmd.redrawstatus()
  if job.done then job.done(nil, "cancelled") end
end

local SLICE_NS = 10e6

-- Runs fn(tick) in slices of about 10 ms so the editor stays responsive. fn calls tick(bytes_done)
-- as it goes and returns its result; done(result, err) runs once, also on cancel.
local function run_job(S, label, span, fn, done, exclusive)
  M.cancel(S)
  local job = { label = label, span = span, done_bytes = 0, done = done, exclusive = exclusive }
  S.job = job
  local co = coroutine.create(function()
    return fn(function(bytes_done)
      job.done_bytes = bytes_done
      if uv.hrtime() > job.deadline then coroutine.yield() end
    end)
  end)

  local function finish(result, err)
    S.job = nil
    vim.cmd.redrawstatus()
    if done then done(result, err) end
  end

  local function step()
    if job.cancelled then return end
    if S.closed then
      -- the buffer is gone: let the job clean up (temp files, fds) instead of leaving them
      S.job = nil
      if done then done(nil, "the viewer was closed") end
      return
    end
    job.deadline = uv.hrtime() + SLICE_NS
    local ok, result, err = coroutine.resume(co)
    if not ok then
      finish(nil, tostring(result))
    elseif coroutine.status(co) == "dead" then
      finish(result, err)
    else
      vim.cmd.redrawstatus()
      vim.defer_fn(step, 1)
    end
  end
  step()
end

-- Scans from the cursor line (past the current match, if it is there); `done(pos, err)` is called
-- when the scan ends. The match line becomes the first line of the window.
local Search = require("streamview_search")
M.search_engine = Search

-- Searches with the streamsearch helper, a process that reads the file on disk in parallel with an
-- index: the first match it prints is shown at once, and the process is stopped.
local function search_with_helper(S, plan, cmd, abs, origin, forward, found, done)
  local r = S.r
  local job = {
    label = "searching (streamsearch)",
    span = r.size,
    done_bytes = 0,
    exclusive = true,
    started = uv.hrtime(),
  }
  local matched = false
  local finished = false
  local function finish(pos, err)
    if finished then return end
    finished = true
    if S.job == job then S.job = nil end
    vim.cmd.redrawstatus()
    if pos then
      found(pos[1], pos[2])
    elseif done then
      done(nil, err)
    end
  end
  job.done = function(_, err) finish(nil, err) end
  S.job = job
  local argv = Search.helper_argv(cmd, plan, r.path, origin, forward)
  local handle = Search.run_helper(argv, {
    on_match = function(start, stop)
      -- going back, a match at the cursor or after it is not wanted; the helper goes on to the next
      if not forward and start >= abs then return false end
      matched = true
      vim.schedule(function() finish({ start, stop - start }) end)
      return true
    end,
    on_progress = function(scanned, total)
      job.done_bytes, job.span = scanned, total or job.span
      vim.schedule(function() vim.cmd.redrawstatus() end)
    end,
    on_exit = function(code, errtext)
      vim.schedule(function()
        if matched or finished then return end
        if code == 1 then
          finish(nil, nil)
        else
          finish(nil, "streamsearch failed: " .. (errtext ~= "" and errtext or ("exit code " .. tostring(code))))
        end
      end)
    end,
  })
  job.kill = handle.kill
end

-- Searches from the cursor for literal text or a Vim regex ('ignorecase' and 'smartcase' count; a
-- regex that is not valid is an error). done(pos, err) is called when the search ends: pos is nil with
-- no err when nothing matched. The match line becomes the first line of the window, the cursor is on
-- the match and, in a line too long for the buffer, the slice slides to it.
function M.search(S, pat, forward, done)
  before_move(S)
  M.cancel(S)
  stop_follow(S)
  if pat == "" then
    if done then done(nil, "the pattern is empty") end
    return
  end
  local plan, perr = Search.plan(pat)
  if not plan then
    if done then done(nil, perr) end
    return
  end
  S.r:refresh()
  sync_row(S)
  local abs = M.cursor_abs(S)
  local origin = forward and abs + 1 or abs
  S.last_search = { pat = pat, forward = forward }
  local function found(pos, len)
    M.goto_abs(S, pos, { pos = pos, len = len }, function()
      if done then done(pos, nil) end
    end)
  end

  local r = S.r
  local cmd = Search.helper()
  if cmd and plan.external and r:pristine() and #r.log == 0 and r.size == r.file_size and not r:changed_on_disk() then
    return search_with_helper(S, plan, cmd, abs, origin, forward, found, done)
  end
  if cmd and not plan.external then
    vim.notify("Stream view: " .. plan.untranslatable .. "; searching with the slower engine", vim.log.levels.INFO)
  end
  run_job(S, "searching", forward and r.size - origin or origin, function(tick)
    return Search.lua_scan(r, plan, origin, forward, function(pos) tick(math.abs(pos - origin)) end)
  end, function(pos, len)
    if pos then
      found(pos, len)
    elseif done then
      done(nil, type(len) == "string" and len or nil)
    end
  end, true)
end



---------------------------------------------------------------------------------------------------
-- Movement. Offsets are absolute: the cursor is at a byte of the file, the buffer holds a slice of
-- its line, and the slice slides when the cursor comes near an edge that is not the line's own.
---------------------------------------------------------------------------------------------------

-- Runs a movement as a coroutine, so that it can wait for a scan that is too long to be done at once.
local function nav(S, body)
  local co = coroutine.create(body)
  local ok, err = coroutine.resume(co)
  if not ok and type(err) == "table" and err.blocked then error(err, 0) end
  if not ok then vim.notify("Stream view: " .. tostring(err), vim.log.levels.ERROR) end
end

-- Scans with fn(so): at once if that is quick, else as a job with progress that the calling
-- coroutine waits for. Returns the result, or nil and why (a cancel, a short read).
local function wait_scan(S, label, span, fn)
  local res, why = fn({ budget = M.opts.sync_scan })
  if res ~= nil or why ~= "budget" then return res, why end
  local co = coroutine.running()
  local waiting, finished, r1, r2 = false, false, nil, nil
  run_job(S, label, span, function(tick) return fn({ tick = tick }) end, function(result, err)
    if waiting then
      local ok, e = coroutine.resume(co, result, err)
      if not ok then vim.notify("Stream view: " .. tostring(e), vim.log.levels.ERROR) end
    else
      finished, r1, r2 = true, result, err
    end
  end, true)
  if finished then return r1, r2 end
  waiting = true
  return coroutine.yield()
end

local function cursor_col(S)
  local win = win_of(S)
  return win and vim.api.nvim_win_get_cursor(win)[2] or S.col or 0
end

-- The byte of the file the cursor is on
function M.cursor_abs(S)
  local row = S.entries[S.row]
  if not row then return 0 end
  return row.from + cursor_col(S)
end

-- How far into its line the slice of a row starts for a cursor at `abs`
local function slice_rel_for(line_start, abs)
  local slice = M.opts.slice
  local margin = math.min(slice * M.opts.slice_hyst, slice / 2 - 1)
  local d = abs - line_start
  if d + margin < slice then return 0 end
  return math.max(0, math.floor(d - slice / 2))
end

-- Shows the file at byte `abs`, on the first row, and puts the cursor on it. match: { pos, len } to
-- highlight. after() runs when the move is done (it may wait for a scan to the start of the line).
function M.goto_abs(S, abs, match, after)
  nav(S, function()
    local function finish() if after then after() end end
    if not before_move(S) then return finish() end
    stop_follow(S)
    local r = S.r
    local size = r:refresh()
    abs = r:align_down(math.max(0, math.min(abs, math.max(size - 1, 0))))
    local ls = wait_scan(S, "finding the start of the line", abs, function(so) return r:line_start(abs, so) end)
    if not ls then return finish() end
    S.offset, S.row = ls, 1
    S.slice_rel = slice_rel_for(ls, abs)
    S.goal_abs = abs
    S.match = match
    M.render(S)
    finish()
  end)
end

-- Absolute byte offset of the cursor in the file, also inside a slice of a long line.
M.cursor_offset = M.cursor_abs

-- Puts the cursor on the byte `abs` of the file, as the first row of the window (a jump into a long
-- line slides the slice there), and waits for the scan that needs. Returns true when the cursor is
-- on that byte; false when it could not be (a refused move, a cancelled scan, or `abs` is not the
-- start of a character, so the cursor is on the character's start).
function M.place(S, abs)
  local landed = false
  M.goto_abs(S, abs, nil, function() landed = true end)
  vim.wait(600000, function() return landed and S.job == nil end, 5)
  return landed and M.cursor_abs(S) == abs
end

-- Scrolls the window n lines (down for n > 0). Beyond a few lines this counts newlines through the file
-- in big chunks, as a job with progress when it is far.
function M.scroll(S, n)
  nav(S, function()
    if not before_move(S) then return end
    stop_follow(S)
    local r = S.r
    r:refresh()
    if n > 0 then
      local to = wait_scan(S, "counting lines", r.size - S.offset, function(so) return r:lines_forward(S.offset, n, so) end)
      if not to then return end
      S.offset = to
    elseif n < 0 then
      local to = wait_scan(S, "counting lines", S.offset, function(so) return r:lines_backward(S.offset, -n, so) end)
      if not to then return end
      S.offset = to
    end
    S.slice_rel = 0
    M.render(S)
  end)
end

-- Goes to line number `line` of the file (the last one if there are fewer). The first time in a big
-- file it counts lines from the nearest checkpoint, as a job with progress; the checkpoints are
-- kept (and saved), so the next jump is quick.
function M.goto_line(S, line)
  nav(S, function()
    if not before_move(S) then return end
    stop_follow(S)
    local r = S.r
    r:refresh()
    r:index_load()
    local off, found = wait_scan(S, "counting lines", r.size, function(so) return r:line_offset(line, so) end)
    if not off then return end
    S.top_line = found
    S.offset, S.row, S.slice_rel, S.col = off, 1, 0, 0
    r:index_save()
    M.render(S)
  end)
end

-- Counts every line of the file once (a job with progress), so that the line numbers are exact
function M.build_index(S, done)
  nav(S, function()
    local r = S.r
    r:index_load()
    if r.nlines then
      r:index_save()
      if done then done(r.nlines) end
      return
    end
    local last = wait_scan(S, "counting lines", r.size, function(so)
      local off, found = r:line_offset(math.huge, so)
      return off and found
    end)
    if last then
      r:index_save()
      if done then done(last) end
    end
  end)
end

local check_slice

-- Moves the cursor; the window scrolls only when the cursor is at its edge.
function M.move(S, n)
  sync_row(S)
  local rows = vim.api.nvim_buf_line_count(S.buf)
  local row = S.row + n
  local win = win_of(S)
  if row > rows then
    if win then vim.cmd(("noautocmd normal! %dj"):format(rows - S.row)) end
    check_slice(S)
    M.scroll(S, row - rows)
  elseif row < 1 then
    if win then vim.cmd(("noautocmd normal! %dk"):format(S.row - 1)) end
    check_slice(S)
    M.scroll(S, row - 1)
  elseif win and n ~= 0 then
    vim.cmd(("noautocmd normal! %d%s"):format(math.abs(n), n > 0 and "j" or "k"))
    check_slice(S)
  end
end

function M.page(S, pages)
  M.scroll(S, pages * height_of(S))
end

-- <C-d>, <C-u>: half a window, or the last count given (which sets it for the next ones)
function M.half_page(S, dir, count)
  if count and count > 0 then S.scroll_amount = count end
  M.scroll(S, dir * (S.scroll_amount or math.max(1, math.floor(height_of(S) / 2))))
end

function M.head(S)
  nav(S, function()
    if not before_move(S) then return end
    stop_follow(S)
    S.offset, S.row, S.slice_rel, S.col = 0, 1, 0, 0
    M.render(S)
  end)
end

function M.tail(S)
  nav(S, function()
    if not before_move(S) then return end
    local r = S.r
    local size = r:refresh()
    local ls = 0
    if size > 0 then
      ls = wait_scan(S, "finding the start of the line", size, function(so) return r:line_start(size - 1, so) end)
      if not ls then return end
      for _ = 2, height_of(S) do
        if ls == 0 then break end
        local prev = wait_scan(S, "finding the start of the line", ls, function(so)
          so.nl_at_off = true
          return r:line_start(ls - 1, so)
        end)
        if not prev then return end
        ls = prev
      end
    end
    S.offset, S.row, S.slice_rel, S.col = ls, height_of(S), 0, 0
    M.render(S)
  end)
end

-- spec: a byte offset (number or "1234"), or a percentage ("60%", "12.5%")
function M.goto_offset(S, spec)
  local size = S.r:refresh()
  local target
  if type(spec) == "number" then
    target = spec
  else
    local pct = tostring(spec):match("^%s*(%d+%.?%d*)%%%s*$")
    if pct then
      target = math.floor(size * math.min(tonumber(pct), 100) / 100)
    else
      target = tonumber(spec)
    end
  end
  if not target then return nil, "expected a byte offset or a percentage, got: " .. tostring(spec) end
  M.goto_abs(S, target)
  return target
end


-- Puts the cursor on byte `abs`: in the slice if it is there, else by sliding the slice along the
-- cursor's line, else (another line) by going to it.
local function place(S, abs)
  local row = S.entries[S.row]
  local win = win_of(S)
  if not (row and win) then return end
  if abs >= row.from and (abs < row.to or (abs == row.to and not row.ropen)) then
    S.col = abs - row.from
    vim.api.nvim_win_set_cursor(win, { S.row, S.col })
    M.check_slice(S)
  elseif abs >= row.off and (row.e == nil or abs <= row.e) then
    S.goal_abs = abs
    S.slice_rel = slice_rel_for(row.off, abs)
    M.render(S)
  else
    M.goto_abs(S, abs)
  end
end

-- Where a motion from the cursor goes, waiting for a scan that takes a job: the byte, then nil and
-- why (cancelled, "fail" when there is nowhere to go), and whether an operator includes that byte.
-- op: the operator pending, if any (cw is ce).
local function motion_target(S, row, key, n, arg, op)
  local r = S.r
  local e = { r = r, pos = M.cursor_abs(S), ls = row.off }
  local function scan(label, f) return wait_scan(S, label, r.size, function(so) return f(so) end) end
  local target, why
  local inclusive = key == "e" or key == "E" or key == "ge" or key == "gE" or key == "$"
  if key == "l" then
    local steps
    target, steps = wait_scan(S, "moving right", r.size, function(so) return Nav.right(e, n, so) end)
    -- with an operator l may go one past the last character: then that one is in the range
    if target and op and steps and steps < n then inclusive = true end
  elseif key == "h" then
    target, why = scan("moving left", function(so) return Nav.left(e, n, so) end)
  elseif (key == "w" or key == "W") and op == "c" and Nav.class_at(r, e.pos) ~= "sp" and Nav.class_at(r, e.pos) ~= "nl" then
    inclusive = true
    target, why = scan("finding the end of the word", function(so) return Nav.word_end(e, n, key == "W", so, true) end)
  elseif key == "w" or key == "W" then
    target, why = scan("finding the next word", function(so) return Nav.word_forward(e, n, key == "W", so, op ~= nil) end)
  elseif key == "e" or key == "E" then
    target, why = scan("finding the end of the word", function(so) return Nav.word_end(e, n, key == "E", so) end)
  elseif key == "b" or key == "B" then
    target, why = scan("finding the start of the word", function(so) return Nav.word_back(e, n, key == "B", so) end)
  elseif key == "ge" or key == "gE" then
    target, why = scan("finding the end of the word", function(so) return Nav.word_end_back(e, n, key == "gE", so) end)
  elseif key == "0" then
    target = row.off
  elseif key == "^" then
    target, why = scan("finding the first word", function(so) return Nav.first_nonblank(e, so) end)
  elseif key == "$" then
    local ls, le = row.off, row.e
    if not le then
      le = scan("finding the end of the line", function(so) return r:line_end(ls, so) end)
      if not le then return nil, "cancelled" end
    end
    -- 3$ is the end of the line two lines down; it fails on the last line
    if n > 1 and le + 1 >= r.size then return nil, "fail" end
    for _ = 2, n do
      if le + 1 >= r.size then break end
      ls = le + 1
      le = scan("finding the end of the line", function(so) return r:line_end(ls, so) end)
      if not le then return nil, "cancelled" end
    end
    local last = le
    if le > ls and le < r.size and r:get(le - 1, 1) == "\r" then last = le - 1 end
    target = last > ls and r:align_down(last - 1) or ls
  elseif key == "|" then
    local le = row.e or scan("finding the end of the line", function(so) return r:line_end(row.off, so) end)
    if not le then return nil, "cancelled" end
    local want = row.off + n - 1
    target = want >= le and (le > row.off and r:align_down(le - 1) or row.off) or r:align_down(want)
  elseif key == "f" or key == "F" or key == "t" or key == "T" or key == ";" or key == "," then
    local last = S.last_find
    local ch, forward, till, again
    if key == ";" or key == "," then
      if not last then return nil, "fail" end
      ch, till, again = last.ch, last.till, true
      forward = (key == ";") == last.forward
    else
      ch, forward, till, again = arg, key == "f" or key == "t", key == "t" or key == "T", false
      S.last_find = { ch = ch, forward = forward, till = till }
    end
    inclusive = forward
    local miss_key = string.format("%d|%s|%s", row.off, ch, forward and "f" or "b")
    local miss = S.miss and S.miss[miss_key]
    if n == 1 and not till and miss and miss.gen == r.gen and (forward and e.pos >= miss.bound or not forward and e.pos <= miss.bound) then
      return nil, "fail"
    end
    target, why = scan("looking for a character", function(so) return Nav.find_char(e, ch, n, forward, till, again, so) end)
    if not target and why == "fail" and n == 1 and not till then
      S.miss = S.miss or {}
      S.miss[miss_key] = { gen = r.gen, bound = e.pos }
    end
  end
  return target, why, inclusive
end

-- Neovim drops the keys typed ahead when a command fails (a beep): "f]%" does not run the % when
-- there is no ] to find. The viewer's own motions do the same.
-- It stops at an <Esc>: feedkeys() with "x" keeps one at the end of what it runs.
local function flush_typeahead()
  for _ = 1, 100000 do
    local c = vim.fn.getchar(1)
    if c == 0 or c == 27 then return end
    vim.fn.getchar(0)
  end
end

local function hmove_abs(S, key, n, arg)
  nav(S, function()
    if not before_move(S) then return end
    sync_row(S)
    local row = S.entries[S.row]
    if not row then return end
    local target, why = motion_target(S, row, key, n, arg)
    if target then
      place(S, target)
    elseif why == "fail" then
      flush_typeahead()
    end
  end)
end

-- The 0 key: to the start of the cursor's line (run by the key's mapping)
function M.home()
  local S = M.state()
  if S then guarded(function() M.hmove(S, "0", 0) end)() end
end

-- Horizontal motions along the cursor's line. They work in absolute bytes, so they never stop at the
-- edge of the slice: inside the slice a plain l or h is Neovim's, anything else (or a motion that
-- reaches an edge of the slice that is not the line's own) is worked out on the file.
function M.hmove(S, key, count, arg)
  local n = math.max(count or 0, 1)
  if (key == "l" or key == "h") and not S.job then
    sync_row(S)
    local row = S.entries[S.row]
    local win = win_of(S)
    if row and win then
      local before = vim.api.nvim_win_get_cursor(win)
      vim.cmd(("noautocmd normal! %d%s"):format(n, key))
      local after = vim.api.nvim_win_get_cursor(win)
      local len = #(vim.api.nvim_buf_get_lines(S.buf, after[1] - 1, after[1], false)[1] or "")
      local at_edge = (key == "l" and row.ropen and len - after[2] <= 8) or (key == "h" and row.lopen and after[2] <= 8)
      if not at_edge then return M.check_slice(S) end
      vim.api.nvim_win_set_cursor(win, before)
    end
  end
  hmove_abs(S, key, n, arg)
end


-- Operators over a range that may lie outside the slice. d, y and c with a motion on a line that is
-- longer than the buffer hold are done on the file: the range is worked out in absolute bytes, deleted
-- from the piece table (no text is loaded for that) or copied to a register (up to opts.yank_max).
-- A register takes lines; a NUL byte is a newline inside a line there
local function set_register(text, linewise)
  local lines = vim.split(text, "\n", { plain = true })
  if linewise and lines[#lines] == "" then lines[#lines] = nil end
  for i, l in ipairs(lines) do
    lines[i] = l:gsub("%z", "\n")
  end
  vim.fn.setreg('"', lines, linewise and "V" or "v")
end

local function finish_edit(S, at, op)
  S.match = nil
  S.goal_abs = at
  local row = S.entries[S.row]
  S.slice_rel = row and slice_rel_for(row.off, at) or 0
  M.render(S)
  if op == "c" then vim.cmd.startinsert() end
end

-- Applies d, y or c to the bytes [lo, hi) of the file. linewise: they are whole lines.
local function operate(S, op, lo, hi, linewise)
  local r = S.r
  if hi <= lo then return end
  local size = hi - lo
  if op == "y" or op == "d" or op == "c" then
    if size <= M.opts.yank_max then
      set_register(r:raw(lo, hi), linewise)
    elseif op == "y" then
      return vim.notify(
        string.format("Stream view: %s is too much to yank into a register (the limit is %s); use :StreamYank", human(size), human(M.opts.yank_max)),
        vim.log.levels.ERROR
      )
    else
      vim.notify(string.format("Stream view: %s deleted; it is not in a register (too big)", human(size)), vim.log.levels.WARN)
    end
  end
  if op == "y" then
    S.match = nil
    return place(S, lo)
  end
  local keep = (linewise and op == "c") and 1 or 0 -- cc keeps the line ending of the last line
  r:apply({ { start = lo, stop = hi - keep, text = "" } })
  finish_edit(S, lo, op)
end

-- d/y/c with a horizontal motion (or the whole line: key "line")
local function far_op(S, op, key, n, arg)
  nav(S, function()
    if not before_move(S) then return end
    sync_row(S)
    local row = S.entries[S.row]
    if not row then return end
    local r = S.r
    local function scan(label, f) return wait_scan(S, label, r.size, function(so) return f(so) end) end
    local function line_bounds(from)
      local le = scan("finding the end of the line", function(so) return r:line_end(from, so) end)
      return le
    end
    if key == "line" or key == "j" or key == "k" then
      -- whole lines: the cursor's, and n - 1 more (dd), or n more below (dj) or above (dk)
      local first, last = row.off, row.e or line_bounds(row.off)
      if not last then return end
      local lines_down, lines_up = 0, 0
      if key == "line" then lines_down = n - 1 elseif key == "j" then lines_down = n else lines_up = n end
      if (key == "j" or (key == "line" and n > 1)) and last + 1 >= r.size then return end -- fails on the last line
      for _ = 1, lines_down do
        if last + 1 >= r.size then break end
        last = line_bounds(last + 1)
        if not last then return end
      end
      for _ = 1, lines_up do
        if first == 0 then
          if key == "k" and lines_up == n and first == row.off then return end -- dk on the first line fails
          break
        end
        first = scan("finding the start of the line", function(so)
          so.nl_at_off = true
          return r:line_start(first - 1, so)
        end)
        if not first then return end
      end
      return operate(S, op, first, math.min(last + 1, r.size), true)
    end
    local pos = M.cursor_abs(S)
    local target, _, inclusive = motion_target(S, row, key, n, arg, op)
    if not target then return end
    local lo, hi
    local linewise = false
    -- the end of an inclusive motion is its last character; on an empty line there is none
    local function after(a) return r:get(a, 1) == "\n" and a or Nav.next_char(r, a) end
    if target >= pos then
      lo, hi = pos, inclusive and after(target) or target
    else
      lo, hi = target, inclusive and after(pos) or pos
    end
    if not inclusive and hi > lo and r:get(hi - 1, 1) == "\n" then
      -- an exclusive motion that ends in column 0 ends at the end of the line before; when it also
      -- starts at or before the first non-blank of its line it takes whole lines
      local ls = scan("finding the start of the line", function(so) return r:line_start(lo, so) end)
      if not ls then return end
      local fnb = scan("finding the first word", function(so) return Nav.first_nonblank({ r = r, pos = ls, ls = ls }, so) end)
      if not fnb then return end
      if lo <= fnb then
        lo, linewise = ls, true
      else
        hi = hi - 1
      end
    end
    operate(S, op, lo, hi, linewise)
  end)
end

M.far_op = far_op

-- The omap for a motion: Neovim's own when the cursor's line fits the buffer, else the file's
local function op_motion_map(S, key)
  vim.keymap.set("o", key, function()
    local op, count = vim.v.operator, vim.v.count
    local arg
    if key == "f" or key == "F" or key == "t" or key == "T" then
      arg = vim.fn.getcharstr()
      if arg == "\27" then return "<Esc>" end
      if arg == "\11" then
        arg = vim.fn.digraph_get(vim.fn.getcharstr() .. vim.fn.getcharstr())
      elseif arg == "\22" then
        arg = vim.fn.getcharstr()
      end
    end
    local row = S.entries[S.row]
    local long = row and (row.lopen or row.ropen)
    if S.closed or not long or not (op == "d" or op == "y" or op == "c") then
      return key .. (arg or "")
    end
    S.pending_op = { op = op, key = key, count = count, arg = arg }
    return "<Esc><Cmd>lua require('streamview').run_pending_op()<CR>"
  end, { buffer = S.buf, expr = true, nowait = true, silent = true, desc = "Stream view: operator motion " .. key })
end

function M.run_pending_op()
  local S = M.state()
  local p = S and S.pending_op
  if not p then return end
  S.pending_op = nil
  far_op(S, p.op, p.key, math.max(p.count, 1), p.arg)
end

-- dd, cc, yy and D C Y on a line longer than the buffer hold act on the whole line, not on the slice
local function line_op_maps(S)
  local function map(lhs, native, fn)
    vim.keymap.set("n", lhs, function()
      sync_row(S)
      local row = S.entries[S.row]
      if S.closed or not (row and (row.lopen or row.ropen)) then
        vim.api.nvim_feedkeys((vim.v.count > 0 and vim.v.count or "") .. native, "nx", false)
        return
      end
      fn(math.max(vim.v.count, 1))
    end, { buffer = S.buf, nowait = true, silent = true, desc = "Stream view: " .. lhs })
  end
  map("dd", "dd", function(n) far_op(S, "d", "line", n) end)
  map("cc", "cc", function(n) far_op(S, "c", "line", n) end)
  map("yy", "yy", function(n) far_op(S, "y", "line", n) end)
  map("Y", "yy", function(n) far_op(S, "y", "line", n) end)
  map("D", "D", function(n) far_op(S, "d", "$", n) end)
  map("C", "C", function(n) far_op(S, "c", "$", n) end)
end

-- zt, zz, zb: scroll so that the cursor's line is at the top, middle or bottom of the window
function M.place_row(S, where)
  nav(S, function()
    if not before_move(S) then return end
    sync_row(S)
    local row = S.entries[S.row]
    if not row then return end
    local r = S.r
    local back = where == "top" and 0 or where == "middle" and math.floor((height_of(S) - 1) / 2) or height_of(S) - 1
    local top, moved = wait_scan(S, "counting lines", row.off, function(so) return r:lines_backward(row.off, back, so) end)
    if not top then return end
    S.goal_abs = M.cursor_abs(S)
    S.offset, S.row = top, 1 + moved
    S.slice_rel = slice_rel_for(row.off, S.goal_abs)
    M.render(S)
  end)
end

-- The cursor row, and the slice of it in the buffer, follow the cursor: entering another row makes
-- that one the cursor row, and a cursor near an edge of the slice that is not the line's own moves
-- the slice. Safe to call at any time; it does nothing when the cursor is well inside.
check_slice = function(S)
  if S.closed or S.job or not S.entries then return end
  local win = win_of(S)
  if not win then return end
  local cur = vim.api.nvim_win_get_cursor(win)
  local row = S.entries[cur[1]]
  if not row then return end
  local changed_row = cur[1] ~= S.row
  S.row = cur[1]
  local slice = M.opts.slice
  local margin = math.min(slice * M.opts.slice_hyst, slice / 2 - 1)
  local width = row.to - row.from
  local near = (row.lopen and cur[2] < margin) or (row.ropen and width - cur[2] < margin)
  if near then
    S.goal_abs = row.from + cur[2]
    S.slice_rel = slice_rel_for(row.off, S.goal_abs)
    M.render(S)
  elseif changed_row and S.slice_rel ~= 0 then
    S.slice_rel = 0
    S.col = cur[2]
    M.render(S)
  end
end

M.check_slice = function(S) return check_slice(S) end

local function attach_nav(S, group)
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    buffer = S.buf,
    callback = function() check_slice(S) end,
  })
end

-- The first `limit` matches from the cursor, as a list to pick from (vim.ui.select), each with the
-- text around it; the last entry asks for more. The picked match is shown like a search hit.
function M.search_all(S, pat, limit, from)
  limit = limit or 50
  local plan, perr = Search.plan(pat)
  if not plan then return vim.notify("StreamSearchAll: " .. tostring(perr), vim.log.levels.ERROR) end
  nav(S, function()
    if not before_move(S) then return end
    sync_row(S)
    local r = S.r
    local origin = from or (M.cursor_abs(S) + 1)
    local found = {}
    local last
    run_job(S, "listing matches", r.size - origin, function(tick)
      local at = origin
      while #found < limit do
        local pos, len = Search.lua_scan(r, plan, at, true, function(p) tick(p - origin) end)
        if not pos then return true end
        local a = math.max(0, pos - 20)
        local text = r:get(a, 90):gsub("[%c\128-\255]", function(c) return c:byte() >= 128 and c or "." end)
        found[#found + 1] = { pos = pos, len = len, text = text }
        at = pos + math.max(len, 1)
        last = at
      end
      return false
    end, function(complete, err)
      if err then return vim.notify("StreamSearchAll: " .. tostring(err), vim.log.levels.ERROR) end
      if #found == 0 then return vim.notify("Pattern not found: " .. pat, vim.log.levels.WARN) end
      local items = vim.list_extend({}, found)
      if not complete then items[#items + 1] = { more = true, text = "(more...)" } end
      vim.ui.select(items, {
        prompt = pat,
        format_item = function(it) return it.more and it.text or string.format("%s  %s", grouped(it.pos), it.text) end,
      }, function(choice)
        if not choice then return end
        if choice.more then return M.search_all(S, pat, limit, last) end
        M.goto_abs(S, choice.pos, { pos = choice.pos, len = choice.len })
      end)
    end, true)
  end)
end

local function notify_search_result(pat)
  return function(pos, err)
    if err == "cancelled" then
      vim.notify("Search cancelled", vim.log.levels.INFO)
    elseif err then
      vim.notify("Search failed: " .. err, vim.log.levels.ERROR)
    elseif not pos then
      vim.notify("Pattern not found: " .. pat, vim.log.levels.WARN)
    end
  end
end

function M.search_again(S, reverse)
  local last = S.last_search
  if not last then return vim.notify("No previous search", vim.log.levels.WARN) end
  local forward = last.forward ~= reverse
  M.search(S, last.pat, forward, notify_search_result(last.pat))
  S.last_search.forward = last.forward
end

function M.prompt_search(S, forward)
  vim.ui.input({ prompt = forward and "/" or "?" }, function(pat)
    if pat and pat ~= "" then M.search(S, pat, forward, notify_search_result(pat)) end
  end)
end

---------------------------------------------------------------------------------------------------
-- Saving: stream the pieces into a temp file and rename it over the original
---------------------------------------------------------------------------------------------------

-- The work lives in streamview_save; it reaches back through these.
M.internal = {
  before_move = before_move,
  draw = draw,
  human = human,
  run_job = run_job,
  stop_follow = stop_follow,
}

M.free_bytes = save.free_bytes

-- opts: path (default the viewed file), force (overwrite a file changed on disk or an existing
-- other file), inplace (true: patch in place when there is no room for a copy, false: refuse,
-- nil: ask). done(ok, err) runs when the save has finished, failed or been cancelled.
function M.write(S, opts, done) return save.write(S, opts, done) end

local function write_command(S, o)
  local path = o.args ~= "" and vim.fn.fnamemodify(vim.fs.normalize(o.args), ":p") or nil
  M.write(S, { path = path, force = o.bang }, function(ok, err)
    if ok then
      local how = S.plan and S.plan.label and (", " .. S.plan.label:gsub("^writing ", "")) or ""
      vim.notify(err and ("Stream view: " .. err) or string.format("Stream view: wrote %s%s", human(S.r.size), how), vim.log.levels.INFO)
    elseif err == "cancelled" then
      vim.notify("Stream view: save cancelled, the file was not touched", vim.log.levels.WARN)
    else
      vim.notify("Stream view: " .. tostring(err), vim.log.levels.ERROR)
    end
  end)
end

---------------------------------------------------------------------------------------------------
-- Ranges in a line: :StreamCol and :StreamYank
---------------------------------------------------------------------------------------------------

-- A byte of the file named by a word: a number, "." (the cursor), "^" and "$" (the start and end of
-- the cursor's line), "e" (the end of the file), or a percentage ("50%") of the cursor's line.
local function resolve_pos(S, word, row, scan)
  local r = S.r
  if word == "." then return M.cursor_abs(S) end
  if word == "^" then return row.off end
  if word == "e" then return r.size end
  local pct = word:match("^(%d+%.?%d*)%%$")
  if word == "$" or pct then
    local le = row.e or scan("finding the end of the line", function(so) return r:line_end(row.off, so) end)
    if not le then return nil end
    if word == "$" then return le end
    return row.off + math.floor((le - row.off) * math.min(tonumber(pct), 100) / 100)
  end
  local n = tonumber(word)
  if n then return math.max(0, math.min(math.floor(n), r.size)) end
  return nil, "not a position: " .. word
end

-- :StreamCol {N|P%|+N|-N}: to byte N of the cursor's line, a percentage of the way along it, or N
-- bytes right or left of the cursor
function M.goto_col(S, spec)
  nav(S, function()
    if not before_move(S) then return end
    sync_row(S)
    local row = S.entries[S.row]
    if not row then return end
    local r = S.r
    local function scan(label, f) return wait_scan(S, label, r.size, function(so) return f(so) end) end
    local target
    local rel = spec:match("^([+-]%d+)$")
    if rel then
      target = M.cursor_abs(S) + tonumber(rel)
    elseif spec:match("^%d+%.?%d*%%$") then
      target = resolve_pos(S, spec, row, scan)
    elseif tonumber(spec) then
      target = row.off + tonumber(spec)
    else
      return vim.notify("StreamCol: expected N, P%, +N or -N, got: " .. spec, vim.log.levels.ERROR)
    end
    if not target then return end
    local le = row.e or scan("finding the end of the line", function(so) return r:line_end(row.off, so) end)
    if not le then return end
    target = math.max(row.off, math.min(target, le > row.off and le - 1 or row.off))
    place(S, r:align_down(target))
  end)
end

-- :StreamYank {from} {to} [file]: the bytes [from, to) into the register, or streamed into `file`
-- without loading them (a job with progress that <C-c> cancels). from and to are bytes of the file
-- or ".", "^", "$", "e" and "P%" as for :StreamCol.
function M.yank_range(S, from_word, to_word, file)
  nav(S, function()
    if not before_move(S) then return end
    sync_row(S)
    local row = S.entries[S.row]
    if not row then return end
    local r = S.r
    local function scan(label, f) return wait_scan(S, label, r.size, function(so) return f(so) end) end
    local from, ferr = resolve_pos(S, from_word, row, scan)
    local to, terr = resolve_pos(S, to_word, row, scan)
    if not (from and to) then return vim.notify("StreamYank: " .. tostring(ferr or terr), vim.log.levels.ERROR) end
    if from > to then from, to = to, from end
    if to == from then return end
    if not file then
      if to - from > M.opts.yank_max then
        return vim.notify(
          string.format("StreamYank: %s is more than the register limit (%s); give a file to write it to", human(to - from), human(M.opts.yank_max)),
          vim.log.levels.ERROR
        )
      end
      set_register(r:raw(from, to), false)
      return vim.notify(string.format("StreamYank: %s yanked", human(to - from)))
    end
    local fd, err = uv.fs_open(file, "w", 420)
    if not fd then return vim.notify("StreamYank: cannot write " .. file .. ": " .. tostring(err), vim.log.levels.ERROR) end
    local chunk = r.bs * 16
    run_job(S, "yanking", to - from, function(tick)
      local pos = from
      while pos < to do
        local hi = math.min(to, pos + chunk)
        local data = r:raw(pos, hi)
        if #data ~= hi - pos then return nil, "short read at byte " .. pos end
        local ok, werr = save.write_all(fd, data, pos - from)
        if not ok then return nil, "write failed: " .. tostring(werr) end
        pos = hi
        tick(pos - from)
      end
      return true
    end, function(ok, werr)
      uv.fs_close(fd)
      if ok then
        vim.notify(string.format("StreamYank: %s written to %s", human(to - from), file))
      else
        uv.fs_unlink(file)
        vim.notify("StreamYank: " .. tostring(werr) .. " (" .. file .. " was removed)", vim.log.levels.ERROR)
      end
    end, true)
  end)
end

---------------------------------------------------------------------------------------------------
-- Attaching to a buffer
---------------------------------------------------------------------------------------------------

local function keymaps(S)
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, guarded(fn), { buffer = S.buf, nowait = true, silent = true, desc = "Stream view: " .. desc })
  end
  map("j", function() M.move(S, vim.v.count1) end, "down")
  map("<Down>", function() M.move(S, vim.v.count1) end, "down")
  map("k", function() M.move(S, -vim.v.count1) end, "up")
  map("<Up>", function() M.move(S, -vim.v.count1) end, "up")
  map("<C-d>", function() M.half_page(S, 1, vim.v.count) end, "scroll down")
  map("<C-u>", function() M.half_page(S, -1, vim.v.count) end, "scroll up")
  map("<C-f>", function() M.page(S, math.max(vim.v.count, 1)) end, "page down")
  map("<PageDown>", function() M.page(S, math.max(vim.v.count, 1)) end, "page down")
  map("<C-b>", function() M.page(S, -math.max(vim.v.count, 1)) end, "page up")
  map("<PageUp>", function() M.page(S, -math.max(vim.v.count, 1)) end, "page up")
  map("<C-e>", function()
    local n = math.max(vim.v.count, 1)
    M.scroll(S, n)
    local win = win_of(S)
    if win then pcall(vim.api.nvim_win_set_cursor, win, { math.max(1, vim.api.nvim_win_get_cursor(win)[1] - n), 0 }) end
  end, "scroll down, keeping the cursor line")
  map("<C-y>", function()
    local n = math.max(vim.v.count, 1)
    M.scroll(S, -n)
    local win = win_of(S)
    if win then pcall(vim.api.nvim_win_set_cursor, win, { math.min(vim.api.nvim_buf_line_count(S.buf), vim.api.nvim_win_get_cursor(win)[1] + n), 0 }) end
  end, "scroll up, keeping the cursor line")
  map("+", function() M.move(S, math.max(vim.v.count, 1)); M.hmove(S, "^", 0) end, "down to the first word")
  map("<CR>", function() M.move(S, math.max(vim.v.count, 1)); M.hmove(S, "^", 0) end, "down to the first word")
  map("-", function() M.move(S, -math.max(vim.v.count, 1)); M.hmove(S, "^", 0) end, "up to the first word")
  map("zt", function() M.place_row(S, "top") end, "cursor line to the top")
  map("zz", function() M.place_row(S, "middle") end, "cursor line to the middle")
  map("zb", function() M.place_row(S, "bottom") end, "cursor line to the bottom")
  for _, key in ipairs({ "l", "h", "w", "W", "b", "B", "e", "E", "^", "$", "|", ";", ",", "ge", "gE" }) do
    map(key, function() M.hmove(S, key, vim.v.count) end, "motion " .. key)
  end
  map("<Right>", function() M.hmove(S, "l", vim.v.count) end, "right")
  map("<Left>", function() M.hmove(S, "h", vim.v.count) end, "left")
  map("<End>", function() M.hmove(S, "$", vim.v.count) end, "end of the line")
  map("<Home>", function() M.hmove(S, "0", 0) end, "start of the line")
  -- 0 is a digit of a count when one is typed
  vim.keymap.set("n", "0", function()
    if vim.v.count > 0 then return "0" end
    -- run in the order the keys were typed: a scheduled move would come after the next key
    return "<Cmd>lua require('streamview').home()<CR>"
  end, { buffer = S.buf, nowait = true, silent = true, expr = true, desc = "Stream view: start of the line" })
  for _, key in ipairs({ "l", "h", "w", "W", "b", "B", "e", "E", "^", "$", "|", ";", ",", "ge", "gE", "f", "F", "t", "T", "j", "k" }) do
    op_motion_map(S, key)
  end
  line_op_maps(S)
  for _, key in ipairs({ "f", "F", "t", "T" }) do
    map(key, function()
      local count = vim.v.count
      local ch = vim.fn.getcharstr()
      if ch == "" then return end
      if ch == "	" then -- <C-k>: a digraph
        ch = vim.fn.digraph_get(vim.fn.getcharstr() .. vim.fn.getcharstr())
      elseif ch == "" then -- <C-v>: the next character as it is
        ch = vim.fn.getcharstr()
      end
      if ch ~= "" then M.hmove(S, key, count, ch) end
    end, "find a character")
  end
  map("gg", function()
    if vim.v.count > 0 then M.goto_line(S, vim.v.count) else M.head(S) end
  end, "start of file, or line {count}")
  map("G", function()
    if vim.v.count > 0 then M.goto_line(S, vim.v.count) else M.tail(S) end
  end, "end of file, or line {count}")
  if S.editable then
    map("u", function() for _ = 1, vim.v.count1 do M.undo(S) end end, "undo (across windows)")
    map("<C-r>", function() for _ = 1, vim.v.count1 do M.redo(S) end end, "redo (across windows)")
  end
  map("/", function() M.prompt_search(S, true) end, "search forward (text or Vim regex)")
  map("?", function() M.prompt_search(S, false) end, "search backward (text or Vim regex)")
  map("n", function() M.search_again(S, false) end, "next match")
  map("N", function() M.search_again(S, true) end, "previous match")
  map("<C-c>", function() M.cancel(S) end, "cancel the running search")
  map("%", function()
    local count = vim.v.count
    if count > 0 then
      M.goto_offset(S, math.min(count, 100) .. "%")
    else
      vim.cmd("normal! %")
    end
  end, "jump to {count} percent")
end

local function setup_buffer_options(buf, editable)
  vim.b[buf].bigfile = true
  vim.b[buf].sleuth_automatic = 0
  local bo = vim.bo[buf]
  -- acwrite is the buffer type that can be modified without being a file Neovim writes itself
  bo.buftype = editable and "acwrite" or "nofile"
  bo.bufhidden = "wipe"
  bo.swapfile = false
  bo.undolevels = -1
  bo.modeline = false
  bo.filetype = "streamview"
  bo.syntax = ""
  bo.modifiable = false
end

local function setup_window_options(S)
  local win = win_of(S)
  if not win then return end
  local wo = vim.wo[win]
  wo.wrap = false
  wo.number = false
  wo.relativenumber = false
  wo.foldenable = false
  wo.list = false
  wo.spell = false
  wo.cursorline = true
  wo.winbar = "%{%v:lua.require('streamview').winbar()%}"
end

local function close(S)
  if S.closed then return end
  S.closed = true
  M.cancel(S)
  stop_follow(S)
  if S.on_close then S.on_close() end
  S.r:close()
  S.r.pieces, S.r.log, S.entries, S.shown = {}, {}, {}, {} -- the typed text is not kept alive
  states[S.buf] = nil
end

-- A buffer for a file that cannot be opened must not be writable: it would write itself, empty,
-- over the file.
local function refuse_buffer(buf, err)
  local bo = vim.bo[buf]
  bo.buftype = "nofile"
  bo.modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Stream view cannot open this file: " .. tostring(err) })
  bo.modifiable = false
  bo.modified = false
end

-- Turns `buf` into a viewer of `path`. Returns the state, or nil and an error.
function M.attach(buf, path)
  if states[buf] then close(states[buf]) end
  local r, err = M.open_reader(path)
  if not r then return nil, err end
  local S = {
    buf = buf,
    path = path,
    r = r,
    offset = 0,
    col = 0,
    row = 1,
    entries = {},
    nxt = 0,
    editable = M.opts.editable,
  }
  states[buf] = S
  setup_buffer_options(buf, S.editable)
  keymaps(S)

  local group = vim.api.nvim_create_augroup("streamview-" .. buf, { clear = true })
  -- :edit on the viewer unloads the buffer and reads it again: read the file again the same way
  vim.api.nvim_create_autocmd("BufUnload", {
    group = group,
    buffer = buf,
    callback = function() close(S) end,
  })
  vim.api.nvim_create_autocmd("BufReadCmd", {
    group = group,
    buffer = buf,
    callback = function()
      local again, aerr = M.attach(buf, path)
      if not again then
        refuse_buffer(buf, aerr)
        vim.notify("Stream view: " .. tostring(aerr), vim.log.levels.ERROR)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    callback = function()
      close(S)
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })
  if S.editable then
    save.attach(S, group)
    vim.api.nvim_create_autocmd("BufWriteCmd", {
      group = group,
      buffer = buf,
      callback = function(ev)
        local name = vim.api.nvim_buf_get_name(buf)
        local target = vim.fn.fnamemodify(ev.file, ":p")
        local same = ev.file == name or target == name or ev.file == "stream://" .. S.path
        write_command(S, { args = same and "" or target, bang = vim.v.cmdbang == 1 })
      end,
    })
  end
  vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
    group = group,
    buffer = buf,
    callback = function() check_pending(S) end,
  })
  attach_nav(S, group)
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    buffer = buf,
    callback = function()
      setup_window_options(S)
      M.render(S)
    end,
  })
  vim.api.nvim_create_autocmd("WinResized", {
    group = group,
    callback = function()
      if S.closed then return end
      if win_of(S) and #S.entries ~= math.min(height_of(S), #S.entries + 1) then M.render(S) end
    end,
  })
  setup_window_options(S)
  M.render(S)
  return S
end

---------------------------------------------------------------------------------------------------
-- Opening: automatically for files too big for memory, or on request
---------------------------------------------------------------------------------------------------

local function read_number(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  return tonumber(text:match("^%s*(%d+)%s*$"))
end

-- Memory left under the tightest memory limit of the process's cgroup (v2 or v1), or nil.
local function cgroup_headroom()
  local f = io.open(M.opts.proc_cgroup, "r")
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  local best
  local function consider(dir, limit_file, usage_file)
    while dir and dir ~= "" do
      local limit = read_number(M.opts.cgroup_root .. dir .. "/" .. limit_file)
      local usage = read_number(M.opts.cgroup_root .. dir .. "/" .. usage_file)
      -- v1 reports "no limit" as a number close to 2^63
      if limit and usage and limit < 2 ^ 60 then best = math.min(best or math.huge, limit - usage) end
      if dir == "/" then break end
      dir = dir:match("^(.*)/[^/]*$")
      if dir == "" then dir = "/" end
    end
  end
  local v2 = text:match("\n?0::(/[^\n]*)")
  if v2 then consider(v2, "memory.max", "memory.current") end
  local v1 = text:match("\n?%d+:[^:\n]*memory[^:\n]*:(/[^\n]*)")
  if v1 then
    local saved = M.opts.cgroup_root
    M.opts.cgroup_root = saved .. "/memory"
    consider(v1, "memory.limit_in_bytes", "memory.usage_in_bytes")
    M.opts.cgroup_root = saved
  end
  return best
end

-- Memory a new file could take: what the machine has available, or what the cgroup allows if less.
function M.available_memory()
  local f = io.open("/proc/meminfo", "r")
  local avail
  if f then
    local kb = f:read("*a"):match("MemAvailable:%s*(%d+)%s*kB")
    f:close()
    avail = kb and tonumber(kb) * 1024
  end
  local cgroup = cgroup_headroom()
  if avail and cgroup then return math.min(avail, cgroup) end
  return avail or cgroup
end

-- vim.g.stream_viewer_min_bytes overrides; otherwise half of the available memory, at least
-- opts.min_bytes.
function M.threshold()
  local override = vim.g.stream_viewer_min_bytes
  if type(override) == "number" then return override end
  return math.max(M.opts.min_bytes, (M.available_memory() or 0) / 2)
end

function M.is_too_big(path)
  local st = uv.fs_stat(path)
  if not st or st.type ~= "file" then return false end
  -- Most files are small: do not read /proc and /sys for each of them
  if type(vim.g.stream_viewer_min_bytes) ~= "number" and st.size <= M.opts.min_bytes then return false end
  return st.size > M.threshold()
end

-- A BufReadCmd autocmd replaces the read of the buffer, so the file is never loaded.
local function take_over_read(name, where)
  vim.api.nvim_create_autocmd("BufReadCmd", vim.tbl_extend("error", where, {
    once = true,
    callback = function(ev)
      local S, err = M.attach(ev.buf, name)
      if not S then
        refuse_buffer(ev.buf, err)
        vim.notify("Stream view: " .. tostring(err), vim.log.levels.ERROR)
        return
      end
      vim.notify(
        string.format("%s is %s: opened in the stream viewer, not loaded", vim.fn.fnamemodify(name, ":t"), human(S.r.size)),
        vim.log.levels.WARN
      )
    end,
  }))
end

local function intercept(buf)
  if vim.bo[buf].buftype ~= "" or vim.api.nvim_buf_is_loaded(buf) then return end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" or name:find("^%a[%w+.-]*://") or not M.is_too_big(name) then return end
  take_over_read(name, { buffer = buf })
end

-- Not expand(): 'wildignore' makes it return "" for a name like *.log or *.bin
local function open_command(o)
  local path = o.args ~= "" and vim.fn.fnamemodify(vim.fs.normalize(o.args), ":p")
    or vim.api.nvim_buf_get_name(0)
  if path == "" then
    vim.notify("StreamView: no file", vim.log.levels.ERROR)
    return
  end
  local name = "stream://" .. path
  for existing in pairs(states) do
    if vim.api.nvim_buf_get_name(existing) == name then
      vim.cmd((o.bang and "buffer! " or "buffer ") .. existing)
      return
    end
  end
  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_name(buf, name)
  local ok, err = pcall(vim.cmd, (o.bang and "buffer! " or "buffer ") .. buf)
  if not ok then
    vim.api.nvim_buf_delete(buf, { force = true })
    vim.notify("StreamView: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  local S, aerr = M.attach(buf, path)
  if not S then
    vim.notify("StreamView: " .. tostring(aerr), vim.log.levels.ERROR)
    vim.api.nvim_buf_delete(buf, { force = true })
  end
end

local function current_state()
  local S = states[vim.api.nvim_get_current_buf()]
  if not S then vim.notify("Not a stream viewer buffer", vim.log.levels.WARN) end
  return S
end

function M.setup()
  local function command(name, fn, opts) vim.api.nvim_create_user_command(name, guarded(fn), opts) end
  local group = vim.api.nvim_create_augroup("streamview", { clear = true })
  vim.api.nvim_create_autocmd("BufNew", {
    group = group,
    callback = function(ev) intercept(ev.buf) end,
  })
  -- Files named on the command line get their buffers after this runs, without BufNew
  for _, arg in ipairs(vim.fn.argv()) do
    local path = vim.fn.fnamemodify(arg, ":p")
    if M.is_too_big(path) then
      take_over_read(path, { group = group, pattern = vim.fn.escape(path, "\\*?[]{},") })
    end
  end

  command("StreamView", open_command, {
    nargs = "?",
    bang = true,
    complete = "file",
    desc = "Open a file in the stream viewer (the current file by default); ! abandons a modified buffer",
  })
  command("StreamGoto", function(o)
    local S = current_state()
    if not S then return end
    local _, err = M.goto_offset(S, o.args)
    if err then vim.notify("StreamGoto: " .. err, vim.log.levels.ERROR) end
  end, { nargs = 1, desc = "Stream view: jump to a byte offset or a percentage (60%)" })

  command("StreamSearchAll", function(o)
    local S = current_state()
    if not S then return end
    local pat, n = o.args:match("^(.-)%s+(%d+)$")
    M.search_all(S, pat or o.args, tonumber(n))
  end, { nargs = "+", desc = "Stream view: list the first matches of a pattern from the cursor (N at the end: how many)" })
  command("StreamLine", function(o)
    local S = current_state()
    if S then M.goto_line(S, math.max(tonumber(o.args) or 1, 1)) end
  end, { nargs = 1, desc = "Stream view: go to line N of the file" })
  command("StreamIndex", function()
    local S = current_state()
    if not S then return end
    M.build_index(S, function(n) vim.notify(string.format("Stream view: %s lines", Nav.grouped and Nav.grouped(n) or n)) end)
  end, { desc = "Stream view: count the lines of the file (a job), so that line numbers are exact" })
  command("StreamCol", function(o)
    local S = current_state()
    if S then M.goto_col(S, vim.trim(o.args)) end
  end, { nargs = 1, desc = "Stream view: to byte N of the line, P% along it, or +N / -N bytes from the cursor" })
  command("StreamYank", function(o)
    local S = current_state()
    if not S then return end
    local a, b, file = o.args:match("^(%S+)%s+(%S+)%s*(.*)$")
    if not a then return vim.notify("StreamYank: expected {from} {to} [file]", vim.log.levels.ERROR) end
    M.yank_range(S, a, b, file ~= "" and vim.fn.fnamemodify(vim.fs.normalize(file), ":p") or nil)
  end, {
    nargs = "+",
    -- not complete = "file": that makes Neovim expand the % of "50%"
    complete = function(lead) return vim.fn.getcompletion(lead, "file") end,
    desc = "Stream view: yank the bytes [from, to) into the register, or stream them into a file",
  })
  command("StreamWrite", function(o)
    local S = current_state()
    if S then write_command(S, o) end
  end, {
    nargs = "?",
    bang = true,
    complete = "file",
    desc = "Stream view: save the edits (to [path]); ! overwrites a file changed on disk or an existing path",
  })
  command("StreamRecover", function()
    local S = current_state()
    if S then save.recover_viewer(S) end
  end, { desc = "Stream view: finish a save that was interrupted (its journal is replayed, never rolled back)" })
  command("StreamFollow", function()
    local S = current_state()
    if S then M.toggle_follow(S) end
  end, { desc = "Stream view: toggle following the end of the file (tail -f)" })

  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      for _, S in pairs(states) do
        if win_of(S) then M.render(S) end
      end
    end,
  })
end

return M

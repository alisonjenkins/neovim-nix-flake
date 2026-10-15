-- Read-only paged viewer for files too big to load into a buffer.
-- The file is never read whole: a window of lines is rebuilt from fixed-size blocks at a byte
-- offset, so memory use does not depend on the file size.
local uv = vim.uv
local M = {}

M.opts = {
  block = 256 * 1024, -- read unit; at most two blocks of file data are held at a time
  line_cap = 64 * 1024, -- bytes of one line shown at once; the rest is reached by horizontal paging
  segment = 16 * 1024 * 1024, -- longest line scanned; a longer one is split at multiples of this
  -- may the window be edited (changes are held as pieces until saved)
  editable = not (vim.g.stream_viewer_readonly == true or vim.g.stream_viewer_readonly == 1),
  edit_warn = 256 * 1024 * 1024, -- bytes of edit text held in memory before a warning
  edit_max = 1024 * 1024 * 1024, -- bytes of edit text held in memory before edits are refused
  follow_ms = 500, -- how often follow mode polls the file size
  min_bytes = 256 * 1024 * 1024, -- floor of the size at which a file opens in the viewer
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
    seg = M.opts.segment,
    cache = {}, -- most recent first: { index, data }
    cuts = {}, -- segment boundary -> where the segment really ends
    nonl = {}, -- segment number -> { from, to }: a stretch known to hold no "\n"
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
  snap.cache, snap.cuts, snap.nonl, snap.log, snap.log_pos = {}, {}, {}, {}, 0
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
  self.cuts = {}
  self.nonl = {}
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
  return { i = a, old = old, new = new }
end

function Reader:undo_op(op) splice(self, op.i, #op.new, op.old) end
function Reader:redo_op(op) splice(self, op.i, #op.old, op.new) end

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

-- Reads the logical bytes of block `index` from the pieces.
function Reader:load(index)
  local lo = index * self.bs
  local hi = math.min(self.size, lo + self.bs)
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

-- Start and length of the valid UTF-8 character that has bytes on both sides of `pos`, or nil when
-- `pos` is at a character boundary (or among bytes that do not form a character).
function Reader:straddle(pos)
  if pos <= 0 or pos >= self.size then return nil end
  local from = math.max(0, pos - 3)
  local s = self:get(from, pos - from + 1)
  local at = #s
  local b = s:byte(at)
  if not b or b < 0x80 or b >= 0xC0 then return nil end
  for k = at - 1, 1, -1 do
    local c = s:byte(k)
    if c >= 0xC2 and c <= 0xF4 then
      local need = c >= 0xF0 and 4 or c >= 0xE0 and 3 or 2
      if k + need > at then return from + k - 1, need end
      return nil
    elseif c < 0x80 or c >= 0xC0 then
      return nil
    end
  end
end

-- Where the segment that ends at the multiple `boundary` of the segment size really ends: before a
-- character that straddles it, so no line is cut inside a UTF-8 character.
function Reader:cut_at(boundary)
  if boundary >= self.size then return self.size end
  local hit = self.cuts[boundary]
  if hit then return hit end
  local cut = self:straddle(boundary) or boundary
  self.cuts[boundary] = cut
  return cut
end

-- Segment number holding `off`, its first byte and the end of the segment (where the next starts).
function Reader:segment(off)
  local k = math.floor(off / self.seg)
  if off < self.size and (k + 1) * self.seg < self.size and off >= self:cut_at((k + 1) * self.seg) then k = k + 1 end
  local start = k == 0 and 0 or self:cut_at(k * self.seg)
  return k, start, math.min(self.size, self:cut_at((k + 1) * self.seg))
end

-- A line of many MB has to be scanned to find that it has no "\n" in a segment; remember it, so that
-- walking over the same stretch again (k, <C-b>) costs nothing. One stretch per segment is kept.
function Reader:is_nonl(k, from, to)
  local known = self.nonl[k]
  return known ~= nil and known[1] <= from and known[2] >= to
end

function Reader:note_nonl(k, from, to)
  local known = self.nonl[k]
  if known and known[1] <= to and from <= known[2] then
    known[1], known[2] = math.min(known[1], from), math.max(known[2], to)
    return
  end
  self.nonl_count = (self.nonl_count or 0) + 1
  if self.nonl_count > 4096 then
    self.nonl, self.nonl_count = {}, 1
  end
  self.nonl[k] = { from, to }
end

-- Lines are cut at "\n" or at the segment edges, so a line never needs more than one segment of
-- scanning in either direction, and the cuts depend only on the file contents.
function Reader:seg_start(off)
  local k, floor = self:segment(off)
  if self:is_nonl(k, floor, off) then return floor end
  local nl = self:find_nl_back(off, floor)
  if nl then return nl + 1 end
  -- the byte at `off` is part of the line too: a walk back from the next segment starts on its last byte
  self:note_nonl(k, floor, self:get(off, 1) == "\n" and off or off + 1)
  return floor
end

-- Returns the offset where the line ends (its "\n", or the cut), the start of the next line,
-- and whether a "\n" ended it.
function Reader:seg_end(start)
  local k, _, limit = self:segment(start)
  if self:is_nonl(k, start, limit) then return limit, limit, false end
  local nl = self:find_nl(start, limit)
  if nl then return nl, nl + 1, true end
  self:note_nonl(k, start, limit)
  return limit, limit, false
end

function Reader:window(start, count)
  local out, pos = {}, start
  while #out < count and pos < self.size do
    local e, nxt, term = self:seg_end(pos)
    out[#out + 1] = { off = pos, e = e, nxt = nxt, term = term }
    pos = nxt
  end
  return out, pos
end

-- Offset of the first line of the last `count` lines.
function Reader:tail_offset(count)
  if self.size == 0 then return 0 end
  local pos = self:seg_start(self.size - 1)
  for _ = 2, count do
    if pos == 0 then break end
    pos = self:seg_start(pos - 1)
  end
  return pos
end

---------------------------------------------------------------------------------------------------
-- Text of one line
---------------------------------------------------------------------------------------------------

-- Drops a multibyte character cut off at the end of `s`.
local function cut_partial_tail(s)
  local n = #s
  for k = 1, math.min(3, n) do
    local b = s:byte(n - k + 1)
    if b < 0x80 then return s end
    if b >= 0xC0 then
      local need = b >= 0xF0 and 4 or b >= 0xE0 and 3 or 2
      return k < need and s:sub(1, n - k) or s
    end
  end
  return s
end

-- Returns the displayed text, the number of prefix bytes before the file's bytes, whether the text
-- is the whole line byte for byte (so it can be edited), and whether a "\r" was cut off its end.
local function line_text(r, ent, col, cap)
  local len = ent.e - ent.off
  local want = math.min(len - col, cap)
  local more = len - col - want
  local text, cr = "", false
  local plain = col == 0 and more <= 0 and (ent.term or ent.e >= r.size)
  local hidden = 0 -- bytes right of the shown text
  if want > 0 then
    local from = ent.off + col
    -- Start and end the text on character boundaries; bytes that are not a character stay bytes
    local lead, need = r:straddle(from)
    if lead and col > 0 then
      local skip = lead + need - from
      from, want = from + skip, want - skip
    end
    text = r:get(from, math.max(want, 0))
    if more > 0 then
      text = cut_partial_tail(text)
    elseif ent.term and text:sub(-1) == "\r" then
      text, cr = text:sub(1, -2), true
    end
    hidden = ent.e - (from + #text)
    local nuls
    text, nuls = text:gsub("%z", NUL_SYMBOL)
    if nuls > 0 then plain = false end
  end
  local prefix = col > 0 and ELLIPSIS or ""
  if hidden > 0 and more > 0 then text = text .. string.format("%s[+%d bytes]", ELLIPSIS, hidden) end
  return prefix .. text, #prefix, plain, cr
end

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

local function draw(S)
  S.r:refresh()
  local ents, nxt = S.r:window(S.offset, height_of(S))
  S.entries, S.nxt = ents, nxt
  local lines, prefixes, plain, cr = {}, {}, {}, {}
  for i, ent in ipairs(ents) do
    lines[i], prefixes[i], plain[i], cr[i] = line_text(S.r, ent, S.col, M.opts.line_cap)
  end
  if #lines == 0 then lines[1] = "" end
  S.shown, S.plain, S.cr = lines, plain, cr

  -- Setting the lines is not an edit: drop the buffer's own undo history with it
  vim.bo[S.buf].undolevels = -1
  vim.bo[S.buf].modifiable = true
  vim.api.nvim_buf_set_lines(S.buf, 0, -1, false, lines)
  vim.bo[S.buf].modifiable = S.editable
  vim.bo[S.buf].undolevels = S.editable and 1000 or -1
  vim.bo[S.buf].modified = S.r.log_pos > 0

  vim.api.nvim_buf_clear_namespace(S.buf, NS, 0, -1)
  local m = S.match
  if m then
    for i, ent in ipairs(ents) do
      local from = m.pos - ent.off - S.col
      if m.pos >= ent.off + S.col and m.pos < ent.e and from + m.len <= #lines[i] - prefixes[i] then
        vim.api.nvim_buf_set_extmark(S.buf, NS, i - 1, from + prefixes[i], {
          end_col = from + prefixes[i] + m.len,
          hl_group = "Search",
        })
      end
    end
  end

  local win = win_of(S)
  if win then
    S.row = math.max(1, math.min(S.row, #lines))
    vim.api.nvim_win_set_cursor(win, { S.row, 0 })
    vim.cmd.redrawstatus()
  end
end

---------------------------------------------------------------------------------------------------
-- Editing: the window's lines are diffed against what was shown and become piece table edits
---------------------------------------------------------------------------------------------------

local function saving(S) return S.job ~= nil and S.job.exclusive == true end

local function sync_row(S)
  local win = win_of(S)
  if win then S.row = vim.api.nvim_win_get_cursor(win)[1] end
end

-- Piece table edits for the lines in the buffer, or nil and the reason they cannot be made.
local function pending_edits(S, cur)
  local ents, r = S.entries, S.r
  if #ents == 0 then
    if #cur == 1 and cur[1] == "" then return {} end
    return { { start = 0, stop = 0, text = table.concat(cur, "\n") .. "\n" } }
  end
  local hunks = vim.diff(
    table.concat(S.shown, "\n") .. "\n",
    table.concat(cur, "\n") .. "\n",
    { result_type = "indices" }
  )
  local last = ents[#ents]
  local no_final_newline = not last.term and last.nxt >= r.size
  local edits = {}
  for h = #hunks, 1, -1 do
    local sa, ca, sb, cb = unpack(hunks[h])
    for i = sa, sa + ca - 1 do
      if not S.plain[i] then
        return nil, string.format("line %d is shown cut or altered (long, NUL bytes or not a whole line): it cannot be edited", i)
      end
    end
    local start, stop
    if ca > 0 then
      start, stop = ents[sa].off, ents[sa + ca - 1].nxt
    elseif sa == 0 then
      start = ents[1].off
      stop = start
    else
      start = ents[sa].nxt
      stop = start
    end
    local eol = S.cr[math.max(sa, 1)] and "\r\n" or "\n"
    local text = ""
    if cb > 0 then
      text = table.concat(cur, eol, sb, sb + cb - 1) .. eol
      if no_final_newline and stop >= r.size then
        text = text:sub(1, -#eol - 1)
        if ca == 0 then text = "\n" .. text end
      end
    end
    edits[#edits + 1] = { start = start, stop = stop, text = text }
  end
  return edits
end

local function window_lines(S) return vim.api.nvim_buf_get_lines(S.buf, 0, -1, false) end

local function is_pending(S)
  return S.editable and S.shown ~= nil and not vim.deep_equal(window_lines(S), S.shown)
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

function M.render(S)
  if saving(S) then return end
  apply_pending(S)
  draw(S)
end

-- Runs first in every movement: the edits made in the window must be in the piece table before
-- offsets are computed from it.
local function before_move(S)
  if saving(S) then
    vim.notify("Stream view: saving, wait for it or cancel it with <C-c>", vim.log.levels.WARN)
    return false
  end
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
  local size = S.r.size
  S.offset = size == 0 and 0 or S.r:seg_start(math.min(at, size - 1))
  S.row = 1
  S.match = nil
  draw(S)
end

-- Undo first takes back what is typed in the window, then the edits made earlier wherever they are.
function M.undo(S)
  if saving(S) then return before_move(S) end
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
  if saving(S) then return before_move(S) end
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
  S.follow = nil
  vim.cmd.redrawstatus()
end

function M.scroll(S, n)
  if not before_move(S) then return end
  stop_follow(S)
  local size = S.r:refresh()
  if n > 0 then
    for _ = 1, n do
      local _, nxt = S.r:seg_end(S.offset)
      if nxt >= size then break end
      S.offset = nxt
    end
  else
    for _ = 1, -n do
      if S.offset == 0 then break end
      S.offset = S.r:seg_start(S.offset - 1)
    end
  end
  M.render(S)
end

-- Moves the cursor; the window scrolls only when the cursor is at its edge.
function M.move(S, n)
  sync_row(S)
  local rows = vim.api.nvim_buf_line_count(S.buf)
  local row = S.row + n
  local function put_cursor(r)
    S.row = r
    local win = win_of(S)
    if win then vim.api.nvim_win_set_cursor(win, { r, 0 }) end
  end
  if row > rows then
    put_cursor(rows)
    M.scroll(S, row - rows)
  elseif row < 1 then
    put_cursor(1)
    M.scroll(S, row - 1)
  else
    put_cursor(row)
  end
end

function M.page(S, pages)
  M.scroll(S, pages * height_of(S))
end

function M.half_page(S, dir)
  M.scroll(S, dir * math.max(1, math.floor(height_of(S) / 2)))
end

function M.head(S)
  if not before_move(S) then return end
  stop_follow(S)
  S.offset, S.row = 0, 1
  M.render(S)
end

function M.tail(S)
  if not before_move(S) then return end
  S.r:refresh()
  S.offset = S.r:tail_offset(height_of(S))
  S.row = height_of(S)
  M.render(S)
end

-- spec: a byte offset (number or "1234"), or a percentage ("60%", "12.5%")
function M.goto_offset(S, spec)
  if not before_move(S) then return nil, "saving" end
  stop_follow(S)
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
  S.offset = size == 0 and 0 or S.r:seg_start(math.max(0, math.min(target, size - 1)))
  S.row = 1
  M.render(S)
  return S.offset
end

-- Like tail -f: polls the size and keeps the end of the file in view. Any other movement stops it.
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
      local size = S.r:refresh()
      if size ~= last then
        last = size
        M.tail(S)
      end
    end)
  )
  vim.cmd.redrawstatus()
end

function M.hscroll(S, dir)
  if not before_move(S) then return end
  local longest = 0
  for _, ent in ipairs(S.entries) do
    longest = math.max(longest, ent.e - ent.off)
  end
  S.col = math.max(0, math.min(S.col + dir * math.floor(M.opts.line_cap / 2), longest - 1))
  M.render(S)
end

function M.lines(S) return vim.api.nvim_buf_get_lines(S.buf, 0, -1, false) end

function M.winbar()
  local S = states[vim.api.nvim_win_get_buf(vim.g.statusline_winid or 0)]
  if not S then return "" end
  local size = S.r.size
  local parts = {
    " STREAM",
    vim.fn.fnamemodify(S.path, ":t"):gsub("%%", "%%%%"),
    string.format("%d / %d (%s)", S.offset, size, human(size)),
    string.format("%.1f%%", size > 0 and S.offset / size * 100 or 100),
  }
  if vim.bo[S.buf].modified then parts[#parts + 1] = "[+]" end
  if S.col > 0 then parts[#parts + 1] = "col +" .. S.col end
  if S.follow then parts[#parts + 1] = "FOLLOW" end
  local job = S.job
  if job then
    local pct = job.span > 0 and job.done_bytes / job.span * 100 or 100
    parts[#parts + 1] = string.format("%s %d%% (<C-c> cancels)", job.label, pct)
  end
  return table.concat(parts, "  ")
end

---------------------------------------------------------------------------------------------------
-- Search: literal text, scanned block by block from the cursor line
---------------------------------------------------------------------------------------------------

-- A match can straddle two blocks, so the last m-1 bytes of the scanned side are carried over.
local function scan_forward(r, pat, from, tick)
  local m = #pat
  local pos, tail = from, ""
  while pos < r.size do
    local index = math.floor(pos / r.bs)
    local base = index * r.bs
    local data = r:block(index)
    if data == "" then return nil end
    local win = tail .. data:sub(pos - base + 1)
    local i = win:find(pat, 1, true)
    if i then return pos - #tail + i - 1 end
    tail = m > 1 and win:sub(-(m - 1)) or ""
    pos = base + r.bs
    tick(pos)
  end
end

-- Finds the last match that starts before `before`.
local function scan_backward(r, pat, before, tick)
  local m = #pat
  local reversed = pat:reverse()
  local hi, after = math.min(before, r.size), ""
  while hi > 0 do
    local index = math.floor((hi - 1) / r.bs)
    local base = index * r.bs
    local win = r:block(index):sub(1, hi - base) .. after
    local i = win:reverse():find(reversed, 1, true)
    if i then return base + #win - i - m + 1 end
    after = win:sub(1, m - 1)
    hi = base
    tick(hi)
  end
end

function M.cancel(S)
  local job = S.job
  if not job then return end
  job.cancelled = true
  S.job = nil
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
function M.search(S, pat, forward, done)
  if not before_move(S) then
    if done then done(nil, "saving") end
    return
  end
  M.cancel(S)
  stop_follow(S)
  if pat == "" or #pat >= S.r.bs then
    if done then done(nil, "the pattern must be 1 to " .. (S.r.bs - 1) .. " bytes") end
    return
  end
  S.r:refresh()
  local cur = S.entries[S.row]
  local origin = cur and cur.off or 0
  local m = S.match
  if cur and m and m.pos >= cur.off and m.pos < cur.e then origin = forward and m.pos + 1 or m.pos end
  S.last_search = { pat = pat, forward = forward }

  local scan = forward and scan_forward or scan_backward
  run_job(S, "searching", forward and S.r.size - origin or origin, function(tick)
    return scan(S.r, pat, origin, function(pos) tick(math.abs(pos - origin)) end)
  end, function(pos, err)
    if pos then
      S.match = { pos = pos, len = #pat }
      S.offset = S.r:seg_start(pos)
      S.row = 1
      M.render(S)
    end
    if done then done(pos, err) end
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

-- Free bytes on the file system of `dir`; replaced in tests.
function M.free_bytes(dir)
  local st = uv.fs_statfs(dir)
  return st and st.bavail * st.bsize or nil
end

-- Gives the new file its owner; replaced in tests.
function M.fchown(fd, uid, gid) return uv.fs_fchown(fd, uid, gid) end

-- True when every edit replaced text by text of the same length, so the changes can be written over
-- the file where they are.
local function patchable(r)
  if r.size ~= r.file_size then return false end
  for i, piece in ipairs(r.pieces) do
    if not piece.str and piece.off ~= r.starts[i] then return false end
  end
  return true
end

local function write_all(fd, data, pos)
  local done = 0
  while done < #data do
    local n, err = uv.fs_write(fd, done == 0 and data or data:sub(done + 1), pos + done)
    if not n then return nil, err end
    done = done + n
  end
  return true
end

-- Re-opens the saved file as the viewer's file. The edit history ends with the save.
local function reopen(S)
  local r, err = M.open_reader(S.path)
  if not r then return nil, err end
  -- Text typed while the save ran is not in the file: it goes on as an edit of the new file, whose
  -- text equals the one the typed text was written against
  local typed
  if is_pending(S) then
    local edits, perr = pending_edits(S, window_lines(S))
    if edits then
      typed = edits
    else
      vim.notify("Stream view: " .. perr .. "; the change was discarded", vim.log.levels.ERROR)
    end
  end
  S.r:close()
  S.r = r
  S.offset = r.size == 0 and 0 or r:seg_start(math.min(S.offset, r.size - 1))
  S.match = nil
  if typed and #typed > 0 then r:apply(typed) end
  draw(S)
  return true
end

local function patch_in_place(S, r, dest)
  local fd, err = uv.fs_open(dest, "r+", 0)
  if not fd then return nil, err end
  for i, piece in ipairs(r.pieces) do
    if piece.str then
      local ok, werr = write_all(fd, piece.str:sub(piece.off + 1, piece.off + piece.len), r.starts[i])
      if not ok then
        uv.fs_close(fd)
        return nil, werr
      end
    end
  end
  uv.fs_fsync(fd)
  uv.fs_close(fd)
  return reopen(S)
end

-- opts: path (default the viewed file), force (overwrite a file changed on disk or an existing
-- other file), inplace (true: patch in place when there is no room for a copy, false: refuse,
-- nil: ask). done(ok, err) runs when the save has finished, failed or been cancelled.
function M.write(S, opts, done)
  opts = opts or {}
  local function finish(ok, err)
    if done then done(ok, err) end
  end
  if S.closed then return finish(false, "the viewer was closed") end
  if S.job then return finish(false, "busy: " .. S.job.label) end
  if not before_move(S) then return finish(false, "busy") end
  local r, rerr = S.r:snapshot()
  if not r then return finish(false, "cannot read the file again: " .. tostring(rerr)) end
  local report = finish
  finish = function(ok, err)
    r:close()
    report(ok, err)
  end
  local target = opts.path or S.path
  local dest = uv.fs_realpath(target) or vim.fn.fnamemodify(target, ":p")
  local same = dest == (uv.fs_realpath(S.path) or S.path)
  local existing = uv.fs_stat(dest)

  if same and S.r:pristine() then return finish(true, "no changes to write") end
  if same and not opts.force and existing and not uv.fs_access(dest, "W") then
    return finish(false, dest .. " is read-only; use ! to write it anyway")
  end
  if same and not opts.force and r:changed_on_disk() then
    return finish(false, S.path .. " changed on disk since it was opened; use ! to overwrite it")
  end
  if not same and existing and not opts.force then
    return finish(false, dest .. " exists; use ! to overwrite it")
  end

  local dir = vim.fs.dirname(dest)
  local need = r.size
  local free = M.free_bytes(dir)
  if same and free and free < need then
    if not patchable(r) or opts.inplace == false then
      return finish(false, string.format(
        "not enough room in %s for a copy: need %s, %s free (nothing was written)", dir, human(need), human(free)
      ))
    end
    local yes = opts.inplace
    if yes == nil then
      yes = vim.fn.confirm(
        string.format("Not enough room for a copy (%s free, %s needed). Patch the file in place? It is not atomic.", human(free), human(need)),
        "&Patch in place\n&Cancel",
        2
      ) == 1
    end
    if not yes then return finish(false, "not saved: no room for a copy") end
    local ok, err = patch_in_place(S, r, dest)
    return finish(ok, err)
  end

  local src = (same and r.stat) or existing or r.stat
  local tmp = string.format("%s/.%s.streamview-%d.tmp", dir, vim.fs.basename(dest), uv.os_getpid())
  local fd, err = uv.fs_open(tmp, "wx", 384)
  if not fd then return finish(false, string.format("cannot create %s: %s (the file was not touched)", tmp, tostring(err))) end
  local function abort(msg)
    uv.fs_close(fd)
    uv.fs_unlink(tmp)
    return finish(false, msg .. " (the file was not touched)")
  end
  local mode_ok, mode_err = uv.fs_fchmod(fd, bit.band(src.mode, 4095))
  if not mode_ok then return abort("cannot set the mode: " .. tostring(mode_err)) end
  local owner_ok, owner_err = M.fchown(fd, src.uid, src.gid)
  if not owner_ok and not opts.force then
    return abort(string.format("cannot keep the owner %d:%d: %s; use ! to save with a new owner", src.uid, src.gid, tostring(owner_err)))
  end

  local chunk = r.bs * 4
  run_job(S, "writing", r.size, function(tick)
    local pos = 0
    while pos < r.size do
      local ok, werr = write_all(fd, r:get(pos, chunk), pos)
      if not ok then return nil, "write failed: " .. tostring(werr) end
      pos = pos + chunk
      tick(math.min(pos, r.size))
    end
    if same and r:changed_on_disk() and not opts.force then return nil, S.path .. " changed on disk while it was being saved" end
    local synced, serr = uv.fs_fsync(fd)
    if not synced then return nil, "fsync failed: " .. tostring(serr) end
    uv.fs_close(fd)
    fd = nil
    local renamed, rerr = uv.fs_rename(tmp, dest)
    if not renamed then return nil, string.format("cannot rename %s over %s: %s", tmp, dest, tostring(rerr)) end
    tmp = nil
    local dfd = uv.fs_open(dir, "r", 0)
    if dfd then
      uv.fs_fsync(dfd)
      uv.fs_close(dfd)
    end
    return true
  end, function(ok, werr)
    if fd then uv.fs_close(fd) end
    if tmp then uv.fs_unlink(tmp) end
    if not ok then return finish(false, werr) end
    if same then
      local reopened, oerr = reopen(S)
      if not reopened then return finish(false, "saved, but cannot reopen: " .. tostring(oerr)) end
    end
    finish(true)
  end, true)
end

local function write_command(S, o)
  local path = o.args ~= "" and vim.fn.fnamemodify(vim.fs.normalize(o.args), ":p") or nil
  M.write(S, { path = path, force = o.bang }, function(ok, err)
    if ok then
      vim.notify(err and ("Stream view: " .. err) or string.format("Stream view: wrote %s", human(S.r.size)), vim.log.levels.INFO)
    elseif err == "cancelled" then
      vim.notify("Stream view: save cancelled, the file was not touched", vim.log.levels.WARN)
    else
      vim.notify("Stream view: " .. tostring(err), vim.log.levels.ERROR)
    end
  end)
end

---------------------------------------------------------------------------------------------------
-- Attaching to a buffer
---------------------------------------------------------------------------------------------------

local function keymaps(S)
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = S.buf, nowait = true, silent = true, desc = "Stream view: " .. desc })
  end
  map("j", function() M.move(S, vim.v.count1) end, "down")
  map("<Down>", function() M.move(S, vim.v.count1) end, "down")
  map("k", function() M.move(S, -vim.v.count1) end, "up")
  map("<Up>", function() M.move(S, -vim.v.count1) end, "up")
  map("<C-d>", function() M.half_page(S, 1) end, "half page down")
  map("<C-u>", function() M.half_page(S, -1) end, "half page up")
  map("<C-f>", function() M.page(S, 1) end, "page down")
  map("<PageDown>", function() M.page(S, 1) end, "page down")
  map("<C-b>", function() M.page(S, -1) end, "page up")
  map("<PageUp>", function() M.page(S, -1) end, "page up")
  map("gg", function() M.head(S) end, "start of file")
  map("G", function() M.tail(S) end, "end of file")
  map("zL", function() M.hscroll(S, 1) end, "page right within long lines")
  map("zH", function() M.hscroll(S, -1) end, "page left within long lines")
  if S.editable then
    map("u", function() for _ = 1, vim.v.count1 do M.undo(S) end end, "undo (across windows)")
    map("<C-r>", function() for _ = 1, vim.v.count1 do M.redo(S) end end, "redo (across windows)")
  end
  map("/", function() M.prompt_search(S, true) end, "search forward (literal text)")
  map("?", function() M.prompt_search(S, false) end, "search backward (literal text)")
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

local function mem_available()
  local f = io.open("/proc/meminfo", "r")
  if not f then return nil end
  local kb = f:read("*a"):match("MemAvailable:%s*(%d+)%s*kB")
  f:close()
  return kb and tonumber(kb) * 1024
end

-- vim.g.stream_viewer_min_bytes overrides; otherwise half of the available memory, at least
-- opts.min_bytes.
function M.threshold()
  local override = vim.g.stream_viewer_min_bytes
  if type(override) == "number" then return override end
  return math.max(M.opts.min_bytes, (mem_available() or 0) / 2)
end

local function is_too_big(path)
  local st = uv.fs_stat(path)
  return st ~= nil and st.type == "file" and st.size > M.threshold()
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
  if name == "" or name:find("^%a[%w+.-]*://") or not is_too_big(name) then return end
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
  local group = vim.api.nvim_create_augroup("streamview", { clear = true })
  vim.api.nvim_create_autocmd("BufNew", {
    group = group,
    callback = function(ev) intercept(ev.buf) end,
  })
  -- Files named on the command line get their buffers after this runs, without BufNew
  for _, arg in ipairs(vim.fn.argv()) do
    local path = vim.fn.fnamemodify(arg, ":p")
    if is_too_big(path) then
      take_over_read(path, { group = group, pattern = vim.fn.escape(path, "\\*?[]{},") })
    end
  end

  vim.api.nvim_create_user_command("StreamView", open_command, {
    nargs = "?",
    bang = true,
    complete = "file",
    desc = "Open a file in the stream viewer (the current file by default); ! abandons a modified buffer",
  })
  vim.api.nvim_create_user_command("StreamGoto", function(o)
    local S = current_state()
    if not S then return end
    local _, err = M.goto_offset(S, o.args)
    if err then vim.notify("StreamGoto: " .. err, vim.log.levels.ERROR) end
  end, { nargs = 1, desc = "Stream view: jump to a byte offset or a percentage (60%)" })

  vim.api.nvim_create_user_command("StreamWrite", function(o)
    local S = current_state()
    if S then write_command(S, o) end
  end, {
    nargs = "?",
    bang = true,
    complete = "file",
    desc = "Stream view: save the edits (to [path]); ! overwrites a file changed on disk or an existing path",
  })
  vim.api.nvim_create_user_command("StreamFollow", function()
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

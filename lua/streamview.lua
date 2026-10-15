-- Read-only paged viewer for files too big to load into a buffer.
-- The file is never read whole: a window of lines is rebuilt from fixed-size blocks at a byte
-- offset, so memory use does not depend on the file size.
local uv = vim.uv
local M = {}

M.opts = {
  block = 256 * 1024, -- read unit; at most two blocks of file data are held at a time
  line_cap = 64 * 1024, -- bytes of one line shown at once; the rest is reached by horizontal paging
  segment = 16 * 1024 * 1024, -- longest line scanned; a longer one is split at multiples of this
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
    size = st.size,
    bs = M.opts.block,
    seg = M.opts.segment,
    cache = {}, -- most recent first: { index, data }
  }, Reader)
end

function Reader:close()
  if self.fd then uv.fs_close(self.fd) end
  self.fd, self.cache = nil, {}
end

function Reader:refresh()
  local st = self.fd and uv.fs_fstat(self.fd)
  if st then self.size = st.size end
  return self.size
end

function Reader:block(index)
  for i, hit in ipairs(self.cache) do
    if hit[1] == index then
      if i > 1 then table.insert(self.cache, 1, table.remove(self.cache, i)) end
      return hit[2]
    end
  end
  local data = self.fd and uv.fs_read(self.fd, self.bs, index * self.bs) or ""
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

-- Lines are cut at "\n" or at multiples of the segment size, so a line never needs more than one
-- segment of scanning in either direction, and the cuts depend only on the file contents.
function Reader:seg_start(off)
  local floor = off - off % self.seg
  local nl = self:find_nl_back(off, floor)
  return nl and nl + 1 or floor
end

-- Returns the offset where the line ends (its "\n", or the cut), the start of the next line,
-- and whether a "\n" ended it.
function Reader:seg_end(start)
  local limit = math.min(self.size, start - start % self.seg + self.seg)
  local nl = self:find_nl(start, limit)
  if nl then return nl, nl + 1, true end
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

-- Returns the displayed text and the number of prefix bytes before the file's bytes.
local function line_text(r, ent, col, cap)
  local len = ent.e - ent.off
  local want = math.min(len - col, cap)
  local more = len - col - want
  local text = ""
  if want > 0 then
    text = r:get(ent.off + col, want)
    if more > 0 then
      text = cut_partial_tail(text)
    elseif ent.term and text:sub(-1) == "\r" then
      text = text:sub(1, -2)
    end
    if col > 0 then text = text:gsub("^[\128-\191]?[\128-\191]?[\128-\191]?", "") end
    text = text:gsub("%z", NUL_SYMBOL)
  end
  local prefix = col > 0 and ELLIPSIS or ""
  if more > 0 then text = text .. string.format("%s[+%d bytes]", ELLIPSIS, more) end
  return prefix .. text, #prefix
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

function M.render(S)
  S.r:refresh()
  local ents, nxt = S.r:window(S.offset, height_of(S))
  S.entries, S.nxt = ents, nxt
  local lines, prefixes = {}, {}
  for i, ent in ipairs(ents) do
    lines[i], prefixes[i] = line_text(S.r, ent, S.col, M.opts.line_cap)
  end
  if #lines == 0 then lines[1] = "" end

  vim.bo[S.buf].modifiable = true
  vim.api.nvim_buf_set_lines(S.buf, 0, -1, false, lines)
  vim.bo[S.buf].modifiable = false
  vim.bo[S.buf].modified = false

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

function M.scroll(S, n)
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
  local rows = #S.entries
  local row = S.row + n
  if row > rows then
    S.row = rows
    M.scroll(S, row - rows)
  elseif row < 1 then
    S.row = 1
    M.scroll(S, row - 1)
  else
    S.row = row
    local win = win_of(S)
    if win then vim.api.nvim_win_set_cursor(win, { row, 0 }) end
  end
end

function M.page(S, pages)
  M.scroll(S, pages * height_of(S))
end

function M.half_page(S, dir)
  M.scroll(S, dir * math.max(1, math.floor(height_of(S) / 2)))
end

function M.head(S)
  S.offset, S.row = 0, 1
  M.render(S)
end

function M.tail(S)
  S.r:refresh()
  S.offset = S.r:tail_offset(height_of(S))
  S.row = height_of(S)
  M.render(S)
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
  S.offset = size == 0 and 0 or S.r:seg_start(math.max(0, math.min(target, size - 1)))
  S.row = 1
  M.render(S)
  return S.offset
end

function M.hscroll(S, dir)
  local longest = 0
  for _, ent in ipairs(S.entries) do
    longest = math.max(longest, ent.e - ent.off)
  end
  S.col = math.max(0, math.min(S.col + dir * math.floor(M.opts.line_cap / 2), longest - 1))
  M.render(S)
end

function M.lines(S) return vim.api.nvim_buf_get_lines(S.buf, 0, -1, false) end

local function human(n)
  local units = { "B", "KiB", "MiB", "GiB", "TiB", "PiB" }
  local i = 1
  while n >= 1024 and i < #units do
    n, i = n / 1024, i + 1
  end
  return i == 1 and string.format("%d B", n) or string.format("%.1f %s", n, units[i])
end

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
  if S.col > 0 then parts[#parts + 1] = "col +" .. S.col end
  return table.concat(parts, "  ")
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
  map("%", function()
    local count = vim.v.count
    if count > 0 then
      M.goto_offset(S, math.min(count, 100) .. "%")
    else
      vim.cmd("normal! %")
    end
  end, "jump to {count} percent")
end

local function setup_buffer_options(buf)
  vim.b[buf].bigfile = true
  vim.b[buf].sleuth_automatic = 0
  local bo = vim.bo[buf]
  bo.buftype = "nofile"
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
  if S.on_close then S.on_close() end
  S.r:close()
  states[S.buf] = nil
end

-- Turns `buf` into a viewer of `path`. Returns the state, or nil and an error.
function M.attach(buf, path)
  if states[buf] then close(states[buf]) end
  local r, err = M.open_reader(path)
  if not r then return nil, err end
  local S = { buf = buf, path = path, r = r, offset = 0, col = 0, row = 1, entries = {}, nxt = 0 }
  states[buf] = S
  setup_buffer_options(buf)
  keymaps(S)

  local group = vim.api.nvim_create_augroup("streamview-" .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufUnload" }, {
    group = group,
    buffer = buf,
    callback = function() close(S) end,
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

-- Replaces the read of a not yet loaded buffer by the viewer when the file is too big.
local function intercept(buf)
  if vim.bo[buf].buftype ~= "" or vim.api.nvim_buf_is_loaded(buf) then return end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" or name:find("^%a[%w+.-]*://") or not is_too_big(name) then return end
  vim.api.nvim_create_autocmd("BufReadCmd", {
    buffer = buf,
    once = true,
    callback = function()
      local S, err = M.attach(buf, name)
      if not S then
        vim.notify("Stream view: " .. tostring(err), vim.log.levels.ERROR)
        return
      end
      vim.notify(
        string.format("%s is %s: opened in the stream viewer, not loaded", vim.fn.fnamemodify(name, ":t"), human(S.r.size)),
        vim.log.levels.WARN
      )
    end,
  })
end

local function open_command(o)
  local path = o.args ~= "" and vim.fn.fnamemodify(vim.fn.expand(o.args), ":p")
    or vim.api.nvim_buf_get_name(0)
  if path == "" then
    vim.notify("StreamView: no file", vim.log.levels.ERROR)
    return
  end
  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_name(buf, "stream://" .. path)
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
  -- Buffers for the files named on the command line exist before this runs
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    intercept(buf)
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

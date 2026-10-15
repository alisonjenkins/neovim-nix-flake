-- Navigation in the stream viewer when lines are longer than the buffer: the buffer holds a slice of
-- the line around the cursor, which slides through the line, and the cursor lives in absolute bytes of
-- the file. Sparse files with planted text keep the lines huge and cheap; the line numbers and offsets
-- are those of the file, not of the buffer.
local h = dofile(os.getenv("TEST_DIR") .. "/harness.lua")
local tmp = os.getenv("TMPDIR") or "/tmp"
local uv = vim.uv
local sv = require("streamview")

local MB = 1024 * 1024

local function write(name, data)
  local path = tmp .. "/" .. name
  local f = assert(io.open(path, "wb"))
  f:write(data)
  f:close()
  return path
end

-- A sparse file of `size` bytes with `planted` = { [offset] = text }
local function sparse(name, size, planted)
  local path = tmp .. "/" .. name
  local fd = assert(uv.fs_open(path, "w", 420))
  uv.fs_ftruncate(fd, size)
  for off, text in pairs(planted) do
    uv.fs_write(fd, text, off)
  end
  uv.fs_close(fd)
  return path
end

local function read_range(path, off, len)
  local f = assert(io.open(path, "rb"))
  f:seek("set", off)
  local data = f:read(len)
  f:close()
  return data
end

local function open(path)
  vim.cmd("StreamView! " .. vim.fn.fnameescape(path))
  return sv.state()
end

-- Movements that scan far are jobs: wait for them
local function settle(S)
  vim.wait(120000, function() return S.job == nil end, 5)
end

local function eq(a, b, name)
  h.check(vim.deep_equal(a, b), name, vim.inspect(a):sub(1, 200) .. " ~= " .. vim.inspect(b):sub(1, 200))
end

local function rss_mb()
  local f = io.open("/proc/self/status")
  local text = f:read("*a")
  f:close()
  return tonumber(text:match("VmRSS:%s*(%d+)")) / 1024
end

local function valid_utf8(s)
  local i = 1
  while i <= #s do
    local b = s:byte(i)
    local n = b < 0x80 and 1 or (b >= 0xC2 and b <= 0xDF) and 2 or (b >= 0xE0 and b <= 0xEF) and 3 or (b >= 0xF0 and b <= 0xF4) and 4 or 0
    if n == 0 then return false end
    for k = 1, n - 1 do
      local c = s:byte(i + k)
      if not c or c < 0x80 or c > 0xBF then return false end
    end
    i = i + n
  end
  return true
end

local function set_lines(first, last, lines)
  vim.api.nvim_buf_set_lines(0, first, last, false, lines)
end

local function save(S, opts)
  local res
  sv.write(S, opts, function(ok, err) res = { ok = ok, err = err } end)
  vim.wait(120000, function() return res ~= nil end, 5)
  return res or { ok = false, err = "timed out" }
end

local function winbar_of(S)
  vim.g.statusline_winid = vim.fn.bufwinid(S.buf)
  return sv.winbar()
end

sv.opts.block = 256 * 1024
sv.opts.editable = true

-- Random motions on the viewer against Neovim's own on a normal buffer with the same text. The
-- slice is small and the scan budget too, so the motions cross slice edges and some take a job.
local function motion_trials(name, lines, keys, trials, counts, chars)
  local saved = { sv.opts.slice, sv.opts.sync_scan }
  sv.opts.slice, sv.opts.sync_scan = 4096, 64 * 1024
  local text = table.concat(lines, "\n") .. "\n"
  local path = write(name, text)
  local starts = {}
  local pos = 0
  for i, l in ipairs(lines) do
    starts[i] = pos
    pos = pos + #l + 1
  end
  local function to_lc(abs)
    for i = #starts, 1, -1 do
      if abs >= starts[i] then return i, abs - starts[i] end
    end
  end

  vim.cmd("only")
  vim.cmd("new")
  local oracle = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(oracle, 0, -1, false, lines)
  local owin = vim.api.nvim_get_current_win()
  vim.cmd("wincmd j")
  local function native(abs, keys_)
    local line, col = to_lc(abs)
    vim.api.nvim_win_set_cursor(owin, { line, col })
    vim.api.nvim_win_call(owin, function() vim.cmd("noautocmd normal " .. keys_) end)
    local c = vim.api.nvim_win_get_cursor(owin)
    return starts[c[1]] + c[2]
  end

  local V = open(path)
  local mismatches, total = {}, 0
  local long = {}
  for i, l in ipairs(lines) do
    if #l > 1000 then long[#long + 1] = i end
  end
  for trial = 1, trials do
    local line_no = math.random(3) == 1 and math.random(#lines) or long[math.random(#long)]
    local abs = starts[line_no] + (#lines[line_no] > 0 and math.random(0, #lines[line_no] - 1) or 0)
    abs = V.r:align_down(abs)
    sv.goto_abs(V, abs)
    settle(V)
    local key = keys[math.random(#keys)]
    local count = counts[math.random(#counts)]
    local ch = chars[math.random(#chars)]
    if key == "0" or key == "^" then count = 0 end
    local before = sv.cursor_abs(V)
    local mkeys, arg = (count > 0 and count or "") .. key, nil
    if key == "f" or key == "F" or key == "t" or key == "T" then
      arg = ch
      mkeys = mkeys .. ch
    elseif key == "|" then
      count = count == 0 and 1 or count
      mkeys = count .. "|"
    end
    local want = native(before, mkeys)
    sv.hmove(V, key, count, arg)
    settle(V)
    local got = sv.cursor_abs(V)
    total = total + 1
    if got ~= want then
      local line, col = to_lc(before)
      mismatches[#mismatches + 1] = string.format("%s from %d (line %d col %d, after %q): got %d want %d", mkeys, before, line, col, text:sub(math.max(1, before - 20), before + 1), got, want)
    end
    if (key == "f" or key == "F" or key == "t" or key == "T") and trial % 2 == 0 then
      local rep = math.random(2) == 1 and ";" or ","
      local line, col = to_lc(want)
      vim.api.nvim_win_set_cursor(owin, { line, col })
      vim.api.nvim_win_call(owin, function() vim.cmd("noautocmd normal " .. rep) end)
      local c = vim.api.nvim_win_get_cursor(owin)
      local want2 = starts[c[1]] + c[2]
      sv.goto_abs(V, got)
      settle(V)
      sv.hmove(V, rep, 0)
      settle(V)
      local got2 = sv.cursor_abs(V)
      total = total + 1
      if got2 ~= want2 then
        mismatches[#mismatches + 1] = string.format("%s%s from %d: got %d want %d", mkeys, rep, got, got2, want2)
      end
    end
  end
  sv.opts.slice, sv.opts.sync_scan = unpack(saved)
  return total, mismatches
end

local S
local first = "first line\n"
local line_len = 64 * MB
local mid = #first + 32 * MB
local last_mark = #first + line_len - 8
local path64 = sparse("line64.bin", #first + line_len + 1 + #"after line\n", {
  [0] = first,
  [mid] = "MARK-MID",
  [last_mark] = "MARK-END",
  [#first + line_len] = "\nafter line\n",
})

local steps = {
  function()
    S = open(path64)
    eq(#S.entries >= 2 and S.entries[2].e == nil, true, "a line past the scan budget is an open row at first")
    eq(S.entries[1].to - S.entries[1].from, #"first line", "a short line is shown whole")
    vim.wait(20000, function() return S.bg == nil and #S.entries == 3 end, 10)
    eq(#S.entries, 3, "its end is found in the background and the rows after it appear")
    eq(S.entries[3].off, #first + line_len + 1, "at the right offset")
    h.check(S.entries[2].ropen and not S.entries[2].lopen, "the 64 MB line shows its beginning")
    h.check(S.entries[2].to - S.entries[2].from <= 64 * 1024, "only a head of it, as the cursor is not on it")
  end,

  function()
    -- jump into the middle of the line
    local t0 = uv.hrtime()
    sv.goto_abs(S, mid)
    settle(S)
    local cold = (uv.hrtime() - t0) / 1e6
    eq(S.entries[1].off, #first, "the first row is the line the byte is in")
    eq(sv.cursor_abs(S), mid, "the cursor is on the byte, in absolute coordinates")
    local row = S.entries[1]
    eq(sv.lines(S)[1]:sub(mid - row.from + 1, mid - row.from + 8), "MARK-MID", "and on the planted text")
    h.check(row.to - row.from <= sv.opts.slice, "the slice is at most the slice size")
    h.check(row.lopen and row.ropen, "the line goes on on both sides of it")
    eq(sv.lines(S)[1], read_range(path64, row.from, row.to - row.from), "the slice is the bytes of the file")
    h.check(winbar_of(S):find("col 33,554,432 / 67,108,864 (50%)", 1, true) ~= nil, "the winbar shows where in the line the cursor is", winbar_of(S))
    t0 = uv.hrtime()
    sv.goto_abs(S, mid + 100)
    local warm = (uv.hrtime() - t0) / 1e6
    h.check(warm < 100, string.format("a second jump into the same line is quick (cold %.0f ms, warm %.1f ms)", cold, warm))
  end,

  function()
    -- the slice slides when the cursor gets near its edge
    local win = vim.fn.bufwinid(S.buf)
    local row = S.entries[1]
    local before_from = row.from
    local width = row.to - row.from
    local abs = mid + 100
    vim.api.nvim_win_set_cursor(win, { 1, width - 1000 })
    local target = row.from + width - 1000
    sv.check_slice(S)
    row = S.entries[1]
    h.check(row.from > before_from, "a cursor near the end of the slice moves the slice on", row.from .. " vs " .. before_from)
    eq(sv.cursor_abs(S), target, "and the cursor stays on the same byte")
    h.check(row.to - row.from <= sv.opts.slice and target - row.from > width / 4, "well inside the new slice")
    eq(sv.lines(S)[1], read_range(path64, row.from, row.to - row.from), "which is the bytes of the file")

    -- and back, near the start
    vim.api.nvim_win_set_cursor(win, { 1, 500 })
    local target2 = row.from + 500
    sv.check_slice(S)
    row = S.entries[1]
    eq(sv.cursor_abs(S), target2, "a cursor near the start moves the slice back on the same byte")
    h.check(target2 - row.from > width / 4, "well inside the slice again")
    _ = abs
  end,

  function()
    -- an edit in the slice replaces just those bytes
    sv.goto_abs(S, mid)
    settle(S)
    local row = S.entries[1]
    local text = sv.lines(S)[1]
    local at = mid - row.from
    set_lines(0, 1, { text:sub(1, at) .. "mark-mid" .. text:sub(at + 9) })
    sv.scroll(S, 0)
    eq(S.r.size, #first + line_len + 1 + #"after line\n", "the size did not change")
    eq(S.r:get(mid, 8), "mark-mid", "the edit is in the file at its offset")
    h.check(#S.r.pieces <= 3, "and costs a few pieces, not the line", tostring(#S.r.pieces))
    eq(S.r:get(mid - 4, 4) .. S.r:get(mid + 8, 4), "\0\0\0\0\0\0\0\0", "the bytes around it are untouched")
    eq(S.r:get(last_mark, 8), "MARK-END", "so is the end of the line")
    sv.undo(S)
    eq(S.r:get(mid, 8), "MARK-MID", "undo puts it back")
    sv.redo(S)
    eq(S.r:get(mid, 8), "mark-mid", "and redo again")
    local res = save(S)
    h.check(res.ok, "the file saves", tostring(res.err))
    eq(read_range(path64, mid, 8), "mark-mid", "the edit is in the saved file")
    eq(read_range(path64, last_mark, 8), "MARK-END", "and the rest is as it was")
    eq(read_range(path64, #first + line_len, 12), "\nafter line\n", "including the lines after")
    eq(uv.fs_stat(path64).size, #first + line_len + 1 + #"after line\n", "and the size")
  end,

  function()
    -- the end of the file with a huge line before it
    sv.tail(S)
    settle(S)
    local l = sv.lines(S)
    eq(l[#l], "after line", "G shows the last line")
    eq(#S.entries, 3, "with the lines before it")
    sv.scroll(S, 1)
    settle(S)
    eq(S.offset, #first, "j goes on to the long line")
    sv.scroll(S, 1)
    settle(S)
    eq(S.offset, #first + line_len + 1, "and over it, to the line after")
    sv.scroll(S, -1)
    settle(S)
    eq(S.offset, #first, "k goes back to the start of the long line")
    sv.scroll(S, -1)
    settle(S)
    eq(S.offset, 0, "and to the line before it")
  end,

  function()
    -- slices never start or end inside a UTF-8 character
    local saved = sv.opts.slice
    sv.opts.slice = 1024
    local unit = "\195\169\226\130\172\240\159\152\128ab" -- 2, 3, 4 and 1+1 bytes
    local line = string.rep(unit, 2000) .. "\n"
    local path = write("utf8-slices.txt", line)
    local U = open(path)
    local bad = {}
    for _, abs in ipairs({ 500, 1000, 1023, 1024, 1500, 2047, 2048, 5000, 9999, 12345, 21990 }) do
      sv.goto_abs(U, abs)
      local row = U.entries[1]
      local text = sv.lines(U)[1]
      local ok = valid_utf8(text) and text == line:sub(row.from + 1, row.to)
      local cursor = sv.cursor_abs(U)
      -- the cursor is on the character holding the byte
      local start = abs
      while start > 0 and line:byte(start + 1) >= 0x80 and line:byte(start + 1) < 0xC0 do start = start - 1 end
      ok = ok and cursor == start
      if not ok then bad[#bad + 1] = abs end
    end
    eq(bad, {}, "slices at many offsets are valid UTF-8, the file's bytes, and the cursor is on its character")
    -- every slice edge as the slice slides along the line
    local edges = {}
    for abs = 1000, 4000, 7 do
      sv.goto_abs(U, abs)
      local row = U.entries[1]
      local b_from = line:byte(row.from + 1)
      local b_to = line:byte(row.to + 1)
      local from_ok = row.from == 0 or b_from < 0x80 or b_from >= 0xC0
      local to_ok = not b_to or b_to < 0x80 or b_to >= 0xC0
      if not (from_ok and to_ok) then edges[#edges + 1] = abs end
    end
    eq(edges, {}, "no slice edge is inside a character")
    sv.opts.slice = saved
  end,

  function()
    -- slices of CRLF lines: the line ending belongs to the end of the line, not to a slice edge
    local saved = sv.opts.slice
    sv.opts.slice = 1024
    local body = string.rep("a", 5000)
    local path = write("crlf-slices.txt", body .. "\r\nnext\r\n")
    local C = open(path)
    sv.goto_abs(C, 2500)
    local row = C.entries[1]
    eq(sv.lines(C)[1], body:sub(row.from + 1, row.to), "inside the line the slice is plain text")
    sv.goto_abs(C, 4990)
    row = C.entries[1]
    eq(row.to, 5001, "at the end the slice reaches the end of the line (the carriage return is part of it)")
    eq(sv.lines(C)[1], body:sub(row.from + 1), "and the carriage return is not shown")
    -- editing at the end keeps the CRLF; a line split inside the slice takes the file's ending
    local text = sv.lines(C)[1]
    set_lines(0, 1, { text:sub(1, -5) .. "bbbb" })
    sv.scroll(C, 0)
    eq(C.r:get(4990, 12), string.rep("a", 6) .. "bbbb\r\n", "an edit at the end of a CRLF line keeps its ending")
    sv.goto_abs(C, 2500)
    text = sv.lines(C)[1]
    local at = 2500 - C.entries[1].from
    set_lines(0, 1, { text:sub(1, at), text:sub(at + 1) })
    sv.scroll(C, 0)
    eq(C.r:get(2498, 6), "aa\r\naa", "a line split inside a slice gets the ending of the file")
    eq(C.r.size, 5008 + 2, "and only that was added")
    sv.undo(C)
    sv.undo(C)
    -- lines cannot be added below a slice that is not the end of its line
    sv.goto_abs(C, 2500)
    set_lines(1, 1, { "new line" })
    sv.scroll(C, 0)
    eq(C.r:get(0, 5000), body, "a line added below a slice is refused and discarded")
    sv.opts.slice = saved
  end,

  function()
    -- several long lines: the cursor row has the slice, the others show their beginning
    local saved = { sv.opts.slice, sv.opts.head }
    sv.opts.slice, sv.opts.head = 3 * MB, 64 * 1024
    local lines = {}
    for i = 1, 4 do lines[i] = string.rep(string.char(96 + i), 2 * MB + i) end
    local path = write("many-long.txt", "short\n" .. table.concat(lines, "\n") .. "\nend\n")
    local M = open(path)
    eq(#M.entries, 6, "all the rows of a window of long lines are there")
    h.check(M.entries[2].to - M.entries[2].from <= sv.opts.head, "the rows the cursor is not on show a head")
    sv.move(M, 1)
    eq(M.row, 2, "j moves down a row")
    h.check(M.entries[2].to - M.entries[2].from == 2 * MB + 1, "and the cursor row shows its whole line (it fits the slice)")
    h.check(not M.entries[2].ropen, "so it is not open")
    sv.move(M, 100)
    settle(M)
    eq(M.row, #M.entries, "j past the last row scrolls the window")
    sv.opts.slice, sv.opts.head = unpack(saved)
  end,

  function()
    -- a scan that takes a job can be cancelled, and what it learned makes the next one instant
    local saved = sv.opts.sync_scan
    sv.opts.sync_scan = 1 * MB
    local size = 1024 * MB
    local path = sparse("line1g.bin", size, { [0] = "x", [size - 12] = "TAIL-MARK\nzz" })
    local base = rss_mb()
    local peak = base
    local timer = uv.new_timer()
    timer:start(0, 10, function() peak = math.max(peak, rss_mb()) end)
    local G = open(path)
    sv.scroll(G, 1)
    h.check(G.job ~= nil, "going over a 1 GB line starts a job")
    h.check(G.job.label:find("end of the line", 1, true) ~= nil, "with a label")
    vim.wait(30, function() return false end)
    sv.cancel(G)
    eq(G.offset, 0, "cancelling it does not move the window")
    h.check(G.job == nil, "and leaves no job")
    local t0 = uv.hrtime()
    sv.scroll(G, 1)
    settle(G)
    local cold = (uv.hrtime() - t0) / 1e6
    eq(G.offset, size - 2, "the next line starts after the 1 GB one: " .. string.format("%.0f ms", cold))
    t0 = uv.hrtime()
    sv.scroll(G, -1)
    settle(G)
    local back = (uv.hrtime() - t0) / 1e6
    eq(G.offset, 0, "going back is instant, the line is known: " .. string.format("%.1f ms", back))
    h.check(back < 100, "in under 100 ms", string.format("%.1f", back))
    local loads = 0
    local load = G.r.load
    G.r.load = function(self, i)
      loads = loads + 1
      return load(self, i)
    end
    local raw_calls = 0
    local raw = G.r.raw
    G.r.raw = function(self, lo, hi)
      raw_calls = raw_calls + 1
      return raw(self, lo, hi)
    end
    sv.scroll(G, 1)
    settle(G)
    sv.scroll(G, -1)
    settle(G)
    h.check(raw_calls <= 12, "walking over the line again reads only what is shown", tostring(raw_calls))
    timer:stop()
    timer:close()
    h.check(peak - base < 300, string.format("process memory stayed bounded (+%.0f MB)", peak - base))
    sv.opts.sync_scan = saved
  end,


  function()
    math.randomseed(5)
    local alphabet = { "a", "b", "c", "d", "e", "foo", "bar", "x1", "Z", "_", "-", ".", ",", ";", ":", "(", ")", " ", " ", " ", "  ", "ab", "cd" }
    local function words(n)
      local t = {}
      for i = 1, n do t[i] = alphabet[math.random(#alphabet)] end
      return table.concat(t)
    end
    local lines = { "short line, with words", words(30000), "", "  indented (words) here;", words(8000), "last" }
    local keys = { "l", "h", "w", "W", "b", "B", "e", "E", "ge", "gE", "0", "^", "$", "|", "f", "F", "t", "T" }
    local total, mismatches = motion_trials("motions.txt", lines, keys, 1200, { 0, 0, 1, 2, 3, 7, 40, 300, 5000 }, { "a", "o", " ", "(", "x", ";" })
    h.check(#mismatches == 0, string.format("%d random motions agree with Neovim's own, across slice edges", total), table.concat(vim.list_slice(mismatches, 1, 6), "\n      "))
  end,

  function()
    -- the same with multibyte characters (2, 3 and 4 bytes), for the motions that count characters
    math.randomseed(9)
    local alphabet = { "a", "\195\169", "\226\130\172", "\240\159\152\128", "b", " ", "foo", "\195\169\195\168", ",", "x", "\226\130\172\226\130\172", " " }
    local function words(n)
      local t = {}
      for i = 1, n do t[i] = alphabet[math.random(#alphabet)] end
      return table.concat(t)
    end
    local lines = { "caf\195\169 au lait", words(12000), "", words(5000), "fin" }
    local keys = { "l", "h", "0", "$", "f", "F", "t", "T" }
    local total, mismatches = motion_trials("motions-utf8.txt", lines, keys, 600, { 0, 0, 1, 2, 3, 7, 40, 300, 3000 }, { "\195\169", "\226\130\172", "\240\159\152\128", "a", " ", "\195\168" })
    h.check(#mismatches == 0, string.format("%d random multibyte motions agree with Neovim's own", total), table.concat(vim.list_slice(mismatches, 1, 6), "\n      "))
  end,
}

h.run(steps, 600000)

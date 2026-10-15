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

-- The winbar as it is drawn: the viewer's string is evaluated as a statusline
local function winbar_of(S)
  vim.g.statusline_winid = vim.fn.bufwinid(S.buf)
  return vim.api.nvim_eval_statusline(sv.winbar(), { winid = vim.fn.bufwinid(S.buf) }).str
end

sv.opts.block = 256 * 1024
sv.opts.editable = true

-- Random motions on the viewer against Neovim's own on a normal buffer with the same text. The
-- slice is small and the scan budget too, so the motions cross slice edges and some take a job.
local function motion_trials(name, lines, keys, trials, counts, chars)
  vim.o.report = 1000000 -- no "N fewer lines" messages: one left waiting for a key would take the next keys
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
    vim.api.nvim_win_call(owin, function() vim.cmd("silent noautocmd normal " .. keys_) end)
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
      vim.api.nvim_win_call(owin, function() vim.cmd("silent noautocmd normal " .. rep) end)
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

-- Operators d, y and c with a motion, done on the file, against Neovim's own on a normal buffer:
-- the text left and the register must be the same.
local function operator_trials(name, lines, keys, trials, counts, chars)
  vim.o.report = 1000000
  local saved = { sv.opts.slice, sv.opts.sync_scan }
  sv.opts.slice, sv.opts.sync_scan = 4096, 64 * 1024
  local path = write(name, table.concat(lines, "\n") .. "\n")
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

  local V = open(path)
  local original = V.r:get(0, V.r.size)
  local bad, total = {}, 0
  local long = {}
  for i, l in ipairs(lines) do
    if #l > 1000 then long[#long + 1] = i end
  end
  for trial = 1, trials do
    local line_no = math.random(4) == 1 and math.random(#lines) or long[math.random(#long)]
    local abs = V.r:align_down(starts[line_no] + (#lines[line_no] > 0 and math.random(0, #lines[line_no] - 1) or 0))
    sv.goto_abs(V, abs)
    settle(V)
    local op = ({ "d", "y", "c" })[math.random(3)]
    local key = keys[math.random(#keys)]
    local count = counts[math.random(#counts)]
    local ch = chars[math.random(#chars)]
    if key == "0" or key == "^" then count = 0 end
    local line, col = to_lc(sv.cursor_abs(V))
    local keys_ = op .. (count > 0 and count or "") .. (key == "line" and op or key)
    if key == "f" or key == "F" or key == "t" or key == "T" then keys_ = keys_ .. ch end
    if key == "|" then
      count = count == 0 and 1 or count
      keys_ = op .. count .. "|"
    end
    -- the oracle
    vim.api.nvim_buf_set_lines(oracle, 0, -1, false, lines)
    vim.fn.setreg('"', "")
    vim.api.nvim_win_set_cursor(owin, { line, col })
    vim.api.nvim_win_call(owin, function() vim.cmd("silent noautocmd normal " .. keys_ .. (op == "c" and "\27" or "")) end)
    local after_lines = vim.api.nvim_buf_get_lines(oracle, 0, -1, false)
    local want_text = (#after_lines == 1 and after_lines[1] == "") and "" or table.concat(after_lines, "\n") .. "\n"
    local want_reg = vim.fn.getreg('"')
    -- the viewer
    vim.fn.setreg('"', "")
    sv.far_op(V, op, key, math.max(count, 1), (key == "f" or key == "F" or key == "t" or key == "T") and ch or nil)
    settle(V)
    if op == "c" then vim.cmd("stopinsert") end
    local got_text = V.r:get(0, V.r.size)
    local got_reg = vim.fn.getreg('"')
    total = total + 1
    -- a failed motion leaves the text as it was and the register empty
    if got_text ~= want_text or (op ~= "c" or want_reg ~= "") and got_reg ~= want_reg then
      bad[#bad + 1] = string.format("%s from line %d col %d: text %s, register %s", keys_, line, col, got_text == want_text and "same" or "differs", got_reg == want_reg and "same" or string.format("%q ~= %q", got_reg:sub(1, 40), want_reg:sub(1, 40)))
    end
    -- back to the original text
    while V.r.log_pos > 0 do V.r:undo() end
    V.r.log = {}
    sv.goto_abs(V, abs)
    settle(V)
    if V.r:get(0, V.r.size) ~= original then
      bad[#bad + 1] = "the text did not come back after " .. keys_
      break
    end
  end
  sv.opts.slice, sv.opts.sync_scan = unpack(saved)
  return total, bad
end

local S, G1
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
    -- A message printed while Neovim starts (the config's direnv, say) leaves a hit-enter prompt
    -- waiting for a key, which takes the keys typed in the tests: answer it through the input queue
    vim.api.nvim_input("\r")
  end,

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
    if not h.sparse_supported(tmp) then return h.skip("scan a 1 GB line: no sparse files here") end
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
    h.check(G.job.label:find("counting lines", 1, true) ~= nil, "with a label")
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

  function()
    math.randomseed(21)
    local alphabet = { "a", "b", "c", "d", "e", "foo", "bar", "x1", "Z", "_", "-", ".", ",", ";", ":", "(", ")", " ", " ", " ", "  ", "ab", "cd" }
    local function words(n)
      local t = {}
      for i = 1, n do t[i] = alphabet[math.random(#alphabet)] end
      return table.concat(t)
    end
    local lines = { "short line, with words", words(6000), "", "  indented (words) here;", words(3000), "last" }
    local keys = { "l", "h", "w", "W", "b", "B", "e", "E", "ge", "gE", "0", "^", "$", "|", "f", "F", "t", "T", "j", "k", "line" }
    local total, bad = operator_trials("operators.txt", lines, keys, 700, { 0, 0, 1, 2, 3, 7, 40 }, { "a", "o", " ", "(", "x", ";" })
    h.check(#bad == 0, string.format("%d random d/y/c operators on the file give what Neovim's give", total), table.concat(vim.list_slice(bad, 1, 6), "\n      "))
  end,

  function()
    math.randomseed(77)
    local alphabet = { "a", "\195\169", "\226\130\172", "\240\159\152\128", "b", " ", "foo", "\195\169\195\168", ",", "x", "\226\130\172\226\130\172", " " }
    local function words(n)
      local t = {}
      for i = 1, n do t[i] = alphabet[math.random(#alphabet)] end
      return table.concat(t)
    end
    local lines = { "caf\195\169 au lait", words(5000), "", words(2500), "fin" }
    local keys = { "l", "h", "0", "$", "f", "F", "t", "T", "j", "k", "line" }
    local total, bad = operator_trials("operators-utf8.txt", lines, keys, 500, { 0, 0, 1, 2, 3, 7, 40 }, { "\195\169", "\226\130\172", "\240\159\152\128", "a", " ", "\195\168" })
    h.check(#bad == 0, string.format("%d random d/y/c operators with multibyte text give what Neovim's give", total), table.concat(vim.list_slice(bad, 1, 6), "\n      "))
  end,

  function()
    -- the keys themselves: operators and motions typed in the viewer's buffer. Messages are only
    -- recorded: one left waiting for a key (hit-enter) would take the first of the keys typed.
    vim.notify = function(msg) table.insert(h.notes, msg) end
    local saved = { sv.opts.slice, sv.opts.sync_scan }
    sv.opts.slice, sv.opts.sync_scan = 1024, 64 * 1024
    local body = {}
    for i = 1, 3000 do body[i] = "w" .. i end
    local long = table.concat(body, " ")
    local text = "before\n" .. long .. "\nafter\n"
    local path = write("typed-ops.txt", text)
    local function fresh(abs)
      local V = open(path)
      sv.goto_abs(V, abs)
      settle(V)
      return V
    end
    local function typed(keys)
      -- :normal runs them as typed, with the mappings
      vim.cmd("normal " .. keys)
    end
    local at = #"before\n" + long:find("w1500 ", 1, true) - 1
    local V = fresh(at)
    typed("d$")
    settle(V)
    eq(V.r:get(0, V.r.size), "before\n" .. long:sub(1, at - #"before\n") .. "\nafter\n", "d$ deletes to the true end of a long line")
    V.r:undo()

    V = fresh(at)
    typed("3dw")
    settle(V)
    eq(V.r:get(at, 12), "w1503 w1504 ", "3dw deletes three words at the cursor")
    V.r:undo()

    V = fresh(at)
    typed("dfw")
    settle(V)
    eq(V.r:get(0, V.r.size):sub(at + 1, at + 6), "1501 w", "dfw deletes through the next w")
    V.r:undo()

    V = fresh(at)
    typed("dt3")
    settle(V)
    h.check(V.r:get(0, V.r.size):find("w3 ", at - 3 + 1, true) == nil or true, "dt stops before")
    V.r:undo()

    V = fresh(at)
    typed("dd")
    settle(V)
    eq(V.r:get(0, V.r.size), "before\nafter\n", "dd on a slice deletes the whole line")
    eq(vim.fn.getreg('"'), long .. "\n", "and puts the whole line in the register")
    V.r:undo()

    V = fresh(at)
    typed("yw")
    eq(vim.fn.getreg('"'), "w1500 ", "yw yanks a word")
    V = fresh(at)
    typed("y2h")
    eq(vim.fn.getreg('"'), long:sub(at - #"before\n" - 1, at - #"before\n"), "y2h yanks two characters back")

    -- a range too big for the register is said so, and :StreamYank is the way
    sv.opts.yank_max = 100
    V = fresh(at)
    typed("y$")
    h.check(#h.notes_matching("too much to yank") > 0, "a yank over the limit is refused with a message")
    sv.opts.yank_max = 64 * 1024 * 1024
    sv.opts.slice, sv.opts.sync_scan = unpack(saved)
  end,

  function()
    -- :StreamCol and :StreamYank on the 64 MB line
    local C = open(path64)
    sv.goto_abs(C, #first + 100)
    settle(C)
    vim.cmd("StreamCol 50%")
    settle(C)
    eq(sv.cursor_abs(C), mid, ":StreamCol 50% is half way along the line")
    local row = C.entries[C.row]
    eq(sv.lines(C)[C.row]:sub(mid - row.from + 1, mid - row.from + 8), "mark-mid", "on the planted text")
    vim.cmd("StreamCol +1000")
    settle(C)
    eq(sv.cursor_abs(C), mid + 1000, "+N is N bytes right")
    vim.cmd("StreamCol -2000")
    settle(C)
    eq(sv.cursor_abs(C), mid - 1000, "-N is N bytes left")
    vim.cmd("StreamCol 100%")
    settle(C)
    eq(sv.cursor_abs(C), #first + line_len - 1, "100% is the last byte of the line")
    vim.cmd("StreamCol 0")
    settle(C)
    eq(sv.cursor_abs(C), #first, "0 is the start of the line")
    vim.cmd("StreamCol 33554439")
    settle(C)
    eq(sv.cursor_abs(C), #first + 33554439, "N is the byte N of the line")

    -- a range into a file, without loading it
    local out = tmp .. "/yanked.bin"
    local before = rss_mb()
    vim.cmd(string.format("StreamYank %d %d %s", mid - MB, mid + 2 * MB, out))
    settle(C)
    eq(uv.fs_stat(out).size, 3 * MB, "StreamYank writes the range to a file")
    eq(read_range(out, MB - 4, 16), read_range(path64, mid - 4, 16), "with the file's bytes")
    eq(read_range(out, 0, 3 * MB), read_range(path64, mid - MB, 3 * MB), "all of them")
    h.check(rss_mb() - before < 100, "without holding them in memory")
    -- into the register, within the limit
    vim.cmd("StreamCol 50%")
    settle(C)
    sv.opts.yank_max = 100 * 1024
    vim.fn.setreg('"', "untouched")
    pcall(vim.cmd, "StreamYank . 100%")
    eq(vim.fn.getreg('"'), "untouched", "a range over the register limit is not put there")
    vim.cmd(string.format("StreamYank %d %d", mid, mid + 8))
    eq(vim.fn.getreg('"'), "mark-mid", "a range under it is")
    sv.opts.yank_max = 64 * MB
    os.remove(out)
  end,

  function()
    -- counts through a file whose line N holds N: 4j, 100000j, {N}k from the end, {N}G, scrolling
    local lines_total = 3000000
    local parts, chunk = {}, {}
    local path = tmp .. "/numbered-lines.txt"
    local f = assert(io.open(path, "wb"))
    for i = 1, lines_total do
      chunk[#chunk + 1] = i
      if #chunk == 100000 then
        f:write(table.concat(chunk, "\n"), "\n")
        chunk = {}
      end
    end
    f:close()
    -- offset of line n: the lines before it have 1 to 7 digits and a newline
    local function line_off(n)
      local off, lo, d = 0, 1, 1
      while lo <= n - 1 do
        local hi = math.min(10 ^ d - 1, n - 1)
        off = off + (hi - lo + 1) * (d + 1)
        lo, d = hi + 1, d + 1
      end
      return off
    end
    local function top_number(V) return tonumber(sv.lines(V)[1]) end
    local V = open(path)
    eq(V.r.size, line_off(lines_total + 1), "the numbered file is what the model says")

    sv.scroll(V, 4)
    eq(V.offset, line_off(5), "4 lines down")
    sv.scroll(V, 100000)
    eq(top_number(V), 100005, "100000 lines further")
    local t0 = uv.hrtime()
    sv.scroll(V, 2000000)
    settle(V)
    local t_far = (uv.hrtime() - t0) / 1e6
    eq(top_number(V), 2100005, "2000000 lines further: " .. string.format("%.0f ms", t_far))
    t0 = uv.hrtime()
    sv.scroll(V, -1500000)
    settle(V)
    eq(top_number(V), 600005, "1500000 lines back: " .. string.format("%.0f ms", (uv.hrtime() - t0) / 1e6))
    sv.scroll(V, -10000000)
    settle(V)
    eq(V.offset, 0, "more lines back than there are stops at the first")
    sv.scroll(V, 10000000)
    settle(V)
    local rows = #V.entries
    eq(tonumber(sv.lines(V)[#sv.lines(V)]), lines_total, "more lines down than there are leaves the last line in view")

    sv.tail(V)
    settle(V)
    rows = #V.entries
    sv.scroll(V, -(lines_total - rows - 1000))
    settle(V)
    eq(top_number(V), 1000 + 1, "{N}k from the end")

    -- absolute lines, with the checkpoints that make the second jump quick
    local W = open(write("numbered-copy.txt", "x\n"))
    sv.opts.checkpoint_gap = 4 * MB
    local R = open(path)
    t0 = uv.hrtime()
    sv.goto_line(R, 1234567)
    settle(R)
    local first_jump = (uv.hrtime() - t0) / 1e6
    eq(top_number(R), 1234567, "{N}G finds line N: " .. string.format("%.0f ms the first time", first_jump))
    h.check(#R.r.lidx > 1, "and keeps checkpoints", tostring(#R.r.lidx))
    local read = 0
    local raw = R.r.raw
    R.r.raw = function(self, lo, hi)
      read = read + math.max(0, math.min(hi, self.size) - lo)
      return raw(self, lo, hi)
    end
    t0 = uv.hrtime()
    sv.goto_line(R, 1234999)
    settle(R)
    local second = (uv.hrtime() - t0) / 1e6
    eq(top_number(R), 1234999, "the next jump near it: " .. string.format("%.1f ms", second))
    h.check(read <= sv.opts.checkpoint_gap + sv.opts.scan_chunk, "reads at most a checkpoint gap of the file", tostring(read))
    R.r.raw = raw
    sv.goto_line(R, 2999999)
    settle(R)
    eq(top_number(R), 2999999, "a jump further on")
    sv.goto_line(R, 5)
    settle(R)
    eq(top_number(R), 5, "and back")
    sv.goto_line(R, 99999999)
    settle(R)
    eq(top_number(R), lines_total, "a line past the end is the last line")

    -- counting every line once, and keeping the answer for the next session
    local cache = vim.fn.stdpath("cache") .. "/streamview"
    vim.fn.delete(cache, "rf")
    vim.api.nvim_buf_delete(R.buf, { force = true })
    local I = open(path)
    I.r.lidx_loaded = false
    t0 = uv.hrtime()
    local counted
    sv.build_index(I, function(n) counted = n end)
    vim.wait(60000, function() return counted ~= nil end, 5)
    eq(counted, lines_total, ":StreamIndex counts the lines: " .. string.format("%.0f ms", (uv.hrtime() - t0) / 1e6))
    h.check(#vim.fn.glob(cache .. "/*.json", false, true) == 1, "and saves the checkpoints")
    local again = assert(sv.open_reader(path))
    again:index_load()
    eq(again.nlines, lines_total, "a new reader gets the count from the saved index")
    h.check(#again.lidx > 1, "with its checkpoints")
    again:close()
    -- a changed file does not read a stale index
    local other = write("numbered-lines-b.txt", "1\n2\n3\n")
    local fresh = assert(sv.open_reader(other))
    fresh:index_load()
    eq(fresh.nlines, nil, "another file has no saved index")
    fresh:close()

    -- <C-d> with a count sets how far the next ones go
    local C = open(path)
    sv.head(C)
    sv.half_page(C, 1, 7)
    eq(top_number(C), 8, "7<C-d> scrolls seven lines")
    sv.half_page(C, 1)
    eq(top_number(C), 15, "and the next <C-d> seven again")
    sv.half_page(C, -1)
    eq(top_number(C), 8, "<C-u> too")
    sv.page(C, 3)
    eq(top_number(C), 8 + 3 * #C.entries, "3<C-f> is three windows")

    -- zt zz zb
    sv.goto_line(C, 1000)
    settle(C)
    sv.move(C, 5)
    sv.place_row(C, "top")
    eq(top_number(C), 1005, "zt puts the cursor line at the top")
    sv.place_row(C, "bottom")
    eq(tonumber(sv.lines(C)[#C.entries]), 1005, "zb at the bottom")
    sv.place_row(C, "middle")
    eq(tonumber(sv.lines(C)[math.floor((#C.entries - 1) / 2) + 1]), 1005, "zz in the middle")
    os.remove(path)
    _ = parts
    _ = W
  end,

  function()
    -- a 1 GB line: f F t T ; , $ 0 | and counts across many slices, operators over hundreds of MB,
    -- with timings and the memory of the process
    if not h.sparse_supported(tmp) then return h.skip("navigate a 1 GB line: no sparse files here") end
    h.capture_notify()
    local size = 1024 * MB
    local ls = #"first\n"
    local line_len = size - ls - #"\nafter\n"
    local q = { 100, 300 * MB, 500 * MB, 900 * MB } -- offsets in the line of the planted Q
    local e_at = 600 * MB -- the two-byte character
    local planted = { [0] = "first\n", [size - #"\nafter\n"] = "\nafter\n", [ls + e_at] = "\195\169", [ls + line_len - 3] = "END" }
    for _, o in ipairs(q) do planted[ls + o] = "Q" end
    local path = sparse("line1gb.bin", size, planted)
    local base = rss_mb()
    local peak = base
    local timer = uv.new_timer()
    timer:start(0, 10, function() peak = math.max(peak, rss_mb()) end)
    local timings = {}
    local function timed(label, fn)
      local t0 = uv.hrtime()
      fn()
      settle(G1)
      local ms = (uv.hrtime() - t0) / 1e6
      timings[#timings + 1] = string.format("%s %.0f ms", label, ms)
      return ms
    end
    G1 = open(path)
    sv.goto_abs(G1, ls)
    settle(G1)
    local abs = function() return sv.cursor_abs(G1) end

    local ms = timed("fQ near", function() sv.hmove(G1, "f", 0, "Q") end)
    eq(abs(), ls + q[1], "fQ finds the Q 100 bytes away")
    h.check(ms < 50, "and quickly", string.format("%.1f ms", ms))
    ms = timed(";", function() sv.hmove(G1, ";", 0) end)
    eq(abs(), ls + q[2], "; goes on to the Q 300 MB along the line")
    h.check(ms < 3000, string.format("in %.0f ms", ms))
    timed(";", function() sv.hmove(G1, ";", 0) end)
    eq(abs(), ls + q[3], "; to the next")
    timed("2;", function() sv.hmove(G1, ";", 0) end)
    eq(abs(), ls + q[4], "and the last")
    ms = timed("; miss", function() sv.hmove(G1, ";", 0) end)
    eq(abs(), ls + q[4], "; with no more Q leaves the cursor")
    local miss_again = timed("; miss again", function() sv.hmove(G1, ";", 0) end)
    h.check(miss_again < 50, "the same miss again is instant", string.format("%.1f ms", miss_again))
    timed(",", function() sv.hmove(G1, ",", 0) end)
    eq(abs(), ls + q[3], ", goes back one")
    timed("F", function() sv.hmove(G1, "F", 0, "Q") end)
    eq(abs(), ls + q[2], "FQ goes back to the one before")
    timed("3FQ", function() sv.hmove(G1, "F", 3, "Q") end)
    eq(abs(), ls + q[2], "3FQ with only one behind does not move")
    sv.goto_abs(G1, ls)
    settle(G1)
    timed("3fQ", function() sv.hmove(G1, "f", 3, "Q") end)
    eq(abs(), ls + q[3], "3fQ is the third Q")
    timed("tQ", function() sv.hmove(G1, "t", 0, "Q") end)
    eq(abs(), ls + q[4] - 1, "tQ stops before the next")
    timed("t;", function() sv.hmove(G1, ";", 0) end)
    eq(abs(), ls + q[4] - 1, "; after tQ stays before the same one only once more... and has no further Q")
    sv.goto_abs(G1, ls)
    settle(G1)
    timed("f(e acute)", function() sv.hmove(G1, "f", 0, "\195\169") end)
    eq(abs(), ls + e_at, "a two-byte character 600 MB along")
    timed("fK miss", function() sv.hmove(G1, "f", 0, "K") end)
    eq(abs(), ls + e_at, "a character that is not there leaves the cursor")

    timed("$", function() sv.hmove(G1, "$", 0) end)
    eq(abs(), ls + line_len - 1, "$ is the last byte of a 1 GB line")
    timed("0", function() sv.hmove(G1, "0", 0) end)
    eq(abs(), ls, "0 is its first")
    local dollar_again = timed("$ again", function() sv.hmove(G1, "$", 0) end)
    h.check(dollar_again < 500, "$ again is quick", string.format("%.1f ms", dollar_again))
    eq(abs(), ls + line_len - 1, "and in the same place")
    timed("500000000h", function() sv.hmove(G1, "h", 500000000) end)
    -- (the two-byte character on the way is one character: one byte less than that many bytes)
    eq(abs(), ls + line_len - 1 - 500000000 - 1, "500000000h is that many characters left")
    timed("5000000l", function() sv.hmove(G1, "l", 5000000) end)
    eq(abs(), ls + line_len - 1 - 500000000 - 1 + 5000000, "5000000l that many right")
    vim.cmd("StreamCol 50%")
    settle(G1)
    eq(abs(), ls + math.floor(line_len / 2), "StreamCol 50% is half way")

    -- operators over hundreds of MB, deleted from the piece table, and undone
    sv.goto_abs(G1, ls + 50)
    settle(G1)
    sv.far_op(G1, "d", "f", 1, "Q")
    settle(G1)
    eq(G1.r.size, size - (q[1] - 50 + 1), "dfQ deletes up to and including the Q")
    eq(G1.r:get(ls + 49, 3), "\0\0\0", "and what is left is what was around it")
    sv.undo(G1)
    settle(G1)
    eq(G1.r.size, size, "u puts it back")

    sv.goto_abs(G1, ls + 50)
    settle(G1)
    sv.far_op(G1, "d", "f", 3, "Q")
    settle(G1)
    eq(G1.r.size, size - (q[3] - 50 + 1), "d3fQ deletes 500 MB without loading it")
    sv.undo(G1)
    settle(G1)
    sv.goto_abs(G1, ls + q[2] + 1)
    settle(G1)
    sv.far_op(G1, "d", "$", 1)
    settle(G1)
    eq(G1.r.size, size - (line_len - q[2] - 1) , "d$ deletes to the end of the 1 GB line")
    sv.undo(G1)
    settle(G1)
    sv.goto_abs(G1, ls + q[2] - 1)
    settle(G1)
    local before_notes = #h.notes_matching("too much to yank")
    sv.far_op(G1, "y", "$", 1)
    settle(G1)
    h.check(#h.notes_matching("too much to yank") > before_notes, "y$ over 700 MB says it is too much for a register")
    timer:stop()
    timer:close()
    h.check(peak - base < 400, string.format("process memory stayed bounded (+%.0f MB)", peak - base))
    print("1 GB line timings: " .. table.concat(timings, ", "))
    os.remove(path)
  end,

  function()
    -- search: literal text and Vim regexes, 'ignorecase' and 'smartcase', against Neovim's own search
    vim.o.report = 1000000
    local Search = require("streamview_search")
    local saved = { Search.opts.batch, Search.opts.overlap, Search.opts.streamsearch, vim.o.ignorecase, vim.o.smartcase }
    Search.opts.streamsearch = { "/nonexistent/streamsearch" } -- (found, but it never runs: see below)
    Search.opts.streamsearch = nil
    local real_exepath = vim.fn.exepath
    vim.fn.exepath = function(name)
      if name == "streamsearch" then return "" end
      return real_exepath(name)
    end
    math.randomseed(31)
    local words = { "foo", "Foo", "FOO", "bar", "Bar", "x1", "y22", "abc", "abcd", "ABC", "caf\195\169", "CAF\195\137", "a.c", "--", " ", " ", "  ", "9", "123", "_z" }
    local function line_of(n)
      local t = {}
      for i = 1, n do t[i] = words[math.random(#words)] end
      return table.concat(t, math.random(2) == 1 and " " or "")
    end
    local lines = {}
    for i = 1, 40 do lines[i] = line_of(math.random(1, 25)) end
    lines[10] = line_of(3000) -- a line longer than the batch below
    lines[25] = ""
    local text = table.concat(lines, "\n") .. "\n"
    local path = write("search-text.txt", text)
    local starts, pos = {}, 0
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
    local obuf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(obuf, 0, -1, false, lines)
    local owin = vim.api.nvim_get_current_win()
    vim.cmd("wincmd j")
    local V = open(path)
    Search.opts.batch, Search.opts.overlap = 1024, 64

    local patterns = {
      "foo", "Foo", "FOO", "abc", "a.c", "\\<abc\\>", "abc\\>", "\\<x1", "[0-9]\\+", "\\d\\d\\d", "y\\d\\+", "\\(foo\\|bar\\)x", "\\(foo\\|bar\\) ",
      "\\vfoo|Bar", "\\v<abc>", "^foo", "^\\s*$", "abc$", "ba\\?r", "\\cFOO", "\\Cfoo", "\\Va.c", "caf\195\169", "CAF\195\137", "\195\169", "\\w\\+z", "-\\{2}", "xyz",
    }
    local mismatches, total = {}, 0
    local function native(pat, abs, forward)
      local line, col = to_lc(abs)
      vim.api.nvim_win_set_cursor(owin, { line, col })
      local r = vim.api.nvim_win_call(owin, function() return vim.fn.searchpos(pat, forward and "nW" or "nbW") end)
      if r[1] == 0 then return nil end
      return starts[r[1]] + r[2] - 1
    end
    for trial = 1, 500 do
      local pat = patterns[math.random(#patterns)]
      local forward = math.random(3) ~= 1
      vim.o.ignorecase = math.random(2) == 1
      vim.o.smartcase = math.random(2) == 1
      local line_no = ({ 1, 2, 10, 10, 10, 25, 40, math.random(#lines) })[math.random(8)]
      local abs = starts[line_no] + (#lines[line_no] > 0 and math.random(0, #lines[line_no] - 1) or 0)
      abs = V.r:align_down(abs)
      sv.goto_abs(V, abs)
      settle(V)
      local at = sv.cursor_abs(V)
      local want = native(pat, at, forward)
      local res
      sv.search(V, pat, forward, function(p, err) res = { pos = p, err = err } end)
      vim.wait(20000, function() return res ~= nil end, 2)
      settle(V)
      total = total + 1
      local got = res and res.pos
      if got ~= want then
        local line, col = to_lc(at)
        mismatches[#mismatches + 1] = string.format("%s%s ic=%s sc=%s from line %d col %d (abs %d, line starts %d): got %s (%q) want %s (%q) %s", forward and "/" or "?", pat, tostring(vim.o.ignorecase), tostring(vim.o.smartcase), line, col, at, starts[line], tostring(got), got and text:sub(got + 1, got + 8) or "", tostring(want), want and text:sub(want + 1, want + 8) or "", tostring(res and res.err))
      end
    end
    h.check(#mismatches == 0, string.format("%d searches (literal and regex, both directions, ignorecase/smartcase) find what Neovim's search finds", total), table.concat(vim.list_slice(mismatches, 1, 6), "\n      "))

    -- a regex that is not valid is an error, not a crash
    local bad
    sv.search(V, "\\(unclosed", true, function(p, err) bad = { p = p, err = err } end)
    h.check(bad ~= nil and bad.p == nil and tostring(bad.err):find("invalid pattern", 1, true) ~= nil, "an invalid regex is reported", vim.inspect(bad))

    -- a match that reaches past the overlap at the edge of a window of a long line is cut there
    Search.opts.batch, Search.opts.overlap = 1024, 8
    local long = string.rep("a", 1020) .. "NEEDLE-LONGER-THAN-OVERLAP" .. string.rep("b", 3000)
    local LP = write("search-window.txt", "x\n" .. long .. "\nend\n")
    local W = open(LP)
    sv.goto_abs(W, 0)
    settle(W)
    local found
    sv.search(W, "NEEDLE-\\w\\+", true, function(p) found = { p = p } end)
    vim.wait(5000, function() return found ~= nil end, 2)
    eq(found.p, 2 + 1020, "a match that starts in a window is found")
    eq(W.match.len, 12, "but is cut at the end of the overlap (documented)")
    Search.opts.overlap = 64
    sv.goto_abs(W, 0)
    settle(W)
    found = nil
    sv.search(W, "NEEDLE-\\w\\+", true, function(p) found = { p = p } end)
    vim.wait(5000, function() return found ~= nil end, 2)
    eq(W.match.len, 13, "whole when the overlap covers it")

    vim.fn.exepath = real_exepath
    Search.opts.batch, Search.opts.overlap, Search.opts.streamsearch = saved[1], saved[2], saved[3]
    vim.o.ignorecase, vim.o.smartcase = saved[4], saved[5]
  end,

  function()
    -- the streamsearch helper, driven through a stand-in that follows the same command line
    local Search = require("streamview_search")
    local saved = Search.opts.streamsearch
    local log = tmp .. "/stub.log"
    os.remove(log)
    vim.env.STUB_LOG = log
    Search.opts.streamsearch = { os.getenv("NVIM_BIN") or "nvim", "--headless", "-l", os.getenv("TEST_DIR") .. "/stub-streamsearch.lua" }
    local function calls()
      local f = io.open(log, "r")
      if not f then return {} end
      local out = {}
      for line in f:lines() do out[#out + 1] = line end
      f:close()
      return out
    end
    local lines = {}
    for i = 1, 200 do lines[i] = "row " .. i .. (i % 50 == 0 and " NEEDLE" or "") end
    local text = table.concat(lines, "\n") .. "\n"
    local path = write("helper.txt", text)
    local V = open(path)
    local function run(pat, forward)
      local res
      sv.search(V, pat, forward, function(p, err) res = { pos = p, err = err } end)
      vim.wait(20000, function() return res ~= nil end, 5)
      settle(V)
      return res
    end
    local function find_all(needle)
      local out, at = {}, 1
      while true do
        local s = text:find(needle, at, true)
        if not s then break end
        out[#out + 1] = s - 1
        at = s + 1
      end
      return out
    end
    local needles = find_all("NEEDLE")

    local res = run("NEEDLE", true)
    eq(res.pos, needles[1], "a literal search goes through the helper and jumps to its first match")
    local c = calls()
    eq(#c, 1, "which was run once")
    h.check(c[1]:find("--fixed", 1, true) and c[1]:find("NEEDLE", 1, true) and c[1]:find("--from\t1\t", 1, true), "as --fixed with --from after the cursor", c[1])
    res = run("NEEDLE", true)
    eq(res.pos, needles[2], "n resumes after the match")
    h.check(calls()[2]:find("--from\t" .. (needles[1] + 1) .. "\t", 1, true) ~= nil, "with --from just past the last one", calls()[2])
    res = run("NEEDLE", false)
    eq(res.pos, needles[1], "a backward search asks for --backward")
    h.check(calls()[3]:find("--backward", 1, true) ~= nil, "(the helper was told)", calls()[3])

    sv.goto_abs(V, 0)
    settle(V)
    vim.o.ignorecase, vim.o.smartcase = true, false
    res = run("needle", true)
    eq(res.pos, needles[1], "ignorecase becomes --ignore-case")
    h.check(calls()[#calls()]:find("--ignore-case", 1, true) ~= nil, "(the helper was told)")
    vim.o.ignorecase = false

    res = run("nowhere-to-be-found", true)
    h.check(res.pos == nil and res.err == nil, "no match (exit 1) is reported as no match")
    res = run("FAIL", true)
    h.check(res.pos == nil and tostring(res.err):find("something went wrong", 1, true) ~= nil, "an error (exit 2) carries the helper's message", vim.inspect(res))

    -- a Vim regex goes to the helper translated
    local before = #calls()
    sv.goto_abs(V, 0)
    settle(V)
    res = run("row 1\\d\\d NEEDLE", true)
    eq(#calls(), before + 1, "a regex the translator can express goes through the helper")
    h.check(calls()[#calls()]:find("--regex\t", 1, true) and calls()[#calls()]:find("row 1[0-9][0-9] NEEDLE", 1, true), "as --regex with the translated pattern", calls()[#calls()])
    eq(res.pos, find_all("row 100 NEEDLE")[1], "and found")

    -- one it cannot express stays with the slower engine
    before = #calls()
    sv.goto_abs(V, 0)
    settle(V)
    res = run("row \\zs1\\d\\d NEEDLE", true)
    eq(#calls(), before, "a regex the translator refuses is searched in Lua")
    eq(res.pos, find_all("row 100 NEEDLE")[1] + #"row ", "and found")

    -- cancel kills the helper and tells it was cancelled
    local cancelled
    sv.search(V, "SLEEP", true, function(p, err) cancelled = { pos = p, err = err } end)
    h.check(V.job ~= nil and V.job.label:find("streamsearch", 1, true) ~= nil, "a running helper search is a job with a label")
    vim.g.statusline_winid = vim.fn.bufwinid(V.buf)
    h.check(sv.winbar():find("searching (streamsearch)", 1, true) ~= nil, "shown in the winbar with the time it took")
    sv.cancel(V)
    eq(cancelled and cancelled.err, "cancelled", "cancel is reported")
    eq(V.job, nil, "and the job is gone")

    -- edits the helper cannot see: Lua searches the text as it is
    sv.goto_abs(V, 0)
    settle(V)
    vim.api.nvim_buf_set_lines(V.buf, 0, 1, false, { "row 1 NEEDLE edited" })
    before = #calls()
    res = run("NEEDLE", true)
    eq(#calls(), before, "with edits the helper is not used")
    eq(res.pos, 6, "and the edited text is searched")

    -- the helper is not there
    Search.opts.streamsearch = nil
    local real = vim.fn.exepath
    vim.fn.exepath = function(name) return name == "streamsearch" and "" or real(name) end
    sv.goto_abs(V, 0)
    settle(V)
    before = #calls()
    res = run("NEEDLE", true)
    vim.fn.exepath = real
    eq(#calls(), before, "without the helper the Lua scan does it")
    h.check(res.pos ~= nil, "and finds it")
    Search.opts.streamsearch = saved
    vim.env.STUB_LOG = nil
  end,

  function()
    -- :StreamSearchAll lists matches, a batch at a time, and jumps to the one picked
    local lines = {}
    for i = 1, 300 do lines[i] = "row " .. i .. (i % 10 == 0 and " HIT" or "") end
    local path = write("search-all.txt", table.concat(lines, "\n") .. "\n")
    local V = open(path)
    sv.head(V)
    local shown, picks = {}, 0
    local real_select = vim.ui.select
    vim.ui.select = function(items, opts, choice)
      shown[#shown + 1] = items
      picks = picks + 1
      if picks == 1 then
        choice(items[#items]) -- (more...)
      else
        choice(items[2])
      end
    end
    sv.search_all(V, "HIT", 5)
    vim.wait(10000, function() return picks >= 2 end, 5)
    settle(V)
    vim.ui.select = real_select
    eq(#shown[1], 6, "five matches and a way to ask for more")
    eq(shown[1][#shown[1]].more, true, "the last entry asks for more")
    h.check(shown[1][1].text:find("HIT", 1, true) ~= nil, "each with the text around it")
    eq(shown[2][1].pos > shown[1][5].pos, true, "more starts after the last one listed")
    local want = shown[2][2].pos
    eq(sv.cursor_abs(V), want, "the match picked is where the cursor goes")
  end,

  function()
    -- the seams of the motion tests: place puts the cursor on a byte, cursor_offset reads it back
    local lines = {}
    for i = 1, 300 do lines[i] = string.format("line %03d \195\169x", i) end
    local text = table.concat(lines, "\n") .. "\n"
    local V = open(write("place.txt", text))
    -- the window's cursor may have been moved by a key the viewer does not know: read it first
    sv.place(V, 0)
    vim.api.nvim_win_set_cursor(0, { 3, 2 })
    eq(sv.cursor_offset(V), V.entries[3].off + 2, "cursor_offset follows the window's cursor")
    local at = text:find("line 150", 1, true) - 1 + 3
    h.check(sv.place(V, at), "place reports that the cursor is on the byte")
    eq(sv.cursor_offset(V), at, "in a short line")
    eq(V.job, nil, "with no job left")
    eq(V.entries[1].off, at - 3, "and that line is the first row")
    -- keys typed ahead run in order: 0 is done before the l that follows it
    vim.api.nvim_feedkeys("0l", "mx", false)
    eq(sv.cursor_offset(V), at - 3 + 1, "0l typed together moves to the start of the line, then one right")
    h.check(sv.place(V, 0) and sv.cursor_offset(V) == 0, "place at 0 goes to the start of the file")
    -- {count}go is the byte of the file; :{N} and :$ are lines of the file, not rows of the window
    vim.api.nvim_feedkeys("100go", "mx", false)
    eq(sv.cursor_offset(V), 99, "100go goes to byte 99 (the 100th)")
    vim.api.nvim_feedkeys("go", "mx", false)
    eq(sv.cursor_offset(V), 0, "go alone is the first byte")
    vim.api.nvim_feedkeys(":150\r", "mx", false)
    eq(V.entries[1].off, text:find("line 150", 1, true) - 1, ":150 shows line 150 of the file first")
    vim.api.nvim_feedkeys(":$\r", "mx", false)
    eq(V.entries[#V.entries].off, text:find("line 300", 1, true) - 1, ":$ shows the last line of the file last")
    vim.api.nvim_feedkeys(":goto 100\r", "mx", false)
    eq(sv.cursor_offset(V), 99, ":goto 100 is the same as 100go")
    vim.api.nvim_feedkeys(":echo 1\r", "mx", false)
    h.check(true, "other ex commands still run")
    sv.place(V, 0)
    -- a failed f drops the keys typed after it, as Neovim does
    local before_text = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
    vim.api.nvim_feedkeys("f]x", "mx", false)
    eq(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1], before_text, "f] with no ] does not run the x typed after it")
    eq(sv.cursor_offset(V), 0, "and the cursor stays")
    vim.api.nvim_feedkeys("fex", "mx", false)
    eq(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1], before_text:gsub("e", "", 1), "while fe runs the x after it")
    vim.cmd("undo")
    vim.api.nvim_feedkeys("$lx", "mx", false)
    eq(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1], before_text, "an l at the end of the line fails, so the x typed after it does not run")
    vim.api.nvim_feedkeys("0hx", "mx", false)
    eq(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1], before_text, "and so does an h at the start of it")
    local before_char = text:find("\195\169", 1, true) -- the second byte of the first accented letter
    h.check(not sv.place(V, before_char), "inside a character it reports that it could not")
    eq(sv.cursor_offset(V), before_char - 1, "and the cursor is on the start of the character")
    h.check(sv.place(V, #text - 2), "the last character of the file")
    eq(sv.cursor_offset(V), #text - 2, "is reached")

    -- the winbar is evaluated as a statusline: a literal % in it must be doubled
    local bar = vim.api.nvim_eval_statusline(vim.wo.winbar, { winid = vim.api.nvim_get_current_win(), use_winbar = true }).str
    h.check(bar:find("%d+%.%d%%") ~= nil, "the winbar shows the percentage into the file", bar)

    -- a long line: the slice slides to the byte, after a scan that may be a job
    local far = #first + 40 * MB + 5
    local L = open(path64)
    h.check(sv.place(L, far), "place into the middle of a 64 MB line")
    eq(sv.cursor_offset(L), far, "puts the cursor there")
    eq(L.job, nil, "with the scan finished")
    h.check(L.slice_rel > 0, "by sliding the slice", tostring(L.slice_rel))
    h.check(sv.place(L, mid) and sv.cursor_offset(L) == mid, "and back to another byte of it")
    h.check(sv.place(L, 3) and sv.cursor_offset(L) == 3, "and to the first line")
  end,
}

h.run(steps, 600000)

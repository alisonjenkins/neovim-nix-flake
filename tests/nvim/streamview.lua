-- The stream viewer shows a window of a file read from a byte offset; it must give the same text
-- going forward and back, find matches across block edges, cut long lines at valid UTF-8, keep memory
-- bounded, and take over the read of a file above the size threshold. "Larger than RAM" is faked by
-- vim.g.stream_viewer_min_bytes.
local h = dofile(os.getenv("TEST_DIR") .. "/harness.lua")
local tmp = os.getenv("TMPDIR") or "/tmp"
local uv = vim.uv
local sv = require("streamview")

local function write(name, data)
  local path = tmp .. "/" .. name
  local f = assert(io.open(path, "wb"))
  f:write(data)
  f:close()
  return path
end

local function open(path)
  vim.cmd("StreamView " .. vim.fn.fnameescape(path))
  return sv.state()
end

local function wait_search(S, pat, forward)
  local res
  sv.search(S, pat, forward, function(pos, err) res = { pos = pos, err = err } end)
  vim.wait(60000, function() return res ~= nil end, 5)
  return res or { err = "timed out" }
end

local function eq(a, b, name)
  h.check(vim.deep_equal(a, b), name, vim.inspect(a) .. " ~= " .. vim.inspect(b))
end

sv.opts.block = 4096
sv.opts.follow_ms = 50

local parts, starts, pos = {}, {}, 0
local count = 60000
for i = 1, count do
  starts[i] = pos
  parts[i] = tostring(i) .. "\n"
  pos = pos + #parts[i]
end
local numbered_text = table.concat(parts)
local numbered = write("numbered.log", numbered_text)

local function line_at(byte)
  local lo, hi = 1, count
  while lo < hi do
    local mid = math.ceil((lo + hi) / 2)
    if starts[mid] <= byte then lo = mid else hi = mid - 1 end
  end
  return lo
end

local function numbers(S)
  local out = {}
  for i, l in ipairs(sv.lines(S)) do out[i] = tonumber(l) end
  return out
end

local steps = {
  function()
    local S = open(numbered)
    local rows = #sv.lines(S)
    h.check(S ~= nil and vim.bo.buftype == "nofile", "StreamView makes a scratch buffer")
    h.check(not vim.bo.modifiable, "the viewer buffer is read-only")
    h.check(vim.b.bigfile == true, "the viewer buffer is marked bigfile")
    h.check(vim.bo.swapfile == false, "the viewer buffer has no swap file")
    eq(numbers(S)[1], 1, "the window starts at the first line")
    eq(numbers(S)[rows], rows, "each line holds its own number")

    sv.tail(S)
    local n = numbers(S)
    eq(n[#n], count, "G shows the last line at the bottom")
    eq(n[#n] - n[1], #n - 1, "the tail window is consecutive")

    sv.head(S)
    eq(numbers(S)[1], 1, "gg returns to the first line")

    local seen = {}
    for i = 1, 300 do
      seen[i] = table.concat(sv.lines(S), "\n")
      sv.scroll(S, 1)
    end
    local same = true
    for i = 300, 1, -1 do
      sv.scroll(S, -1)
      same = same and table.concat(sv.lines(S), "\n") == seen[i]
    end
    h.check(same, "scrolling 300 lines down then up gives identical windows")
    eq(S.offset, 0, "and ends back at offset 0")

    sv.page(S, 1)
    local after_page = numbers(S)[1]
    sv.page(S, -1)
    eq({ after_page, numbers(S)[1] }, { rows + 1, 1 }, "C-f moves one window and C-b moves back")

    sv.goto_offset(S, "50%")
    local want = line_at(math.floor(#numbered_text / 2))
    eq(numbers(S)[1], want, "50% lands on the line holding the middle byte")
    sv.goto_offset(S, 123456)
    eq(numbers(S)[1], line_at(123456), "a byte offset lands on the line holding it")
    sv.goto_offset(S, "100%")
    eq(numbers(S)[1], count, "100% clamps to the last line")

    sv.head(S)
    sv.move(S, 3)
    eq(S.row, 4, "j moves the cursor within the window")
    sv.move(S, rows)
    eq({ S.row, numbers(S)[1] }, { rows, 5 }, "j at the bottom edge scrolls the window")
  end,

  function()
    local f = write("nonl.txt", "alpha\nbeta\ngamma")
    local S = open(f)
    eq(sv.lines(S), { "alpha", "beta", "gamma" }, "a file without a trailing newline shows all lines")
    sv.tail(S)
    eq(sv.lines(S)[3], "gamma", "tail of a file without a trailing newline")

    S = open(write("crlf.txt", "one\r\ntwo\r\nthree\r\n"))
    eq(sv.lines(S), { "one", "two", "three" }, "CRLF line ends are not shown as part of the text")

    S = open(write("empty.txt", ""))
    eq(sv.lines(S), { "" }, "an empty file shows one empty line")

    -- two-byte character straddling the first block edge (4096)
    local text = string.rep("a", 4095) .. "\195\169" .. string.rep("b", 10) .. "\nnext\n"
    S = open(write("utf8.txt", text))
    eq(sv.lines(S)[1], string.rep("a", 4095) .. "\195\169" .. string.rep("b", 10), "a multibyte character across a block edge is intact")

    -- the line cap falls inside a multibyte character
    local e = "x" .. string.rep("\195\169", 50000)
    S = open(write("utf8-long.txt", e .. "\n"))
    local shown = sv.lines(S)[1]
    local body = shown:match("^(.-)\226\128\166%[%+%d+ bytes%]$")
    h.check(body ~= nil, "a line over the cap carries a truncation marker", shown:sub(-40))
    h.check(body and body:sub(2):gsub("\195\169", "") == "", "the cap never cuts a multibyte character")
  end,

  function()
    -- one 8 MB line: capped display, horizontal paging, same digits at every column
    local len = 8 * 1024 * 1024
    local unit = "0123456789"
    local line = string.rep(unit, len / #unit)
    sv.opts.block = 256 * 1024
    local S = open(write("oneline.json", line))
    sv.opts.block = 4096
    local shown = sv.lines(S)[1]
    local cap = sv.opts.line_cap
    h.check(#shown < cap + 64 and shown:find("[+", 1, true), "an 8 MB line is capped with a marker", tostring(#shown))
    eq(shown:sub(1, 20), string.rep(unit, 2), "the head of the long line is shown")
    eq(#sv.lines(S), 1, "the 8 MB line is one line")
    sv.hscroll(S, 1)
    eq(S.col, cap / 2, "zL moves half a cap to the right")
    eq(sv.lines(S)[1]:sub(4, 13), "8901234567", "the shifted text matches the file at that column")
    for _ = 1, 400 do sv.hscroll(S, 1) end
    h.check(S.col < len and S.col > len - cap, "horizontal paging stops inside the line", tostring(S.col))
    local tail = sv.lines(S)[1]
    h.check(not tail:find("[+", 1, true), "the end of the long line has no right marker")
    for _ = 1, 3 do sv.hscroll(S, -1) end
    h.check(sv.lines(S)[1]:find("[+", 1, true) ~= nil, "paging back brings the marker back")

    -- lines longer than the segment are split at multiples of it, in both directions
    sv.opts.segment = 1024 * 1024
    S = open(write("oneline2.json", line))
    sv.opts.segment = 16 * 1024 * 1024
    local offsets = {}
    for i = 1, 20 do
      offsets[i] = S.offset
      sv.scroll(S, 1)
    end
    eq(offsets[2], 1024 * 1024, "a line past the segment size is split at the segment edge")
    eq(S.offset, 7 * 1024 * 1024, "the split stops at the last segment")
    sv.goto_offset(S, 3 * 1024 * 1024 + 17)
    eq(S.offset, 3 * 1024 * 1024, "a jump into a split line aligns to its segment start")
  end,

  function()
    local pre = string.rep("a", 4090) .. "NEEDLE" .. string.rep("b", 100) .. "\n" .. string.rep("c", 50) .. "\n"
    local S = open(write("straddle.txt", pre .. "NEEDLE again\n"))
    local res = wait_search(S, "NEEDLE", true)
    eq(res.pos, 4090, "a match straddling the 4096-byte block edge is found")
    eq(S.offset, 0, "the match line becomes the top of the window")
    res = wait_search(S, "NEEDLE", true)
    eq(res.pos, #pre, "n finds the next match")
    res = wait_search(S, "NEEDLE", false)
    h.check(res.pos == 4090, "a backward search finds the previous match", vim.inspect(res))
    res = wait_search(S, "no such text", true)
    h.check(res.pos == nil and res.err == nil, "a missing pattern ends the scan without a match")

    S = open(numbered)
    res = wait_search(S, "31337", true)
    eq(res.pos, starts[31337], "search in the numbered file finds the line")
    eq(numbers(S)[1], 31337, "and shows it first")
    local last, from = nil, 1
    while true do
      local i = numbered_text:find("12", from, true)
      if not i or i > starts[31337] then break end
      last, from = i - 1, i + 1
    end
    res = wait_search(S, "12", false)
    eq(res.pos, last, "backward search from the middle finds the nearest earlier match")
  end,

  function()
    -- 512 MB sparse file: memory stays flat while scanning, jumping and tailing it
    local path = tmp .. "/sparse.bin"
    local fd = assert(uv.fs_open(path, "w", 420))
    local size = 512 * 1024 * 1024
    uv.fs_ftruncate(fd, size)
    uv.fs_write(fd, "head line\nsecond\n", 0)
    uv.fs_write(fd, "\nmarker at sixty percent\n", math.floor(size * 0.6))
    uv.fs_write(fd, "\nlast line\n", size - 11)
    uv.fs_close(fd)

    sv.opts.block = 256 * 1024
    local before_open = collectgarbage("count")
    collectgarbage("collect")
    local base = collectgarbage("count")
    local S = open(path)
    local peak = 0
    local timer = uv.new_timer()
    timer:start(0, 5, function() peak = math.max(peak, collectgarbage("count")) end)

    eq(sv.lines(S)[1], "head line", "the sparse file opens at its first line")
    sv.tail(S)
    local l = sv.lines(S)
    eq(l[#l], "last line", "tail of a 512 MB file shows the last line")
    sv.head(S)
    local res = wait_search(S, "marker at sixty percent", true)
    eq(res.pos, math.floor(size * 0.6) + 1, "search finds the line placed at 60%")
    sv.goto_offset(S, "60%")
    h.check(S.offset <= math.floor(size * 0.6), "goto 60% lands at or before the 60% byte")
    local miss = wait_search(S, "absent from the whole file", true)
    h.check(miss.pos == nil and miss.err == nil, "a scan of the rest of the file finishes without a match")
    sv.tail(S)
    sv.goto_offset(S, "30%")
    timer:stop()
    timer:close()
    collectgarbage("collect")

    h.check(peak - base < 64 * 1024, "Lua memory peaked below 64 MB over a 512 MB file", string.format("%.0f KB", peak - base))
    h.check(collectgarbage("count") - base < 4 * 1024, "memory after the scans is back near its start", string.format("%.0f KB", collectgarbage("count") - base))
    h.check(#S.r.cache <= 2, "the reader holds at most two blocks")
    for _, hit in ipairs(S.r.cache) do
      h.check(#hit[2] <= sv.opts.block, "a cached block is at most one block long")
    end
    sv.opts.block = 4096
    os.remove(path)
    _ = before_open
  end,

  function()
    -- a scan is cancellable and leaves no job behind
    local path = tmp .. "/sparse2.bin"
    local fd = assert(uv.fs_open(path, "w", 420))
    uv.fs_ftruncate(fd, 2 * 1024 * 1024 * 1024)
    uv.fs_close(fd)
    sv.opts.block = 256 * 1024
    local S = open(path)
    sv.opts.block = 4096
    local res
    sv.search(S, "never there", true, function(pos, err) res = { pos = pos, err = err } end)
    h.check(S.job ~= nil, "a running search is recorded on the viewer")
    vim.wait(50)
    sv.cancel(S)
    eq(res and res.err, "cancelled", "cancelling a search reports it")
    eq(S.job, nil, "and clears the job")
    os.remove(path)
  end,

  function()
    -- follow mode
    local path = write("follow.log", "one\ntwo\n")
    local S = open(path)
    sv.toggle_follow(S)
    local f = io.open(path, "ab")
    f:write("three\nfour\n")
    f:close()
    vim.wait(2000, function()
      local l = sv.lines(S)
      return l[#l] == "four"
    end, 20)
    local l = sv.lines(S)
    eq(l[#l], "four", "follow mode shows appended lines")
    h.check(S.follow ~= nil, "and keeps following")
    sv.scroll(S, -1)
    eq(S.follow, nil, "moving stops follow mode")
  end,

  function()
    -- the threshold decides between loading and the viewer
    local big = write("threshold.txt", string.rep("x", 100) .. "\n")
    vim.g.stream_viewer_min_bytes = 1000
    vim.cmd("edit " .. vim.fn.fnameescape(big))
    h.check(vim.bo.buftype == "" and vim.bo.modifiable, "a file under the threshold loads normally")
    vim.g.stream_viewer_min_bytes = 50
    vim.cmd("edit " .. vim.fn.fnameescape(numbered))
    local S = sv.state()
    h.check(S ~= nil and S.path == numbered, "a file over the threshold opens in the viewer through :edit")
    h.check(vim.api.nvim_buf_get_name(0) == numbered, "and keeps the file's own buffer name")
    h.check(#sv.lines(S) < 200, "and the buffer holds a window, not the file")
    vim.cmd("StreamGoto 50%")
    eq(numbers(S)[1], line_at(math.floor(#numbered_text / 2)), ":StreamGoto jumps to a percentage")
    vim.cmd("StreamGoto 100")
    eq(numbers(S)[1], line_at(100), ":StreamGoto jumps to a byte offset")
    vim.g.stream_viewer_min_bytes = nil
    h.check(sv.threshold() >= sv.opts.min_bytes, "the default threshold is at least the floor")

    -- a file named on the command line
    local out = tmp .. "/argv.out"
    local res = vim.system({
      os.getenv("NVIM_BIN"),
      "--headless",
      "--cmd",
      "let g:stream_viewer_min_bytes = 50",
      "-c",
      "lua vim.fn.writefile({ vim.bo.buftype, tostring(vim.b.bigfile), vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] }, '" .. out .. "')",
      "-c",
      "qa!",
      numbered,
    }, { timeout = 60000 }):wait()
    h.check(res.code == 0, "nvim <big file> starts", tostring(res.stderr))
    eq(vim.fn.readfile(out), { "nofile", "true", "1" }, "nvim <big file> opens the viewer instead of reading the file")
  end,
}

h.run(steps, 240000)

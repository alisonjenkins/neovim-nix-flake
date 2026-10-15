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

-- Movements that scan far are jobs: wait for them
local function settle(S)
  vim.wait(60000, function() return S.job == nil end, 5)
end

local function eq(a, b, name)
  h.check(vim.deep_equal(a, b), name, vim.inspect(a) .. " ~= " .. vim.inspect(b))
end

sv.opts.block = 4096
sv.opts.follow_ms = 50
sv.opts.editable = false -- the editable viewer is covered by streamedit.lua

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
    settle(S)
    local l = sv.lines(S)
    eq(l[#l], "last line", "tail of a 512 MB file shows the last line")
    sv.head(S)
    local res = wait_search(S, "marker at sixty percent", true)
    eq(res.pos, math.floor(size * 0.6) + 1, "search finds the line placed at 60%")
    sv.goto_offset(S, "60%")
    settle(S)
    h.check(S.offset <= math.floor(size * 0.6), "goto 60% lands at or before the 60% byte")
    local miss = wait_search(S, "absent from the whole file", true)
    h.check(miss.pos == nil and miss.err == nil, "a scan of the rest of the file finishes without a match")
    sv.tail(S)
    settle(S)
    sv.goto_offset(S, "30%")
    settle(S)
    timer:stop()
    timer:close()
    collectgarbage("collect")

    h.check(peak - base < 64 * 1024, "Lua memory peaked below 64 MB over a 512 MB file", string.format("%.0f KB", peak - base))
    h.check(collectgarbage("count") - base < 32 * 1024, "memory after the scans is back near its start", string.format("%.0f KB", collectgarbage("count") - base))
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
    eq(vim.fn.readfile(out), { "acwrite", "true", "1" }, "nvim <big file> opens the (editable) viewer instead of reading the file")
  end,
  function()
    -- the threshold follows the cgroup limit, and small files do not cost a /proc read
    local root = tmp .. "/cg"
    vim.fn.mkdir(root .. "/a/b", "p")
    local function put(path, text) write(path:gsub("^" .. vim.pesc(tmp .. "/"), ""), text) end
    put(root .. "/a/memory.max", "4000000000\n")
    put(root .. "/a/memory.current", "1000000000\n")
    put(root .. "/a/b/memory.max", "max\n")
    put(root .. "/a/b/memory.current", "500000000\n")
    write("cg/proc-cgroup", "0::/a/b\n")
    local saved = { sv.opts.cgroup_root, sv.opts.proc_cgroup }
    sv.opts.cgroup_root, sv.opts.proc_cgroup = root, tmp .. "/cg/proc-cgroup"
    local avail = sv.available_memory()
    h.check(avail and avail <= 3000000000, "the cgroup headroom (4 GB limit, 1 GB used) caps the available memory", tostring(avail))
    write("cg/v1-cgroup", "4:memory:/m\n")
    vim.fn.mkdir(root .. "/memory/m", "p")
    put(root .. "/memory/m/memory.limit_in_bytes", "2000000000\n")
    put(root .. "/memory/m/memory.usage_in_bytes", "500000000\n")
    sv.opts.proc_cgroup = tmp .. "/cg/v1-cgroup"
    eq(math.min(sv.available_memory(), 1500000000), sv.available_memory(), "a v1 limit counts too")
    put(root .. "/memory/m/memory.limit_in_bytes", "9223372036854771712\n")
    sv.opts.proc_cgroup = tmp .. "/cg/none-cgroup" -- no cgroup entry: what the machine has free
    local free = sv.available_memory()
    sv.opts.proc_cgroup = tmp .. "/cg/v1-cgroup"
    eq(sv.available_memory(), free, "and 'no limit' does not cap it")
    sv.opts.cgroup_root, sv.opts.proc_cgroup = unpack(saved)

    local meminfo_reads = 0
    local real_open = io.open
    io.open = function(path, ...)
      if path == "/proc/meminfo" then meminfo_reads = meminfo_reads + 1 end
      return real_open(path, ...)
    end
    vim.fn.bufadd(write("small-edit.txt", "small\n"))
    eq(meminfo_reads, 0, "opening a small file does not read /proc/meminfo")
    local big = tmp .. "/big-sparse.bin"
    local fd = assert(uv.fs_open(big, "w", 420))
    uv.fs_ftruncate(fd, sv.opts.min_bytes + 4096)
    uv.fs_close(fd)
    vim.g.stream_viewer_min_bytes = nil
    vim.fn.bufadd(big)
    io.open = real_open
    h.check(meminfo_reads > 0, "a file past the floor does")
    os.remove(big)
    vim.g.stream_viewer_min_bytes = 50
  end,

}

h.run(steps, 240000)

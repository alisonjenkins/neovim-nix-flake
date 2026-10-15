-- Lifecycle of the stream viewer: what happens around a viewer buffer's life (wipe, :edit, a read that
-- fails, the size threshold) and while it follows a growing, truncated or rotated file.
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

local function read(path)
  local f = assert(io.open(path, "rb"))
  local data = f:read("*a")
  f:close()
  return data
end

local function open(path)
  vim.cmd("StreamView! " .. vim.fn.fnameescape(path))
  return sv.state()
end

local function eq(a, b, name)
  h.check(vim.deep_equal(a, b), name, vim.inspect(a) .. " ~= " .. vim.inspect(b))
end

local function numbered(n)
  local t = {}
  for i = 1, n do
    t[i] = string.format("L%03d\n", i)
  end
  return table.concat(t)
end

local function leftovers(dir)
  local found = {}
  for name in vim.fs.dir(dir) do
    if name:find(".streamview-", 1, true) then found[#found + 1] = name end
  end
  return found
end

sv.opts.block = 64
sv.opts.editable = true

local function append(path, text)
  local f = assert(io.open(path, "ab"))
  f:write(text)
  f:close()
end

local function last_line(S)
  local l = sv.lines(S)
  return l[#l]
end

local typing_path, TS

local steps = {
  function()
    local path = write("leak.txt", numbered(100))
    local function count() return #vim.api.nvim_get_autocmds({ event = "WinResized" }) end
    local before = count()
    local last
    for _ = 1, 20 do
      local S = open(path)
      last = S
      vim.api.nvim_buf_set_lines(S.buf, 0, 1, false, { "typed" })
      sv.scroll(S, 1)
      vim.cmd("bwipeout!")
    end
    eq(count(), before, "wiping a viewer buffer leaves no WinResized autocmd behind")
    local ok = pcall(vim.api.nvim_get_autocmds, { group = "streamview-" .. last.buf })
    h.check(not ok, "and removes the buffer's autocmd group")
    h.check(last.closed, "and the state is closed")
  end,

  function()
    -- :edit and :edit! unload the buffer and read it again
    vim.g.stream_viewer_min_bytes = 100
    local path = write("reload.txt", numbered(100))
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local first = sv.state()
    h.check(first ~= nil, "a file over the threshold opens in the viewer")
    vim.cmd("edit")
    local S = sv.state()
    h.check(S ~= nil and S ~= first and not S.closed, ":edit makes a fresh viewer state")
    eq(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1], "L001", "and the reloaded buffer shows the file, not a blank buffer")
    h.check(not vim.bo.modified, "and is not modified")

    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "typed" })
    sv.scroll(S, 1)
    h.check(vim.bo.modified, "an edit marks the viewer modified")
    vim.cmd("edit!")
    S = sv.state()
    eq(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1], "L001", ":edit! drops the edits and shows the file again")
    h.check(not vim.bo.modified, "and the buffer is not modified")

    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "XXXX" })
    vim.cmd("write")
    vim.wait(5000, function() return read(path):sub(1, 5) == "XXXX\n" end, 10)
    eq(read(path):sub(1, 10), "XXXX\nL002\n", ":w after a reload saves through the new state")
    eq(leftovers(tmp), {}, "and leaves no temp file")

    -- a state that was closed by the reload cannot write
    local stale = S
    vim.cmd("edit!")
    h.check(stale.closed, "the reload closed the old state")
    local res
    sv.write(stale, {}, function(ok, err) res = { ok = ok, err = err } end)
    vim.wait(2000, function() return res ~= nil end, 10)
    h.check(res ~= nil and res.ok == false, "writing through a closed state fails")
    eq(leftovers(tmp), {}, "and creates no temp file")
    eq(read(path):sub(1, 10), "XXXX\nL002\n", "and leaves the file as it was")

    -- an explicit :StreamView buffer reloads too
    local S2 = open(path)
    local buf = S2.buf
    vim.cmd("edit!")
    S2 = sv.state()
    h.check(S2 ~= nil and S2.buf == buf and not S2.closed, ":edit! on a stream:// buffer attaches again")
    eq(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1], "XXXX", "and shows the file")
    vim.g.stream_viewer_min_bytes = nil
    vim.cmd("silent! %bwipeout!")
  end,

  function()
    -- a job running when the buffer goes away releases its temp file
    local path = write("jobclose.txt", numbered(400))
    local S = open(path)
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "typed" })
    local t = 0
    local orig = uv.hrtime
    uv.hrtime = function()
      t = t + 20e6
      return t
    end
    local res
    sv.write(S, {}, function(ok, err) res = { ok = ok, err = err } end)
    uv.hrtime = orig
    h.check(S.job ~= nil, "a slow save is still running")
    vim.cmd("bwipeout!")
    vim.wait(2000, function() return res ~= nil end, 10)
    h.check(res ~= nil and res.ok == false, "wiping the buffer ends the save as failed")
    eq(leftovers(tmp), {}, "and removes its temp file")
    eq(read(path), numbered(400), "and the file is untouched")
  end,

  function()
    -- a read that is taken over but cannot open the file leaves a buffer that cannot write
    h.capture_notify()
    vim.g.stream_viewer_min_bytes = 100
    local path = write("noaccess.txt", numbered(100))
    local real = sv.open_reader
    sv.open_reader = function() return nil, "EACCES: permission denied" end
    pcall(vim.cmd, "edit " .. vim.fn.fnameescape(path)) -- the reported error also aborts :edit
    sv.open_reader = real
    h.check(sv.state() == nil, "no viewer is attached when the file cannot be opened")
    h.check(not vim.bo.modifiable and not vim.bo.modified, "the buffer is not modifiable and not modified")
    h.check(#h.notes_matching("EACCES") > 0, "the error is reported")
    local ok = pcall(vim.cmd, "write")
    h.check(not ok, ":w refuses")
    ok = pcall(vim.cmd, "write!")
    h.check(not ok, ":w! refuses")
    eq(read(path), numbered(100), "and the file is untouched")
    vim.cmd("silent! %bwipeout!")

    -- files that are not regular files are never taken over
    vim.g.stream_viewer_min_bytes = 0
    local dir = tmp .. "/adir"
    vim.fn.mkdir(dir, "p")
    h.check(not sv.is_too_big(dir), "a directory is not taken over")
    local fifo = tmp .. "/afifo"
    vim.system({ "mkfifo", fifo }):wait()
    h.check(not sv.is_too_big(fifo), "a FIFO is not taken over")
    h.check(not sv.is_too_big("/dev/zero"), "a character device is not taken over")
    h.check(not sv.is_too_big(tmp .. "/missing"), "a missing file is not taken over")
    h.check(sv.is_too_big(path), "a regular file over the threshold is taken over")
    vim.g.stream_viewer_min_bytes = nil
  end,

  function()
    -- the size threshold honours cgroup limits and does not read memory figures for small files
    local KiB = 1024
    local fake = tmp .. "/fakesys"
    local function put(rel, text)
      vim.fn.mkdir(vim.fs.dirname(fake .. "/" .. rel), "p")
      write("fakesys/" .. rel, text)
    end
    local saved_cg, saved_proc, saved_min = sv.opts.cgroup_root, sv.opts.proc_cgroup, sv.opts.min_bytes
    sv.opts.min_bytes = 1 * KiB
    vim.g.stream_viewer_min_bytes = nil

    sv.opts.cgroup_root, sv.opts.proc_cgroup = fake .. "/cg", fake .. "/none"
    local machine = sv.available_memory()
    h.check(machine and machine > 1024 * KiB, "without a cgroup the available memory is MemAvailable", tostring(machine))

    -- cgroup v2: the cgroup has 100 KiB of headroom, its parent more
    sv.opts.proc_cgroup = fake .. "/cgroup"
    put("cgroup", "0::/work/job\n")
    put("cg/work/job/memory.max", (1024 * KiB) .. "\n")
    put("cg/work/job/memory.current", (924 * KiB) .. "\n")
    put("cg/work/memory.max", "max\n")
    put("cg/work/memory.current", (1 * KiB) .. "\n")
    eq(sv.available_memory(), 100 * KiB, "a cgroup v2 limit minus its usage caps the available memory")
    eq(sv.threshold(), 50 * KiB, "and the threshold is half of that")

    -- an ancestor with less headroom wins
    put("cg/work/memory.max", (60 * KiB) .. "\n")
    put("cg/work/memory.current", (20 * KiB) .. "\n")
    eq(sv.available_memory(), 40 * KiB, "the tightest ancestor limit wins")

    -- a limit above MemAvailable changes nothing
    put("cg/work/memory.max", "max\n")
    put("cg/work/job/memory.max", (1024 * 1024 * 1024 * KiB) .. "\n")
    put("cg/work/job/memory.current", "0\n")
    h.check(sv.available_memory() >= machine * 0.5, "a roomier cgroup does not raise MemAvailable")

    -- cgroup v1
    put("cgroup", "4:cpu:/x\n3:memory:/legacy\n")
    put("cg/memory/legacy/memory.limit_in_bytes", (300 * KiB) .. "\n")
    put("cg/memory/legacy/memory.usage_in_bytes", (100 * KiB) .. "\n")
    eq(sv.available_memory(), 200 * KiB, "a cgroup v1 limit minus its usage caps the available memory")
    put("cg/memory/legacy/memory.limit_in_bytes", "9223372036854771712\n")
    h.check(sv.available_memory() >= machine * 0.5, "and the v1 value for no limit is ignored")

    -- a file over the cgroup threshold is taken over even though the machine has plenty of memory
    put("cgroup", "0::/work/job\n")
    put("cg/work/job/memory.max", (1024 * KiB) .. "\n")
    put("cg/work/job/memory.current", (924 * KiB) .. "\n")
    local big = write("cgbig.bin", string.rep("x", 60 * KiB))
    h.check(sv.is_too_big(big), "a 60 KiB file is taken over in a cgroup with 100 KiB of headroom")

    -- a file at or under the floor never reads the memory figures
    local reads = 0
    local real = sv.available_memory
    sv.available_memory = function()
      reads = reads + 1
      return real()
    end
    local small = write("cgsmall.txt", string.rep("x", 1000))
    h.check(not sv.is_too_big(small), "a small file is not taken over")
    eq(reads, 0, "and the memory figures were not read for it")
    sv.is_too_big(big)
    h.check(reads >= 1, "but they are for a file over the floor")

    sv.available_memory = real
    sv.opts.cgroup_root, sv.opts.proc_cgroup, sv.opts.min_bytes = saved_cg, saved_proc, saved_min
  end,

  -- follow mode does not redraw under the user's hands. Keys are typed on the main loop, between
  -- steps, so Insert mode lasts across them.
  function()
    typing_path = write("typing.log", numbered(30))
    sv.opts.follow_ms = 40
    TS = open(typing_path)
    sv.toggle_follow(TS)
    append(typing_path, "grown1\n")
  end,
  {
    ["until"] = function() return last_line(TS) == "grown1" end,
    what = "follow to show an appended line",
  },
  function()
    h.check(true, "follow shows an appended line when nothing is typed")
    -- <Esc> first: the viewer's notice may have left a hit-enter prompt that would swallow the key
    vim.api.nvim_feedkeys(vim.keycode("<Esc>i"), "n", false)
  end,
  {
    ["until"] = function() return vim.api.nvim_get_mode().mode == "i" end,
    what = "Insert mode",
  },
  function() append(typing_path, "grown2\n") end,
  function()
    vim.wait(400, function() return false end, 20)
    eq(last_line(TS), "grown1", "no redraw in Insert mode")
    h.check(TS.follow ~= nil, "and follow is still on")
    vim.api.nvim_feedkeys("typed", "n", false)
  end,
  {
    ["until"] = function() return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("typed", 1, true) end,
    what = "the typed text",
  },
  function()
    append(typing_path, "grown3\n")
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "n", false)
  end,
  {
    ["until"] = function() return vim.api.nvim_get_mode().mode == "n" end,
    what = "Normal mode",
  },
  function()
    vim.wait(400, function() return false end, 20)
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    h.check(text:find("typed", 1, true) ~= nil, "typed text survives while the typed change is unapplied")
    h.check(TS.follow_paused == true, "and follow reports that it is paused")
    sv.undo(TS)
  end,
  {
    ["until"] = function() return last_line(TS) == "grown3" end,
    what = "the held-back lines once the typed change is gone",
  },
  function()
    h.check(not TS.follow_paused, "then follow is no longer paused")

    -- a hit-enter or more prompt ("r?", "rm") is not typing into the buffer
    local real_mode = vim.api.nvim_get_mode
    vim.api.nvim_get_mode = function() return { mode = "r?", blocking = true } end
    append(typing_path, "grown4\n")
    vim.wait(3000, function() return last_line(TS) == "grown4" end, 20)
    vim.api.nvim_get_mode = real_mode
    eq(last_line(TS), "grown4", "follow keeps going at a hit-enter prompt")
    sv.toggle_follow(TS, false)
    sv.opts.follow_ms = 500
  end,

  function()
    -- the file grows while edits are held: they stay, the new lines appear, a save has both
    sv.opts.follow_ms = 40
    local base = numbered(40)
    local path = write("growedit.log", base)
    local S = open(path)
    vim.api.nvim_buf_set_lines(S.buf, 0, 1, false, { "HEAD EDIT" })
    sv.tail(S)
    local rows = #sv.lines(S)
    vim.api.nvim_buf_set_lines(S.buf, rows - 1, rows, false, { "TAIL EDIT" })
    sv.toggle_follow(S) -- puts the typed edit in the history, then follows
    h.check(not S.r:pristine(), "there are edits in the history")
    append(path, "grown1\ngrown2\n")
    vim.wait(3000, function() return last_line(S) == "grown2" end, 20)
    eq(last_line(S), "grown2", "growth is shown while edits are held")
    local lines = sv.lines(S)
    eq(lines[#lines - 2], "TAIL EDIT", "the edit at the end of the old file is still there")
    eq(S.r:get(0, 10), "HEAD EDIT\n", "and so is the edit at the start")
    local expect = "HEAD EDIT\n" .. base:sub(6, -6) .. "TAIL EDIT\ngrown1\ngrown2\n"
    eq(S.r:get(0, S.r.size), expect, "the logical text is the edits over the grown file")

    append(path, "grown3\n")
    vim.wait(3000, function() return last_line(S) == "grown3" end, 20)
    eq(last_line(S), "grown3", "and keeps growing")
    sv.toggle_follow(S, false)

    sv.undo(S)
    eq(S.r:get(0, S.r.size):sub(-26), "L040\ngrown1\ngrown2\ngrown3\n", "undo of the tail edit keeps the grown lines")
    sv.redo(S)
    eq(S.r:get(0, S.r.size), expect .. "grown3\n", "and redo applies it again")

    local res
    sv.write(S, {}, function(ok, err) res = { ok = ok, err = err } end)
    vim.wait(10000, function() return res ~= nil end, 5)
    h.check(res and res.ok, "the save is not refused for the growth it already includes", vim.inspect(res))
    eq(read(path), expect .. "grown3\n", "and the file has the edits and the growth")
    sv.opts.follow_ms = 500
  end,

  -- Bugs of the editing and saving code found by the reviewers and by tests/nvim/streamfuzz.lua, each a
  -- minimal repro. One is still open and runs as h.xfail: it fails as XPASS once fixed, then the
  -- marker goes and the check stays.
  function()
    local function window_edit(name, text, change)
      local S = open(write(name, text))
      local cur = vim.api.nvim_buf_get_lines(S.buf, 0, -1, false)
      vim.api.nvim_buf_set_lines(S.buf, 0, -1, false, change(cur))
      sv.render(S)
      return S.r:get(0, S.r.size)
    end

    local got = window_edit("xf-crlf-tail.txt", "a\r\nb", function(cur) return { "a", "b", "c" } end)
    h.check(got == "a\r\nb\r\nc", "a line typed after an unterminated last line of a CRLF file ends the line before it with CRLF", string.format("%q", got))

    got = window_edit("xf-del-tail.txt", "a\nb\nc", function(cur) return { "a", "b" } end)
    h.check(got == "a\nb", "deleting the unterminated last line leaves the line before it without a line end", string.format("%q", got))

    got = window_edit("xf-del-all.txt", "a\nb\n", function(cur) return { "" } end)
    h.check(got == "", "deleting every line of the file leaves an empty file", string.format("%q", got))

    got = window_edit("xf-mixed.txt", "a\r\nb\n", function(cur) return { "A", "B" } end)
    h.check(got == "A\r\nB\n", "replacing lines with different line ends keeps the end of each line", string.format("%q", got))

    -- an edit undone, text typed and taken back with u, a movement, then redo: the edit comes back
    local S = open(write("xf-redo-typed.txt", numbered(60)))
    vim.api.nvim_buf_set_lines(S.buf, 0, 1, false, { "EDIT" })
    sv.render(S)
    sv.undo(S)
    vim.api.nvim_buf_set_lines(S.buf, 1, 2, false, { "TYPED" })
    sv.undo(S)
    sv.head(S)
    sv.redo(S)
    local text = S.r:get(0, S.r.size)
    local want = "EDIT\n" .. numbered(60):sub(6)
    h.xfail("redo after taken-back typing redoes the earlier edit, not the typing", text == want, string.format("%q", text:sub(1, 30)))
    vim.cmd("silent! %bwipeout!")
  end,

  function()
    -- an edit and a movement made while a save is writing must not change what is saved
    local base = numbered(100)
    local path = write("xf-during-save.txt", base)
    sv.opts.block = 64
    local S = open(path)
    vim.api.nvim_buf_set_lines(S.buf, 0, 1, false, { "AAA" })
    local t = 0
    local real = uv.hrtime
    uv.hrtime = function()
      t = t + 20e6
      return t
    end
    local res
    sv.write(S, {}, function(ok, err) res = { ok = ok, err = err } end)
    vim.api.nvim_buf_set_lines(S.buf, 0, 3, false, { "ZZZZZZZZZZ" })
    pcall(sv.scroll, S, 1)
    vim.wait(10000, function() return res ~= nil end, 5)
    uv.hrtime = real
    h.check(res ~= nil, "the save under an edit finishes")
    h.check(read(path) == "AAA\n" .. base:sub(6), "a save writes the text as it was when the save started", "the file differs from the snapshot")
    vim.cmd("silent! %bwipeout!")
  end,

  function()
    -- redo after the file grew on disk must still apply, and the saved file must keep the growth
    local path = write("xf-redo-refresh.txt", numbered(10))
    local S = open(path)
    vim.api.nvim_buf_set_lines(S.buf, 0, 1, false, { "EDITED" })
    sv.scroll(S, 0)
    sv.undo(S)
    append(path, "APPENDED1\nAPPENDED2\n")
    sv.scroll(S, 0) -- draws: the reader adopts the grown file
    sv.redo(S)
    local res
    sv.write(S, {}, function(ok, err) res = { ok = ok, err = err } end)
    vim.wait(10000, function() return res ~= nil end, 5)
    local out = read(path)
    h.check(out:find("EDITED", 1, true) and out:find("APPENDED2", 1, true), "redo after the file grew keeps the redo history and the growth", vim.inspect(res) .. " " .. string.format("%q", out:sub(1, 40)))
    vim.cmd("silent! %bwipeout!")
  end,
}

h.run(steps, 240000)

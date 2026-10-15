-- The save path of the stream viewer (lua/streamview_save.lua): what is written is an immutable
-- snapshot, the window cannot change while a save runs, and every way a save can go wrong leaves
-- the file as it was. Each check compares bytes with a model built in Lua.
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

local function save(S, opts)
  local res
  sv.write(S, opts, function(ok, err) res = { ok = ok, err = err } end)
  vim.wait(60000, function() return res ~= nil end, 5)
  return res or { ok = false, err = "timed out" }
end

local function eq(a, b, name)
  h.check(vim.deep_equal(a, b), name, vim.inspect(a) .. " ~= " .. vim.inspect(b))
end

local function leftovers(dir)
  local found = {}
  for name in vim.fs.dir(dir) do
    if name:find(".streamview-", 1, true) then found[#found + 1] = name end
  end
  return found
end

local function numbered(n)
  local t = {}
  for i = 1, n do
    t[i] = "line " .. i
  end
  return table.concat(t, "\n") .. "\n"
end

-- Makes every job tick end its time slice, so a job spans many event loop turns.
local function slow_slices()
  local real, t = uv.hrtime, 0
  uv.hrtime = function()
    t = t + 20e6
    return t
  end
  return function() uv.hrtime = real end
end

sv.opts.block = 64
sv.opts.editable = true

local S

local steps = {
  function()
    -- R1: the text written is the text at the start of the save, whatever happens meanwhile
    local path = write("snap.txt", numbered(400))
    S = open(path)
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "FIRST EDITED" })
    local expect = "FIRST EDITED\n" .. numbered(400):sub(#"line 1\n" + 1)
    local restore = slow_slices()
    local res
    sv.write(S, {}, function(ok, err) res = { ok = ok, err = err } end)
    h.check(res == nil, "a slow save is still running after the first slice")
    local function refused(fn, name)
      local ok, err = pcall(fn)
      h.check(not ok and type(err) == "table" and err.blocked ~= nil, name .. " is refused while saving", vim.inspect(err))
    end
    refused(function() sv.scroll(S, 1) end, "scrolling")
    refused(function() sv.goto_offset(S, "50%") end, "a jump")
    refused(function() sv.tail(S) end, "going to the end")
    refused(function() sv.undo(S) end, "undo")
    refused(function() sv.redo(S) end, "redo")
    refused(function() sv.search(S, "line 3", true) end, "a search")
    h.check(not pcall(vim.api.nvim_buf_set_lines, 0, 0, 1, false, { "typed" }), "typing in the window is refused while saving")
    vim.wait(60000, function() return res ~= nil end, 5)
    restore()
    h.check(res and res.ok, "the save finishes", vim.inspect(res))
    eq(read(path), expect, "the file is the text at the start of the save")
    h.check(vim.bo.modifiable and not vim.bo.modified, "the window is editable again and not modified")
    sv.scroll(S, 1)
    h.check(true, "and moves again")
  end,

  function()
    -- R1: even if the live text is changed behind the guards, the file gets the snapshot, and the
    -- change is not thrown away by the reload
    local path = write("snap2.txt", numbered(400))
    S = open(path)
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "SNAPSHOT EDIT" })
    local expect = "SNAPSHOT EDIT\n" .. numbered(400):sub(#"line 1\n" + 1)
    local restore = slow_slices()
    local res
    sv.write(S, {}, function(ok, err) res = { ok = ok, err = err } end)
    S.r:replace(0, 4, "LATER")
    S.r:replace(S.r.size - 3, S.r.size - 1, "LATE")
    vim.wait(60000, function() return res ~= nil end, 5)
    restore()
    eq(read(path), expect, "the file holds the snapshot, not the later change")
    h.check(res and not res.ok and res.err:find("changed during the save", 1, true), "the save says the later change is unsaved", vim.inspect(res))
    h.check(S.r:get(0, 5) == "LATER", "and the later change is still in the viewer")
    eq(leftovers(tmp), {}, "no temp file is left")
  end,

  function()
    -- R2: a read-only file is not replaced without !
    if uv.getuid() == 0 then
      h.check(true, "skipped: root can write read-only files")
      return
    end
    local path = write("ro.txt", numbered(20))
    uv.fs_chmod(path, 292) -- 0444
    local ino = uv.fs_stat(path).ino
    S = open(path)
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "RO EDIT" })
    local res = save(S)
    h.check(not res.ok and res.err:find("read-only", 1, true), "saving a 0444 file is refused", vim.inspect(res))
    eq(read(path), numbered(20), "and the file is untouched")
    eq(uv.fs_stat(path).ino, ino, "and still the same inode")
    eq(leftovers(tmp), {}, "and no temp file is left")
    res = save(S, { force = true })
    h.check(res.ok, "! saves it", vim.inspect(res))
    h.check(read(path):sub(1, 8) == "RO EDIT\n", "with the edit")
    eq(bit.band(uv.fs_stat(path).mode, 4095), 292, "and keeps the mode 0444")
  end,

  function()
    -- R2: a failed chown is reported instead of silently changing the owner
    local path = write("own.txt", numbered(20))
    S = open(path)
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "OWN EDIT" })
    local real = uv.fs_fchown
    uv.fs_fchown = function() return nil, "EPERM: operation not permitted" end
    local res = save(S)
    h.check(not res.ok and res.err:find("cannot keep the owner", 1, true), "a chown failure aborts the save", vim.inspect(res))
    eq(read(path), numbered(20), "and the file is untouched")
    eq(leftovers(tmp), {}, "and no temp file is left")
    res = save(S, { force = true })
    uv.fs_fchown = real
    h.check(res.ok and read(path):sub(1, 9) == "OWN EDIT\n", "! saves anyway", vim.inspect(res))
  end,

  function()
    -- R3: saving what is unmodified does no I/O
    local path = write("pristine.txt", numbered(50))
    local before = uv.fs_stat(path)
    S = open(path)
    local writes = 0
    local real = uv.fs_write
    uv.fs_write = function(...)
      writes = writes + 1
      return real(...)
    end
    local res = save(S)
    h.check(res.ok, "saving an unmodified file succeeds", vim.inspect(res))
    local after = uv.fs_stat(path)
    eq({ after.ino, after.mtime.sec, after.mtime.nsec }, { before.ino, before.mtime.sec, before.mtime.nsec }, "and keeps the inode and mtime")
    eq(writes, 0, "and writes nothing")
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "EDIT" })
    sv.scroll(S, 1)
    sv.undo(S)
    res = save(S)
    eq(writes, 0, "also after an edit was undone")
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "EDIT" })
    res = save(S)
    uv.fs_write = real
    h.check(res.ok and writes > 0 and read(path):sub(1, 5) == "EDIT\n", "a modified file is written", vim.inspect(res))
  end,

  function()
    -- R4: a source that shrinks during the save aborts it; nothing is zero filled
    local path = write("shrink.txt", numbered(400))
    S = open(path)
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "SHRINK EDIT" })
    local restore = slow_slices()
    local res
    sv.write(S, {}, function(ok, err) res = { ok = ok, err = err } end)
    local kept = numbered(400):sub(1, 1000)
    local tfd = assert(uv.fs_open(path, "r+", 0))
    assert(uv.fs_ftruncate(tfd, 1000))
    uv.fs_close(tfd)
    vim.wait(60000, function() return res ~= nil end, 5)
    restore()
    h.check(res and not res.ok and res.err:find("short read", 1, true), "a truncated source aborts the save", vim.inspect(res))
    eq(read(path), kept, "and the file is left as it is")
    eq(leftovers(tmp), {}, "and no temp file is left")
    h.check(vim.bo.modifiable, "and the window is editable again")
  end,

  function()
    -- R4: a write that makes no progress is an error, not a loop
    local path = write("stall.txt", numbered(400))
    S = open(path)
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "STALL EDIT" })
    local real = uv.fs_write
    uv.fs_write = function() return 0 end
    local res = save(S)
    uv.fs_write = real
    h.check(not res.ok and res.err:find("wrote 0", 1, true), "a write of 0 bytes aborts the save", vim.inspect(res))
    eq(read(path), numbered(400), "and the file is untouched")
    eq(leftovers(tmp), {}, "and no temp file is left")
  end,

  function()
    -- S1: :wq, :x and ZZ save, then close the window; a failed save keeps it open
    for _, how in ipairs({ "wq", "x", "ZZ" }) do
      local path = write("quit-" .. how .. ".txt", numbered(400))
      vim.cmd("only")
      S = open(path)
      vim.cmd("split")
      local win = vim.api.nvim_get_current_win()
      vim.api.nvim_buf_set_lines(0, 0, 1, false, { "QUIT EDIT" })
      local restore = slow_slices()
      if how == "ZZ" then
        -- the mapping itself: a key press can be taken by other plugins' triggers (which-key)
        vim.fn.maparg("ZZ", "n", false, true).callback()
      else
        vim.api.nvim_feedkeys(":" .. how .. "\r", "tx", false)
      end
      h.check(vim.api.nvim_win_is_valid(win), ":" .. how .. " keeps the window while the save runs")
      vim.wait(60000, function() return not vim.api.nvim_win_is_valid(win) end, 5)
      restore()
      h.check(not vim.api.nvim_win_is_valid(win), ":" .. how .. " closes the window when the save is done")
      h.check(read(path):sub(1, 10) == "QUIT EDIT\n", ":" .. how .. " saved the edit")
    end

    -- a save that ends before the command returns: the command quits by itself, once
    local small = write("quit-small.txt", numbered(3))
    vim.cmd("only")
    S = open(small)
    vim.cmd("split")
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "SMALL" })
    local quick_win = vim.api.nvim_get_current_win()
    vim.api.nvim_feedkeys(":wq\r", "tx", false)
    h.check(not vim.api.nvim_win_is_valid(quick_win), ":wq on a quick save closes the window")
    h.check(read(small):sub(1, 6) == "SMALL\n", "and saved it")
    vim.cmd("only")
    S = open(small)
    vim.cmd("split")
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "PLAIN" })
    quick_win = vim.api.nvim_get_current_win()
    vim.api.nvim_feedkeys(":w\r", "tx", false)
    h.check(vim.api.nvim_win_is_valid(quick_win), ":w does not close the window")

    local path = write("quit-fail.txt", numbered(400))
    vim.cmd("only")
    S = open(path)
    vim.cmd("split")
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "QUIT EDIT" })
    local restore = slow_slices()
    vim.api.nvim_feedkeys(":wq\r", "tx", false)
    local tfd = assert(uv.fs_open(path, "r+", 0))
    assert(uv.fs_ftruncate(tfd, 1000))
    uv.fs_close(tfd)
    vim.wait(60000, function() return not S.saving end, 5)
    restore()
    vim.wait(100)
    h.check(vim.api.nvim_win_is_valid(win), "a failed save does not close the window")
    h.check(vim.bo[S.buf].modified, "and the buffer stays modified")
    vim.cmd("only")
  end,
}

h.run(steps, 600000)

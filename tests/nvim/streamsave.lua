-- The save path of the stream viewer (lua/streamview_save.lua): what is written is an immutable
-- snapshot, the window cannot change while a save runs, and every way a save can go wrong leaves
-- the file as it was. Each check compares bytes with a model built in Lua.
local h = dofile(os.getenv("TEST_DIR") .. "/harness.lua")
local tmp = os.getenv("TMPDIR") or "/tmp"
local uv = vim.uv
local sv = require("streamview")
local fs = require("streamview_fs")

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

-- A move over far-apart lines is a job: wait for it
local function settle(S)
  vim.wait(120000, function() return S.job == nil end, 5)
end

local function save(S, opts)
  local res
  sv.write(S, opts, function(ok, err) res = { ok = ok, err = err } end)
  vim.wait(60000, function() return res ~= nil end, 5)
  return res or { ok = false, err = "timed out" }
end

local function eq(a, b, name)
  local function short(v)
    local s = vim.inspect(v)
    return #s > 200 and (s:sub(1, 200) .. "... (" .. #s .. " chars)") or s
  end
  h.check(vim.deep_equal(a, b), name, short(a) .. " ~= " .. short(b))
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


-- A sparse file of `size` bytes with the given { offset, text } regions; everything else is a hole.
local function sparse_file(name, size, regions)
  local path = tmp .. "/" .. name
  local fd = assert(uv.fs_open(path, "w", 420))
  assert(uv.fs_ftruncate(fd, size))
  for _, region in ipairs(regions) do
    assert(uv.fs_write(fd, region[2], region[1]))
  end
  uv.fs_close(fd)
  return path
end

local function allocated(path) return uv.fs_stat(path).blocks * 512 end

-- True when the file has exactly the regions and zeros everywhere else; returns the first
-- difference otherwise.
local function matches_regions(path, size, regions)
  local st = uv.fs_stat(path)
  if st.size ~= size then return false, "size " .. st.size .. " ~= " .. size end
  local fd = assert(uv.fs_open(path, "r", 0))
  local step = 4 * 1024 * 1024
  for base = 0, size - 1, step do
    local len = math.min(step, size - base)
    local data = uv.fs_read(fd, len, base)
    if not data or #data ~= len then return false, "short read at " .. base end
    local expect = nil
    for _, region in ipairs(regions) do
      local from, to = math.max(region[1], base), math.min(region[1] + #region[2], base + len)
      if from < to then
        expect = expect or string.rep("\0", len)
        expect = expect:sub(1, from - base) .. region[2]:sub(from - region[1] + 1, to - region[1]) .. expect:sub(to - base + 1)
      end
    end
    if expect then
      if data ~= expect then return false, "differs in the block at " .. base end
    elseif not fs.is_zero(data) then
      return false, "not zero in the block at " .. base
    end
  end
  uv.fs_close(fd)
  return true
end

-- A file of `size` bytes: random text with zero pages in it, so that holes are made and skipped.
local function mixed_content(rnd, size)
  local parts, n = {}, 0
  while n < size do
    local len = math.min(rnd(1, 20000), size - n)
    if rnd(1, 4) == 1 then
      parts[#parts + 1] = string.rep("\0", len)
    else
      local t = {}
      for k = 1, len do
        t[k] = string.char(rnd(1, 255))
      end
      parts[#parts + 1] = table.concat(t)
    end
    n = n + len
  end
  return table.concat(parts)
end

-- Random edits applied to the viewer's reader and to a string model. kind: "same" keeps every
-- length, "tail" edits only the last 2%, "any" edits anywhere with any length.
local function random_edits(S, rnd, model, kind, count)
  for _ = 1, count do
    local size = #model
    local lo = kind == "tail" and math.floor(size * 0.98) or 0
    local start = rnd(lo, math.max(size - 1, lo))
    local len = rnd(0, math.min(300, size - start))
    local text_len = kind == "same" and len or rnd(0, 400)
    local t = {}
    for k = 1, text_len do
      t[k] = string.char(rnd(97, 122))
    end
    local text = table.concat(t)
    S.r:apply({ { start = start, stop = start + len, text = text } })
    model = model:sub(1, start) .. text .. model:sub(start + len + 1)
  end
  return model
end

local function save_journal(path) return require("streamview_save").journal_path(path) end

-- Stands in for a reflink clone: copies the file. The real call needs a file system that clones.
local function fake_clone(src, dst)
  local size = uv.fs_fstat(src).size
  local pos = 0
  while pos < size do
    local n = assert(fs.copy_range(src, pos, dst, pos, size - pos))
    pos = pos + n
  end
  return true
end

-- Runs fn and counts the bytes passed to uv.fs_write meanwhile.
local function count_writes(fn)
  local real, total = uv.fs_write, 0
  uv.fs_write = function(fd, data, ...)
    total = total + #data
    return real(fd, data, ...)
  end
  local ok, result = pcall(fn)
  uv.fs_write = real
  assert(ok, result)
  return { bytes = total, result = result }
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
    -- the user's commands and keys say so, instead of raising the error table
    h.capture_notify()
    h.notes = {}
    local cmd_ok, cmd_err = pcall(vim.cmd, "StreamGoto 50%")
    h.check(cmd_ok, ":StreamGoto during a save raises nothing", tostring(cmd_err))
    h.check(#h.notes_matching("a save is running") > 0, "it tells the user a save is running", vim.inspect(h.notes))
    for _, c in ipairs({ "StreamLine 5", "StreamCol 3", "StreamYank 0 5" }) do
      h.notes = {}
      cmd_ok, cmd_err = pcall(vim.cmd, c)
      h.check(cmd_ok and #h.notes_matching("a save is running") > 0, ":" .. c .. " during a save only gives a message", tostring(cmd_err) .. vim.inspect(h.notes))
    end
    h.notes = {}
    vim.fn.maparg("G", "n", false, true).callback()
    h.check(#h.notes_matching("a save is running") > 0, "the G key says the same", vim.inspect(h.notes))
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
    -- R2: a fifo, a directory and a symlink to one are not replaced, not even with !
    local path = write("nonreg-src.txt", numbered(20))
    local fifo = tmp .. "/nonreg.fifo"
    local dirpath = tmp .. "/nonreg.dir"
    local link = tmp .. "/nonreg.link"
    os.remove(fifo)
    os.remove(link)
    vim.fn.delete(dirpath, "rf")
    h.check(vim.system({ "mkfifo", fifo }):wait().code == 0, "a fifo can be made")
    assert(uv.fs_mkdir(dirpath, 493))
    assert(uv.fs_symlink(fifo, link))
    S = open(path)
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "NONREG EDIT" })
    for _, target in ipairs({ fifo, dirpath, link }) do
      for _, force in ipairs({ false, true }) do
        local res = save(S, { path = target, force = force })
        h.check(
          not res.ok and res.err:find("not a regular file", 1, true),
          string.format("saving over %s (force=%s) is refused", vim.fs.basename(target), tostring(force)),
          vim.inspect(res)
        )
      end
    end
    eq(uv.fs_stat(fifo).type, "fifo", "the fifo is still a fifo")
    eq(uv.fs_lstat(link).type, "link", "the symlink is still a symlink")
    eq(uv.fs_stat(dirpath).type, "directory", "the directory is still a directory")
    eq(read(path), numbered(20), "and the viewed file is untouched")
    eq(leftovers(tmp), {}, "no temp file is left")
    os.remove(fifo)
    os.remove(link)
    vim.fn.delete(dirpath, "rf")
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

  function()
    -- S2: an atomic rewrite keeps the holes of a sparse file
    local size = 256 * 1024 * 1024
    local mid = math.floor(size * 0.6)
    local regions = {
      { 0, "head line\nsecond line\n" },
      { mid - 1, "\nmiddle line\n" },
      { size - 9, "\nlast ln\n" },
    }
    local path = sparse_file("sparse.bin", size, regions)
    if allocated(path) > 1024 * 1024 then
      h.check(true, "skipped: this file system does not keep holes")
      return
    end
    local mid_new = "MIDDLE LINE EDITED AND LONGER"
    local want_size = size + (#mid_new - #"middle line") + (#"LAST" - #"last ln")
    local want = {
      { 0, "head line\nsecond line\n" },
      { mid - 1, "\n" .. mid_new .. "\n" },
      { want_size - 6, "\nLAST\n" },
    }
    for _, mode in ipairs({ "seek", "no seek" }) do
      local real_seek = fs.seek_data
      if mode == "no seek" then fs.seek_data = function() return nil, "UNSUPPORTED" end end
      path = sparse_file("sparse.bin", size, regions)
      S = open(path)
      sv.goto_offset(S, mid)
      settle(S)
      vim.api.nvim_buf_set_lines(0, 0, 1, false, { mid_new })
      sv.tail(S)
      settle(S)
      local rows = vim.api.nvim_buf_line_count(0)
      vim.api.nvim_buf_set_lines(0, rows - 1, rows, false, { "LAST" })
      local res = save(S, { strategy = "atomic" })
      fs.seek_data = real_seek
      h.check(res.ok, mode .. ": the sparse file is saved", vim.inspect(res))
      local ok, why = matches_regions(path, want_size, want)
      h.check(ok, mode .. ": it has the edits and zeros everywhere else", tostring(why))
      h.check(allocated(path) < 1024 * 1024, mode .. ": and is still sparse", allocated(path) .. " bytes allocated")
      eq(leftovers(tmp), {}, mode .. ": and no temp file is left")
      vim.cmd("bwipeout!")
      os.remove(path)
    end
  end,

  function()
    -- S3: extended attributes and ACLs survive an atomic save
    local path = write("xattr.txt", numbered(20))
    local function sh(cmd) return vim.system(cmd, { text = true }):wait() end
    if vim.fn.executable("setfattr") == 0 or vim.fn.executable("setfacl") == 0 then
      h.check(true, "skipped: setfattr and setfacl are not installed")
      return
    end
    local set = sh({ "setfattr", "-n", "user.streamsave", "-v", "kept", path })
    if set.code ~= 0 then
      h.check(true, "skipped: this file system has no user extended attributes: " .. vim.trim(set.stderr))
      return
    end
    local acl = sh({ "setfacl", "-m", "u:1:r,g:2:rw", path })
    local has_acl = acl.code == 0
    if not has_acl then h.check(true, "no ACL check: " .. vim.trim(acl.stderr)) end
    local function attrs() return sh({ "getfattr", "-d", "-m", "-", "--absolute-names", path }).stdout:gsub("# file:[^\n]*\n", "") end
    local function acls() return sh({ "getfacl", "--absolute-names", path }).stdout:gsub("# file:[^\n]*\n", "") end
    local attrs_before, acls_before = attrs(), acls()
    local ino = uv.fs_stat(path).ino
    S = open(path)
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "XATTR EDIT AND LONGER" })
    local res = save(S, { strategy = "atomic" })
    h.check(res.ok, "the file with attributes is saved", vim.inspect(res))
    h.check(uv.fs_stat(path).ino ~= ino, "by a copy")
    eq(attrs(), attrs_before, "and keeps its extended attributes")
    h.check(attrs():find("user.streamsave=\"kept\"", 1, true) ~= nil, "including the user one")
    if has_acl then
      eq(acls(), acls_before, "and its ACL")
      h.check(acls():find("user:[^:\n]+:r%-%-") ~= nil, "with the entry that was set")
    end
    -- an attribute that cannot be copied stops the save instead of being dropped
    local real = fs.copy_xattrs
    fs.copy_xattrs = function() return { "security.selinux: EACCES" } end
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "SECOND EDIT" })
    res = save(S, { strategy = "atomic" })
    h.check(not res.ok and res.err:find("extended attributes", 1, true), "an attribute that cannot be copied refuses the save", vim.inspect(res))
    eq(leftovers(tmp), {}, "and leaves no temp file")
    res = save(S, { strategy = "atomic", force = true })
    fs.copy_xattrs = real
    h.check(res.ok, "! saves without it", vim.inspect(res))
    vim.cmd("bwipeout!")
  end,

  function()
    -- S3: a symlink stays a symlink and its target is replaced atomically
    local real = write("link-target.txt", numbered(20))
    local link = tmp .. "/link-name.txt"
    os.remove(link)
    assert(uv.fs_symlink(real, link))
    local ino = uv.fs_stat(real).ino
    S = open(link)
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "VIA THE LINK" })
    local res = save(S, { strategy = "atomic" })
    h.check(res.ok, "a file opened through a symlink is saved", vim.inspect(res))
    eq(uv.fs_lstat(link).type, "link", "the link is still a link")
    eq(uv.fs_readlink(link), real, "to the same target")
    h.check(read(real):sub(1, 13) == "VIA THE LINK\n", "and the target has the edit")
    h.check(uv.fs_stat(real).ino ~= ino, "written as a copy renamed over the target")
    eq(leftovers(tmp), {}, "with no temp file left beside either")
    vim.cmd("bwipeout!")
    os.remove(link)
  end,

  function()
    -- S3: a file with other hard links is patched in place so that they see the edit
    local first = write("hard-a.txt", numbered(20))
    local second = tmp .. "/hard-b.txt"
    os.remove(second)
    assert(uv.fs_link(first, second))
    S = open(first)
    local line_one = "line 1"
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { string.rep("X", #line_one) })
    local res = save(S, { links = "keep" })
    h.check(res.ok, "a same-length edit of a hard-linked file is saved", vim.inspect(res))
    eq(uv.fs_stat(first).nlink, 2, "both names are kept")
    eq(read(second):sub(1, 7), "XXXXXX\n", "and the other name has the edit")
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "a longer first line" })
    res = save(S, { links = "keep" })
    h.check(res.ok, "an edit that changes the length is patched in place too", vim.inspect(res))
    eq(uv.fs_stat(first).nlink, 2, "and both names are kept")
    eq(read(second):sub(1, 20), "a longer first line\n", "the other name has it")
    eq(read(second), read(first), "and they are the same text")
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "detached" })
    res = save(S, { links = "break" })
    h.check(res.ok and read(first):sub(1, 9) == "detached\n", "links = break detaches it and saves", vim.inspect(res))
    eq(uv.fs_stat(first).nlink, 1, "this name is a file of its own")
    eq(read(second):sub(1, 20), "a longer first line\n", "and the other name keeps the older text")
    vim.cmd("bwipeout!")
    os.remove(second)
  end,

  function()
    -- S4a: a patch in place goes through a journal, in slices, and can be cancelled
    local save_mod = require("streamview_save")
    local content = numbered(6000)
    local path = write("inplace.txt", content)
    local ino = uv.fs_stat(path).ino
    S = open(path)
    local function at(text) return content:find(text, 1, true) - 1 end
    local model = content
    local function replace(offset, text)
      S.r:apply({ { start = offset, stop = offset + #text, text = text } })
      model = model:sub(1, offset) .. text .. model:sub(offset + #text + 1)
    end
    replace(at("line 3\n"), "LINE 3\n")
    replace(at("line 2500\n"), "LINE 2500\n")
    replace(at("line 5999\n"), "LINE 5999\n")
    local journal = save_mod.journal_path(path)
    local seen = {}
    save_mod.hooks.journal_written = function() seen.journal = uv.fs_stat(journal) ~= nil and read(journal):sub(1, 20) end
    local restore = slow_slices()
    local res
    sv.write(S, { strategy = "inplace" }, function(ok, err) res = { ok = ok, err = err } end)
    h.check(res == nil and S.job and S.job.label:find("in place", 1, true), "an in-place save runs in slices", vim.inspect(S.job))
    eq(read(path), content, "and does not touch the file before the journal is complete")
    vim.wait(60000, function() return res ~= nil end, 5)
    restore()
    save_mod.hooks.journal_written = nil
    h.check(res and res.ok, "it finishes", vim.inspect(res))
    eq(read(path), model, "the file has the edits")
    eq(uv.fs_stat(path).ino, ino, "in the same file")
    eq(seen.journal, "STREAMVIEW-JOURNAL 1", "a journal was written first")
    eq(uv.fs_stat(journal), nil, "and is removed afterwards")
    eq(leftovers(tmp), {}, "no temp file")
    vim.cmd("bwipeout!")

    -- cancelling before the journal is complete leaves the file as it was
    path = write("inplace-cancel.txt", content)
    S = open(path)
    replace(at("line 3\n"), "LINE 3\n")
    restore = slow_slices()
    res = nil
    sv.write(S, { strategy = "inplace" }, function(ok, err) res = { ok = ok, err = err } end)
    sv.cancel(S)
    restore()
    eq(res and res.err, "cancelled", "a cancelled in-place save reports it")
    eq(read(path), content, "and the file is untouched")
    eq(uv.fs_stat(save_mod.journal_path(path)), nil, "and no journal is left")
    h.check(S.r.log_pos > 0, "and the edits are still held")
    vim.cmd("bwipeout!")

    -- cancelling once the journal is complete finishes the patch instead
    path = write("inplace-late.txt", content)
    S = open(path)
    model = content
    replace(at("line 3\n"), "LINE 3\n")
    replace(at("line 2500\n"), "LINE 2500\n")
    local committed = false
    save_mod.hooks.committed = function() committed = true end
    restore = slow_slices()
    res = nil
    sv.write(S, { strategy = "inplace" }, function(ok, err) res = { ok = ok, err = err } end)
    vim.wait(60000, function() return committed end, 5)
    h.check(res == nil, "the save is still running once the journal is complete")
    sv.cancel(S)
    restore()
    save_mod.hooks.committed = nil
    h.check(res and res.ok, "cancelling then finishes the save", vim.inspect(res))
    eq(read(path), model, "so the file has all the edits")
    eq(uv.fs_stat(save_mod.journal_path(path)), nil, "and the journal is gone")
    vim.cmd("bwipeout!")

    -- the journal's records are synced before its C line is written
    path = write("inplace-sync-order.txt", content)
    S = open(path)
    model = content
    replace(at("line 3\n"), "LINE 3\n")
    local journal, seen_sync = save_mod.journal_path(path), {}
    local real_fsync = uv.fs_fsync
    uv.fs_fsync = function(fd, ...)
      local jf = io.open(journal, "rb")
      if jf then
        local text = jf:read("*a")
        jf:close()
        if text:find("D %d+ %d+\n") then seen_sync[#seen_sync + 1] = text:find("\nC %d+ %d+\n$") ~= nil end
      end
      return real_fsync(fd, ...)
    end
    res = save(S, { strategy = "inplace" })
    uv.fs_fsync = real_fsync
    h.check(res.ok, "the save finishes", vim.inspect(res))
    eq(seen_sync[1], false, "the first sync after the records comes before the C line is written")
    eq(seen_sync[2], true, "and the C line is synced after it", vim.inspect(seen_sync))
    vim.cmd("bwipeout!")
  end,

  function()
    -- S4a: killed with SIGKILL at each step, the file is repaired to the bytes it should have
    local save_mod = require("streamview_save")
    local rows = {}
    for i = 1, 8000 do
      rows[i] = string.format("row %06d ..............\n", i)
    end
    local content = table.concat(rows)
    local edits = { { 100, "XXXXXXXX" }, { 50000, "YYYYYYYY" }, { 120000, "ZZZZZZZZ" }, { 190000, "WWWWWWWW" } }
    local model = content
    for _, e in ipairs(edits) do
      model = model:sub(1, e[1]) .. e[2] .. model:sub(e[1] + #e[2] + 1)
    end
    local function spawn(path, stop, after, edit_list, slow)
      local marker = path .. ".marker"
      os.remove(marker)
      local env = vim.tbl_extend("force", vim.fn.environ(), {
        SV_PATH = path,
        SV_MARKER = marker,
        SV_STOP = stop or "",
        SV_AFTER = tostring(after or 0),
        SV_EDITS = vim.json.encode(edit_list or edits),
        SV_SLOW = slow and "1" or "0",
      })
      local child = vim.system({ os.getenv("NVIM_BIN"), "--headless", "-n", "-c", "luafile " .. os.getenv("TEST_DIR") .. "/streamsave-child.lua" }, { env = env })
      return child, marker
    end
    local function kill(child, marker, what)
      local ok = vim.wait(120000, function() return uv.fs_stat(marker) ~= nil end, 20)
      child:kill(9)
      local waited = child:wait()
      h.check(ok and waited.signal == 9, what .. ": the child was killed in the middle of the save", vim.inspect(waited))
    end
    local function reopen_and_recover(path)
      save_mod.opts.recover = "finish"
      vim.cmd("StreamView! " .. vim.fn.fnameescape(path))
      vim.wait(10000, function() return uv.fs_stat(save_mod.journal_path(path)) == nil end, 20)
      vim.wait(100)
      vim.cmd("bwipeout!")
      save_mod.opts.recover = nil
    end

    -- before the journal is complete: the file was never touched
    local path = write("crash-early.bin", content)
    local child, marker = spawn(path, "journal_written")
    kill(child, marker, "before the commit")
    eq(read(path), content, "before the commit: the file is untouched")
    local state = save_mod.journal_state(path)
    h.check(state and not state.committed, "and the journal is not complete")
    reopen_and_recover(path)
    eq(read(path), content, "opening it again leaves the original")
    eq(save_mod.journal_state(path), nil, "and removes the unfinished journal")

    -- after the commit, before and in the middle of the patch, and before the journal is removed
    for _, point in ipairs({ { "committed", 0 }, { "applied", 8192 + 30 }, { "patched", 0 } }) do
      local name = point[1]
      path = write("crash-" .. name .. ".bin", content)
      child, marker = spawn(path, name, point[2])
      kill(child, marker, name)
      state = save_mod.journal_state(path)
      h.check(state and state.committed, name .. ": the journal is complete")
      if name == "committed" then eq(read(path), content, name .. ": and the file is not patched yet") end
      if name == "applied" then
        local now = read(path)
        h.check(now ~= content and now ~= model, name .. ": the file is half patched")
      end
      reopen_and_recover(path)
      eq(read(path), model, name .. ": opening it finishes the patch, byte for byte")
      eq(save_mod.journal_state(path), nil, name .. ": and removes the journal")
      eq(leftovers(tmp), {}, name .. ": with no temp file")
    end

    -- a journal that is left alone stops a save until it is finished
    path = write("crash-leave.bin", content)
    child, marker = spawn(path, "committed")
    kill(child, marker, "leave")
    save_mod.opts.recover = "leave"
    S = open(path)
    vim.wait(500)
    save_mod.opts.recover = nil
    h.check(save_mod.journal_state(path) ~= nil, "a journal that is left is still there")
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "A NEW EDIT" })
    local res = save(S, { strategy = "atomic" })
    h.check(not res.ok and res.err:find("interrupted", 1, true), "saving is refused while it is", vim.inspect(res))
    eq(read(path), content, "and the file is untouched")
    vim.cmd("bwipeout!")
    os.remove(save_mod.journal_path(path))

    -- :StreamRecover finishes a journal that was left: it is a redo log, so it never rolls back
    path = write("crash-recover.bin", content)
    child, marker = spawn(path, "committed")
    kill(child, marker, "recover")
    save_mod.opts.recover = "leave"
    S = open(path)
    vim.wait(500)
    save_mod.opts.recover = nil
    h.check(save_mod.journal_state(path) ~= nil, ":StreamRecover: the journal is still there")
    h.capture_notify()
    h.notes = {}
    vim.cmd("StreamRecover")
    eq(read(path), model, ":StreamRecover finishes the interrupted save, byte for byte")
    eq(save_mod.journal_state(path), nil, "and removes the journal")
    h.check(#h.notes_matching("finished the interrupted save") > 0, "and says so", vim.inspect(h.notes))
    eq(S.r.size, #model, "the window shows the finished file")
    h.notes = {}
    vim.cmd("StreamRecover")
    h.check(#h.notes_matching("no interrupted save") > 0, "with nothing left it says so", vim.inspect(h.notes))
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "A NEW EDIT" })
    res = save(S, { strategy = "atomic" })
    h.check(res.ok, "and a save works again", vim.inspect(res))
    vim.cmd("bwipeout!")
    -- a journal that was never completed is dropped, the file was never touched
    path = write("crash-recover2.bin", content)
    child, marker = spawn(path, "journal_written")
    kill(child, marker, "recover (early)")
    S = open(path)
    vim.wait(300)
    h.notes = {}
    vim.cmd("StreamRecover")
    eq(read(path), content, ":StreamRecover leaves the file as it was when the journal was not complete")
    eq(save_mod.journal_state(path), nil, "and the journal is gone")
    vim.cmd("bwipeout!")

    -- killed at random moments, the file is the old text or the new, never something between
    math.randomseed(11)
    local results = { old = 0, new = 0 }
    local many = {}
    local big_model = {}
    for i = 1, 8000 do
      big_model[i] = string.format("row %06d ..............\n", i)
    end
    local big = table.concat(big_model)
    local wide = big:rep(20) -- 4.6 MB, edited 300 times
    local wide_model = wide
    for k = 1, 300 do
      local offset = k * 13000 + 7
      many[k] = { offset, "EDIT" .. string.format("%04d", k) }
      wide_model = wide_model:sub(1, offset) .. many[k][2] .. wide_model:sub(offset + 9)
    end
    for round = 1, 10 do
      path = write("crash-random.bin", wide)
      child, marker = spawn(path, nil, nil, many, true)
      vim.wait(120000, function() return uv.fs_stat(marker) ~= nil end, 2)
      vim.wait(math.random(0, 1500))
      child:kill(9)
      child:wait()
      reopen_and_recover(path)
      local got = read(path)
      local whole = got == wide or got == wide_model
      h.check(whole, "random kill " .. round .. ": the file is whole after recovery")
      results[got == wide_model and "new" or "old"] = results[got == wide_model and "new" or "old"] + 1
      eq(leftovers(tmp), {}, "random kill " .. round .. ": with no temp file")
      eq(save_mod.journal_state(path), nil, "random kill " .. round .. ": and no journal")
    end
    io.stdout:write(string.format("      random kills ended old=%d new=%d\n", results.old, results.new))
  end,

  function()
    -- S4c: long data extents are copied inside the kernel, with the same bytes as a plain copy
    local save_mod = require("streamview_save")
    local real_copy, calls = fs.copy_range, 0
    fs.copy_range = function(...)
      calls = calls + 1
      return real_copy(...)
    end
    local block, kernel = save_mod.opts.copy_block, save_mod.opts.kernel_block
    save_mod.opts.copy_block, save_mod.opts.kernel_block = 64 * 1024, 256 * 1024
    local rnd = function(a, b) return math.random(a, b) end
    math.randomseed(5)
    local content = mixed_content(rnd, 3 * 1024 * 1024)
    local path = write("kernel.bin", content)
    vim.cmd("StreamView! " .. vim.fn.fnameescape(path))
    S = sv.state()
    local model = random_edits(S, rnd, content, "any", 6)
    local res = save(S, { strategy = "atomic" })
    save_mod.opts.copy_block, save_mod.opts.kernel_block = block, kernel
    fs.copy_range = real_copy
    h.check(res.ok and read(path) == model, "a save through copy_file_range gives the model's bytes", vim.inspect(res))
    h.check(calls > 0, "and used it", tostring(calls))
    vim.cmd("bwipeout!")
  end,

  function()
    -- the zero page finder, with and without the FFI
    local z = string.rep("\0", 4096)
    eq(fs.data_runs(""), {}, "an empty string has no data")
    eq(fs.data_runs(z .. z), {}, "zero pages have no data")
    eq(fs.data_runs("abc"), { 0, 3 }, "a short string is one run")
    eq(fs.data_runs(z .. "\0\0ab\0" .. z), { 4098, 4100 }, "zeros around data are trimmed")
    eq(fs.data_runs("a" .. z .. z .. "b"), { 0, 1, 8193, 8194 }, "zero pages split the runs")
    eq(fs.data_runs(z .. z .. "x"), { 8192, 8193 }, "a run at the end")
    h.check(fs.is_zero(z) and not fs.is_zero(z .. "x"), "is_zero tells zero from data")
  end,

  function()
    -- every kind of edit set gives the bytes of the string model, whichever way it is saved
    local real_clone = fs.clone
    fs.clone = fake_clone
    local counts = {}
    for _, kind in ipairs({ "same", "tail", "any" }) do
      for _, strategy in ipairs({ "atomic", "inplace", "reflink", "auto", "auto/noclone" }) do
        for seed = 1, 5 do
          local rnd = function(a, b) return math.random(a, b) end
          math.randomseed(seed * 31 + #kind + #strategy)
          local content = mixed_content(rnd, rnd(1, 3 * 1024 * 1024))
          local path = write("model-" .. kind .. ".bin", content)
          vim.cmd("StreamView! " .. vim.fn.fnameescape(path))
          S = sv.state()
          local model = random_edits(S, rnd, content, kind, rnd(1, 12))
          fs.clone = strategy == "auto/noclone" and function() return nil, "EOPNOTSUPP" end or fake_clone
          local res = save(S, { strategy = strategy:gsub("/.*", "") })
          local label = kind .. " edits #" .. seed .. " (" .. strategy .. ")"
          h.check(res.ok and read(path) == model, label .. " match the model", vim.inspect(res))
          local used = S.plan and S.plan.strategy or "?"
          counts[strategy .. "/" .. used] = (counts[strategy .. "/" .. used] or 0) + 1
          vim.cmd("bwipeout!")
          os.remove(path)
          if leftovers(tmp)[1] or uv.fs_stat(save_journal(path)) then
            h.check(false, label .. " left a temp file or a journal", vim.inspect(leftovers(tmp)))
          end
        end
      end
    end
    fs.clone = real_clone
    local names = vim.tbl_keys(counts)
    table.sort(names)
    for i, name in ipairs(names) do
      names[i] = name .. "=" .. counts[name]
    end
    io.stdout:write("      requested/used: " .. table.concat(names, " ") .. "\n")
  end,

  function()
    -- S4b: the plan: which way a save goes, why, and what it will write
    local real_clone = fs.clone
    fs.clone = function() return nil, "EOPNOTSUPP" end
    local function plan_of(content, edit, opts)
      local path = write("plan.bin", content)
      vim.cmd("StreamView! " .. vim.fn.fnameescape(path))
      S = sv.state()
      edit(S)
      local restore = slow_slices()
      local res
      sv.write(S, opts or {}, function(ok, err) res = { ok = ok, err = err } end)
      local running = S.job and S.job.label
      local bar = sv.winbar()
      vim.wait(60000, function() return res ~= nil end, 5)
      restore()
      local plan = S.plan
      local data = read(path)
      vim.cmd("bwipeout!")
      os.remove(path)
      return plan, res, running, bar, data
    end
    local text = numbered(20000) -- 200 KB
    local function change(offset, replacement, length)
      return function(Sv) Sv.r:apply({ { start = offset, stop = offset + (length or #replacement), text = replacement } }) end
    end

    local plan, res, running, bar = plan_of(text, change(100, "XXXXXX"))
    h.check(res.ok and plan.strategy == "inplace" and plan.kind == "ranges", "same-length edits are patched in place", vim.inspect(plan))
    h.check(plan.bytes == 6 and plan.why:find("kept its place", 1, true), "with the bytes and the reason", vim.inspect(plan))
    h.check(running and running:find("in place", 1, true) and running:find("6 B", 1, true), "the job says what it does", tostring(running))
    h.check(bar:find("writing in place", 1, true) and bar:find("kept its place", 1, true), "and the winbar shows the plan", bar)

    plan, res = plan_of(text, change(#text - 300, "tail text", 20))
    h.check(res.ok and plan.strategy == "inplace" and plan.kind == "tail", "an edit near the end rewrites only the end", vim.inspect(plan))
    h.check(plan.bytes < 2000, "of a few hundred bytes", vim.inspect(plan))

    plan, res = plan_of(text, change(100, "longer text", 5))
    h.check(res.ok and plan.strategy == "atomic" and plan.kind == "full", "an edit near the start copies the file", vim.inspect(plan))
    h.check(plan.why:find("most of the file", 1, true) ~= nil, "because most of it moves", vim.inspect(plan))

    plan, res = plan_of(text, change(100, "longer text", 5), { strategy = "atomic" })
    h.check(res.ok and plan.strategy == "atomic" and plan.why == "save_strategy = atomic", "strategy = atomic is obeyed", vim.inspect(plan))
    plan, res = plan_of(text, change(100, "XXXXXX"), { strategy = "atomic" })
    h.check(res.ok and plan.strategy == "atomic", "even for a same-length edit", vim.inspect(plan))
    plan, res = plan_of(text, change(100, "longer text", 5), { strategy = "inplace" })
    h.check(res.ok and plan.strategy == "inplace" and plan.kind == "tail", "strategy = inplace rewrites the end from the edit", vim.inspect(plan))
    sv.opts.save_strategy = "atomic"
    plan, res = plan_of(text, change(100, "XXXXXX"))
    sv.opts.save_strategy = "auto"
    h.check(res.ok and plan.strategy == "atomic", "opts.save_strategy sets the default", vim.inspect(plan))

    -- cutting the end off
    local data
    plan, res, _, _, data = plan_of(text, change(#text - 1000, "", 1000))
    h.check(res.ok and data == text:sub(1, #text - 1000), "a truncation is saved", vim.inspect(res))
    h.check(plan.strategy == "inplace" and plan.kind == "ranges", "in place, with nothing to move", vim.inspect(plan))

    fs.clone = real_clone
  end,

  function()
    -- S4b: a clone of the file takes only the changes (the clone is faked: this file system has none)
    local real_clone = fs.clone
    local content = numbered(20000)
    local path = write("clone.txt", content)
    local ino = uv.fs_stat(path).ino
    S = open(path)
    local clones = 0
    fs.clone = function(a, b)
      clones = clones + 1
      return fake_clone(a, b)
    end
    S.r:apply({ { start = 100, stop = 106, text = "XXXXXX" } })
    S.r:apply({ { start = #content - 300, stop = #content - 280, text = "end" } })
    local model = content:sub(1, 100) .. "XXXXXX" .. content:sub(107, #content - 300) .. "end" .. content:sub(#content - 279)
    local written = count_writes(function() return save(S) end)
    h.check(written.result.ok and read(path) == model, "a cloned save gives the right bytes", vim.inspect(written.result))
    eq(clones, 1, "the file was cloned once")
    eq(S.plan.strategy, "reflink", "and the plan says so")
    h.check(written.bytes < 1000, "and writes about the changes, not the file", tostring(written.bytes))
    h.check(uv.fs_stat(path).ino ~= ino, "a new inode replaced the file, atomically")
    eq(leftovers(tmp), {}, "no temp file")
    vim.cmd("bwipeout!")

    -- explicit, on a file system that cannot clone
    fs.clone = function() return nil, "EOPNOTSUPP" end
    S = open(path)
    S.r:apply({ { start = 0, stop = 4, text = "ABCD" } })
    local res = save(S, { strategy = "reflink" })
    h.check(not res.ok and res.err:find("cannot be cloned", 1, true), "strategy = reflink fails where there is no clone", vim.inspect(res))
    res = save(S)
    h.check(res.ok and read(path):sub(1, 4) == "ABCD", "while auto falls back", vim.inspect(res))
    eq(leftovers(tmp), {}, "and leaves no temp file")
    vim.cmd("bwipeout!")
    fs.clone = real_clone
  end,

  function()
    -- S4b: a same-length edit of a 512 MB sparse file writes about the changed bytes, and a copy of
    -- a sparse file writes only its data
    local size = 512 * 1024 * 1024
    local mid = math.floor(size * 0.6)
    local regions = { { 0, "head\n" }, { mid - 1, "\nmiddle line\n" }, { size - 6, "\nlast\n" } }
    local path = sparse_file("sparse-write.bin", size, regions)
    if allocated(path) > 1024 * 1024 then
      h.check(true, "skipped: this file system does not keep holes")
      return
    end
    local real_clone = fs.clone
    fs.clone = function() return nil, "EOPNOTSUPP" end
    S = open(path)
    sv.goto_offset(S, mid)
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "MIDDLE LINE" })
    local written = count_writes(function() return save(S) end)
    h.check(written.result.ok, "the sparse file is patched", vim.inspect(written.result))
    h.check(written.bytes < 3 * 8192, "with a few KB written, journal included", tostring(written.bytes))
    eq(S.plan.strategy, "inplace", "in place")
    h.check(allocated(path) < 1024 * 1024, "and it is still sparse", tostring(allocated(path)))
    vim.cmd("bwipeout!")

    S = open(path)
    sv.goto_offset(S, mid)
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "A LONGER MIDDLE LINE" })
    written = count_writes(function() return save(S, { strategy = "atomic" }) end)
    h.check(written.result.ok, "a length-changing edit is saved by a copy", vim.inspect(written.result))
    h.check(written.bytes < 3 * 8192, "which writes only the data, not 512 MB", tostring(written.bytes))
    h.check(allocated(path) < 1024 * 1024, "and is still sparse", tostring(allocated(path)))
    vim.cmd("bwipeout!")
    fs.clone = real_clone
    os.remove(path)
  end,
}

h.run(steps, 600000)

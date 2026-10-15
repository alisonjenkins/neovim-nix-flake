-- Edits made in the stream viewer's window are held as pieces and only reach the file on save. Checks
-- the logical text after edits in several windows, undo and redo across windows, search over edited
-- text, and the save: byte-exact results compared with a model built in Lua from the original text,
-- the failure paths that must leave the file untouched, and the in-place patch.
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

local function read_head(path, n)
  local f = assert(io.open(path, "rb"))
  local data = f:read(n)
  f:close()
  return data
end

-- The logical text, i.e. what a save would write
local function logical(S)
  return S.r:get(0, S.r.size)
end

local function set_lines(first, last, lines)
  vim.api.nvim_buf_set_lines(0, first, last, false, lines)
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

sv.opts.block = 256
sv.opts.editable = true

local count = 3000
local model = {}
for i = 1, count do model[i] = "line " .. i end
local function text_of(lines) return table.concat(lines, "\n") .. "\n" end
local original = text_of(model)
local numbered = write("edit-numbered.txt", original)

local function top_number(S) return tonumber(sv.lines(S)[1]:match("%d+")) end

local S

local steps = {
  function()
    uv.fs_chmod(numbered, 416) -- 0640
    S = open(numbered)
    h.check(vim.bo.buftype == "acwrite" and vim.bo.modifiable, "the viewer buffer is editable")
    h.check(not vim.bo.modified, "and not modified at first")

    -- start of the file
    set_lines(1, 2, { "LINE 2 EDITED" })
    model[2] = "LINE 2 EDITED"
    -- middle of the file: a replaced line and two inserted ones
    sv.goto_offset(S, "50%")
    h.check(vim.bo.modified, "an edit sets the modified flag")
    local top = top_number(S)
    set_lines(3, 3, { "inserted A", "inserted B" })
    table.insert(model, top + 3, "inserted A")
    table.insert(model, top + 4, "inserted B")
    set_lines(0, 1, { "FIRST OF THE WINDOW" })
    model[top] = "FIRST OF THE WINDOW"
    -- end of the file
    sv.tail(S)
    local rows = #sv.lines(S)
    set_lines(rows - 2, rows - 1, { "tail edit" })
    model[#model - 1] = "tail edit"
    set_lines(rows - 1, rows, {})
    table.remove(model)
    sv.head(S)
    eq(logical(S), text_of(model), "edits at the start, middle and end give the expected text")
    eq(original, read(numbered), "and the file on disk is untouched until a save")
    eq(sv.lines(S)[2], "LINE 2 EDITED", "the first window shows the edit")
  end,

  function()
    -- undo and redo across windows
    sv.goto_offset(S, "90%")
    sv.undo(S)
    h.check(sv.lines(S)[1] ~= nil and logical(S) ~= text_of(model), "undo takes back the last edit from another window")
    h.check(vim.bo.modified, "and the buffer is still modified")
    local before_redo = logical(S)
    sv.redo(S)
    eq(logical(S), text_of(model), "redo applies it again")
    h.check(before_redo ~= logical(S), "and redo changed the text")
    sv.undo(S)
    sv.undo(S)
    sv.undo(S)
    sv.undo(S)
    eq(logical(S), original, "undoing every edit gives the original text")
    h.check(not vim.bo.modified, "and the buffer is not modified")
    sv.redo(S)
    sv.redo(S)
    sv.redo(S)
    sv.redo(S)
    eq(logical(S), text_of(model), "redoing every edit gives the edited text again")

    -- undo of what is typed in the window comes before the earlier edits
    sv.head(S)
    local before = logical(S)
    set_lines(4, 5, { "typed, not committed" })
    sv.undo(S)
    eq(sv.lines(S)[5], model[5], "undo takes back the text typed in the window first")
    eq(logical(S), before, "without touching the earlier edits")
  end,

  function()
    -- search sees the edited text and not the removed text
    sv.head(S)
    set_lines(0, 1, { "line 1 and the NEEDLE_ADDED" })
    model[1] = "line 1 and the NEEDLE_ADDED"
    sv.goto_offset(S, "10%")
    local res
    sv.search(S, "NEEDLE_ADDED", false, function(pos, err) res = { pos = pos, err = err } end)
    vim.wait(10000, function() return res ~= nil end, 5)
    eq(res.pos, #"line 1 and the ", "backward search finds text that was typed in")
    sv.goto_offset(S, "10%")
    set_lines(0, 0, { "line 8 REMOVED_SOON" })
    sv.head(S)
    res = nil
    sv.search(S, "REMOVED_SOON", true, function(pos, err) res = { pos = pos, err = err } end)
    vim.wait(10000, function() return res ~= nil end, 5)
    h.check(res.pos ~= nil, "text typed in a later window is found")
    sv.undo(S)
    res = nil
    sv.head(S)
    sv.search(S, "REMOVED_SOON", true, function(pos, err) res = { pos = pos, err = err } end)
    vim.wait(10000, function() return res ~= nil end, 5)
    h.check(res.pos == nil and res.err == nil, "text taken out by an undo is no longer found")
    h.check(logical(S) == text_of(model), "and the text is back to the model")
  end,

  function()
    -- save: atomic, byte exact, mode kept
    local before = uv.fs_stat(numbered)
    local res = save(S)
    h.check(res.ok, "the save succeeds", tostring(res.err))
    eq(read(numbered), text_of(model), "the saved file is byte for byte the model")
    h.check(not vim.bo.modified, "the buffer is not modified after the save")
    eq(S.r.log_pos, 0, "the edit history ends with the save")
    h.check(sv.state().r.size == #text_of(model), "the viewer reads the new file")
    local after = uv.fs_stat(numbered)
    eq(bit.band(after.mode, 511), 416, "the file mode is kept")
    h.check(after.ino ~= before.ino, "the save replaced the file by rename")
    eq(leftovers(tmp), {}, "no temp file is left behind")
    eq(sv.lines(S)[1], "line 1 and the NEEDLE_ADDED", "the window shows the saved text")

    -- the write command and :write take the same path
    set_lines(1, 2, { "written by :write" })
    model[2] = "written by :write"
    sv.head(S)
    vim.cmd("write")
    vim.wait(10000, function() return not vim.bo.modified end, 5)
    eq(read(numbered), text_of(model), ":write saves through the viewer")
    set_lines(2, 3, { "written by :StreamWrite" })
    model[3] = "written by :StreamWrite"
    vim.cmd("StreamWrite")
    vim.wait(10000, function() return not vim.bo.modified end, 5)
    eq(read(numbered), text_of(model), ":StreamWrite saves too")
  end,

  function()
    -- a modified viewer cannot be left or quit without !
    set_lines(0, 1, { "unsaved" })
    local ok, err = pcall(vim.cmd, "enew")
    h.check(not ok and tostring(err):find("E37", 1, true), "leaving a modified viewer is refused", tostring(err))
    local ok_q, err_q = pcall(vim.cmd, "quit")
    h.check(not ok_q and tostring(err_q):find("E37", 1, true), ":quit with unsaved edits is refused", tostring(err_q))
    set_lines(0, 1, { "line 1 and the NEEDLE_ADDED" })
    vim.cmd("StreamView! " .. vim.fn.fnameescape(numbered))
  end,

  function()
    -- line endings, a missing final newline, invalid UTF-8 and cut lines
    S = open(write("edit-crlf.txt", "a\r\nb\r\nc"))
    set_lines(1, 2, { "B" })
    set_lines(2, 3, { "c", "d" })
    sv.head(S)
    eq(logical(S), "a\r\nB\r\nc\nd", "CRLF is kept and the missing final newline stays missing")
    local res = save(S)
    eq(read(tmp .. "/edit-crlf.txt"), "a\r\nB\r\nc\nd", "and so is the saved file")

    local bad = "ok\n\255\254 bad bytes\nend\n"
    S = open(write("edit-bad.txt", bad))
    eq(sv.lines(S)[2], "\255\254 bad bytes", "invalid UTF-8 is shown as the bytes it is")
    set_lines(2, 3, { "END" })
    sv.head(S)
    eq(logical(S), "ok\n\255\254 bad bytes\nEND\n", "an edit next to invalid bytes keeps them")
    set_lines(1, 2, { "\255\254 bad bytes, edited" })
    sv.head(S)
    eq(logical(S), "ok\n\255\254 bad bytes, edited\nEND\n", "editing a line with invalid bytes keeps them")
    save(S)
    eq(read(tmp .. "/edit-bad.txt"), "ok\n\255\254 bad bytes, edited\nEND\n", "invalid bytes are saved byte for byte")

    S = open(write("edit-empty.txt", ""))
    set_lines(0, 1, { "first", "second" })
    sv.head(S)
    eq(logical(S), "first\nsecond\n", "typing into an empty file")

    h.capture_notify()
    local long = string.rep("x", 70000) .. "\nshort\n"
    S = open(write("edit-long.txt", long))
    set_lines(0, 1, { "changed" })
    sv.scroll(S, 1)
    eq(logical(S), long, "an edit to a line shown cut is discarded")
    h.check(#h.notes_matching("cannot be edited") > 0, "with a message")
    S = open(write("edit-nul.txt", "ok\nhas\0nul\nend\n"))
    set_lines(1, 2, { "changed" })
    sv.head(S)
    eq(logical(S), "ok\nhas\0nul\nend\n", "an edit to a line with NUL bytes is discarded")
    set_lines(0, 1, { "OK" })
    sv.head(S)
    eq(logical(S), "OK\nhas\0nul\nend\n", "its neighbours can be edited")
    vim.cmd("StreamView! " .. vim.fn.fnameescape(numbered))
  end,

  function()
    -- failures leave the file untouched
    local dir = tmp .. "/ro"
    vim.fn.mkdir(dir, "p")
    local file = write("ro/data.txt", "one\ntwo\n")
    S = open(file)
    set_lines(0, 1, { "ONE" })
    sv.head(S)
    uv.fs_chmod(dir, 320) -- r-x
    local probe = io.open(dir .. "/probe", "w")
    local res
    if probe then
      probe:close()
      os.remove(dir .. "/probe")
      h.check(true, "directory permissions are not enforced here (running as root): unwritable-directory case skipped")
    else
      res = save(S)
      h.check(not res.ok, "a save into an unwritable directory fails", tostring(res.err))
      h.check(tostring(res.err):find("not touched", 1, true) ~= nil, "and says the file was not touched", tostring(res.err))
      eq(read(file), "one\ntwo\n", "the original is untouched after the failed save")
      eq(leftovers(dir), {}, "no temp file is left behind")
      h.check(vim.bo.modified, "and the edits are still held")
    end
    uv.fs_chmod(dir, 448)

    -- the file changed on disk since it was opened
    write("ro/data.txt", "one\ntwo\nthree, added elsewhere\n")
    res = save(S)
    h.check(not res.ok and tostring(res.err):find("changed on disk", 1, true) ~= nil, "a save over a file changed on disk is refused", tostring(res.err))
    eq(read(file), "one\ntwo\nthree, added elsewhere\n", "and the other change is still there")
    res = save(S, { force = true })
    h.check(res.ok, "a forced save goes through", tostring(res.err))
    eq(read(file), "ONE\ntwo\n", "and writes what the viewer holds")

    -- another path: no overwrite without force, the viewed file stays as it is
    set_lines(1, 2, { "TWO" })
    sv.head(S)
    local other = write("ro/other.txt", "existing\n")
    res = save(S, { path = other })
    h.check(not res.ok and tostring(res.err):find("exists", 1, true) ~= nil, "saving over another existing file is refused", tostring(res.err))
    eq(read(other), "existing\n", "and that file is untouched")
    res = save(S, { path = tmp .. "/ro/copy.txt" })
    h.check(res.ok, "saving to a new path works", tostring(res.err))
    eq(read(tmp .. "/ro/copy.txt"), "ONE\nTWO\n", "and writes the edited text")
    eq(read(file), "ONE\ntwo\n", "the viewed file is not touched")
    h.check(vim.bo.modified, "and the buffer stays modified")
  end,

  function()
    -- no room for a copy: patch in place only if every edit kept the length
    local real_free = sv.free_bytes
    sv.free_bytes = function() return 0 end
    local file = write("edit-patch.txt", "aaaa\nbbbb\ncccc\n")
    local before = uv.fs_stat(file)
    S = open(file)
    set_lines(1, 2, { "BBBB" })
    sv.head(S)
    local res = save(S, { inplace = true })
    h.check(res.ok, "an edit that kept the length is patched in place", tostring(res.err))
    eq(read(file), "aaaa\nBBBB\ncccc\n", "the patched file has the edit")
    eq(uv.fs_stat(file).ino, before.ino, "and it is the same file")
    h.check(not vim.bo.modified, "and the buffer is not modified")

    set_lines(0, 1, { "longer than before" })
    sv.head(S)
    res = save(S, { inplace = true })
    h.check(not res.ok and tostring(res.err):find("not enough room", 1, true) ~= nil, "an edit that changed the length is refused without room", tostring(res.err))
    eq(read(file), "aaaa\nBBBB\ncccc\n", "and the file is untouched")
    eq(leftovers(tmp), {}, "with no temp file")

    set_lines(0, 1, { "aaaa" })
    sv.head(S)
    res = save(S, { inplace = false })
    h.check(not res.ok and tostring(res.err):find("not enough room", 1, true) ~= nil, "inplace = false never patches", tostring(res.err))
    eq(read(file), "aaaa\nBBBB\ncccc\n", "and leaves the file untouched")
    sv.free_bytes = real_free
  end,

  function()
    -- cancel a save: no temp file, the original untouched
    local path = tmp .. "/edit-sparse.bin"
    local fd = assert(uv.fs_open(path, "w", 420))
    uv.fs_ftruncate(fd, 1024 * 1024 * 1024)
    uv.fs_write(fd, "first\nsecond\n", 0)
    uv.fs_close(fd)
    sv.opts.block = 64 * 1024
    S = open(path)
    sv.opts.block = 256
    set_lines(0, 1, { "FIRST" })
    sv.head(S)
    local res
    sv.write(S, nil, function(ok, err) res = { ok = ok, err = err } end)
    h.check(S.job ~= nil and S.job.label == "writing", "a running save is recorded on the viewer")
    sv.cancel(S)
    eq(res and res.err, "cancelled", "cancelling a save reports it")
    eq(leftovers(tmp), {}, "and removes the temp file")
    eq(read_head(path, 13), "first\nsecond\n", "and the original is untouched")
    h.check(vim.bo.modified, "and the edits are still held")
    os.remove(path)
  end,

  function()
    -- memory caps
    sv.opts.edit_warn, sv.opts.edit_max = 10, 100
    S = open(write("edit-cap.txt", "one\ntwo\nthree\n"))
    h.reset_windows()
    h.capture_notify()
    set_lines(0, 1, { "twenty bytes of text" })
    sv.head(S)
    h.check(#h.notes_matching("held in memory, save soon") == 1, "a warning is shown past the warn size")
    set_lines(1, 2, { string.rep("y", 200) })
    sv.head(S)
    eq(logical(S), "twenty bytes of text\ntwo\nthree\n", "an edit past the cap is discarded")
    h.check(#h.notes_matching("more than") > 0, "with a message")
    sv.opts.edit_warn, sv.opts.edit_max = 256 * 1024 * 1024, 1024 * 1024 * 1024
  end,

  function()
    -- a 512 MB sparse file: an edit at 60%, saved in place, memory stays flat
    local path = tmp .. "/edit-sparse-big.bin"
    local size = 512 * 1024 * 1024
    local at = math.floor(size * 0.6)
    local fd = assert(uv.fs_open(path, "w", 420))
    uv.fs_ftruncate(fd, size)
    uv.fs_write(fd, "head line\n", 0)
    uv.fs_write(fd, "\nmarker line at sixty percent\n", at)
    uv.fs_write(fd, "\nlast line\n", size - 11)
    uv.fs_close(fd)

    sv.opts.block = 256 * 1024
    collectgarbage("collect")
    local base = collectgarbage("count")
    S = open(path)
    sv.opts.block = 256
    local peak = 0
    local timer = uv.new_timer()
    timer:start(0, 5, function() peak = math.max(peak, collectgarbage("count")) end)

    local res
    sv.search(S, "marker line at sixty percent", true, function(pos, err) res = { pos = pos, err = err } end)
    vim.wait(60000, function() return res ~= nil end, 5)
    eq(res.pos, at + 1, "the marker is found")
    set_lines(0, 1, { "MARKER LINE AT SIXTY PERCENT" }) -- same length
    sv.tail(S)
    local l = sv.lines(S)
    eq(l[#l], "last line", "tail still works with an edit held")
    set_lines(#l - 1, #l, { "LAST LINE" })
    sv.goto_offset(S, "60%")
    eq(#S.r.pieces <= 7, true, "the edits cost a few pieces, not the file: " .. #S.r.pieces)
    eq(S.r:get(at + 1, 28), "MARKER LINE AT SIXTY PERCENT", "the edit is visible at its offset")
    eq(S.r.size, size, "and the size did not change")

    local real_free = sv.free_bytes
    sv.free_bytes = function() return 0 end
    res = save(S, { inplace = true })
    sv.free_bytes = real_free
    h.check(res.ok, "a same-length edit in a 512 MB file is patched in place", tostring(res.err))
    timer:stop()
    timer:close()
    local f = assert(io.open(path, "rb"))
    f:seek("set", at + 1)
    eq(f:read(28), "MARKER LINE AT SIXTY PERCENT", "the patch is in the file at the edit")
    f:seek("set", size - 11)
    eq(f:read(11), "\nLAST LINE\n", "and at the end")
    f:seek("set", 1000000)
    eq(f:read(8), "\0\0\0\0\0\0\0\0", "and nothing else was written")
    f:close()
    collectgarbage("collect")
    h.check(peak - base < 64 * 1024, "Lua memory peaked below 64 MB", string.format("%.0f KB", peak - base))
    os.remove(path)
  end,

  function()
    -- the piece table against a plain string model, with random edits, undo and redo
    sv.opts.block = 64
    math.randomseed(7)
    local orig = {}
    for i = 1, 1000 do orig[i] = string.char(97 + math.random(0, 25)) end
    local path = write("edit-model.bin", table.concat(orig))
    local r = assert(sv.open_reader(path))
    local models = { table.concat(orig) }
    local bad
    for step = 1, 2000 do
      local op = math.random(1, 10)
      if op <= 6 then
        local cur = models[r.log_pos + 1]
        local cuts = {}
        for i = 1, 4 do cuts[i] = math.random(0, #cur) end
        table.sort(cuts, function(a, b) return a > b end)
        local edits, m = {}, cur
        for i = 1, 2 do
          local stop, start = cuts[2 * i - 1], cuts[2 * i]
          local text = math.random(1, 4) == 1 and "" or string.rep("Z", math.random(0, 150))
          edits[i] = { start = start, stop = stop, text = text }
          m = m:sub(1, start) .. text .. m:sub(stop + 1)
        end
        r:apply(edits)
        for i = #models, r.log_pos + 2, -1 do models[i] = nil end
        models[r.log_pos + 1] = m
      elseif op <= 8 then
        r:undo()
      else
        r:redo()
      end
      if r:get(0, r.size) ~= models[r.log_pos + 1] then
        bad = step
        break
      end
    end
    h.check(bad == nil, "2000 random edits, undos and redos match a string model", tostring(bad))
    r:close()
  end,
}

h.run(steps, 240000)

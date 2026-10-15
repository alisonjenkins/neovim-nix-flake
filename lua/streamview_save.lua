-- Saving for the stream viewer: stream the pieces into a temp file and rename it over the original,
-- or patch the file where it is. Everything here is reached through streamview.write.
local uv = vim.uv
local M = {}

-- streamview requires this module, so it is looked up when needed
local function sv() return require("streamview") end

-- Free bytes on the file system of `dir`; replaced in tests (through streamview.free_bytes).
function M.free_bytes(dir)
  local st = uv.fs_statfs(dir)
  return st and st.bavail * st.bsize or nil
end

-- True when every edit replaced text by text of the same length, so the changes can be written over
-- the file where they are.
local function patchable(r)
  if r.size ~= r.file_size then return false end
  for i, piece in ipairs(r.pieces) do
    if not piece.str and piece.off ~= r.starts[i] then return false end
  end
  return true
end

function M.write_all(fd, data, pos)
  local done = 0
  while done < #data do
    local n, err = uv.fs_write(fd, done == 0 and data or data:sub(done + 1), pos + done)
    if not n then return nil, err end
    if n == 0 then return nil, string.format("wrote 0 of the %d bytes left at offset %d", #data - done, pos + done) end
    done = done + n
  end
  return true
end
local write_all = M.write_all

-- A private reader over the pieces as they are now. Pieces are never changed in place, so a shallow
-- copy of the list is a stable view of the text however the live reader is edited meanwhile.
local function snapshot(r)
  local pieces, starts = {}, {}
  for i, piece in ipairs(r.pieces) do
    pieces[i], starts[i] = piece, r.starts[i]
  end
  local snap = setmetatable({}, getmetatable(r))
  for k, v in pairs(r) do
    snap[k] = v
  end
  snap.pieces, snap.starts, snap.cache = pieces, starts, {}
  return snap
end

local function same_pieces(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do
    if a[i] ~= b[i] then return false end
  end
  return true
end

-- Re-opens the saved file as the viewer's file. The edit history ends with the save.
local function reopen(S)
  local r, err = sv().open_reader(S.path)
  if not r then return nil, err end
  S.r:close()
  S.r = r
  S.offset = r.size == 0 and 0 or r:line_start(math.min(S.offset, r.size - 1))
  S.match = nil
  sv().internal.draw(S)
  return true
end

local function patch_in_place(S, dest)
  local r = S.r
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
  local internal = sv().internal
  local human = internal.human
  opts = opts or {}
  -- plugins' write hooks may run the event loop, so the request expires by time, not by a callback
  local quit = S.quit_next ~= nil and uv.now() - S.quit_next < 2000
  S.quit_next = nil
  local function finish(ok, err)
    if done then done(ok, err) end
  end
  -- a viewer that was closed (the buffer was wiped, or read again with :edit) must not write
  if S.closed then return finish(false, "the viewer was closed") end
  if S.job then return finish(false, "busy: " .. S.job.label) end
  internal.before_move(S)
  local r = S.r
  local target = opts.path or S.path
  local dest = uv.fs_realpath(target) or vim.fn.fnamemodify(target, ":p")
  local same = dest == (uv.fs_realpath(S.path) or S.path)
  local existing = uv.fs_stat(dest)

  if same and not opts.force and r:changed_on_disk() then
    return finish(false, S.path .. " changed on disk since it was opened; use ! to overwrite it")
  end
  if not same and existing and not opts.force then
    return finish(false, dest .. " exists; use ! to overwrite it")
  end

  if same and r:pristine() and not r:changed_on_disk() then return finish(true) end

  if existing and not opts.force and not uv.fs_access(dest, "W") then
    return finish(false, dest .. " is read-only; use ! to overwrite it")
  end

  local dir = vim.fs.dirname(dest)
  local need = r.size
  local free = sv().free_bytes(dir)
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
    local ok, err = patch_in_place(S, dest)
    return finish(ok, err)
  end

  local src = (same and r.stat) or existing or r.stat
  local tmp = string.format("%s/.%s.streamview-%d.tmp", dir, vim.fs.basename(dest), uv.os_getpid())
  local fd, err = uv.fs_open(tmp, "wx", 384)
  if not fd then return finish(false, string.format("cannot create %s: %s (the file was not touched)", tmp, tostring(err))) end
  local function abandon(msg)
    uv.fs_close(fd)
    uv.fs_unlink(tmp)
    return finish(false, msg .. " (the file was not touched)")
  end
  local ok_mode, mode_err = uv.fs_fchmod(fd, bit.band(src.mode, 4095))
  if not ok_mode then return abandon(string.format("cannot set the mode of %s: %s", tmp, tostring(mode_err))) end
  local ok_own, own_err = uv.fs_fchown(fd, src.uid, src.gid)
  if not ok_own then
    if not opts.force then
      return abandon(string.format(
        "cannot keep the owner %d:%d of %s: %s; use ! to save it as yourself", src.uid, src.gid, dest, tostring(own_err)
      ))
    end
    vim.notify(string.format("Stream view: %s now belongs to you, not to %d:%d", dest, src.uid, src.gid), vim.log.levels.WARN)
  end

  local snap = snapshot(r)
  local chunk = snap.bs * 4
  internal.stop_follow(S)
  S.saving = true
  vim.bo[S.buf].modifiable = false
  local quit_win = quit and vim.api.nvim_get_current_win()
  local starting = true
  internal.run_job(S, "writing", snap.size, function(tick)
    local pos = 0
    while pos < snap.size do
      local want = math.min(chunk, snap.size - pos)
      local data = snap:get(pos, chunk)
      if #data ~= want then
        return nil, string.format("short read at offset %d: got %d of %d bytes (was the file truncated?)", pos, #data, want)
      end
      local ok, werr = write_all(fd, data, pos)
      if not ok then return nil, "write failed: " .. tostring(werr) end
      pos = pos + chunk
      tick(math.min(pos, snap.size))
    end
    if same and r:changed_on_disk() and not opts.force then return nil, S.path .. " changed on disk while it was being saved" end
    local written = uv.fs_fstat(fd)
    if not written or written.size ~= snap.size then
      return nil, string.format("the copy has %s bytes, expected %d", written and written.size or "?", snap.size)
    end
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
    S.saving = nil
    if vim.api.nvim_buf_is_valid(S.buf) then vim.bo[S.buf].modifiable = S.editable end
    if fd then uv.fs_close(fd) end
    if tmp then uv.fs_unlink(tmp) end
    if not ok then return finish(false, werr) end
    if same then
      if not same_pieces(r.pieces, snap.pieces) then
        return finish(false, "saved, but the text changed during the save; the newer changes are not saved yet (use :w! to save them)")
      end
      local reopened, oerr = reopen(S)
      if not reopened then return finish(false, "saved, but cannot reopen: " .. tostring(oerr)) end
    end
    finish(true)
    -- A save that ended before the write command returned leaves the buffer unmodified, and the
    -- command quits by itself
    if quit_win and not starting and vim.api.nvim_win_is_valid(quit_win) then
      vim.api.nvim_win_call(quit_win, function()
        local quit_ok, quit_err = pcall(vim.cmd, "quit")
        if not quit_ok then vim.notify("Stream view: saved, but cannot quit: " .. tostring(quit_err), vim.log.levels.WARN) end
      end)
    end
  end)
  starting = false
  if quit_win and S.saving then
    vim.notify("Stream view: the save is running; quitting when it has finished", vim.log.levels.INFO)
  end
end

-- :wq and friends write through BufWriteCmd and then quit only if the buffer is unmodified, which a
-- sliced save is not yet. The commands are recognised as they are typed, and the quit is done when
-- the save has succeeded.
local QUIT_COMMANDS = { wq = true, x = true, xi = true, xit = true, exi = true, exit = true }

local function want_quit(S)
  S.quit_next = uv.now()
end

function M.attach(S, group)
  vim.api.nvim_create_autocmd("CmdlineLeave", {
    group = group,
    callback = function(ev)
      if vim.v.event.abort or ev.match ~= ":" or vim.api.nvim_get_current_buf() ~= S.buf then return end
      local name = vim.fn.getcmdline():match("^%s*:*%s*(%a+)!?%s*$")
      if name and QUIT_COMMANDS[name] then want_quit(S) end
    end,
  })
  vim.keymap.set("n", "ZZ", function()
    want_quit(S)
    pcall(vim.cmd, "x")
  end, { buffer = S.buf, nowait = true, silent = true, desc = "Stream view: save and quit" })
end

return M

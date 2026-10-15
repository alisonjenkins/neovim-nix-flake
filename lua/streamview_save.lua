-- Saving for the stream viewer: stream the pieces into a temp file and rename it over the original,
-- or patch the file where it is, behind a journal that makes a crash recoverable. Everything here
-- is reached through streamview.write.
local uv = vim.uv
local fs = require("streamview_fs")
local M = {}

M.opts = {
  -- unit of copying, hole checks and yielding to the editor
  copy_block = 1024 * 1024,
  -- unit of a copy inside the kernel (copy_file_range); 8 MiB was the fastest of 1 to 1024 MiB
  kernel_block = 8 * 1024 * 1024,
  -- A length-changing edit rewrites the file from the edit to the end. Done in place (behind a
  -- journal) when that is at most this many bytes of data or this fraction of a full copy.
  tail_bytes = 64 * 1024 * 1024,
  tail_fraction = 0.05,
  -- what to do with the journal of an interrupted save when a file is opened: "finish", "leave",
  -- or nil to ask
  recover = nil,
}

-- Functions the tests can set to stop a save at a named point
M.hooks = {}

local function hook(name, ...)
  local fn = M.hooks[name]
  if fn then fn(...) end
end

-- streamview requires this module, so it is looked up when needed
local function sv() return require("streamview") end

-- Free bytes on the file system of `dir`; replaced in tests (through streamview.free_bytes).
function M.free_bytes(dir)
  local st = uv.fs_statfs(dir)
  return st and st.bavail * st.bsize or nil
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

local function sync_dir(dir)
  local dfd = uv.fs_open(dir, "r", 0)
  if dfd then
    uv.fs_fsync(dfd)
    uv.fs_close(dfd)
  end
end

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

---------------------------------------------------------------------------------------------------
-- What the edits changed
---------------------------------------------------------------------------------------------------

-- Edits closer together than this are written as one range
local COALESCE_GAP = 4096

-- What the edits did to the file, from the pieces of a snapshot. Pieces of the file that sit where
-- they were are unchanged; everything else has to be written:
--   ranges   { from, to } pairs, ascending: the edit text that kept its place, then, from the first
--            piece of the file that moved, everything to the end (the tail)
--   tail     where the tail starts, nil when no piece of the file moved
--   size, added (bytes of edit text), changed (bytes in the ranges before the tail)
--   unchanged  the text is the file
-- Edits closer together than COALESCE_GAP are one range.
local function analyse(snap)
  local pieces, starts = snap.pieces, snap.starts
  local info = { size = snap.size, added = 0, changed = 0, ranges = {} }
  local moved
  for i, piece in ipairs(pieces) do
    if piece.str then
      info.added = info.added + piece.len
    elseif not moved and piece.off ~= starts[i] then
      moved = i
    end
  end
  local limit = snap.size
  if moved then
    -- the text edited just before the first moved piece has to be written with it
    while moved > 1 and pieces[moved - 1].str do
      moved = moved - 1
    end
    info.tail = starts[moved]
    limit = info.tail
  end
  local ranges = info.ranges
  for i, piece in ipairs(pieces) do
    local start = starts[i]
    if start >= limit then break end
    if piece.str then
      local last = ranges[#ranges]
      if last and start - last[2] <= COALESCE_GAP then
        last[2] = start + piece.len
      else
        ranges[#ranges + 1] = { start, start + piece.len }
      end
    end
  end
  for _, range in ipairs(ranges) do
    info.changed = info.changed + range[2] - range[1]
  end
  if info.tail and info.tail < snap.size then ranges[#ranges + 1] = { info.tail, snap.size } end
  info.unchanged = #ranges == 0 and snap.size == snap.file_size
  return info
end

---------------------------------------------------------------------------------------------------
-- Walking the text: the pieces are copied to a sink, and the holes of the file are not read
---------------------------------------------------------------------------------------------------

-- Bytes of data (not holes) in [from, to) of an open file, or nil when the file system cannot tell
-- or the file has too many extents to count cheaply.
local function data_bytes(fd, from, to)
  local total, pos = 0, from
  for _ = 1, 4096 do
    if pos >= to then return total end
    local d, derr = fs.seek_data(fd, pos)
    if not d then return derr == "ENXIO" and total or nil end
    if d >= to then return total end
    local h = fs.seek_hole(fd, d)
    if not h then return nil end
    local stop = math.min(h, to)
    total = total + (stop - d)
    pos = stop
  end
  return nil
end

local function short_read(pos, got, want)
  return string.format("short read at offset %d: got %d of %d bytes (was the file truncated?)", pos, got, want)
end

-- Copies file bytes [soff, soff + n) to logical position dpos of the sink. Holes are reported to
-- sink.zero without being read, and so are blocks that are all zero; the rest goes to sink.data.
local function emit_file(fd, soff, dpos, n, sink, tick)
  local st = uv.fs_fstat(fd)
  if not st or st.size < soff + n then return short_read(soff, st and math.max(st.size - soff, 0) or 0, n) end
  local block = M.opts.copy_block
  local left = n
  while left > 0 do
    local d, derr = fs.seek_data(fd, soff)
    local stop
    local exact = d ~= nil -- the file system told where the data is, so zero pages inside it are rare
    if not d then
      if derr == "ENXIO" then
        -- only a hole follows, unless the file has been cut short since the check above
        local now = uv.fs_fstat(fd)
        if not now or now.size < soff + left then return short_read(soff, 0, left) end
        sink.zero(dpos, left)
        return nil
      elseif derr ~= "UNSUPPORTED" then
        return "cannot find the data of the file: " .. tostring(derr)
      end
      d, stop = soff, soff + left
    elseif d >= soff + left then
      sink.zero(dpos, left)
      return nil
    end
    if d > soff then
      sink.zero(dpos, d - soff)
      dpos, left, soff = dpos + (d - soff), left - (d - soff), d
    end
    if not stop then
      local h = fs.seek_hole(fd, soff)
      stop = math.min(h or math.huge, soff + left)
    end
    while soff < stop do
      if exact and sink.copy and stop - soff >= block then
        local len = math.min(M.opts.kernel_block, stop - soff)
        local copied = sink.copy(fd, soff, dpos, len)
        if copied == 0 then return short_read(soff, 0, len) end
        if copied then
          soff, dpos, left = soff + copied, dpos + copied, left - copied
          tick(dpos)
          goto continue
        end
        sink.copy = nil -- EXDEV, ENOSYS ...: read and write instead
      end
      do
      local len = math.min(block, stop - soff)
      local data = uv.fs_read(fd, len, soff)
      if not data or #data ~= len then return short_read(soff, data and #data or 0, len) end
      local runs = fs.data_runs(data)
      if #runs == 0 then
        sink.zero(dpos, len)
      elseif runs[1] == 0 and runs[2] == len then
        sink.data(dpos, data)
      else
        local at = 0
        for k = 1, #runs, 2 do
          if runs[k] > at then sink.zero(dpos + at, runs[k] - at) end
          sink.data(dpos + runs[k], data:sub(runs[k] + 1, runs[k + 1]))
          at = runs[k + 1]
        end
        if at < len then sink.zero(dpos + at, len - at) end
      end
      soff, dpos, left = soff + len, dpos + len, left - len
      tick(dpos)
      end
      ::continue::
    end
  end
end

-- Copies logical bytes [from, to) of the snapshot to the sink: sink.data(pos, text) and
-- sink.zero(pos, len), in ascending order. Returns nil, or an error message.
local function walk(snap, from, to, sink, tick)
  local block = M.opts.copy_block
  local pos = from
  local i = snap:locate(from)
  while pos < to do
    local piece, start = snap.pieces[i], snap.starts[i]
    if not piece then return short_read(pos, 0, to - pos) end
    local b = math.min(to, start + piece.len)
    if piece.str then
      while pos < b do
        local len = math.min(block, b - pos)
        local from_str = piece.off + (pos - start)
        sink.data(pos, piece.str:sub(from_str + 1, from_str + len))
        pos = pos + len
        tick(pos)
      end
    else
      local err = emit_file(snap.fd, piece.off + (pos - start), pos, b - pos, sink, tick)
      if err then return err end
      pos = b
    end
    i = i + 1
  end
end

-- Makes [pos, pos + len) of an open file read as zeros without changing its size.
local function zero_range(fd, pos, len)
  if fs.punch(fd, pos, len) then return true end
  local zeros = string.rep("\0", math.min(M.opts.copy_block, len))
  local done = 0
  while done < len do
    local n = math.min(#zeros, len - done)
    local ok, err = write_all(fd, n == #zeros and zeros or zeros:sub(1, n), pos + done)
    if not ok then return nil, err end
    done = done + n
  end
  return true
end

---------------------------------------------------------------------------------------------------
-- The journal: what an in-place patch is about to write, kept until the file has it
---------------------------------------------------------------------------------------------------

-- A patch in place is not atomic, so the new bytes are first written, whole, to a journal beside
-- the file and made durable. The journal is complete once its last line is there; the file is not
-- touched before that. From then on the patch is a replay of the journal, which can be repeated
-- as often as needed, so a crash at any point is repaired by running it again. A journal without
-- its last line is an unfinished plan and is thrown away.
--
-- Layout: a header block (text, with its own hash), then records, then the last line:
--   D <offset> <length>\n<bytes>\n     write the bytes at the offset
--   Z <offset> <length>\n              make the range read as zeros
--   C <records> <end of the records>\n
-- A journal of the original bytes (rollback) was considered. Both cost the same, but a rollback
-- journal has the file half changed while it is written, and needs the old bytes read first; this
-- one leaves the file whole until the journal is complete.

local HEADER = 8192
local MAGIC = "STREAMVIEW-JOURNAL 1"

function M.journal_path(dest)
  return string.format("%s/.%s.streamview-journal", vim.fs.dirname(dest), vim.fs.basename(dest))
end

local Journal = {}
Journal.__index = Journal

-- `st` is the stat of the file about to be patched, `new_size` the size it will have.
local function journal_create(dest, st, new_size)
  local path = M.journal_path(dest)
  local fd, err = uv.fs_open(path, "wx", 384)
  if not fd then return nil, err end
  local body = string.format("%s\ntarget=%s\ndev=%d\nino=%d\nold=%d\nnew=%d\n", MAGIC, dest, st.dev, st.ino, st.size, new_size)
  local head = body .. "sha=" .. vim.fn.sha256(body) .. "\n"
  local ok, werr = false, "the path is too long"
  if #head <= HEADER then ok, werr = write_all(fd, head .. string.rep(" ", HEADER - #head), 0) end
  if not ok then
    uv.fs_close(fd)
    uv.fs_unlink(path)
    return nil, werr
  end
  return setmetatable({ fd = fd, path = path, pos = HEADER, records = 0, dir = vim.fs.dirname(dest) }, Journal)
end

function Journal:append(text)
  local ok, err = write_all(self.fd, text, self.pos)
  if not ok then error("cannot write the journal " .. self.path .. ": " .. tostring(err), 0) end
  self.pos = self.pos + #text
  self.records = self.records + 1
end

function Journal:data(off, text) self:append("D " .. off .. " " .. #text .. "\n" .. text .. "\n") end

function Journal:zero(off, len) self:append("Z " .. off .. " " .. len .. "\n") end

-- Makes the journal complete and durable.
function Journal:commit()
  local line = string.format("C %d %d\n", self.records, self.pos)
  local ok, err = write_all(self.fd, line, self.pos)
  if not ok then error("cannot write the journal " .. self.path .. ": " .. tostring(err), 0) end
  local synced, serr = uv.fs_fsync(self.fd)
  if not synced then error("cannot sync the journal " .. self.path .. ": " .. tostring(serr), 0) end
  sync_dir(self.dir)
end

function Journal:close()
  if self.fd then uv.fs_close(self.fd) end
  self.fd = nil
end

-- Reads a journal: { path, valid, meta, committed, fd, end_pos }. Close fd when done.
local function journal_read(path)
  local fd, err = uv.fs_open(path, "r", 0)
  if not fd then return nil, err end
  local st = uv.fs_fstat(fd)
  local j = { path = path, fd = fd, valid = false, committed = false }
  local head = st and uv.fs_read(fd, HEADER, 0) or ""
  local body, sha = head:match("^(.-)sha=(%x+)\n")
  if body and vim.fn.sha256(body) == sha then
    local meta = {}
    for key, value in body:gmatch("\n(%a+)=([^\n]*)") do
      meta[key] = value
    end
    if body:sub(1, #MAGIC + 1) == MAGIC .. "\n" and meta.target and meta.dev and meta.ino and meta.new then
      j.valid = true
      j.meta = { target = meta.target, dev = tonumber(meta.dev), ino = tonumber(meta.ino), old = tonumber(meta.old), new = tonumber(meta.new) }
      local tail = uv.fs_read(fd, 64, math.max(st.size - 64, 0)) or ""
      local count, end_pos = tail:match("C (%d+) (%d+)\n$")
      if count and st.size == tonumber(end_pos) + #("C " .. count .. " " .. end_pos .. "\n") then
        j.committed, j.end_pos = true, tonumber(end_pos)
      end
    end
  end
  return j
end

-- Writes the records of a complete journal into the open file `fd` and gives it the final size.
local function journal_apply(j, fd, tick)
  local pos = HEADER
  while pos < j.end_pos do
    local head = uv.fs_read(j.fd, 80, pos) or ""
    local kind, off, len, body = head:match("^([DZ]) (%d+) (%d+)\n()")
    if not kind then return nil, string.format("damaged journal %s at offset %d", j.path, pos) end
    off, len = tonumber(off), tonumber(len)
    if kind == "D" then
      local data = uv.fs_read(j.fd, len + 1, pos + body - 1)
      if not data or #data ~= len + 1 or data:sub(-1) ~= "\n" then
        return nil, string.format("damaged journal %s at offset %d", j.path, pos)
      end
      local ok, err = write_all(fd, data:sub(1, len), off)
      if not ok then return nil, "cannot write the file: " .. tostring(err) end
      pos = pos + body - 1 + len + 1
    else
      local ok, err = zero_range(fd, off, len)
      if not ok then return nil, "cannot write the file: " .. tostring(err) end
      pos = pos + body - 1
    end
    hook("applied", pos)
    if tick then tick(pos - HEADER) end
  end
  local cut, cerr = uv.fs_ftruncate(fd, j.meta.new)
  if not cut then return nil, "cannot set the size of the file: " .. tostring(cerr) end
  local synced, serr = uv.fs_fsync(fd)
  if not synced then return nil, "cannot sync the file: " .. tostring(serr) end
  return true
end

-- What a journal beside `dest` says: nil when there is none, else { path, committed, valid }.
function M.journal_state(dest)
  local path = M.journal_path(dest)
  if not uv.fs_stat(path) then return nil end
  local j = journal_read(path)
  if not j then return { path = path, valid = false, committed = false } end
  uv.fs_close(j.fd)
  return { path = path, valid = j.valid, committed = j.committed, meta = j.meta }
end

-- Repairs an interrupted patch of `dest`: a journal that was not completed is removed (the file was
-- never touched), a complete one is replayed. Returns true and what was done, or nil and why not.
function M.recover(dest)
  local path = M.journal_path(dest)
  local j, err = journal_read(path)
  if not j then
    if uv.fs_stat(path) then return nil, "cannot read " .. path .. ": " .. tostring(err) end
    return true, "none"
  end
  local function done(ok, what)
    uv.fs_close(j.fd)
    return ok, what
  end
  if not j.committed then
    uv.fs_unlink(path)
    return done(true, "discarded")
  end
  if j.meta.target ~= dest then
    return done(nil, string.format("%s belongs to %s, not to %s", path, j.meta.target, dest))
  end
  local fd, oerr = uv.fs_open(dest, "r+", 0)
  if not fd then return done(nil, "cannot open " .. dest .. ": " .. tostring(oerr)) end
  local st = uv.fs_fstat(fd)
  if not st or st.dev ~= j.meta.dev or st.ino ~= j.meta.ino then
    uv.fs_close(fd)
    return done(nil, string.format("%s was made for another file than %s (replaced since?); remove it by hand", path, dest))
  end
  local ok, aerr = journal_apply(j, fd)
  uv.fs_close(fd)
  if not ok then return done(nil, aerr) end
  uv.fs_unlink(path)
  sync_dir(vim.fs.dirname(dest))
  return done(true, "finished")
end

---------------------------------------------------------------------------------------------------
-- Running a save
---------------------------------------------------------------------------------------------------

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

-- Runs a save as a job. ctx: snap, same, quit, label, span, finish, body(tick) -> true | nil, err,
-- and cleanup(ok, err) -> ok, err which releases what the body held.
local function launch(S, ctx)
  local internal = sv().internal
  local r, snap = S.r, ctx.snap
  internal.stop_follow(S)
  S.saving = true
  vim.bo[S.buf].modifiable = false
  local quit_win = ctx.quit and vim.api.nvim_get_current_win()
  local starting = true
  internal.run_job(S, ctx.label, ctx.span, ctx.body, function(ok, err)
    S.saving = nil
    if vim.api.nvim_buf_is_valid(S.buf) then vim.bo[S.buf].modifiable = S.editable end
    ok, err = ctx.cleanup(ok, err)
    if not ok then return ctx.finish(false, err) end
    if ctx.same then
      if not same_pieces(r.pieces, snap.pieces) then
        return ctx.finish(false, "saved, but the text changed during the save; the newer changes are not saved yet (use :w! to save them)")
      end
      local reopened, oerr = reopen(S)
      if not reopened then return ctx.finish(false, "saved, but cannot reopen: " .. tostring(oerr)) end
    end
    ctx.finish(true)
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

-- Patches the file where it is. o: snap, dest, ranges ({ from, to } logical ranges to write; the
-- file is cut or extended to the size of the snapshot), bytes, journal (false: write straight into
-- the file, which a crash can leave half done), label, same, force, quit, finish.
local function start_inplace(S, o)
  local r, snap = S.r, o.snap
  local fd, err = uv.fs_open(o.dest, "r+", 0)
  if not fd then return o.finish(false, string.format("cannot open %s: %s", o.dest, tostring(err))) end
  local st = uv.fs_fstat(fd)
  if o.same and (not st or st.dev ~= r.stat.dev or st.ino ~= r.stat.ino) then
    uv.fs_close(fd)
    return o.finish(false, o.dest .. " is no longer the file that was opened; use ! to overwrite it")
  end
  local j, applied
  local state = { committed = false }

  launch(S, {
    snap = snap,
    same = o.same,
    quit = o.quit,
    finish = o.finish,
    label = o.label,
    span = o.journal and 2 * o.bytes or o.bytes,
    body = function(tick)
      if not o.journal then
        local sink = {
          data = function(pos, text)
            local ok, werr = write_all(fd, text, pos)
            if not ok then error("write failed: " .. tostring(werr), 0) end
          end,
          zero = function() end,
        }
        for _, range in ipairs(o.ranges) do
          local werr = walk(snap, range[1], range[2], sink, tick)
          if werr then return nil, werr end
        end
        local cut, cerr = uv.fs_ftruncate(fd, snap.size)
        if not cut then return nil, "cannot set the size of the file: " .. tostring(cerr) end
        local synced, serr = uv.fs_fsync(fd)
        if not synced then return nil, "fsync failed: " .. tostring(serr) end
        return true
      end

      local created, jerr = journal_create(o.dest, st, snap.size)
      if not created then
        return nil, string.format("cannot create the journal %s: %s (the file was not touched)", M.journal_path(o.dest), tostring(jerr))
      end
      j = created
      local sink = {
        data = function(pos, text) j:data(pos, text) end,
        zero = function(pos, len) j:zero(pos, len) end,
      }
      local done_bytes = 0
      for _, range in ipairs(o.ranges) do
        local base = done_bytes
        local werr = walk(snap, range[1], range[2], sink, function(pos) tick(math.min(base + pos - range[1], o.bytes)) end)
        if werr then return nil, werr end
        done_bytes = done_bytes + range[2] - range[1]
      end
      hook("journal_written")
      if o.same and not o.force and r:changed_on_disk() then
        return nil, S.path .. " changed on disk while it was being saved"
      end
      j:commit()
      state.committed = true
      hook("committed")
      local reader, rerr = journal_read(j.path)
      if not reader then return nil, "cannot read back the journal: " .. tostring(rerr) end
      local ok, aerr = journal_apply(reader, fd, function(pos) tick(math.min(o.bytes + pos, 2 * o.bytes)) end)
      uv.fs_close(reader.fd)
      if not ok then return nil, aerr end
      applied = true
      hook("patched")
      uv.fs_unlink(j.path)
      sync_dir(vim.fs.dirname(o.dest))
      return true
    end,
    cleanup = function(ok, werr)
      uv.fs_close(fd)
      if j then j:close() end
      if ok then return true end
      if not j then return false, werr end
      if not state.committed then
        uv.fs_unlink(j.path)
        return false, werr
      end
      if applied then return false, werr end
      -- Past the point where the journal is complete the patch is finished, not abandoned
      if werr == "cancelled" then
        local recovered, rerr = M.recover(o.dest)
        if recovered then return true end
        werr = rerr
      end
      return false, string.format("%s (the journal %s is kept; it finishes the save when the file is opened or saved again)", tostring(werr), j.path)
    end,
  })
end

-- Creates the temp file for a copy with the mode, owner and extended attributes of the file it will
-- replace. Returns its descriptor and path, or nil and why not (nothing is left behind).
local function create_tmp(o)
  local dir = vim.fs.dirname(o.dest)
  local src = (o.same and o.snap.stat) or o.existing or o.snap.stat
  local tmp = string.format("%s/.%s.streamview-%d.tmp", dir, vim.fs.basename(o.dest), uv.os_getpid())
  local fd, err = uv.fs_open(tmp, "wx", 384)
  if not fd then return nil, string.format("cannot create %s: %s (the file was not touched)", tmp, tostring(err)) end
  local function abandon(msg)
    uv.fs_close(fd)
    uv.fs_unlink(tmp)
    return nil, msg .. " (the file was not touched)"
  end
  local ok_mode, mode_err = uv.fs_fchmod(fd, bit.band(src.mode, 4095))
  if not ok_mode then return abandon(string.format("cannot set the mode of %s: %s", tmp, tostring(mode_err))) end
  local ok_own, own_err = uv.fs_fchown(fd, src.uid, src.gid)
  if not ok_own then
    if not o.force then
      return abandon(string.format(
        "cannot keep the owner %d:%d of %s: %s; use ! to save it as yourself", src.uid, src.gid, o.dest, tostring(own_err)
      ))
    end
    vim.notify(string.format("Stream view: %s now belongs to you, not to %d:%d", o.dest, src.uid, src.gid), vim.log.levels.WARN)
  end
  -- ACLs, SELinux labels and user attributes live in extended attributes
  local sfd = o.existing and uv.fs_open(o.dest, "r", 0)
  if sfd then
    local lost = fs.copy_xattrs(sfd, fd)
    uv.fs_close(sfd)
    if #lost > 0 then
      local list = table.concat(lost, ", ")
      if not o.force then
        return abandon(string.format("cannot keep the extended attributes of %s (%s); use ! to save without them", o.dest, list))
      end
      vim.notify(string.format("Stream view: %s lost these extended attributes: %s", o.dest, list), vim.log.levels.WARN)
    end
  end
  return fd, tmp
end

-- Writes a copy beside the file and renames it over the file. o: snap, dest, existing, ranges (nil:
-- everything is written; else the copy starts as a reflink clone of the file and only these ranges
-- are written), label, bytes, same, force, quit, finish. Returns "unsupported" when the clone
-- cannot be made (nothing has been started then), nil otherwise.
local function start_copy(S, o)
  local r, snap = S.r, o.snap
  local dir = vim.fs.dirname(o.dest)
  local fd, tmp = create_tmp(o)
  if not fd then return o.finish(false, tmp) end
  if o.ranges then
    local sfd = uv.fs_open(o.dest, "r", 0)
    local cloned, cerr = false, "cannot open " .. o.dest
    if sfd then
      cloned, cerr = fs.clone(sfd, fd)
      uv.fs_close(sfd)
    end
    if not cloned then
      uv.fs_close(fd)
      uv.fs_unlink(tmp)
      return "unsupported", cerr
    end
  end

  launch(S, {
    snap = snap,
    same = o.same,
    quit = o.quit,
    finish = o.finish,
    label = o.label,
    span = o.bytes,
    body = function(tick)
      local sink = {
        data = function(pos, text)
          local ok, werr = write_all(fd, text, pos)
          if not ok then error("write failed: " .. tostring(werr), 0) end
        end,
        copy = function(src, soff, pos, len) return (fs.copy_range(src, soff, fd, pos, len)) end,
        -- a fresh copy has holes already; a clone has the old data there
        zero = function(pos, len)
          if not o.ranges then return end
          local ok, werr = zero_range(fd, pos, len)
          if not ok then error("write failed: " .. tostring(werr), 0) end
        end,
      }
      local done_bytes = 0
      for _, range in ipairs(o.ranges or { { 0, snap.size } }) do
        local base = done_bytes
        local werr = walk(snap, range[1], range[2], sink, function(pos) tick(math.min(base + pos - range[1], o.bytes)) end)
        if werr then return nil, werr end
        done_bytes = done_bytes + range[2] - range[1]
      end
      local grown, gerr = uv.fs_ftruncate(fd, snap.size)
      if not grown then return nil, "cannot set the size of the copy: " .. tostring(gerr) end
      if o.same and r:changed_on_disk() and not o.force then return nil, S.path .. " changed on disk while it was being saved" end
      local written = uv.fs_fstat(fd)
      if not written or written.size ~= snap.size then
        return nil, string.format("the copy has %s bytes, expected %d", written and written.size or "?", snap.size)
      end
      local synced, serr = uv.fs_fsync(fd)
      if not synced then return nil, "fsync failed: " .. tostring(serr) end
      uv.fs_close(fd)
      fd = nil
      local renamed, rerr = uv.fs_rename(tmp, o.dest)
      if not renamed then return nil, string.format("cannot rename %s over %s: %s", tmp, o.dest, tostring(rerr)) end
      tmp = nil
      sync_dir(dir)
      return true
    end,
    cleanup = function(ok, werr)
      if fd then uv.fs_close(fd) end
      if tmp then uv.fs_unlink(tmp) end
      return ok, werr
    end,
  })
end

-- Which way to save. The cheapest that is safe for the file wins: a clone of the file with only the
-- changes written (atomic, if the file system can clone), a patch in place when little is written
-- (journaled, not atomic), else a full copy.
--   e: strategy, same, existing, info (from analyse), need (bytes a full copy writes), tail (bytes
--   the end of the file takes when a piece moved), keep_links, inplace (the option).
-- Returns a plan { strategy, kind, why, bytes, ranges, fallback }.
local function choose(e)
  local info = e.info
  local bytes = info.changed + e.tail
  local function atomic(why)
    return { strategy = "atomic", kind = "full", why = why, bytes = e.need }
  end
  local function patch(strategy, why)
    return { strategy = strategy, kind = info.tail and "tail" or "ranges", why = why, bytes = bytes, ranges = info.ranges }
  end
  if not e.same or not e.existing or e.existing.type ~= "file" then return atomic("saving to another path") end
  if e.strategy == "atomic" then return atomic("save_strategy = atomic") end
  if e.strategy == "inplace" then return patch("inplace", "save_strategy = inplace") end
  if e.strategy == "reflink" then return patch("reflink", "save_strategy = reflink") end
  if e.keep_links then return patch("inplace", "the file has other hard links") end

  local why
  if not info.tail then
    why = string.format("every edit kept its place, %d range(s)", #info.ranges)
  else
    why = string.format("the edits move the last %.1f%% of the file", info.size > 0 and 100 * (info.size - info.tail) / info.size or 100)
  end
  local small = not info.tail or e.tail <= math.max(M.opts.tail_bytes, M.opts.tail_fraction * e.need)
  -- in place the bytes are written twice, to the journal and to the file
  local worth = e.inplace ~= false and small and bytes * 2 < e.need
  local plan = atomic(worth and why or "the edits move most of the file")
  if worth then
    plan = patch("inplace", why)
    plan.fallback = atomic(why)
  end
  local clone = patch("reflink", worth and why or "the edits move most of the file")
  clone.fallback = plan
  return clone
end


local function describe(plan, human)
  local what = ({ atomic = "atomic copy", inplace = "in place", reflink = "reflink copy" })[plan.strategy]
  return string.format("%s (%s, ~%s)", what, plan.why, human(plan.bytes))
end

-- opts: path (default the viewed file), force (overwrite a file changed on disk or an existing
-- other file), strategy ("auto", "atomic", "inplace" or "reflink"), inplace (true: patch in place
-- without a journal when there is no room for one, false: never patch in place, nil: ask), links
-- ("keep" or "break" for a file with other hard links, nil: ask). done(ok, err) runs when the
-- save has finished, failed or been cancelled.
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
  S.plan = nil
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

  local pending = M.journal_state(dest)
  if pending and pending.valid and pending.committed then
    -- finishing it changes the file under the edits held here, so it is left to a reopen
    return finish(false, string.format(
      "an earlier save of %s was interrupted; open the file again to finish it (journal %s)", dest, pending.path
    ))
  elseif pending then
    M.recover(dest) -- never completed, so the file was not touched
  end

  local snap = snapshot(r)
  local info = analyse(snap)
  if same and info.unchanged and not r:changed_on_disk() then return finish(true) end

  -- A copy renamed over the file leaves the other names of a hard-linked file with the old text
  local keep_links = false
  if existing and existing.nlink > 1 then
    local links = opts.links
    if links == nil and not same then links = "break" end
    if links == nil then
      local choice = vim.fn.confirm(
        string.format("%s has %d hard links. A copy would detach this name from the others.", dest, existing.nlink),
        "&Keep the links (patch in place, not atomic)\n&Detach (atomic copy)\n&Cancel",
        3
      )
      links = ({ "keep", "break" })[choice]
      if not links then return finish(false, "not saved: " .. dest .. " has hard links") end
    end
    keep_links = links == "keep"
    if keep_links and not same then
      return finish(false, string.format("%s has %d hard links; use links = \"break\" to replace it", dest, existing.nlink))
    end
  end

  local dir = vim.fs.dirname(dest)
  -- holes of the file stay holes in the copy, so only its data and the edits take room
  local need = r.size
  local allocated = r.fd and data_bytes(r.fd, 0, r.file_size)
  if allocated then need = math.min(need, allocated + r.added) end
  -- what moving the end of the file takes: its data, and the text edited in it
  local tail = 0
  if same and info.tail then
    local old_tail = r.fd and data_bytes(r.fd, math.min(info.tail, r.file_size), r.file_size)
    tail = (old_tail or math.max(r.file_size - info.tail, 0)) + math.max(info.added - info.changed, 0)
  end
  local free = sv().free_bytes(dir)

  local requested = opts.strategy or sv().opts.save_strategy or "auto"
  local env = {
    strategy = requested, same = same, existing = existing, info = info, need = need, tail = tail,
    keep_links = keep_links, inplace = opts.inplace,
  }
  local plan = choose(env)

  local function run(p)
    -- no room for a copy: the edits can still be written over the file
    if p.strategy == "atomic" and same and free and free < need then
      local refuse = string.format(
        "not enough room in %s for a copy: need %s, %s free (nothing was written)", dir, human(need), human(free)
      )
      if opts.inplace == false or requested == "atomic" then return finish(false, refuse) end
      if info.tail and tail * 1.01 + 2 * HEADER > free then return finish(false, refuse) end
      p = choose(vim.tbl_extend("force", env, { strategy = "inplace" }))
      p.why = "no room for a copy"
    end
    p.label = "writing " .. describe(p, human)
    S.plan = p
    if p.strategy == "inplace" then
      local journal = true
      local jneed = p.bytes * 1.01 + 2 * HEADER
      if free and free < jneed then
        -- without a journal a crash can leave the file half patched: only on request, and only
        -- when the edits are in ranges
        if info.tail then
          return finish(false, string.format(
            "not enough room in %s for the journal of the patch: need %s, %s free (nothing was written)", dir, human(jneed), human(free)
          ))
        end
        local yes = opts.inplace
        if yes == nil then
          yes = vim.fn.confirm(
            string.format("No room for a journal (%s free). Patch the file in place without it? A crash could leave it half written.", human(free)),
            "&Patch in place\n&Cancel",
            2
          ) == 1
        end
        if not yes then return finish(false, "not saved: no room for a journal beside " .. dest) end
        journal = false
      end
      return start_inplace(S, {
        snap = snap, dest = dest, ranges = p.ranges, bytes = p.bytes, journal = journal, label = p.label,
        same = same, force = opts.force, quit = quit, finish = finish,
      })
    end
    local started, why = start_copy(S, {
      snap = snap, dest = dest, existing = existing, ranges = p.strategy == "reflink" and p.ranges or nil,
      bytes = p.strategy == "reflink" and p.bytes or snap.size, label = p.label,
      same = same, force = opts.force, quit = quit, finish = finish,
    })
    if started == "unsupported" then
      if p.fallback and requested == "auto" then return run(p.fallback) end
      return finish(false, string.format("%s cannot be cloned: %s (save_strategy = reflink)", dest, tostring(why)))
    end
  end
  run(plan)
end

-- Looks for a journal of an interrupted patch of the viewed file and offers to finish it. how:
-- "finish", "leave" or nil to ask. Returns true when there is nothing left to do.
function M.check_journal(S, how)
  if S.saving then return false end -- the journal may be the one being written
  local dest = uv.fs_realpath(S.path) or S.path
  local state = M.journal_state(dest)
  if not state then return true end
  if state.valid and state.committed then
    how = how or (vim.fn.confirm(
      string.format("An earlier save of %s was interrupted. Finish it now?", dest),
      "&Finish\n&Leave",
      1
    ) == 1 and "finish" or "leave")
    if how ~= "finish" then return false end
  end
  local ok, what = M.recover(dest)
  if not ok then
    vim.notify("Stream view: " .. tostring(what), vim.log.levels.ERROR)
    return false
  end
  if what == "discarded" then
    vim.notify("Stream view: dropped an unfinished save journal of " .. dest .. "; the file was not touched", vim.log.levels.INFO)
  end
  if what == "finished" then
    vim.notify("Stream view: finished the interrupted save of " .. dest, vim.log.levels.WARN)
    local reopened, err = reopen(S)
    if not reopened then vim.notify("Stream view: cannot reopen " .. S.path .. ": " .. tostring(err), vim.log.levels.ERROR) end
  end
  return true
end

-- :StreamRecover. The journal is a redo log: once it is complete the save always goes forward and is
-- never rolled back, so this finishes the interrupted save without asking; a journal that was not
-- completed is dropped, the file was never touched. Returns true when nothing is left to do.
function M.recover_viewer(S)
  if S.saving or S.job then
    vim.notify("Stream view: a save or a scan is running; try again when it has finished", vim.log.levels.WARN)
    return false
  end
  local dest = uv.fs_realpath(S.path) or S.path
  if not M.journal_state(dest) then
    vim.notify("Stream view: no interrupted save of " .. dest, vim.log.levels.INFO)
    return true
  end
  return M.check_journal(S, "finish")
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
  vim.schedule(function()
    if not S.closed then M.check_journal(S, M.opts.recover) end
  end)
end

return M

-- System calls libuv does not expose, for the stream viewer's save: finding the data in a sparse
-- file, copying inside the kernel, cloning, punching holes and copying extended attributes. They
-- go through LuaJIT's FFI; where that is missing every function reports "unsupported" and the
-- caller does without.
local M = {}

local ok, ffi = pcall(require, "ffi")
local C
if ok then
  -- a second load declares the same names again, which fails harmlessly
  pcall(
    ffi.cdef,
    [[
    int64_t lseek(int fd, int64_t offset, int whence);
    int64_t copy_file_range(int fd_in, int64_t *off_in, int fd_out, int64_t *off_out, size_t len, unsigned int flags);
    int ioctl(int fd, unsigned long request, ...);
    int fallocate(int fd, int mode, int64_t offset, int64_t len);
    int64_t flistxattr(int fd, char *list, size_t size);
    int64_t fgetxattr(int fd, const char *name, void *value, size_t size);
    int fsetxattr(int fd, const char *name, const void *value, size_t size, int flags);
    int memcmp(const void *a, const void *b, size_t n);
  ]]
  )
  local usable = pcall(function() return ffi.C.lseek, ffi.C.copy_file_range, ffi.C.fallocate, ffi.C.fsetxattr end)
  C = usable and ffi.C or nil
end

M.available = C ~= nil

local ERRNO = {
  [1] = "EPERM",
  [2] = "ENOENT",
  [6] = "ENXIO",
  [9] = "EBADF",
  [18] = "EXDEV",
  [22] = "EINVAL",
  [28] = "ENOSPC",
  [38] = "ENOSYS",
  [61] = "ENODATA",
  [95] = "EOPNOTSUPP",
}

local function errname()
  local e = ffi.errno()
  return ERRNO[e] or ("errno " .. e)
end

M.errors = { unsupported = "UNSUPPORTED" }

local SEEK_DATA, SEEK_HOLE = 3, 4

-- Offset of the first byte of data at or after `off`; nil and "ENXIO" when only a hole (or the end
-- of the file) follows; nil and "UNSUPPORTED" when the file system cannot tell.
function M.seek_data(fd, off)
  if not C then return nil, "UNSUPPORTED" end
  local r = tonumber(C.lseek(fd, off, SEEK_DATA))
  if r < 0 then
    local name = errname()
    return nil, (name == "EINVAL" or name == "EOPNOTSUPP") and "UNSUPPORTED" or name
  end
  return r
end

-- Offset of the first hole at or after `off`; every file has a virtual hole at its end.
function M.seek_hole(fd, off)
  if not C then return nil, "UNSUPPORTED" end
  local r = tonumber(C.lseek(fd, off, SEEK_HOLE))
  if r < 0 then
    local name = errname()
    return nil, (name == "EINVAL" or name == "EOPNOTSUPP") and "UNSUPPORTED" or name
  end
  return r
end

-- Copies `len` bytes from src at soff to dst at doff inside the kernel. Returns the number of
-- bytes copied (0 at the end of the source), or nil and an error name (EXDEV, EINVAL, ENOSYS ...
-- mean "use read and write instead").
function M.copy_range(src, soff, dst, doff, len)
  if not C then return nil, "UNSUPPORTED" end
  local off_in, off_out = ffi.new("int64_t[1]", soff), ffi.new("int64_t[1]", doff)
  local n = tonumber(C.copy_file_range(src, off_in, dst, off_out, len, 0))
  if n < 0 then return nil, errname() end
  return n
end

local FICLONE = 0x40049409

-- Makes dst share the data blocks of src (a reflink copy). nil and an error name when the file
-- system cannot (EOPNOTSUPP, EXDEV, EINVAL ...).
function M.clone(src, dst)
  if not C then return nil, "UNSUPPORTED" end
  if C.ioctl(dst, FICLONE, ffi.cast("int", src)) < 0 then return nil, errname() end
  return true
end

-- Frees the blocks of [off, off + len) without changing the size of the file; reads as zeros after.
function M.punch(fd, off, len)
  if not C then return nil, "UNSUPPORTED" end
  if C.fallocate(fd, 3, off, len) < 0 then return nil, errname() end
  return true
end

function M.collapse(fd, off, len)
  if not C then return nil, "UNSUPPORTED" end
  if C.fallocate(fd, 0x08, off, len) < 0 then return nil, errname() end
  return true
end

function M.insert(fd, off, len)
  if not C then return nil, "UNSUPPORTED" end
  if C.fallocate(fd, 0x20, off, len) < 0 then return nil, errname() end
  return true
end

local zeros_cache = {}

-- True when every byte of `s` is NUL.
function M.is_zero(s)
  local n = #s
  if n == 0 then return true end
  if C then
    local z = zeros_cache[n]
    if not z then
      z = ffi.new("char[?]", n)
      if next(zeros_cache) then zeros_cache = {} end
      zeros_cache[n] = z
    end
    return C.memcmp(s, z, n) == 0
  end
  return not s:find("[^%z]")
end

local PAGE = 4096

-- The parts of `s` that are not whole zero pages, as a flat list { from1, to1, from2, to2 ... } of
-- 0-based [from, to) offsets in ascending order; empty when `s` is all zero.
function M.data_runs(s)
  local n = #s
  local runs = {}
  if n == 0 then return runs end
  local from
  if C then
    local zero = zeros_cache[PAGE] or ffi.new("char[?]", PAGE)
    zeros_cache[PAGE] = zero
    local p = ffi.cast("const char *", s)
    for off = 0, n - 1, PAGE do
      local len = math.min(PAGE, n - off)
      if C.memcmp(p + off, zero, len) ~= 0 then
        from = from or off
      elseif from then
        runs[#runs + 1], runs[#runs + 2] = from, off
        from = nil
      end
    end
  else
    for off = 0, n - 1, PAGE do
      local i = s:find("[^%z]", off + 1)
      if i and i <= off + PAGE then
        from = from or off
      elseif from then
        runs[#runs + 1], runs[#runs + 2] = from, off
        from = nil
      end
    end
  end
  if from then runs[#runs + 1], runs[#runs + 2] = from, n end
  -- a run is whole pages; the zeros at its ends need not be written either
  for k = 1, #runs, 2 do
    local a, b = runs[k], runs[k + 1]
    while a < b and s:byte(a + 1) == 0 do
      a = a + 1
    end
    while b > a and s:byte(b) == 0 do
      b = b - 1
    end
    runs[k], runs[k + 1] = a, b
  end
  return runs
end

local ATTR_IGNORED = { ["security.capability"] = true }

-- Copies every extended attribute of src to dst: ACLs, SELinux labels and user attributes.
-- Returns a list of "name: error" for those that could not be copied (a file system without
-- extended attributes is not an error).
function M.copy_xattrs(src, dst)
  local failed = {}
  if not C then return failed end
  local size = tonumber(C.flistxattr(src, nil, 0))
  if size < 0 then
    local name = errname()
    if name ~= "EOPNOTSUPP" then failed[1] = "listing: " .. name end
    return failed
  end
  if size == 0 then return failed end
  local list = ffi.new("char[?]", size)
  size = tonumber(C.flistxattr(src, list, size))
  if size < 0 then return { "listing: " .. errname() } end
  local names = ffi.string(list, size)
  for name in names:gmatch("([^%z]+)") do
    if not ATTR_IGNORED[name] then
      local vsize = tonumber(C.fgetxattr(src, name, nil, 0))
      if vsize < 0 then
        failed[#failed + 1] = name .. ": " .. errname()
      else
        local value = ffi.new("char[?]", math.max(vsize, 1))
        vsize = tonumber(C.fgetxattr(src, name, value, vsize))
        if vsize < 0 then
          failed[#failed + 1] = name .. ": " .. errname()
        elseif C.fsetxattr(dst, name, value, vsize, 0) < 0 then
          failed[#failed + 1] = name .. ": " .. errname()
        end
      end
    end
  end
  return failed
end

return M

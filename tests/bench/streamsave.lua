-- Benchmark of the ways the stream viewer can write a file back. Not a check: it writes gigabytes.
--
--   BENCH_DIR=/path SIZE_GIB=4 RUNS=3 ONLY=<substring> nvim -u NONE --headless -c 'luafile tests/bench/streamsave.lua'
--
-- BENCH_DIR holds the source (made on first use from /dev/urandom) and the copies; COPY_DIR (default
-- BENCH_DIR) is where the copies go, e.g. /tmp to leave the disk out. Each line is the median of RUNS
-- full rewrites of the source with a length-changing edit in the middle, so every byte after it
-- moves by 19.
local uv = vim.uv
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
package.path = root .. "/lua/?.lua;" .. package.path
local fs = require("streamview_fs")

local dir = os.getenv("BENCH_DIR") or (os.getenv("HOME") .. "/streamsave-bench")
local copy_dir = os.getenv("COPY_DIR") or dir
local size = math.floor(tonumber(os.getenv("SIZE_GIB") or "4") * 1024 * 1024 * 1024)
local runs = tonumber(os.getenv("RUNS") or "3")
local only = os.getenv("ONLY")
-- WARM=1 reads the source into the page cache first (CPU and syscall cost); otherwise it is evicted
-- before every run (what a file that has not been looked at costs)
local warm = os.getenv("WARM") == "1"
local MiB = 1024 * 1024
local EDIT = "MIDDLE LINE EDITED AND LONGER\n"
local REPLACED = 11

vim.fn.mkdir(dir, "p")
vim.fn.mkdir(copy_dir, "p")
local src_path = dir .. "/source.bin"
local dst_path = copy_dir .. "/copy.tmp"
if not uv.fs_stat(src_path) or uv.fs_stat(src_path).size ~= size then
  local r = vim.system({ "sh", "-c", string.format("head -c %d /dev/urandom > %s", size, vim.fn.shellescape(src_path)) }):wait()
  assert(r.code == 0, r.stderr)
end
local half = math.floor(size / 2)

local counts, bytes_written
local function wrap(tbl, name, key)
  local real = tbl[name]
  tbl[name] = function(...)
    counts[key] = (counts[key] or 0) + 1
    return real(...)
  end
  return function() tbl[name] = real end
end

local function evict(path)
  vim.system({ "dd", "if=" .. path, "iflag=nocache", "count=0", "status=none" }):wait()
end

local function write_all(fd, data, pos)
  local done = 0
  while done < #data do
    done = done + assert(uv.fs_write(fd, done == 0 and data or data:sub(done + 1), pos + done))
  end
end

local function copy_read(block, runs_of_data)
  return function(src, dst, soff, doff, n)
    while n > 0 do
      local len = math.min(block, n)
      local data = assert(uv.fs_read(src, len, soff))
      assert(#data == len)
      if runs_of_data then
        local r = fs.data_runs(data)
        if #r == 2 and r[1] == 0 and r[2] == len then
          write_all(dst, data, doff)
        else
          for k = 1, #r, 2 do
            write_all(dst, data:sub(r[k] + 1, r[k + 1]), doff + r[k])
          end
        end
      else
        write_all(dst, data, doff)
      end
      soff, doff, n = soff + len, doff + len, n - len
    end
  end
end

local function copy_kernel(block)
  return function(src, dst, soff, doff, n)
    while n > 0 do
      local c = assert(fs.copy_range(src, soff, dst, doff, math.min(block, n)))
      assert(c > 0)
      soff, doff, n = soff + c, doff + c, n - c
    end
  end
end

-- sendfile writes at the file position of dst, which the sequential walk keeps in step
local function copy_sendfile(block)
  return function(src, dst, soff, doff, n)
    while n > 0 do
      local c = assert(uv.fs_sendfile(dst, src, soff, math.min(block, n)))
      assert(c > 0)
      soff, doff, n = soff + c, doff + c, n - c
    end
  end
end

local function rewrite(copy, sync, sequential)
  return function(src, dst)
    copy(src, dst, 0, 0, half)
    assert(uv.fs_write(dst, EDIT, sequential and -1 or half) == #EDIT)
    copy(src, dst, half + REPLACED, half + #EDIT, size - half - REPLACED)
    sync(dst)
  end
end

local function sync_fsync(fd) assert(uv.fs_fsync(fd)) end
local function sync_fdatasync(fd) assert(uv.fs_fdatasync(fd)) end
local function sync_none() end

local rows = {}

local function run(name, fn, opts)
  opts = opts or {}
  local times, sync_times = {}, {}
  local last
  for _ = 1, runs do
    os.remove(dst_path)
    if warm then
      vim.system({ "cat", src_path }, { stdout = false }):wait()
    else
      evict(src_path)
    end
    counts = {}
    local undo = {
      wrap(uv, "fs_read", "read"),
      wrap(uv, "fs_write", "write"),
      wrap(uv, "fs_fsync", "fsync"),
      wrap(uv, "fs_fdatasync", "fdatasync"),
      wrap(uv, "fs_sendfile", "sendfile"),
      wrap(fs, "copy_range", "copy_file_range"),
    }
    local src = assert(uv.fs_open(src_path, "r", 0))
    local dst = assert(uv.fs_open(dst_path, "wx", 420))
    local t0 = uv.hrtime()
    fn(src, dst)
    local t1 = uv.hrtime()
    uv.fs_close(src)
    uv.fs_close(dst)
    for _, restore in ipairs(undo) do
      restore()
    end
    times[#times + 1] = (t1 - t0) / 1e9
    last = counts
    assert(uv.fs_stat(dst_path).size == (opts.out_size or size + #EDIT - REPLACED))
    os.remove(dst_path)
  end
  table.sort(times)
  local median = times[math.ceil(#times / 2)]
  local calls = {}
  for k, v in pairs(last) do
    calls[#calls + 1] = k .. "=" .. v
  end
  table.sort(calls)
  local line = string.format("| %-36s | %7.2f | %6.0f | %6.2f | %6.2f | %s |", name, median, size / MiB / median, times[1], times[#times], table.concat(calls, " "))
  rows[#rows + 1] = line
  print(line)
  io.stdout:flush()
end

local function maybe(name, fn, opts)
  if not only or name:find(only, 1, true) then run(name, fn, opts) end
end

print(string.format("source %s, %.1f GiB; copies in %s; %d runs", src_path, size / 1024 / MiB, copy_dir, runs))
print("| method | median s | MiB/s | min s | max s | calls in the last run |")
print("|---|---|---|---|---|---|")

for _, b in ipairs({ 256 * 1024, 1 * MiB, 4 * MiB, 8 * MiB }) do
  maybe(string.format("read+pwrite %dK, fsync", b / 1024), rewrite(copy_read(b, false), sync_fsync))
end
for _, b in ipairs({ 256 * 1024, 1 * MiB, 4 * MiB }) do
  maybe(string.format("read+pwrite+zero runs %dK, fsync", b / 1024), rewrite(copy_read(b, true), sync_fsync))
end
for _, b in ipairs({ 1 * MiB, 4 * MiB, 8 * MiB, 64 * MiB, 1024 * MiB }) do
  maybe(string.format("copy_file_range %dK, fsync", b / 1024), rewrite(copy_kernel(b), sync_fsync))
end
for _, b in ipairs({ 1 * MiB, 8 * MiB, 64 * MiB }) do
  maybe(string.format("sendfile %dK, fsync", b / 1024), rewrite(copy_sendfile(b), sync_fsync, true))
end
maybe("read+pwrite 1024K, fdatasync", rewrite(copy_read(MiB, false), sync_fdatasync))
maybe("read+pwrite 1024K, no sync", rewrite(copy_read(MiB, false), sync_none))
maybe("copy_file_range 8192K, fdatasync", rewrite(copy_kernel(8 * MiB), sync_fdatasync))
maybe("copy_file_range 8192K, no sync", rewrite(copy_kernel(8 * MiB), sync_none))
maybe("cp --sparse=always --reflink=auto (no edit)", function()
  local r = vim.system({ "cp", "--sparse=always", "--reflink=auto", src_path, dst_path }):wait()
  assert(r.code == 0, r.stderr)
  local fd = uv.fs_open(dst_path, "r+", 0)
  uv.fs_fsync(fd)
  uv.fs_close(fd)
end, { out_size = size })
maybe("cp (no edit)", function()
  local r = vim.system({ "cp", src_path, dst_path }):wait()
  assert(r.code == 0, r.stderr)
  local fd = uv.fs_open(dst_path, "r+", 0)
  uv.fs_fsync(fd)
  uv.fs_close(fd)
end, { out_size = size })

vim.cmd("qa!")

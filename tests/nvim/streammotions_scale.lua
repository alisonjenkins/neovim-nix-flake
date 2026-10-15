-- Scale probes (rows with chk = "scale"): the key a user would type on planted huge files, with a
-- time budget and a bound on the peak resident size of the Neovim that runs it.
-- STREAM_SCALE = "64" (default): 64 MB many-line file and 64 MB single line.
-- STREAM_SCALE = "big": 2 GB many-line file and 1 GB (sparse) single line; skipped with a message
-- when the file system lacks the room or sparse files. Results are keyed id (64 MB) and id@big.
-- STREAM_BUDGET_X multiplies every time budget (slow machines).
local h = dofile(os.getenv("TEST_DIR") .. "/harness.lua")
local L = dofile(os.getenv("TEST_DIR") .. "/streammotions_lib.lua")
local uv = vim.uv

local BIG = (rawget(_G, "STREAM_SCALE") or os.getenv("STREAM_SCALE") or "64") == "big"
local X = tonumber(os.getenv("STREAM_BUDGET_X") or "1")
local SUFFIX = BIG and "@big" or ""
local MB = 1024 * 1024

local function skip(ids, why)
  for _, id in ipairs(ids) do
    io.stdout:write(string.format("SKIP  %s%s -- %s\n", id, SUFFIX, why))
  end
end

---------------------------------------------------------------------------------------------------
-- Planted files
---------------------------------------------------------------------------------------------------

-- Many lines: line N holds N
local function many_file()
  local n = BIG and 226000000 or 8000000
  local path, why = L.seq_file(BIG and "scale-seq-2g.txt" or "scale-seq-64m.txt", n)
  if not path then return nil, why end
  return { path = path, n = n, size = L.seq_off(n + 1) }
end

-- One line. The 64 MB file is real text ("ab cd ef gh " repeated); the 1 GB file is sparse (NUL
-- bytes). Both hold the same planted bytes at offsets scaled to the size.
local function one_file()
  local size = BIG and 1024 * MB or 64 * MB
  local at = function(frac) return math.floor(size * frac) end
  local f = {
    size = size,
    q1 = at(0.60), q2 = at(0.90), -- the only Q bytes
    open = at(BIG and 0.005 or 0.015), close = at(BIG and 0.85 or 0.75), -- one ( ) pair
    lone = at(0.93), -- a ( that never closes
    marker = at(0.70), -- "MARKER42"
    k = at(0.45),
  }
  local path = L.dir .. (BIG and "/scale-line-1g.txt" or "/scale-line-64m.txt")
  f.path = path
  local st = uv.fs_stat(path)
  local patch = function(fd, off, data) assert(uv.fs_write(fd, data, off)) end
  if not (st and st.size == size) then
    local free = L.free_bytes(L.dir)
    if free and free < (BIG and 64 * MB or 2 * size) then return nil, "not enough disk for " .. path end
    local fd = assert(uv.fs_open(path, "w", 420))
    if BIG then
      assert(uv.fs_ftruncate(fd, size))
      local blocks = uv.fs_fstat(fd).blocks * 512
      patch(fd, f.q1, "Q")
      uv.fs_fsync(fd)
      if (uv.fs_fstat(fd).blocks * 512) > 64 * MB then
        uv.fs_close(fd)
        os.remove(path)
        return nil, "the file system does not keep sparse files (" .. blocks .. " bytes allocated for a hole)"
      end
    else
      local pat = string.rep("ab cd ef gh ", 87381) -- ~1 MiB, a multiple of 12
      local written = 0
      while written < size - 1 do
        local take = math.min(#pat, size - 1 - written)
        patch(fd, written, pat:sub(1, take))
        written = written + take
      end
    end
    patch(fd, size - 1, "\n")
    patch(fd, f.q1, "Q")
    patch(fd, f.q2, "Q")
    patch(fd, f.open, "(")
    patch(fd, f.close, ")")
    patch(fd, f.lone, "(")
    patch(fd, f.marker, "MARKER42")
    uv.fs_close(fd)
  end
  return f
end

---------------------------------------------------------------------------------------------------
-- Probes
---------------------------------------------------------------------------------------------------

local function pos_is(want) return function(r) return r.snap.pos == want, string.format("cursor byte %s, want %s", r.snap.pos, want) end end
local function pos_near(want, frac, size)
  return function(r)
    return math.abs(r.snap.pos - want) <= frac * size, string.format("cursor byte %s, want %s +-%.0f%%", r.snap.pos, want, frac * 100)
  end
end

local function reg_len(want)
  return function(r)
    local len = tonumber((r.snap.regs['"'] or ""):match("^%a:(%d+):"))
    return len == want, string.format("register holds %s bytes, want %s", tostring(len), want)
  end
end

-- id, keys (one string per key press), check(result, probe context), seconds {64 MB, big}
-- What was typed in the window is in the file's text once the window is drawn again
local SIZE_AFTER_RENDER = "local sv = require('streamview') local S = sv.state() sv.render(S) return S.r.size"

local function many_ops(f)
  local n = f.n
  local k = BIG and 150000000 or 5000000
  local t1 = BIG and 225999999 or 7999999
  local t2 = BIG and 100000123 or 1234567
  local B = math.floor(f.size * 0.37)
  local pages = {}
  for i = 1, 200 do
    pages[i] = "<C-f>"
  end
  local last_len = #tostring(n)
  return {
    { "scale.G", { "G" }, pos_is(L.seq_off(n)), { 1, 3 } },
    { "scale.gg", { "G", "gg" }, pos_is(0), { 1, 3 } },
    { "scale.NG", { k .. "G" }, pos_is(L.seq_off(k)), { 3, 30 } },
    { "scale.colon", { ":" .. k .. "<CR>" }, pos_is(L.seq_off(k)), { 3, 30 } },
    { "scale.dollar", { ":$<CR>" }, pos_is(L.seq_off(n)), { 1, 3 } },
    { "scale.pct", { "50%" }, pos_near(L.seq_off(math.floor(n / 2)), 0.01, f.size), { 1, 3 } },
    { "scale.go", { B .. "go" }, pos_is(B - 1), { 1, 3 } },
    { "scale.jN", { "100000j" }, pos_is(L.seq_off(100001)), { 5, 15 } },
    { "scale.kN", { "G", "100000k" }, pos_is(L.seq_off(n - 100000)), { 5, 15 } },
    { "scale.pages", pages, pos_is(L.seq_off(1 + 200 * 25)), { 5, 8 } },
    { "scale.search", { "/" .. t1 .. "<CR>" }, pos_is(L.seq_off(t1)), { 5, 60 } },
    { "scale.search_back", { "G", "?" .. t2 .. "<CR>" }, pos_is(L.seq_off(t2)), { 5, 60 } },
    { "scale.paragraph", { "}" }, pos_is(L.seq_off(n) + last_len - 1), { 5, 60 } },
    { "scale.paragraph_back", { "G", "{" }, pos_is(0), { 5, 60 } },
    { "scale.yank", { "y100000j" }, reg_len(L.seq_off(100002)), { 3, 10 }, { regs = { '"' } } },
    {
      "scale.edit", { k .. "G", "ihi<Esc>" },
      function(_, c) return c.exec(SIZE_AFTER_RENDER) == f.size + 2, "edit not applied" end,
      { 3, 10 },
    },
  }
end

local function one_ops(f)
  local K = math.floor(f.size * 0.45)
  local near_end = f.size - 2
  local ops = {
    { "scale1.dollar", { "$" }, pos_is(near_end), { 1, 3 } },
    { "scale1.zero", { "$", "0" }, pos_is(0), { 1, 3 } },
    { "scale1.bigl", { K .. "l" }, pos_is(K), { 2, 6 } },
    { "scale1.fq", { "fQ" }, pos_is(f.q1), { 3, 10 } },
    { "scale1.fq_repeat", { "fQ", ";" }, pos_is(f.q2), { 3, 10 } },
    { "scale1.Fq", { "$", "FQ" }, pos_is(f.q2), { 3, 10 } },
    { "scale1.pct", { f.open .. "l", "%" }, pos_is(f.close), { 5, 60 } },
    { "scale1.pct_back", { f.open .. "l", "%", "%" }, pos_is(f.open), { 10, 120 } },
    { "scale1.unmatched", { f.lone .. "l", "%" }, pos_is(f.lone), { 5, 60 } },
    { "scale1.search", { "/MARKER42<CR>" }, pos_is(f.marker), { 3, 30 } },
    { "scale1.search_back", { "$", "?MARKER42<CR>" }, pos_is(f.marker), { 3, 30 } },
    { "scale1.go", { K .. "go" }, pos_is(K - 1), { 1, 3 } },
    { "scale1.gg_G", { K .. "l", "G" }, pos_is(K), { 1, 3 } }, -- the only line: G stays in its column
    {
      "scale1.xdel", { K .. "l", "x" },
      function(_, c) return c.exec(SIZE_AFTER_RENDER) == f.size - 1, "x did not delete one byte" end,
      { 2, 6 },
    },
  }
  if not BIG then
    local W = 1000000
    ops[#ops + 1] = { "scale1.w", { W .. "w" }, pos_is(3 * W), { 3, 3 } }
    ops[#ops + 1] = { "scale1.e", { W .. "e" }, pos_is(1 + 3 * (W - 1)), { 3, 3 } }
    ops[#ops + 1] = { "scale1.yank", { (f.size - 8 * MB) .. "l", "y$" }, reg_len(8 * MB - 1), { 3, 3 }, { regs = { '"' } } }
  end
  return ops
end

local function run_op(op, f)
  local id, keys, check, secs, spec = op[1] .. SUFFIX, op[2], op[3], op[4], op[5]
  local budget = secs[BIG and 2 or 1] * X
  local rss_mb = BIG and 900 or 500
  local c = L.spawn("viewer")
  local t0 = uv.hrtime()
  local r, err = c:call("run", { f.path, {}, {}, 0, keys, spec or {} }, math.floor((budget * 4 + 60) * 1000))
  local total = (uv.hrtime() - t0) / 1e9
  local ok, detail = false, nil
  if not r then
    detail = "no result: " .. tostring(err)
  elseif r.err then
    detail = r.err
  else
    local good, why = check(r, { exec = function(code) return c:exec(code) end })
    local secs_used = r.ms / 1000
    local hwm = (r.hwm_kb or 0) / 1024
    io.stdout:write(string.format("perf  %-24s %7.2f s (budget %5.1f)  peak RSS %5.0f MB (bound %d)\n", id, secs_used, budget, hwm, rss_mb))
    if not good then
      detail = why
    elseif secs_used > budget then
      detail = string.format("took %.2f s, budget %.1f s", secs_used, budget)
    elseif hwm > rss_mb then
      detail = string.format("peak RSS %.0f MB, bound %d MB", hwm, rss_mb)
    else
      ok = true
    end
  end
  c:stop()
  L.record(h, id, ok, detail, { total = 1, failed = ok and 0 or 1, secs = total })
end

local function cancel_probe(f)
  local id = "scale.cancel" .. SUFFIX
  local c = L.spawn("viewer")
  assert(c:call("open", { f.path, {}, { block = 4096 } }))
  c:call("start_keys", { "/ZZZZ<CR>" })
  vim.wait(500)
  local st = c:call("status", {})
  if not st.job then
    c:stop()
    return L.record(h, id, false, "the scan of the whole file was over in 500 ms: nothing to cancel")
  end
  local t0 = uv.hrtime()
  c:call("input", { "<C-c>" })
  vim.wait(5000, function()
    st = c:call("status", {})
    return st.job == nil
  end, 20)
  local ms = (uv.hrtime() - t0) / 1e6
  local hwm = (c:call("hwm_kb", {}) or 0) / 1024
  c:stop()
  L.record(h, id, st.job == nil and st.pos == 0 and ms < 1500 * X and hwm < 900,
    string.format("job=%s pos=%s after %.0f ms, peak RSS %.0f MB", tostring(st.job), st.pos, ms, hwm))
end

---------------------------------------------------------------------------------------------------

local t0 = uv.hrtime()
local rows = dofile(os.getenv("TEST_DIR") .. "/streammotions_rows.lua")
local want = {}
for _, row in ipairs(rows) do
  if row.chk == "scale" and L.selected(row.id) then want[row.id] = row end
end

local function skipped_by_status(id)
  local st = L.status[id .. SUFFIX]
  return st and st[1] == "skip"
end

-- The build directory may be a tmpfs: the 2 GB file then lives in memory
local function mem_available_mb()
  local f = io.open("/proc/meminfo", "r")
  if not f then return nil end
  local kb = f:read("*a"):match("MemAvailable:%s*(%d+)")
  f:close()
  return kb and tonumber(kb) / 1024
end

local f1, why1
if BIG and (mem_available_mb() or 0) < 6144 and os.getenv("STREAM_HUGE") ~= "1" then
  why1 = "less than 6 GB of memory available (set STREAM_HUGE=1 to run anyway)"
else
  f1, why1 = many_file()
end
if not f1 then
  skip(vim.tbl_keys(want), why1)
else
  for _, op in ipairs(many_ops(f1)) do
    if want[op[1]] and not skipped_by_status(op[1]) then run_op(op, f1) end
  end
  if BIG and want["scale.cancel"] then cancel_probe(f1) end
end

local f2, why2 = one_file()
if not f2 then
  local ids = {}
  for id in pairs(want) do
    if id:find("^scale1") then ids[#ids + 1] = id end
  end
  skip(ids, why2)
else
  for _, op in ipairs(one_ops(f2)) do
    if want[op[1]] and not skipped_by_status(op[1]) then run_op(op, f2) end
  end
  
end

L.stop()
io.stdout:write(string.format("class scale%s: %.1f s\n", SUFFIX, (uv.hrtime() - t0) / 1e9))
L.write_report("scale" .. (BIG and "_big" or ""))
h.finish()

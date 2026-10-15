-- Driver of the streammotions tests. It starts two child Neovims (see streammotions_child.lua),
-- a stock one as the oracle and one running the stream viewer, feeds both the same keys at the same
-- absolute byte offset of the same file, and compares cursor offset, mode, registers and text.
--
-- Environment: STREAM_SEED (default 1), STREAM_CASES (percent of random cases, default 100),
-- STREAM_MB (size of the generated files, default 2.5), STREAM_ONLY (only ids with this prefix),
-- STREAM_STRICT=1 (an XPASS fails the check), STREAM_LUA_DIR (use another lua/ for the viewer),
-- STREAM_REPORT (directory that gets a JSON report per check).
local uv = vim.uv
local files = dofile(os.getenv("TEST_DIR") .. "/streammotions_files.lua")
local status = dofile(os.getenv("TEST_DIR") .. "/streammotions_status.lua")

local L = { files = files, status = status }

L.seed = tonumber(os.getenv("STREAM_SEED") or "1")
L.cases_pct = tonumber(os.getenv("STREAM_CASES") or "100")
L.strict = os.getenv("STREAM_STRICT") == "1"
L.only = os.getenv("STREAM_ONLY") and vim.split(os.getenv("STREAM_ONLY"), ",", { plain = true }) or nil

-- A check may set L.only to a list of id prefixes to take a part of its class
function L.selected(id)
  if not L.only then return true end
  for _, p in ipairs(L.only) do
    if id:sub(1, #p) == p then return true end
  end
  return false
end
L.bytes = math.floor(tonumber(os.getenv("STREAM_MB") or "2.5") * 1024 * 1024)
L.log = os.getenv("STREAM_LOG") and io.open(os.getenv("STREAM_LOG"), "w") or nil
L.dir = (os.getenv("TMPDIR") or "/tmp") .. "/streammotions"
vim.fn.mkdir(L.dir, "p")

-- Viewer settings that make every motion cross block, line-cap and segment edges
L.cfgs = {
  { block = 4096, line_cap = 4096, segment = 16384 },
  { block = 16384, line_cap = 16384, segment = 65536 },
  { block = 65536, line_cap = 8192, segment = 32768 },
}

---------------------------------------------------------------------------------------------------
-- Children
---------------------------------------------------------------------------------------------------

local Child = {}
Child.__index = Child

function Child:start()
  local argv = { os.getenv("NVIM_BIN"), "-u", "NONE", "--noplugin", "--headless", "--embed", "-i", "NONE" }
  for _, a in ipairs(self.argv or {}) do
    argv[#argv + 1] = a
  end
  self.ch = vim.fn.jobstart(argv, { rpc = true })
  assert(self.ch > 0, "cannot start " .. self.role)
  vim.rpcrequest(self.ch, "nvim_exec_lua", "dofile(...)", { os.getenv("TEST_DIR") .. "/streammotions_child.lua" })
  if not self.raw then
    vim.rpcrequest(self.ch, "nvim_exec_lua", "return SM.init(...)", {
      self.role,
      { lines = 30, columns = 100, lua_dir = os.getenv("STREAM_LUA_DIR") or "" },
    })
  end
end

-- A new child. A raw child gets no SM.init (for startup tests); argv are extra command line arguments.
function L.spawn(role, o)
  o = o or {}
  local c = setmetatable({ role = role, argv = o.argv, raw = o.raw }, Child)
  L.spawned = L.spawned or {}
  L.spawned[#L.spawned + 1] = c
  c:start()
  return c
end

-- Waits for a child that is quitting; returns its exit code, or nil on timeout
function Child:exit_code(timeout_ms)
  local code = vim.fn.jobwait({ self.ch }, timeout_ms or 10000)[1]
  if code == -1 then return nil end
  self.ch = nil
  return code
end

function Child:exec(code, args, timeout_ms) return self:call("exec", { code, args or {} }, timeout_ms) end

function Child:stop()
  if self.ch then pcall(vim.fn.jobstop, self.ch) end
  self.ch = nil
end

function Child:send(name, args)
  self.n = (self.n or 0) + 1
  local reply = string.format("%s/reply-%s-%d", L.dir, self.role, self.n)
  vim.rpcnotify(self.ch, "nvim_exec_lua", "local n, a, r = ... SM.serve(n, a, r)", { name, args, reply })
  return reply
end

-- Returns the decoded result, or nil and an error; a child that does not answer is restarted.
function Child:wait(reply, timeout_ms)
  local done = vim.wait(timeout_ms or 60000, function() return uv.fs_stat(reply) ~= nil end, 2)
  if not done then
    self:stop()
    self:start()
    return nil, "TIMEOUT after " .. (timeout_ms or 60000) .. " ms"
  end
  local f = assert(io.open(reply, "rb"))
  local body = f:read("*a")
  f:close()
  os.remove(reply)
  local msg = vim.json.decode(body, { luanil = { object = true, array = true } })
  if not msg.ok then return nil, msg.err end
  return msg.res
end

function Child:call(name, args, timeout_ms) return self:wait(self:send(name, args), timeout_ms) end

function L.start()
  L.oracle = setmetatable({ role = "oracle" }, Child)
  L.viewer = setmetatable({ role = "viewer" }, Child)
  L.oracle:start()
  L.viewer:start()
end

function L.stop()
  if L.oracle then L.oracle:stop() end
  if L.viewer then L.viewer:stop() end
  for _, c in ipairs(L.spawned or {}) do c:stop() end
end

---------------------------------------------------------------------------------------------------
-- One case: the same keys in both
---------------------------------------------------------------------------------------------------

-- Returns oracle result, viewer result
local function run_both(path, fo, cfg, at, keys, spec, timeout)
  local ro = L.oracle:send("run", { path, fo, cfg, at, keys, spec })
  local rv = L.viewer:send("run", { path, fo, cfg, at, keys, spec })
  local a, aerr = L.oracle:wait(ro, timeout)
  local b, berr = L.viewer:wait(rv, timeout)
  return a or { err = "oracle: " .. tostring(aerr) }, b or { err = tostring(berr) }
end

local function same_table(a, b)
  for k, v in pairs(a or {}) do
    if b == nil or b[k] ~= v then return false, k end
  end
  for k in pairs(b or {}) do
    if a == nil or a[k] == nil then return false, k end
  end
  return true
end

-- Returns a description of the first difference, or nil
local function differ(a, b, row)
  if a.err then return "ORACLE ERROR " .. a.err end
  if b.err then return "viewer: " .. b.err end
  local x, y = a.snap, b.snap
  if row.tol and math.abs(x.pos - y.pos) <= row.tol * (a.size or 1) then
    y.pos = x.pos
  end
  if x.pos ~= y.pos then return string.format("cursor byte %d, viewer %d", x.pos, y.pos) end
  if x.mode ~= y.mode then return string.format("mode %s, viewer %s", x.mode, y.mode) end
  if x.anchor ~= y.anchor then return string.format("visual anchor %s, viewer %s", tostring(x.anchor), tostring(y.anchor)) end
  for _, name in ipairs({ "regs", "marks" }) do
    local same, k = same_table(x[name], y[name])
    if not same then
      return string.format("%s %s: %s, viewer %s", name, k, vim.inspect(x[name] and x[name][k]), vim.inspect(y[name] and y[name][k]))
    end
  end
  if x.sha ~= y.sha then return string.format("text %d bytes, viewer %d bytes (or different bytes)", x.len or -1, y.len or -1) end
  local limit = row.case_ms or 5000
  if b.ms > limit then return string.format("slow: %.0f ms (limit %d)", b.ms, limit) end
end

---------------------------------------------------------------------------------------------------
-- Rows
---------------------------------------------------------------------------------------------------

local function pick(R, list) return list[R(#list)] end

local function make_cases(row, R, fkind, finfo)
  local cases = {}
  local starts = finfo.starts
  local function start_for(i)
    local policy = row.at or "mix"
    if policy == "origin" then return 0 end
    local s = starts[(i % #starts) + 1]
    if policy == "line" then return s.line end
    if policy == "inside" then return s.inside end
    -- mix: origin, a line start, an offset inside a line
    local m = i % 3
    if m == 0 then return 0 end
    if m == 1 then return fkind == "one" and s.inside or s.line end
    return s.inside
  end
  local n = 0
  local function add(toks)
    -- Neovim itself needs tens of seconds to change the case of a multi-MB line
    if fkind == "one" and (table.concat(toks):find("[~U]") or table.concat(toks):find("g[u~]")) then return end
    n = n + 1
    local cfg = L.cfgs[(n % #L.cfgs) + 1]
    local at = start_for(n)
    if row.at == "edge" then
      -- just before or after a block or segment edge, where a slice has to be joined
      local unit = (n % 2 == 0) and cfg.block or cfg.segment
      local k = 1 + R(math.max(1, math.floor(finfo.size / unit) - 2))
      at = math.min(k * unit + (R(7) - 4), finfo.size - 1)
    end
    for i, t in ipairs(toks) do
      toks[i] = t:gsub("{W}", function() return files.pick_word(R) end)
    end
    cases[#cases + 1] = { toks = toks, at = at, cfg = cfg, n = n }
  end
  for _, keys in ipairs(row.cases or {}) do
    add({ keys })
  end
  if row.rand then
    local count = math.max(1, math.floor(row.rand.n * L.cases_pct / 100 * (fkind == "one" and 0.5 or 1)))
    local lo, hi = row.rand.len and row.rand.len[1] or 1, row.rand.len and row.rand.len[2] or 3
    for _ = 1, count do
      local toks = {}
      if row.rand.pre then toks[#toks + 1] = pick(R, row.rand.pre) end
      local len = lo + (hi > lo and R(hi - lo + 1) - 1 or 0)
      for _ = 1, len do
        toks[#toks + 1] = pick(R, row.rand.pool)
      end
      if row.rand.post then toks[#toks + 1] = pick(R, row.rand.post) end
      if row.rand.glue then
        toks = { table.concat(toks) }
      end
      add(toks)
    end
  end
  return cases
end

local function shrink(row, path, fo, case, spec)
  local toks = vim.deepcopy(case.toks)
  local i = #toks
  local runs = 0
  while i >= 1 and #toks > 1 and runs < 40 do
    local try = vim.deepcopy(toks)
    table.remove(try, i)
    runs = runs + 1
    local a, b = run_both(path, fo, case.cfg, case.at, try, spec, 30000)
    if differ(a, b, row) and not a.err then toks = try end
    i = i - 1
  end
  return toks
end

local infos = {}
local function info_of(name)
  if not infos[name] then
    local path = files.get(L.dir, name, L.bytes)
    local starts, size = files.starts(path, files.rng(99), 24)
    infos[name] = { path = path, starts = starts, size = size, kind = files.kinds[name], bin = files.binary[name] }
  end
  return infos[name]
end

-- Runs one row over its files. Returns results keyed by test id: { total, failed, repro, ms }.
function L.run_row(row)
  local results = {}
  local specs = row.spec or {}
  local spec = {
    regs = specs.regs,
    marks = specs.marks,
    text = specs.text,
  }
  for _, kind in ipairs({ "many", "one" }) do
    local names = row[kind]
    local id = kind == "one" and row.id .. "@1" or row.id
    if names and not (status[id] and status[id][1] == "skip") then
      local res = { id = id, total = 0, failed = 0, ms = 0, t0 = vim.uv.hrtime() }
      results[id] = res
      for fi, name in ipairs(names) do
        local R = files.rng(L.seed * 1000 + fi * 17 + #row.id)
        local finfo = info_of(name)
        local fo = { bin = finfo.bin }
        for _, case in ipairs(make_cases(row, R, kind, finfo)) do
          res.total = res.total + 1
          local keys = table.concat(case.toks)
          if L.log then
            L.log:write(string.format("%s %s at=%d %q\n", id, name, case.at, keys))
            L.log:flush()
          end
          local a, b = run_both(finfo.path, fo, case.cfg, case.at, case.toks, spec, row.timeout_ms or 20000)
          res.ms = math.max(res.ms, b.ms or 0)
          local why = differ(a, b, row)
          if a.err and a.err:find("TIMEOUT", 1, true) then
            res.total, res.skipped, why = res.total - 1, (res.skipped or 0) + 1, nil
            io.stdout:write(string.format("note  %s: oracle too slow for %q on %s, case dropped\n", id, keys, name))
          end
          if why and a.err then error(id .. ": oracle failed on " .. keys .. ": " .. a.err) end
          if why then
            res.failed = res.failed + 1
            if not res.repro then
              local toks = (#case.toks > 1 and not why:find("cannot place", 1, true)) and shrink(row, finfo.path, fo, case, spec) or case.toks
              res.repro = string.format("file=%s at=%d cfg=%d/%d/%d seed=%d keys=%s: %s", name, case.at,
                case.cfg.block, case.cfg.line_cap, case.cfg.segment, L.seed, vim.inspect(table.concat(toks)), why)
              if #toks ~= #case.toks then
                local a2, b2 = run_both(finfo.path, fo, case.cfg, case.at, toks, spec, 30000)
                res.repro = string.format("file=%s at=%d cfg=%d/%d/%d seed=%d keys=%s: %s", name, case.at,
                  case.cfg.block, case.cfg.line_cap, case.cfg.segment, L.seed, vim.inspect(table.concat(toks)), differ(a2, b2, row) or why)
              end
            end
          end
        end
      end
      res.secs = (vim.uv.hrtime() - res.t0) / 1e9
    end
  end
  return results
end

---------------------------------------------------------------------------------------------------
-- Status handling and reporting
---------------------------------------------------------------------------------------------------

L.report = {}

-- Records one test id's outcome. ok is true/false; detail is the minimal repro.
function L.record(h, id, ok, detail, counts)
  local st = status[id] or { "pass" }
  local kind, owner, reason = st[1], st[2], st[3]
  L.report[id] = { ok = ok, status = kind, owner = owner, detail = detail, counts = counts }
  local tag = counts and string.format(" (%d/%d, %.1fs)", counts.total - counts.failed, counts.total, counts.secs or 0) or ""
  if kind == "skip" then
    io.stdout:write(string.format("SKIP  %s -- %s\n", id, reason or ""))
  elseif ok and kind == "xfail" then
    io.stdout:write(string.format("XPASS %s%s -- was xfail (%s); flip it to pass in streammotions_status.lua\n", id, tag, reason or ""))
    if L.strict then h.check(false, id .. " xpass (STREAM_STRICT=1)") end
  elseif ok then
    h.check(true, id .. tag)
  elseif kind == "xfail" then
    io.stdout:write(string.format("XFAIL %s%s [%s] -- %s\n      %s\n", id, tag, owner or "?", reason or "", detail or ""))
  else
    h.check(false, id .. tag, detail)
  end
end

function L.write_report(class)
  local dir = os.getenv("STREAM_REPORT")
  if not dir or dir == "" then return end
  vim.fn.mkdir(dir, "p")
  local f = assert(io.open(dir .. "/" .. class .. (L.only and ("-" .. L.only[1]:gsub("%W", "")) or "") .. ".json", "wb"))
  f:write(vim.json.encode(L.report))
  f:close()
end

-- Runs the hand-written probes of the rows with chk = `class`. A probe is function(L) returning
-- true, or false and a description of what was wrong.
function L.run_probes(h, class, probes)
  local rows = dofile(os.getenv("TEST_DIR") .. "/streammotions_rows.lua")
  local t0 = uv.hrtime()
  for _, row in ipairs(rows) do
    if row.chk == class and L.selected(row.id) then
      local st = status[row.id]
      if st and st[1] == "skip" then
        L.record(h, row.id, true)
      else
        local fn = assert(probes[row.id], "no probe for " .. row.id)
        local p0 = uv.hrtime()
        local ok, res, detail = pcall(fn, L)
        if not ok then res, detail = false, "probe error: " .. tostring(res) end
        L.record(h, row.id, res == true, detail, {
          total = 1, failed = res == true and 0 or 1, secs = (uv.hrtime() - p0) / 1e9,
        })
      end
    end
  end
  L.stop()
  io.stdout:write(string.format("class %s: %.1f s\n", class, (uv.hrtime() - t0) / 1e9))
  L.write_report(class)
end

-- Byte offset of line n (1-based) of the file made by `seq 1 N`
function L.seq_off(n)
  local off, d, lo = 0, 1, 1
  while true do
    local hi = 10 ^ d - 1
    if n <= hi then return off + (n - lo) * (d + 1) end
    off = off + (hi - lo + 1) * (d + 1)
    d, lo = d + 1, hi + 1
  end
end

function L.free_bytes(dir)
  local st = uv.fs_statfs(dir)
  return st and st.bavail * st.bsize or nil
end

-- Writes `seq 1 n` to a file (line N holds N). Returns its path, or nil and why when the disk is too small.
function L.seq_file(name, n)
  local path = L.dir .. "/" .. name
  local size = L.seq_off(n + 1)
  local st = uv.fs_stat(path)
  if st and st.size == size then return path end
  local free = L.free_bytes(L.dir)
  if free and free < size * 1.2 + 512 * 1024 * 1024 then
    return nil, string.format("only %d MB free in %s, need %d MB", free / 1048576, L.dir, size * 1.2 / 1048576)
  end
  local res = vim.system({ "sh", "-c", string.format("seq 1 %d > '%s'", n, path) }):wait()
  assert(res.code == 0, "seq failed: " .. tostring(res.stderr))
  return path
end

function L.write_file(name, data)
  local path = L.dir .. "/" .. name
  local f = assert(io.open(path, "wb"))
  f:write(data)
  f:close()
  return path
end

function L.read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

-- Runs every row of `class` (rows come from streammotions_rows.lua)
function L.run_class(h, class)
  local rows = dofile(os.getenv("TEST_DIR") .. "/streammotions_rows.lua")
  L.start()
  local t0 = uv.hrtime()
  for _, row in ipairs(rows) do
    if row.chk == class and L.selected(row.id) then
      local res = L.run_row(row)
      for id, r in pairs(res) do
        L.record(h, id, r.failed == 0, r.repro, r)
      end
      for _, id in ipairs({ row.id, row.id .. "@1" }) do
        if not res[id] and status[id] and status[id][1] == "skip" then L.record(h, id, true) end
      end
    end
  end
  L.stop()
  io.stdout:write(string.format("class %s: %.1f s, seed %d\n", class, (uv.hrtime() - t0) / 1e9, L.seed))
  L.write_report(class)
end

return L

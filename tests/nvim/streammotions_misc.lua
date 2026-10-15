-- Hand-written probes of the viewer (rows with chk = "misc"): the save and quit states, folds,
-- display options, splits, takeover, cancel and robustness. Each probe starts its own child
-- Neovim, so a probe that quits or crashes its Neovim cannot disturb the next one.
local h = dofile(os.getenv("TEST_DIR") .. "/harness.lua")
local L = dofile(os.getenv("TEST_DIR") .. "/streammotions_lib.lua")

local CFG = { block = 4096, line_cap = 4096, segment = 16384 }
local ORIG = L.read_file(L.files.get(L.dir, "log", 300 * 1024))

local P = {}

local function fresh(name, data, cfg)
  local path = L.write_file(name, data or ORIG)
  local c = L.spawn("viewer")
  assert(c:call("open", { path, {}, cfg or CFG }))
  return c, path
end

local function lua_errors(c)
  local msgs = c:call("messages", {}) or ""
  return (msgs:find("E5108", 1, true) or msgs:find("traceback", 1, true) or msgs:find("Error executing", 1, true)) and msgs or nil
end

local function ok_or(cond, what) return cond and true or false, what end

-- Folds are off in the viewer: a fold of window lines would hide lines that are not the file's
P["fld.off"] = function()
  local c = fresh("fld.txt")
  for _, k in ipairs({ "zfj", "zc", "zM", "zfap", "zc" }) do
    c:call("keys", { k })
  end
  local r = c:exec([[
    local closed = 0
    for i = 1, vim.fn.line("$") do
      if vim.fn.foldclosed(i) ~= -1 then closed = closed + 1 end
    end
    return { enable = vim.wo.foldenable, closed = closed, lines = vim.fn.line("$") }
  ]])
  return ok_or(r.enable == false and r.closed == 0, vim.inspect(r))
end

P["dsp.opts"] = function()
  local c = fresh("dsp.txt")
  local r = c:exec([[
    local wo = vim.wo
    return { wrap = wo.wrap, list = wo.list, spell = wo.spell, number = wo.number, rnu = wo.relativenumber,
      conceal = wo.conceallevel, fold = wo.foldenable, cc = wo.colorcolumn }
  ]])
  local want = { wrap = false, list = false, spell = false, number = false, rnu = false, conceal = 0, fold = false, cc = "" }
  return ok_or(vim.deep_equal(r, want), vim.inspect(r))
end

P["dsp.longline"] = function()
  local line = string.rep("abcdefghij ", 100000)
  local c = fresh("dsp-long.txt", line .. "\n")
  c:call("keys", { ":set list<CR>" })
  local t0 = vim.uv.hrtime()
  c:call("keys", { "$" })
  c:call("keys", { "0" })
  local ms = (vim.uv.hrtime() - t0) / 1e6
  local r = c:exec([[
    local m = 0
    for _, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do m = math.max(m, #l) end
    return m
  ]])
  return ok_or(r <= CFG.line_cap + 64 and ms < 1500, string.format("longest displayed line %d bytes (cap %d), $0 took %.0f ms", r, CFG.line_cap, ms))
end

P["dsp.unicode"] = function()
  local data = L.read_file(L.files.get(L.dir, "multibyte", 300 * 1024))
  local c = fresh("dsp-mb.txt", data)
  local shown = c:exec([[return vim.api.nvim_buf_get_lines(0, 0, 20, false)]])
  local want = {}
  for line in data:gmatch("[^\n]*\n") do
    want[#want + 1] = line:sub(1, -2)
    if #want == #shown then break end
  end
  for i, l in ipairs(shown) do
    if #want[i] <= CFG.line_cap and l ~= want[i] then return false, string.format("line %d: %q, want %q", i, l, want[i]) end
  end
  return true
end

P["win.split"] = function()
  local c = fresh("win.txt")
  c:call("keys", { ":split<CR>" })
  c:call("keys", { "<C-f>" })
  c:call("keys", { "3j" })
  local r = c:exec([[
    local wins = vim.api.nvim_tabpage_list_wins(0)
    local b1, b2 = vim.api.nvim_win_get_buf(wins[1]), vim.api.nvim_win_get_buf(wins[2])
    local rows = vim.api.nvim_buf_line_count(b1)
    local cur = vim.api.nvim_win_get_cursor(wins[1])
    return { n = #wins, same = b1 == b2, cur_ok = cur[1] >= 1 and cur[1] <= rows }
  ]])
  c:call("keys", { ":q<CR>" })
  c:call("keys", { "G" })
  local after = c:exec([[return { wins = #vim.api.nvim_tabpage_list_wins(0), line = vim.api.nvim_get_current_line() }]])
  local err = lua_errors(c)
  return ok_or(
    r.n == 2 and r.same and r.cur_ok and after.wins == 1 and not err,
    vim.inspect({ r, after }) .. (err or "")
  )
end

---------------------------------------------------------------------------------------------------
-- Save and quit states: expected like Vim, on the logical text
---------------------------------------------------------------------------------------------------

local function same_bytes(path, want)
  local got = L.read_file(path)
  if got == want then return true end
  return false, string.format("file is %d bytes, want %d", got and #got or -1, #want)
end

local function edited(name)
  local c, path = fresh(name)
  c:call("keys", { "x" })
  return c, path, ORIG:sub(2)
end

P["wri.w"] = function()
  local c, path, want = edited("wri-w.txt")
  c:call("keys", { ":w<CR>" })
  local ok, why = same_bytes(path, want)
  local left = vim.fn.glob(L.dir .. "/.wri-w.txt.streamview-*", false, true)
  return ok_or(ok and #left == 0, (why or "") .. (#left > 0 and " leftover temp file" or ""))
end

local function quit_with(name, keys, want_saved, tag)
  local c, path = edited(name)
  c:send("keys", { keys })
  local code = c:exit_code(10000)
  if code ~= 0 then return false, tag .. ": exit code " .. tostring(code) end
  return same_bytes(path, want_saved and ORIG:sub(2) or ORIG)
end

P["wri.wq"] = function() return quit_with("wri-wq.txt", ":wq<CR>", true, ":wq") end
P["wri.x"] = function()
  local ok, why = quit_with("wri-x.txt", ":x<CR>", true, ":x")
  if not ok then return false, why end
  local c, path = fresh("wri-x2.txt")
  local before = vim.uv.fs_stat(path).mtime
  c:send("keys", { ":x<CR>" })
  if c:exit_code(10000) ~= 0 then return false, ":x on an unmodified buffer did not quit" end
  local after = vim.uv.fs_stat(path).mtime
  return ok_or(before.sec == after.sec and before.nsec == after.nsec, ":x rewrote an unmodified file")
end
P["wri.ZZ"] = function() return quit_with("wri-zz.txt", "ZZ", true, "ZZ") end
P["wri.qbang"] = function()
  local ok, why = quit_with("wri-qb.txt", ":q!<CR>", false, ":q!")
  if not ok then return false, why end
  return quit_with("wri-zq.txt", "ZQ", false, "ZQ")
end

P["wri.q_modified"] = function()
  local c, path = edited("wri-q.txt")
  c:call("keys", { ":q<CR>" })
  local alive = c:call("status", {})
  local msgs = c:call("messages", {}) or ""
  local ok, why = same_bytes(path, ORIG)
  return ok_or(alive and ok and msgs:find("E37", 1, true) ~= nil, "alive=" .. tostring(alive ~= nil) .. " " .. (why or "") .. " E37 missing from messages: " .. msgs)
end

P["wri.update"] = function()
  local c, path = edited("wri-up.txt")
  c:call("keys", { ":update<CR>" })
  local ok, why = same_bytes(path, ORIG:sub(2))
  if not ok then return false, why end
  local before = vim.uv.fs_stat(path).mtime
  vim.wait(1100)
  c:call("keys", { ":update<CR>" })
  local after = vim.uv.fs_stat(path).mtime
  return ok_or(before.sec == after.sec and before.nsec == after.nsec, ":update wrote an unmodified buffer")
end

P["wri.saveas"] = function()
  local c, path, want = edited("wri-as.txt")
  local other = L.dir .. "/wri-as-other.txt"
  os.remove(other)
  c:call("keys", { ":w " .. other .. "<CR>" })
  local ok, why = same_bytes(other, want)
  if not ok then return false, "new file: " .. why end
  ok, why = same_bytes(path, ORIG)
  if not ok then return false, "original: " .. why end
  c:call("keys", { "x:w " .. other .. "<CR>" })
  local refused = same_bytes(other, want)
  c:call("keys", { ":w! " .. other .. "<CR>" })
  local forced = same_bytes(other, ORIG:sub(3))
  return ok_or(refused and forced, "w without ! over an existing file must refuse (" .. tostring(refused) .. "); w! must write (" .. tostring(forced) .. ")")
end

P["wri.range"] = function()
  local c = fresh("wri-range.txt")
  local out = L.dir .. "/wri-range-out.txt"
  os.remove(out)
  c:call("keys", { ":100,200w " .. out .. "<CR>" })
  local lines, want = {}, {}
  for line in ORIG:gmatch("[^\n]*\n") do
    lines[#lines + 1] = line
  end
  for i = 100, 200 do
    want[#want + 1] = lines[i]
  end
  return same_bytes(out, table.concat(want))
end

P["wri.perm"] = function()
  local c, path = edited("wri-perm.txt")
  vim.uv.fs_chmod(path, tonumber("444", 8))
  c:call("keys", { ":w<CR>" })
  local ok, why = same_bytes(path, ORIG)
  vim.uv.fs_chmod(path, tonumber("644", 8))
  return ok_or(ok, "a read-only file was overwritten by :w without ! (" .. (why or "") .. ")")
end

P["wri.symlink"] = function()
  local c0, real = fresh("wri-real.txt")
  c0:stop()
  local link = L.dir .. "/wri-link.txt"
  os.remove(link)
  vim.uv.fs_symlink(real, link)
  local c = L.spawn("viewer")
  assert(c:call("open", { link, {}, CFG }))
  c:call("keys", { "x" })
  c:call("keys", { ":w<CR>" })
  local st = vim.uv.fs_lstat(link)
  local ok, why = same_bytes(real, ORIG:sub(2))
  return ok_or(st and st.type == "link" and ok, "link kept: " .. tostring(st and st.type) .. ", " .. (why or ""))
end

---------------------------------------------------------------------------------------------------
-- Takeover of the read
---------------------------------------------------------------------------------------------------

local SETUP = "lua vim.g.stream_viewer_min_bytes = 1000; require('streamview').setup()"
local IS_VIEWER = [[
  local sv = require("streamview")
  return { viewer = sv.state() ~= nil, buftype = vim.bo.buftype, lines = vim.api.nvim_buf_line_count(0) }
]]

P["rob.takeover.argv"] = function()
  local path = L.write_file("take-argv.txt", ORIG)
  local c = L.spawn("viewer", { raw = true, argv = { "--cmd", SETUP, path } })
  local r = c:exec(IS_VIEWER)
  return ok_or(r.viewer and r.lines < 200, vim.inspect(r))
end

P["rob.takeover.edit"] = function()
  local path = L.write_file("take-edit.txt", ORIG)
  local c = L.spawn("viewer", { raw = true, argv = { "--cmd", SETUP } })
  c:exec("vim.cmd('edit ' .. vim.fn.fnameescape(...))", { path })
  local r = c:exec(IS_VIEWER)
  return ok_or(r.viewer and r.lines < 200, vim.inspect(r))
end

P["rob.takeover.split"] = function()
  local path = L.write_file("take-split.txt", ORIG)
  local c = L.spawn("viewer", { raw = true, argv = { "--cmd", SETUP } })
  c:exec("vim.cmd('split ' .. vim.fn.fnameescape(...))", { path })
  c:exec("vim.cmd('badd ' .. vim.fn.fnameescape(...)) vim.cmd('buffer ' .. vim.fn.fnameescape(...))", { path .. ".b" })
  local r = c:exec(IS_VIEWER)
  local small = L.write_file("take-small.txt", "tiny\n")
  c:exec("vim.cmd('edit ' .. vim.fn.fnameescape(...))", { small })
  local s = c:exec(IS_VIEWER)
  return ok_or(r.viewer ~= nil and not s.viewer and s.lines == 1, vim.inspect({ r, s }))
end

---------------------------------------------------------------------------------------------------
-- Cancel and quit while a scan runs
---------------------------------------------------------------------------------------------------

local BIG
local function big()
  BIG = BIG or L.seq_file("seq-128m.txt", 14500000)
  return BIG
end

local SLOW = { block = 64, line_cap = 4096, segment = 16384 }

local function start_scan(keys)
  local path = big()
  if not path then return nil, "not enough disk for the 128 MB scan file" end
  local c = L.spawn("viewer")
  assert(c:call("open", { path, {}, SLOW }))
  if keys:sub(1, 1) == "?" then c:call("keys", { "G" }) end
  local before = c:call("status", {})
  c:call("start_keys", { keys })
  vim.wait(300)
  local st = c:call("status", {})
  if not st.job then return nil, "the scan was over before it could be cancelled" end
  return c, before
end

local function cancel_ok(keys)
  local c, before = start_scan(keys)
  if not c then return false, before end
  local t0 = vim.uv.hrtime()
  c:call("input", { "<C-c>" })
  local st
  vim.wait(3000, function()
    st = c:call("status", {})
    return st.job == nil
  end, 20)
  local ms = (vim.uv.hrtime() - t0) / 1e6
  local cancelled = false
  for _, n in ipairs(st.notes or {}) do
    if n:find("ancel", 1, true) then cancelled = true end
  end
  return ok_or(
    st.job == nil and st.pos == before.pos and cancelled and ms < 1500,
    string.format("job=%s pos %s -> %s, cancelled message=%s, %.0f ms", tostring(st.job), before.pos, st.pos, tostring(cancelled), ms)
  )
end

P["can.search"] = function() return cancel_ok("/ZZZ<CR>") end
P["can.search_back"] = function() return cancel_ok("?ZZZ<CR>") end
P["can.again"] = function()
  local c, before = start_scan("/ZZZ<CR>")
  if not c then return false, before end
  c:call("input", { "<C-c>" })
  vim.wait(1500, function() return c:call("status", {}).job == nil end, 20)
  c:call("start_keys", { "/1000000<CR>" })
  local st
  vim.wait(60000, function()
    st = c:call("status", {})
    return st.job == nil and st.pos > 0
  end, 50)
  local want = L.seq_off(1000000)
  return ok_or(st.pos == want, string.format("after a cancel the next search landed at %s, want %s", tostring(st.pos), want))
end

P["can.quit"] = function()
  local c = start_scan("/ZZZ<CR>")
  if not c then return false, "no scan" end
  c:send("exec", { "vim.cmd('qa!')", {} })
  local code = c:exit_code(5000)
  return ok_or(code == 0, "quitting during a scan: exit code " .. tostring(code))
end

---------------------------------------------------------------------------------------------------
-- Robustness: the file changes under the viewer
---------------------------------------------------------------------------------------------------

P["rob.truncate"] = function()
  local c, path = fresh("rob-trunc.txt", ORIG .. ORIG .. ORIG)
  c:call("keys", { "G" })
  local fd = vim.uv.fs_open(path, "r+", 0)
  vim.uv.fs_ftruncate(fd, #ORIG)
  vim.uv.fs_close(fd)
  for _, k in ipairs({ "<C-f>", "k", "gg", "G", "<C-b>", "10j", "zL", "zH", "x" }) do
    c:call("keys", { k })
  end
  local err = lua_errors(c)
  return ok_or(not err and c:call("status", {}) ~= nil, err or "child died")
end

P["rob.deleted"] = function()
  local c, path = fresh("rob-del.txt")
  os.remove(path)
  for _, k in ipairs({ "G", "gg", "<C-f>", "j", "x" }) do
    c:call("keys", { k })
  end
  local err = lua_errors(c)
  return ok_or(not err and c:call("status", {}) ~= nil, err or "child died")
end

P["rob.empty"] = function()
  local c = fresh("rob-empty.txt", "")
  for _, k in ipairs({ "j", "k", "G", "gg", "x", "p", "dd", "<C-f>", "<C-b>", "/a<CR>", "n", "zL", ":w<CR>", "ihi<Esc>", "u" }) do
    c:call("keys", { k })
  end
  local err = lua_errors(c)
  return ok_or(not err and c:call("status", {}) ~= nil, err or "child died")
end

P["rob.dir"] = function()
  local c = L.spawn("viewer")
  c:exec("vim.cmd('StreamView ' .. ...)", { L.dir })
  local err = lua_errors(c)
  return ok_or(not err and c:call("status", {}) ~= nil, err or "child died")
end

P["x.follow"] = function()
  local c, path = fresh("follow.txt", "one\ntwo\n")
  c:call("keys", { ":StreamFollow<CR>" })
  local f = io.open(path, "ab")
  f:write("appended-last-line\n")
  f:close()
  local last
  vim.wait(3000, function()
    last = c:exec([=[return vim.api.nvim_buf_get_lines(0, -2, -1, false)[1]]=])
    return last == "appended-last-line"
  end, 50)
  return ok_or(last == "appended-last-line", "last line is " .. tostring(last))
end

P["x.fileinfo"] = function()
  local c = fresh("info.txt")
  c:call("keys", { "G" })
  local s = c:exec([[return vim.api.nvim_eval_statusline(vim.wo.winbar, { winid = 0, use_winbar = true }).str]])
  return ok_or(s:find("%d+ / %d+") and s:find("%d+%.%d%%"), "winbar is " .. tostring(s))
end

P["x.reload"] = function()
  local c, path = fresh("reload.txt", "one\ntwo\n")
  local f = io.open(path, "ab")
  f:write("three\n")
  f:close()
  c:call("keys", { ":edit!<CR>" })
  c:call("keys", { "G" })
  local last = c:exec([=[return vim.api.nvim_buf_get_lines(0, -2, -1, false)[1]]=])
  return ok_or(last == "three" and not lua_errors(c), "last line is " .. tostring(last))
end

P["ins.completion"] = function()
  local c = fresh("compl.txt")
  local t0 = vim.uv.hrtime()
  c:call("keys", { "A<C-n><C-p><C-x><C-l><Esc>" }, 15000)
  local ms = (vim.uv.hrtime() - t0) / 1e6
  return ok_or(ms < 2000 and not lua_errors(c), string.format("insert completion took %.0f ms", ms))
end

L.run_probes(h, "misc", P)
h.finish()

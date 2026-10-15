-- Loaded into the two child Neovims of the streammotions tests (see streammotions_lib.lua):
-- role "oracle" is a stock Neovim that loads the file whole; role "viewer" runs the same keys
-- in the stream viewer. Both answer with the same snapshot so the driver can compare them.
--
-- Seams the viewer offers:
--   sv.cursor_offset(S)  -> absolute byte offset of the cursor
--   sv.place(S, byte)    -> puts the cursor on the absolute byte offset, returns true
-- and S.job is non-nil while a background scan/save runs. Other positions (a visual anchor, a mark)
-- are worked out from the rows: S.entries[lnum].from + the byte column.
local SM = {}
_G.SM = SM
local uv = vim.uv

local function termcodes(k) return vim.api.nvim_replace_termcodes(k, true, true, true) end

function SM.init(role, o)
  SM.role = role
  vim.o.lines, vim.o.columns = o.lines, o.columns
  vim.o.more = false
  vim.o.hidden = true
  vim.o.modeline = false
  vim.notify = function(msg) SM.notes[#SM.notes + 1] = tostring(msg) end
  vim.o.swapfile = false
  vim.o.shortmess = vim.o.shortmess .. "I"
  if o.lua_dir and o.lua_dir ~= "" then vim.opt.rtp:prepend(o.lua_dir) end
  if role == "viewer" then
    SM.sv = require("streamview")
    SM.sv.setup()
    SM.sv.opts.editable = true
    SM.sv.opts.follow_ms = 50
    vim.ui.input = function(opts, cb) cb(vim.fn.input(opts and opts.prompt or "")) end
  end
  return true
end

local function sha(s) return vim.fn.sha256(s) end

-- Absolute byte offset of (lnum, 0-based byte col) in the current buffer.
local function abs_of(lnum, col)
  if lnum < 1 then return -1 end
  if SM.role == "oracle" then
    if lnum > vim.api.nvim_buf_line_count(0) then return -2 end
    return vim.fn.line2byte(lnum) + col - 1
  end
  local sv = SM.sv
  local S = sv.state()
  if not S then return -3 end
  local cur = vim.api.nvim_win_get_cursor(0)
  if sv.cursor_offset and lnum == cur[1] and col == cur[2] then return sv.cursor_offset(S) end
  local ent = S.entries[lnum]
  if not ent then return -2 end
  -- a row holds the bytes [from, to) of the file as they are
  return ent.from + col
end

local function cursor_abs()
  local c = vim.api.nvim_win_get_cursor(0)
  return abs_of(c[1], c[2])
end

local function new_buffer_state()
  vim.cmd("silent! %bwipeout!")
  for r in ("abcdefghijklmnopqrstuvwxyz0123456789\"-/"):gmatch(".") do
    pcall(vim.fn.setreg, r, "")
  end
  vim.cmd("silent! delmarks! | silent! delmarks A-Z0-9")
  vim.cmd("clearjumps")
  vim.cmd("nohlsearch")
end

function SM.open(path, fo, cfg)
  new_buffer_state()
  if SM.role == "oracle" then
    vim.cmd("edit " .. (fo.bin and "++bin " or "") .. vim.fn.fnameescape(path))
    vim.wo.wrap = false
    vim.wo.winbar = " "
  else
    local sv = SM.sv
    for k, v in pairs(cfg or {}) do sv.opts[k] = v end
    vim.cmd("StreamView! " .. vim.fn.fnameescape(path))
    if not sv.state() then return false, "no viewer state" end
  end
  return true
end

function SM.place(B)
  if B <= 0 then return true end
  if SM.role == "oracle" then
    vim.cmd(("goto %d"):format(B + 1))
    vim.cmd("normal! zt")
    return true
  end
  local sv = SM.sv
  local S = sv.state()
  if sv.place then return sv.place(S, B) and true or false end
  sv.goto_offset(S, B)
  for i, ent in ipairs(S.entries) do
    if ent.off <= B and B < ent.nxt then
      local ok = pcall(vim.api.nvim_win_set_cursor, 0, { i, B - ent.off })
      S.row = i
      return ok and cursor_abs() == B
    end
  end
  return false
end

local function settle()
  if SM.role ~= "viewer" then return end
  local S = SM.sv.state()
  vim.wait(600000, function() return not (S and S.job) end, 5)
end

function SM.keys(keys)
  local mode = SM.role == "viewer" and "mx" or "nx"
  vim.api.nvim_feedkeys(termcodes(keys), mode, false)
  settle()
end

local function eol_of()
  return vim.bo.fileformat == "dos" and "\r\n" or "\n"
end

local function oracle_text()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local eol = eol_of()
  local text = table.concat(lines, eol)
  if vim.bo.eol and not (#lines == 1 and lines[1] == "" and vim.fn.line2byte(1) == -1) then text = text .. eol end
  return text
end

function SM.text()
  if SM.role == "oracle" then return oracle_text() end
  local sv = SM.sv
  local S = sv.state()
  sv.render(S)
  return S.r:get(0, S.r.size)
end

local function reg_summary(r)
  local s = vim.fn.getreg(r)
  return vim.fn.getregtype(r) .. ":" .. #s .. ":" .. (#s <= 60 and s or sha(s))
end

function SM.snap(spec)
  local mode = vim.fn.mode(1)
  local s = { pos = cursor_abs(), mode = mode }
  if mode:find("^[vV\22]") then
    local v = vim.fn.getpos("v")
    s.anchor = abs_of(v[2], v[3] - 1)
  end
  if spec.regs then
    s.regs = {}
    for _, r in ipairs(spec.regs) do
      s.regs[r] = reg_summary(r)
    end
  end
  if spec.marks then
    s.marks = {}
    for _, m in ipairs(spec.marks) do
      local p = vim.fn.getpos("'" .. m)
      s.marks[m] = p[2] == 0 and -1 or abs_of(p[2], p[3] - 1)
    end
  end
  if spec.text then
    local t = SM.text()
    s.len, s.sha = #t, sha(t)
  end
  return s
end

function SM.run(path, fo, cfg, at, keys, spec)
  local ok, err = SM.open(path, fo, cfg)
  if not ok then return { err = "open: " .. tostring(err) } end
  if at > 0 and not SM.place(at) then return { err = "cannot place the cursor at byte " .. at, place = true } end
  local t0 = uv.hrtime()
  for _, k in ipairs(keys) do SM.keys(k) end
  local ms = (uv.hrtime() - t0) / 1e6
  return {
    snap = SM.snap(spec or {}),
    ms = ms,
    size = (uv.fs_stat(path) or {}).size,
    rss_kb = SM.rss_kb(),
    hwm_kb = SM.hwm_kb(),
  }
end

local function proc_kb(field)
  local f = io.open("/proc/self/status", "r")
  if not f then return nil end
  local kb = f:read("*a"):match(field .. ":%s*(%d+)")
  f:close()
  return kb and tonumber(kb)
end

function SM.rss_kb() return proc_kb("VmRSS") end

-- Peak resident size: a spike that is gone again still counts
function SM.hwm_kb() return proc_kb("VmHWM") end

SM.notes = {}

-- Typed ahead, not executed: the keys run when the child is back in its main loop, so a scan that
-- runs in slices can be interrupted by the next call
function SM.start_keys(keys)
  vim.api.nvim_feedkeys(termcodes(keys), SM.role == "viewer" and "m" or "n", false)
  return true
end

function SM.input(keys)
  vim.api.nvim_input(keys)
  return true
end

function SM.status()
  local S = SM.sv and SM.sv.state()
  return {
    job = S and S.job and S.job.label or nil,
    pos = cursor_abs(),
    mode = vim.fn.mode(1),
    rss_kb = SM.rss_kb(),
    notes = SM.notes,
  }
end

function SM.messages() return vim.fn.execute("messages") end

function SM.exec(code, args)
  local fn, err = loadstring(code, "=probe")
  if not fn then error(err) end
  return fn(unpack(args or {}))
end

-- Called by the driver: runs SM[name](unpack(args)) and writes the JSON reply file
function SM.serve(name, args, reply)
  local ok, res = pcall(function() return SM[name](unpack(args)) end)
  local body = vim.json.encode({ ok = ok, res = ok and res or nil, err = (not ok) and tostring(res) or nil })
  local tmp = reply .. ".part"
  local f = assert(io.open(tmp, "wb"))
  f:write(body)
  f:close()
  uv.fs_rename(tmp, reply)
end

return SM

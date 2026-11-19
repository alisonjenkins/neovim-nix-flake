-- Randomised checks of the stream viewer against models built from plain strings:
--   1. the piece table under random edits, undo and redo, with distinct tokens so an edit applied in
--      the wrong place or order shows;
--   2. the real buffer: text typed in the window, scrolling, jumping, undo, redo and saves, compared
--      with a model of the file's lines after every step.
-- STREAMFUZZ_SEED (default 1) seeds the random numbers and STREAMFUZZ_STEPS sets the steps per run;
-- a failure prints the seed and the steps that led to it.
--
-- h.xfail marks an open case: with mixed line ends, setting, deleting and inserting lines in one change gives some lines another ending than the model expects.
local h = dofile(os.getenv("TEST_DIR") .. "/harness.lua")
local tmp = os.getenv("TMPDIR") or "/tmp"
local uv = vim.uv
local sv = require("streamview")

local SEED = tonumber(os.getenv("STREAMFUZZ_SEED") or "1")
local STEPS = tonumber(os.getenv("STREAMFUZZ_STEPS") or "250")

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

local function eq(a, b, name)
  h.check(vim.deep_equal(a, b), name, vim.inspect(a) .. " ~= " .. vim.inspect(b))
end

local function open(path)
  vim.cmd("StreamView! " .. vim.fn.fnameescape(path))
  return sv.state()
end

local function save(S)
  local res
  sv.write(S, {}, function(ok, err) res = { ok = ok, err = err } end)
  vim.wait(60000, function() return res ~= nil end, 2)
  return res or { ok = false, err = "timed out" }
end

-- Where two texts first differ, with a little of each around it
local function first_diff(got, want)
  local i = 1
  while i <= #got and i <= #want and got:byte(i) == want:byte(i) do
    i = i + 1
  end
  local from = math.max(1, i - 20)
  return string.format("differ at byte %d (sizes %d and %d): got %q, model %q", i - 1, #got, #want, got:sub(from, i + 20), want:sub(from, i + 20))
end

local counter = 0
-- A text no other call returns, of varying length and content
local function token()
  counter = counter + 1
  local alphabet = { "a", "b", "q", "Z", " ", "-", "\195\169", "9" }
  local out = { "t" .. counter .. ":" }
  for _ = 1, math.random(0, 12) do
    out[#out + 1] = alphabet[math.random(#alphabet)]
  end
  return table.concat(out)
end

---------------------------------------------------------------------------------------------------
-- 1. Piece table
---------------------------------------------------------------------------------------------------

local function piece_table_run(seed, block)
  math.randomseed(seed)
  sv.opts.block = block
  local orig = {}
  for i = 1, 600 do
    orig[i] = string.char(97 + math.random(0, 25))
  end
  local path = write("fuzz-pieces.bin", table.concat(orig))
  local r = assert(sv.open_reader(path))
  local models = { table.concat(orig) }
  local trail = {}
  local function fail(step, what)
    return string.format("seed %d block %d step %d: %s; steps: %s", seed, block, step, what, table.concat(trail, " ", math.max(1, #trail - 6)))
  end
  for step = 1, 1500 do
    local op = math.random(1, 10)
    if op <= 6 then
      local cur = models[r.log_pos + 1]
      local cuts = {}
      for i = 1, 4 do
        cuts[i] = math.random(0, #cur)
      end
      table.sort(cuts, function(a, b) return a > b end)
      local edits, m = {}, cur
      for i = 1, math.random(1, 2) do
        local stop, start = cuts[2 * i - 1], cuts[2 * i]
        local text = math.random(1, 5) == 1 and "" or token()
        edits[i] = { start = start, stop = stop, text = text }
        m = m:sub(1, start) .. text .. m:sub(stop + 1)
        trail[#trail + 1] = string.format("[%d,%d)=%q", start, stop, text)
      end
      r:apply(edits)
      for i = #models, r.log_pos + 2, -1 do
        models[i] = nil
      end
      models[r.log_pos + 1] = m
    elseif op <= 8 then
      trail[#trail + 1] = "undo"
      r:undo()
    else
      trail[#trail + 1] = "redo"
      r:redo()
    end
    local want = models[r.log_pos + 1]
    local got = r:get(0, r.size)
    if got ~= want then return fail(step, "text differs") end
    -- a slice that starts inside the text, and the lines as the window cuts them
    local from = math.random(0, #want)
    local len = math.random(0, 3 * block)
    if r:get(from, len) ~= want:sub(from + 1, from + len) then return fail(step, "slice " .. from .. "+" .. len .. " differs") end
    local pos, joined = 0, {}
    while pos < r.size do
      local e = r:line_end(pos, {})
      local nl = want:find("\n", pos + 1, true)
      local want_end = nl and nl - 1 or r.size
      if e ~= want_end then return fail(step, string.format("line end from %d is %s, the model has %d", pos, tostring(e), want_end)) end
      local nxt = nl and e + 1 or r.size
      joined[#joined + 1] = want:sub(pos + 1, nxt)
      pos = nxt
    end
    if table.concat(joined) ~= want then return fail(step, "line ends do not cover the text") end
  end
  r:close()
end

---------------------------------------------------------------------------------------------------
-- 2. The window
---------------------------------------------------------------------------------------------------

-- The file as lines: { t = text, e = line end } and whether the last line ends with its end.
local Model = {}
Model.__index = Model

function Model.new(lines, eol, final, mixed)
  local m = setmetatable({ lines = {}, final = final }, Model)
  for i, t in ipairs(lines) do
    m.lines[i] = { t = t, e = mixed and (math.random(2) == 1 and "\r\n" or "\n") or eol }
  end
  return m:normalize()
end

-- An empty last line without a line end is no line at all: the line before it ends the file
function Model:normalize()
  while #self.lines > 1 and not self.final and self.lines[#self.lines].t == "" do
    self.lines[#self.lines] = nil
    self.final = true
  end
  return self
end

function Model:text()
  local out = {}
  for i, l in ipairs(self.lines) do
    out[i] = l.t .. ((i < #self.lines or self.final) and l.e or "")
  end
  return table.concat(out)
end

function Model:copy()
  local c = setmetatable({ lines = {}, final = self.final }, Model)
  for i, l in ipairs(self.lines) do
    c.lines[i] = { t = l.t, e = l.e }
  end
  return c
end

-- Index of the line that starts at byte `off` (0-based), or nil
function Model:line_at(off)
  local pos = 0
  for i, l in ipairs(self.lines) do
    if pos == off then return i end
    pos = pos + #l.t + #l.e
  end
end

local function make_lines(n)
  local lines = {}
  for i = 1, n do
    lines[i] = math.random(5) == 1 and "" or (token() .. " " .. i)
  end
  return lines
end

-- kind: eol, final newline, mixed line ends
local KINDS = {
  { name = "LF", eol = "\n", final = true },
  { name = "LF without a final newline", eol = "\n", final = false },
  { name = "CRLF", eol = "\r\n", final = true },
  { name = "CRLF without a final newline", eol = "\r\n", final = false },
  { name = "mixed LF and CRLF", eol = "\n", final = true, mixed = true },
}

-- Runs random steps on a viewer of a file of `kind`. Returns nil, or a description of the first
-- difference from the model.
local function window_run(kind, seed, steps, opts)
  opts = opts or {}
  math.randomseed(seed)
  sv.opts.block = 48
  vim.o.lines = 12
  vim.cmd("silent! %bwipeout!")
  local nlines = math.random(15, 60)
  local model = Model.new(make_lines(nlines), kind.eol, kind.final, kind.mixed)
  local path = write("fuzz-window.txt", model:text())
  local S = open(path)
  local history, pos = { model:copy() }, 1
  local disk = model:text()
  local trail = {}

  local function fail(what)
    local tail = {}
    for i = math.max(1, #trail - 8), #trail do
      tail[#tail + 1] = trail[i]
    end
    return string.format("%s, seed %d: %s\n       steps: %s", kind.name, seed, what, table.concat(tail, " | "))
  end

  local function check(step)
    local want = history[pos]:text()
    local got = S.r:get(0, S.r.size)
    if got ~= want then return fail(string.format("step %d: text %s", step, first_diff(got, want))) end
    local idx = want == "" and 1 or history[pos]:line_at(S.offset)
    if not idx then return fail(string.format("step %d: offset %d is not the start of a line", step, S.offset)) end
    local shown = vim.api.nvim_buf_get_lines(S.buf, 0, -1, false)
    local expect = {}
    local rows = vim.api.nvim_win_get_height(0)
    for i = idx, math.min(#history[pos].lines, idx + rows - 1) do
      expect[#expect + 1] = history[pos].lines[i].t
    end
    if #expect == 0 then expect = { "" } end
    if not vim.deep_equal(shown, expect) then
      return fail(string.format("step %d: window %s, model %s", step, vim.inspect(shown), vim.inspect(expect)))
    end
    if vim.bo[S.buf].modified ~= (pos > 1) then return fail(string.format("step %d: modified is %s at history %d", step, tostring(vim.bo[S.buf].modified), pos)) end
  end

  -- Types random changes into the window; returns the model after them
  local function type_into_window()
    local cur = vim.api.nvim_buf_get_lines(S.buf, 0, -1, false)
    local idx = history[pos]:line_at(S.offset)
    local next_model = history[pos]:copy()
    local new = vim.deepcopy(cur)
    for _, l in ipairs(next_model.lines) do
      l.last = nil
    end
    next_model.lines[#next_model.lines].last = true
    local entries = {}
    for i = 1, #cur do
      entries[i] = next_model.lines[idx + i - 1]
    end
    local desc = {}
    for _ = 1, math.random(1, 3) do
      local op = math.random(1, 3)
      local i = math.random(1, #new)
      if op == 1 then
        local t = token()
        new[i] = t
        entries[i] = { t = t, e = entries[i].e, last = entries[i].last }
        desc[#desc + 1] = "set" .. i
      elseif op == 2 and #new > 1 and not (not next_model.final and entries[i].last) then
        table.remove(new, i)
        table.remove(entries, i)
        desc[#desc + 1] = "del" .. i
      else
        local t = token()
        table.insert(new, i + 1, t)
        table.insert(entries, i + 1, { t = t, e = entries[i].e, last = entries[i].last })
        entries[i].last = nil
        desc[#desc + 1] = "ins" .. i
      end
    end
    if vim.deep_equal(new, cur) then return nil end
    local lines = next_model.lines
    local out = {}
    for i = 1, idx - 1 do
      out[#out + 1] = lines[i]
    end
    for _, e in ipairs(entries) do
      out[#out + 1] = e
    end
    for i = idx + #cur, #lines do
      out[#out + 1] = lines[i]
    end
    next_model.lines = out
    next_model:normalize()
    vim.api.nvim_buf_set_lines(S.buf, 0, -1, false, new)
    trail[#trail + 1] = "type(" .. table.concat(desc, ",") .. ")@" .. S.offset
    return next_model
  end

  local function commit(next_model)
    for i = #history, pos + 1, -1 do
      history[i] = nil
    end
    history[#history + 1] = next_model
    pos = #history
  end

  local function mutate_model_to_disk()
    history, pos = { history[pos]:copy() }, 1
  end

  local function disk_equals(step)
    local on_disk = read(path)
    if on_disk ~= history[pos]:text() then
      return fail(string.format("step %d: file %s", step, first_diff(on_disk, history[pos]:text())))
    end
  end

  for step = 1, steps do
    local size = S.r.size
    local roll = math.random(100)
    if roll <= 14 then
      local to = math.random(0, size)
      trail[#trail + 1] = "goto " .. to
      sv.goto_offset(S, to)
    elseif roll <= 24 then
      local n = math.random(-8, 8)
      trail[#trail + 1] = "scroll " .. n
      sv.scroll(S, n)
    elseif roll <= 28 then
      trail[#trail + 1] = "head"
      sv.head(S)
    elseif roll <= 32 then
      trail[#trail + 1] = "tail"
      sv.tail(S)
    elseif roll <= 36 then
      trail[#trail + 1] = "page"
      sv.page(S, math.random(0, 1) == 1 and 1 or -1)
    elseif roll <= 70 then
      local next_model = type_into_window()
      if next_model then
        local how = math.random(3)
        if how == 1 then
          trail[#trail + 1] = "scroll 0"
          sv.scroll(S, 0)
        elseif how == 2 then
          trail[#trail + 1] = "render"
          sv.render(S)
        elseif how == 3 then
          trail[#trail + 1] = "goto 0"
          sv.goto_offset(S, 0)
        end
        commit(next_model)
      end
    elseif roll <= 82 then
      sv.render(S)
      trail[#trail + 1] = "undo"
      if pos > 1 then pos = pos - 1 end
      sv.undo(S)
    elseif roll <= 90 then
      sv.render(S)
      trail[#trail + 1] = "redo"
      if pos < #history then pos = pos + 1 end
      sv.redo(S)
    else
      trail[#trail + 1] = "save"
      local res = save(S)
      if not res.ok then return fail("step " .. step .. ": save failed: " .. tostring(res.err)) end
      local d = disk_equals(step)
      if d then return d end
      -- saving an unmodified buffer writes nothing, so what can be redone stays
      if pos > 1 then mutate_model_to_disk() end
    end
    local d = check(step)
    if d then return d end
    if opts.stop_after_first_edit and pos > 1 then break end
  end
  sv.render(S)
  local res = save(S)
  if not res.ok then return fail("final save failed: " .. tostring(res.err)) end
  local d = disk_equals("final")
  vim.cmd("silent! %bwipeout!")
  return d
end

local steps = {
  function()
    local bad
    for _, block in ipairs({ 8, 64, 1000 }) do
      for seed = SEED, SEED + 2 do
        bad = bad or piece_table_run(seed, block)
      end
    end
    h.check(bad == nil, "3000 random edits, undos and redos with distinct tokens match a string model, at 3 block sizes", tostring(bad))
    sv.opts.block = 64
  end,
}

for _, kind in ipairs(KINDS) do
  steps[#steps + 1] = function()
    sv.opts.editable = true
    local started = uv.hrtime()
    local bad
    for seed = SEED, SEED + 2 do
      bad = bad or window_run(kind, seed, STEPS)
    end
    local ms = (uv.hrtime() - started) / 1e6
    if kind.mixed then
      h.xfail("window edits on a file with mixed line ends match the model", bad == nil, bad)
    else
      h.check(bad == nil, "window fuzz on " .. kind.name .. " matches the model", bad)
    end
    io.stdout:write(string.format("      (%s: %.0f ms)\n", kind.name, ms))
  end
end

h.run(steps, 600000)

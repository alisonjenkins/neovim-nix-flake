-- Search in the stream viewer: what is searched for (literal text or a Vim regex, with 'ignorecase'
-- and 'smartcase'), how the file is scanned (in Lua, in bounded memory, or by the streamsearch helper
-- when it is there) and how the helper's answers are read. The viewer decides where to start and
-- what to do with a match.
local uv = vim.uv
local S = {}

S.opts = {
  batch = 4 * 1024 * 1024, -- bytes of whole lines handed to vim.regex at a time
  overlap = 64 * 1024, -- how far past the end of a window of a long line a match may reach
  context = 256, -- bytes before the start of a window of a long line that the regex can look at
  streamsearch = nil, -- the helper: a path, a command (list), or nil to look for it on PATH
}

---------------------------------------------------------------------------------------------------
-- What is searched for
---------------------------------------------------------------------------------------------------

-- Vim ignores an uppercase letter that follows a backslash when it decides about 'smartcase'
local function has_upper(pat)
  local i = 1
  while i <= #pat do
    local c = pat:sub(i, i)
    if c == "\\" then
      i = i + 1
    elseif c:match("%u") then
      return true
    end
    i = i + 1
  end
  return false
end

-- Whether a "\c" or "\C" in the pattern decides the case, and which
local function case_flag(pat)
  local flag
  local i = 1
  while i <= #pat do
    if pat:sub(i, i) == "\\" then
      local n = pat:sub(i + 1, i + 1)
      if n == "c" then flag = true end
      if n == "C" then flag = false end
      i = i + 2
    else
      i = i + 1
    end
  end
  return flag
end

-- The literal text of a pattern that has no regex magic, or nil
local function literal_of(pat)
  if pat:sub(1, 2) == "\\V" then
    -- very nomagic: only a backslash is special
    local text = pat:sub(3):gsub("\\([\\/])", "%1")
    if not text:find("\\", 1, true) then return text end
    return nil
  end
  if pat:find("[%.%*%[%]%^%$~\\]") then return nil end
  return pat
end

-- Returns the plan for a pattern: { text, ic } for literal text, or { regex, ic, anchored } for
-- a Vim regex; also .external (what the helper takes) or .untranslatable (why it cannot).
-- Returns nil and a message for a pattern that is not valid.
function S.plan(pat, o)
  o = o or {}
  local ignorecase = o.ignorecase
  if ignorecase == nil then ignorecase = vim.o.ignorecase end
  local smartcase = o.smartcase
  if smartcase == nil then smartcase = vim.o.smartcase end
  local forced = case_flag(pat)
  local ic
  if forced ~= nil then
    ic = forced
  else
    ic = ignorecase and not (smartcase and has_upper(pat))
  end
  local plan = { pat = pat, ic = ic }
  local text = literal_of(pat)
  -- case folding in Lua is for ASCII; other letters go through the regex engine
  if text and (not ic or not text:find("[\128-\255]")) and not (pat:find("\\[cC]")) then
    plan.text = text
  else
    local src = (ic and "\\c" or "\\C") .. pat
    local ok, re = pcall(vim.regex, src)
    if not ok then return nil, "invalid pattern: " .. tostring(re):gsub("^.-:%s*", "") end
    plan.regex, plan.re = src, re
    plan.anchored = pat:find("^", 1, true) ~= nil
  end
  -- the helper takes the literal text, or the translation of the regex
  local okt, tr = pcall(require, "streamsearch_regex")
  if plan.text then
    plan.external = { mode = "fixed", pattern = plan.text, ic = ic }
  elseif okt and tr and tr.translate then
    local t, why = tr.translate(pat, { ignorecase = ignorecase, smartcase = smartcase })
    if t then
      plan.external = { mode = t.mode, pattern = t.pattern, ic = t.case == "ignore" }
    else
      plan.untranslatable = why or "untranslatable"
    end
  else
    plan.untranslatable = "no translator for Vim regexes"
  end
  return plan
end

---------------------------------------------------------------------------------------------------
-- Scanning in Lua. All of them return the offset of a match and its length; tick(pos) is called
-- between chunks and may yield.
---------------------------------------------------------------------------------------------------

-- A match can straddle two blocks, so the last m-1 bytes of the scanned side are carried over.
local function fixed_forward(r, text, ic, from, tick)
  if ic then text = text:lower() end
  local m = #text
  local pos, tail = from, ""
  while pos < r.size do
    local index = math.floor(pos / r.bs)
    local base = index * r.bs
    local data = r:block(index)
    if data == "" then return nil end
    local win = tail .. data:sub(pos - base + 1)
    local i = (ic and win:lower() or win):find(text, 1, true)
    if i then return pos - #tail + i - 1, m end
    tail = m > 1 and win:sub(-(m - 1)) or ""
    pos = base + r.bs
    tick(pos)
  end
end

-- Finds the last match that starts before `before`.
local function fixed_backward(r, text, ic, before, tick)
  if ic then text = text:lower() end
  local m = #text
  local reversed = text:reverse()
  -- (a match that starts before `before` may end after it: the bytes there are part of the window)
  local hi, after = math.min(before, r.size), m > 1 and r:get(before, m - 1) or ""
  while hi > 0 do
    local index = math.floor((hi - 1) / r.bs)
    local base = index * r.bs
    local win = r:block(index):sub(1, hi - base) .. after
    local i = (ic and win:lower() or win):reverse():find(reversed, 1, true)
    if i then return base + #win - i - m + 1, m end
    after = win:sub(1, m - 1)
    hi = base
    tick(hi)
  end
end

local scratch -- a buffer that holds the text vim.regex looks at
local function scratch_buf()
  if scratch and vim.api.nvim_buf_is_valid(scratch) then return scratch end
  scratch = vim.api.nvim_create_buf(false, true)
  vim.bo[scratch].undolevels = -1
  vim.bo[scratch].swapfile = false
  vim.bo[scratch].bufhidden = "hide"
  return scratch
end

-- Every match of `re` in line `lnum` of the scratch buffer that starts in [col, limit), in order.
-- from_start: the matches are those found going along the line from its start, one after the
-- other (a match that covers `col` hides the ones inside it), as Neovim's search finds them.
local function matches_in(re, buf, lnum, col, limit, anchored, from_start)
  local out = {}
  local at = (anchored or from_start) and 0 or col
  while true do
    local s, e = re:match_line(buf, lnum, at)
    if not s then break end
    local start = at + s
    if start >= limit then break end
    if start >= col then out[#out + 1] = { start, e - s } end
    -- an anchored pattern can only match once in the line
    if anchored then break end
    at = start + math.max(e - s, 1)
  end
  return out
end

-- Windows of a long line: the line [ls, le) is searched in pieces so that no more than a piece and
-- its overlap is held. Only matches that start in a piece count for it; one longer than the overlap
-- that crosses into the next piece is not found. Calls fn(window_start_abs, text, col_of_piece_start,
-- piece_len, at_line_start); fn returns a match or nil.
local function each_window(r, ls, le, from, backward, fn, tick)
  local W, ov, ctx = S.opts.batch, S.opts.overlap, S.opts.context
  local pieces = {}
  local first = math.max(ls, from)
  if backward then
    -- from the end back to the start
    local w = ls + math.floor((le - ls - 1) / W) * W
    while w >= ls do
      pieces[#pieces + 1] = w
      w = w - W
    end
  else
    local w = ls + math.floor((first - ls) / W) * W
    while w < le do
      pieces[#pieces + 1] = w
      w = w + W
    end
  end
  for _, w in ipairs(pieces) do
    local text_from = math.max(ls, w - ctx)
    local text_to = math.min(le, w + W + ov)
    local text = r:raw(text_from, text_to)
    local res = fn(text_from, text, w - text_from, math.min(W, le - w), text_from == ls)
    if res then return res end
    tick(w)
  end
end

-- A Vim regex, forward from `from`: the first match that starts at or after it
local function regex_forward(r, plan, from, tick)
  local buf = scratch_buf()
  local re = plan.re
  local batch = S.opts.batch
  local ls = r:line_start(from, { tick = tick })
  if not ls then return nil end
  local pos = ls
  local first = true
  while pos < r.size do
    local hi = math.min(r.size, pos + batch)
    local data = r:raw(pos, hi)
    local usable
    if hi >= r.size then
      usable = data
    else
      local from_end = select(2, data:reverse():find("\n", 1, true))
      if from_end then usable = data:sub(1, #data - from_end + 1) end
    end
    if not usable then
      -- a line longer than the batch
      local le = r:line_end(pos, { tick = tick })
      if not le then return nil end
      local hit = each_window(r, pos, le, first and from or pos, false, function(text_from, text, col, plen, at_start)
        if plan.anchored and not at_start then return nil end
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
        local lowest = col
        if first then lowest = math.max(col, from - text_from) end
        for _, m in ipairs(matches_in(re, buf, 0, lowest, col + plen, plan.anchored, first and lowest > col)) do
          if text_from + m[1] >= from then return { text_from + m[1], m[2] } end
        end
      end, tick)
      if hit then return hit[1], hit[2] end
      pos = le + 1
    else
      local body = usable:sub(-1) == "\n" and usable:sub(1, -2) or usable
      local lines = vim.split(body, "\n", { plain = true })
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      local off = pos
      for i, line in ipairs(lines) do
        local col = (first and i == 1) and (from - pos) or 0
        if col <= #line then
          local ms = matches_in(re, buf, i - 1, col, #line + 1, plan.anchored, col > 0)
          if ms[1] then return off + ms[1][1], ms[1][2] end
        end
        off = off + #line + 1
      end
      pos = pos + #usable
      tick(pos)
    end
    first = false
  end
end

-- A Vim regex, backward: the last match that starts before `before`
local function regex_backward(r, plan, before, tick)
  local buf = scratch_buf()
  local re = plan.re
  local batch = S.opts.batch
  local top = math.min(before, r.size) -- the text from here on is not searched, except the line it is in
  while top > 0 do
    local ls = r:line_start(top - 1, { tick = tick })
    if not ls then return nil end
    local le = r:line_end(ls, { tick = tick })
    if not le then return nil end
    if le - ls > batch then
      local hit = each_window(r, ls, le, ls, true, function(text_from, text, col, plen, at_start)
        if plan.anchored and not at_start then return nil end
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
        local ms = matches_in(re, buf, 0, col, col + plen, plan.anchored)
        for i = #ms, 1, -1 do
          if text_from + ms[i][1] < before then return { text_from + ms[i][1], ms[i][2] } end
        end
      end, tick)
      if hit then return hit[1], hit[2] end
      top = ls
    else
      -- whole lines, back from this one until a batch is full
      local start = ls
      while start > 0 and le - start < batch do
        local prev = r:line_start(start - 1, { tick = tick, nl_at_off = true })
        if not prev or le - prev > batch then break end
        start = prev
      end
      local lines = vim.split(r:raw(start, le), "\n", { plain = true })
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      local offs, o = {}, start
      for i, line in ipairs(lines) do
        offs[i] = o
        o = o + #line + 1
      end
      for i = #lines, 1, -1 do
        local ms = matches_in(re, buf, i - 1, 0, #lines[i] + 1, plan.anchored)
        for j = #ms, 1, -1 do
          if offs[i] + ms[j][1] < before then return offs[i] + ms[j][1], ms[j][2] end
        end
      end
      top = start
    end
    tick(top)
  end
end

-- scan(r, plan, origin, forward, tick) -> offset, length of the match; nil when there is none.
-- Forward finds the first match that starts at or after `origin`, backward the last that starts
-- before it.
function S.lua_scan(r, plan, origin, forward, tick)
  if plan.text then
    return (forward and fixed_forward or fixed_backward)(r, plan.text, plan.ic, origin, tick)
  end
  return (forward and regex_forward or regex_backward)(r, plan, origin, tick)
end

---------------------------------------------------------------------------------------------------
-- The helper
---------------------------------------------------------------------------------------------------

-- The command (a list) that runs the helper, or nil when it is not there
function S.helper()
  local o = S.opts.streamsearch
  if type(o) == "table" then return o end
  if type(o) == "string" and o ~= "" and vim.fn.executable(o) == 1 then return { o } end
  local path = vim.fn.exepath("streamsearch")
  if path ~= "" then return { path } end
end

-- The argument list for a search with the helper (no shell: the pattern is an argument after --)
function S.helper_argv(cmd, plan, file, from, forward, extra)
  local ext = plan.external
  local argv = vim.list_extend({}, cmd)
  vim.list_extend(argv, { "--" .. ext.mode })
  if ext.ic then argv[#argv + 1] = "--ignore-case" end
  if not forward then argv[#argv + 1] = "--backward" end
  vim.list_extend(argv, { "--from", string.format("%d", from) })
  vim.list_extend(argv, { "--progress-ms", "200" })
  if extra then vim.list_extend(argv, extra) end
  vim.list_extend(argv, { "--", ext.pattern, file })
  return argv
end

-- Runs the helper and reports its matches as they come. h: { on_match(start, stop) -> true to stop,
-- on_progress(scanned, total), on_exit(code, stderr) }. Returns a handle with kill().
function S.run_helper(argv, h)
  local buffered = ""
  local err_buffered, err_text = "", {}
  local stopped = false
  local proc
  local function lines_of(chunk, held, fn)
    held = held .. chunk
    while true do
      local nl = held:find("\n", 1, true)
      if not nl then break end
      fn(held:sub(1, nl - 1))
      held = held:sub(nl + 1)
    end
    return held
  end
  local ok, started = pcall(vim.system, argv, {
    stdout = function(_, data)
      if not data or stopped then return end
      buffered = lines_of(data, buffered, function(line)
        local okj, obj = pcall(vim.json.decode, line)
        if okj and type(obj) == "table" and obj.start and obj["end"] and not stopped then
          if h.on_match(obj.start, obj["end"]) then
            stopped = true
            if proc then proc:kill("sigterm") end
          end
        end
      end)
    end,
    stderr = function(_, data)
      if not data then return end
      err_buffered = lines_of(data, err_buffered, function(line)
        local okj, obj = pcall(vim.json.decode, line)
        if okj and type(obj) == "table" and obj.scanned then
          if h.on_progress then h.on_progress(obj.scanned, obj.total) end
        else
          err_text[#err_text + 1] = line
        end
      end)
    end,
  }, function(res)
    h.on_exit(stopped and 0 or res.code, table.concat(err_text, "\n"), stopped, res.signal)
  end)
  if not ok then
    vim.schedule(function() h.on_exit(2, tostring(started), false, 0) end)
    return { kill = function() end }
  end
  proc = started
  return {
    kill = function()
      stopped = true
      proc:kill("sigterm")
    end,
  }
end

return S

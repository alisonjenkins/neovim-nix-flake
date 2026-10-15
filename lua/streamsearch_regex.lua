-- Translate a Vim regex into the pattern syntax of the `streamsearch` helper.
--
--   local r, why = require("streamsearch_regex").translate([[\<foo\(bar\)\{2,3}]], {
--     ignorecase = vim.o.ignorecase, smartcase = vim.o.smartcase,
--   })
--   -- r = { pattern = [[\<foo(?:...)]], mode = "regex", case = "sensitive" }
--   -- or r == nil and why = "untranslatable: \\zs in regex mode"
--
-- `mode` is "fixed" (pattern is the literal text), "regex" or "pcre"; `case` is
-- "ignore" or "sensitive". Pass them as --fixed/--regex/--pcre and -i.
-- Anything that cannot be expressed returns nil plus a reason: fall back to
-- vim.regex on the window around the cursor.

local M = {}

local CLASSES = {
  s = "[ \\t]", S = "[^ \\t]",
  d = "[0-9]", D = "[^0-9]",
  w = "[0-9A-Za-z_]", W = "[^0-9A-Za-z_]",
  a = "[A-Za-z]", A = "[^A-Za-z]",
  l = "[a-z]", L = "[^a-z]",
  u = "[A-Z]", U = "[^A-Z]",
  h = "[A-Za-z_]", H = "[^A-Za-z_]",
  x = "[0-9A-Fa-f]", X = "[^0-9A-Fa-f]",
  o = "[0-7]", O = "[^0-7]",
}
local CONTROL = { n = "\\n", t = "\\t", r = "\\r", e = "\\x1b", b = "\\x08" }
local LITERAL_OF = { n = "\n", t = "\t", r = "\r", e = "\27", b = "\8" }
-- Escaped in the output when they stand for themselves.
local RUST_META = "[%.%+%*%?%(%)%|%[%]{}%^%$#&%-~\\]"
-- Magic only when escaped (or, under \v, only when bare).
local GROUP_B = "[%(%)|%+%?={<>@%%&]"
local BARE_A = "[%.%*%[~%^%$]"

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

local function escape(c)
  if c:match(RUST_META) then
    return "\\" .. c
  end
  return c
end

local function parse_collection(pat, i)
  -- `i` points at "[". Returns the translated class and the next index, or nil
  -- when there is no closing "]" (Vim then treats "[" as a literal).
  local j = i + 1
  local out = { "[" }
  if pat:sub(j, j) == "^" then
    out[#out + 1] = "^"
    j = j + 1
  end
  if pat:sub(j, j) == "]" then
    out[#out + 1] = "\\]"
    j = j + 1
  end
  while j <= #pat do
    local c = pat:sub(j, j)
    if c == "]" then
      out[#out + 1] = "]"
      return table.concat(out), j + 1
    elseif c == "[" and pat:sub(j + 1, j + 1) == ":" then
      local close = pat:find(":]", j + 2, true)
      if not close then
        return nil
      end
      out[#out + 1] = pat:sub(j, close + 1)
      j = close + 2
    elseif c == "\\" then
      local n = pat:sub(j + 1, j + 1)
      if CONTROL[n] then
        out[#out + 1] = CONTROL[n]
      elseif n == "]" or n == "^" or n == "-" or n == "\\" then
        out[#out + 1] = "\\" .. n
      else
        out[#out + 1] = "\\\\"
        j = j - 1
      end
      j = j + 2
    elseif c == "[" or c == "&" or c == "~" then
      out[#out + 1] = "\\" .. c
      j = j + 1
    else
      out[#out + 1] = c
      j = j + 1
    end
  end
  return nil
end

local function parse_braces(pat, i)
  -- `i` points just after "\{" (or "{" under \v). Returns the quantifier text.
  local close = pat:find("\\?}", i)
  if not close then
    return nil
  end
  local body = pat:sub(i, close - 1)
  local after = close + (pat:sub(close, close) == "\\" and 2 or 1)
  local lazy = false
  if body:sub(1, 1) == "-" then
    lazy = true
    body = body:sub(2)
  end
  local lo, comma, hi = body:match("^(%d*)(,?)(%d*)$")
  if not lo then
    return nil
  end
  local q
  if lo == "" and comma == "" and hi == "" then
    q = "*"
  elseif comma == "" then
    q = "{" .. lo .. "}"
  else
    q = "{" .. (lo == "" and "0" or lo) .. "," .. hi .. "}"
  end
  return q .. (lazy and "?" or ""), after
end

function M.translate(pat, opts)
  opts = opts or {}
  local engine = opts.engine == "pcre" and "pcre" or "regex"
  local out, lit = {}, {}
  local meta = false
  local very = false
  local case = nil
  local at_start = true -- nothing that a quantifier could apply to yet
  local i, n = 1, #pat

  local function untranslatable(why)
    return nil, "untranslatable: " .. why
  end
  local function emit_literal(raw, text)
    out[#out + 1] = text or escape(raw)
    lit[#lit + 1] = raw
    at_start = false
  end
  local function emit_meta(text, starts)
    out[#out + 1] = text
    meta = true
    at_start = starts or false
  end
  local function ends_branch(k)
    if k > n then
      return true
    end
    local two = pat:sub(k, k + 1)
    if very then
      local c = pat:sub(k, k)
      return c == ")" or c == "|" or two == "\\n"
    end
    return two == "\\)" or two == "\\|" or two == "\\n"
  end

  while i <= n do
    local c = pat:sub(i, i)
    local escaped = false
    local width = 1
    if c == "\\" then
      if i == n then
        return untranslatable("trailing backslash")
      end
      escaped = true
      c = pat:sub(i + 1, i + 1)
      width = 2
    end
    local special
    if escaped then
      special = not very and c:match(GROUP_B) ~= nil
    else
      special = c:match(BARE_A) ~= nil or (very and c:match(GROUP_B) ~= nil)
    end
    local nxt = i + width

    if escaped and not special and c:match("%a") then
      -- Letter escapes behave the same under every magic level.
      if c == "v" then
        very = true
      elseif c == "m" then
        very = false
      elseif c == "M" or c == "V" then
        return untranslatable("\\" .. c .. " magic level")
      elseif c == "c" then
        case = "ignore"
      elseif c == "C" then
        case = "sensitive"
      elseif CLASSES[c] then
        emit_meta(CLASSES[c])
      elseif CONTROL[c] then
        emit_literal(LITERAL_OF[c], CONTROL[c])
      elseif c == "z" then
        local k = pat:sub(i + 2, i + 2)
        if k == "s" and engine == "pcre" then
          emit_meta("\\K")
          nxt = i + 3
        else
          return untranslatable("\\z" .. k .. " in " .. engine .. " mode")
        end
      else
        return untranslatable("\\" .. c)
      end
    elseif escaped and not special and c:match("%d") then
      if engine == "pcre" and c ~= "0" then
        emit_meta("\\" .. c)
      else
        return untranslatable("back-reference \\" .. c)
      end
    elseif escaped and c == "_" then
      local k = pat:sub(i + 2, i + 2)
      nxt = i + 3
      if k == "." then
        emit_meta("(?s:.)")
      elseif k == "s" then
        emit_meta("[ \\t\\n]")
      elseif k == "^" then
        emit_meta("^", true)
      elseif k == "$" then
        emit_meta("$")
      else
        return untranslatable("\\_" .. k)
      end
    elseif special then
      if c == "." then
        emit_meta(".")
      elseif c == "~" then
        return untranslatable("~ (last substitute string)")
      elseif c == "[" then
        local cls, after = parse_collection(pat, i)
        if cls then
          emit_meta(cls)
          nxt = after
        else
          emit_literal("[")
        end
      elseif c == "*" then
        if at_start then
          emit_literal("*")
        else
          emit_meta("*")
        end
      elseif c == "^" then
        local prev_ok = i == 1 or at_start
        if prev_ok then
          emit_meta("^", true)
        else
          emit_literal("^")
        end
      elseif c == "$" then
        if ends_branch(nxt) then
          emit_meta("$")
        else
          emit_literal("$")
        end
      elseif c == "+" or c == "?" or c == "=" then
        if at_start then
          return untranslatable("quantifier without an atom")
        end
        emit_meta(c == "=" and "?" or c)
      elseif c == "{" then
        local q, after = parse_braces(pat, nxt)
        if not q then
          return untranslatable("malformed \\{ quantifier")
        end
        emit_meta(q)
        nxt = after
      elseif c == "(" then
        emit_meta("(", true)
      elseif c == ")" then
        emit_meta(")")
      elseif c == "|" then
        emit_meta("|", true)
      elseif c == "<" then
        emit_meta(engine == "pcre" and "\\b(?=\\w)" or "\\b{start}")
      elseif c == ">" then
        emit_meta(engine == "pcre" and "\\b(?<=\\w)" or "\\b{end}")
      elseif c == "%" then
        local k = pat:sub(nxt, nxt)
        if k == "(" then
          emit_meta("(?:", true)
          nxt = nxt + 1
        else
          return untranslatable("\\%" .. k)
        end
      elseif c == "@" then
        return untranslatable("\\@ look-around")
      else
        return untranslatable("operator " .. c)
      end
    else
      -- A literal: bare text, or an escaped punctuation character.
      if escaped and c == "/" then
        emit_literal("/")
      elseif escaped and CONTROL[c] then
        emit_literal(LITERAL_OF[c], CONTROL[c])
      else
        -- Multibyte characters pass through as one unit.
        local len = c:byte() >= 0xF0 and 4 or c:byte() >= 0xE0 and 3 or c:byte() >= 0xC0 and 2 or 1
        local ch = pat:sub(i + width - 1, i + width - 2 + len)
        nxt = i + width - 1 + len
        emit_literal(ch)
      end
    end
    i = nxt
  end

  if case == nil then
    if opts.ignorecase then
      case = (opts.smartcase and has_upper(pat)) and "sensitive" or "ignore"
    else
      case = "sensitive"
    end
  end
  if not meta then
    local text = table.concat(lit)
    if text == "" then
      return untranslatable("empty pattern")
    end
    return { pattern = text, mode = "fixed", case = case }
  end
  return { pattern = table.concat(out), mode = engine, case = case }
end

return M

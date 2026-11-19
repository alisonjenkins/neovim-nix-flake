-- Deterministic test files for the streammotions tests. Every generator takes (dir, bytes) and
-- returns the path; the same arguments always give the same bytes.
local M = {}

local function rng(seed)
  local s = seed % 2147483647
  if s <= 0 then s = s + 2147483646 end
  return function(n)
    s = (s * 48271) % 2147483647
    return n and (s % n) + 1 or s
  end
end
M.rng = rng

local SYL = { "ka", "to", "mi", "re", "su", "no", "an", "el", "or", "ba", "ti", "qu", "ex", "in", "da", "ve" }
local WORDS
local function words()
  if WORDS then return WORDS end
  local R = rng(7)
  WORDS = {}
  for i = 1, 300 do
    local w = {}
    for _ = 1, R(3) do
      w[#w + 1] = SYL[R(#SYL)]
    end
    WORDS[i] = table.concat(w)
  end
  return WORDS
end

local function word(R)
  local w = words()
  return w[R(#w)]
end

local function phrase(R, n)
  local out = {}
  for i = 1, n do
    out[i] = word(R)
  end
  return table.concat(out, " ")
end

local function write(dir, name, parts)
  local path = dir .. "/" .. name
  local f = assert(io.open(path, "wb"))
  for _, p in ipairs(parts) do
    f:write(p)
  end
  f:close()
  return path
end

-- Appends strings to `parts` until `bytes` are reached; gen(i) returns the next piece.
local function fill(bytes, gen)
  local parts, size, i = {}, 0, 0
  while size < bytes do
    i = i + 1
    local s = gen(i)
    parts[#parts + 1] = s
    size = size + #s
  end
  return parts
end

local JSON_STRINGS = {
  [["hello world"]],
  [["a]b[c"]],
  [["quote \" inside {"]],
  [["back\\slash\\"]],
  [["é中"]],
  [["tab\tnl\n"]],
  [=["}}]]((("]=],
  [["http://x.test/y?a=1&b=[2]#{f}"]],
  [["café \"quoted\" (paren) [bracket] {brace}"]],
  [["plain"]],
  '"\195\169\228\184\173\240\159\152\128"',
}

local function json_node(R, depth)
  local k = R(depth > 5 and 4 or 8)
  if k <= 2 then return { t = "s", v = JSON_STRINGS[R(#JSON_STRINGS)] } end
  if k == 3 then return { t = "n", v = tostring(R(100000) - 500) .. (R(4) == 1 and ".5e3" or "") } end
  if k == 4 then return { t = "n", v = ({ "true", "false", "null" })[R(3)] } end
  local n = R(5) - 1
  if k <= 6 then
    local node = { t = "a", v = {} }
    for i = 1, n do
      node.v[i] = json_node(R, depth + 1)
    end
    return node
  end
  local node = { t = "o", v = {} }
  for i = 1, n do
    node.v[i] = { k = '"' .. word(R) .. '"', v = json_node(R, depth + 1) }
  end
  return node
end

local function json_emit(node, pretty, ind, out)
  local pad = pretty and string.rep("  ", ind + 1) or ""
  local padc = pretty and string.rep("  ", ind) or ""
  local nl = pretty and "\n" or ""
  if node.t == "s" or node.t == "n" then
    out[#out + 1] = node.v
  elseif #node.v == 0 then
    out[#out + 1] = node.t == "a" and "[]" or "{}"
  else
    out[#out + 1] = (node.t == "a" and "[" or "{") .. nl
    for i, item in ipairs(node.v) do
      out[#out + 1] = pad
      if node.t == "o" then out[#out + 1] = item.k .. (pretty and ": " or ":") end
      json_emit(node.t == "o" and item.v or item, pretty, ind + 1, out)
      out[#out + 1] = (i < #node.v and "," or "") .. nl
    end
    out[#out + 1] = padc .. (node.t == "a" and "]" or "}")
  end
end

local function json_pair(dir, bytes)
  local R = rng(11)
  local pretty, mini = { "[\n" }, { "[" }
  local size, i = 0, 0
  while size < bytes do
    i = i + 1
    local node = { t = "o", v = {} }
    for j = 1, 2 + R(4) do
      node.v[j] = { k = '"' .. word(R) .. '"', v = json_node(R, 0) }
    end
    local a, b = {}, {}
    json_emit(node, true, 1, a)
    json_emit(node, false, 0, b)
    local pa, pb = "  " .. table.concat(a), table.concat(b)
    pretty[#pretty + 1] = (i > 1 and ",\n" or "") .. pa
    mini[#mini + 1] = (i > 1 and "," or "") .. pb
    size = size + #pa
  end
  pretty[#pretty + 1] = "\n]\n"
  mini[#mini + 1] = "]\n"
  return write(dir, "pretty.json", pretty), write(dir, "min.json", mini)
end

local LEVELS = { "INFO", "INFO", "INFO", "WARN", "ERROR", "DEBUG" }

local function log_line(R, i, eol)
  local base = string.format(
    "2026-06-10T14:%02d:%02dZ %s svc[%d] req id=%d path=/%s/%s status=%d took=%dms msg=\"%s\"",
    math.floor(i / 60) % 60, i % 60, LEVELS[R(#LEVELS)], R(99), R(1000000), word(R), word(R), 200 + R(4) * 100 - 100, R(900),
    phrase(R, 1 + R(8))
  )
  local k = R(60)
  if k == 1 then
    base = base .. " payload=" .. '{"a":[1,2,{"b":"x]y"}],"c":"q\\"z{"}'
  elseif k == 2 then
    base = base .. " trace=(" .. word(R) .. "(" .. word(R) .. ")) [" .. phrase(R, 3) .. "]"
  elseif k == 3 then
    base = base .. " " .. phrase(R, 200 + R(400))
  end
  return base .. eol
end

local function log_file(dir, name, bytes, eol)
  local R = rng(13)
  local parts = fill(bytes, function(i)
    if i % 41 == 0 then return eol end
    return log_line(R, i, eol)
  end)
  return write(dir, name, parts)
end

local function yaml_file(dir, bytes)
  local R = rng(17)
  local parts = fill(bytes, function(i)
    local out = { i % 25 == 1 and "---\n" or "" }
    out[#out + 1] = word(R) .. ":\n"
    for _ = 1, 1 + R(4) do
      out[#out + 1] = "  " .. word(R) .. ": " .. ({ "[a, b, {c: d}]", '"str: with colon # not comment"', tostring(R(999)), "'it''s'", "~" })[R(5)] .. "\n"
    end
    out[#out + 1] = "  list:\n"
    for _ = 1, R(5) do
      out[#out + 1] = "    - " .. phrase(R, R(4)) .. (R(5) == 1 and "  # note (x)" or "") .. "\n"
    end
    if R(3) == 1 then out[#out + 1] = "  # " .. phrase(R, 6) .. "\n" end
    if R(6) == 1 then out[#out + 1] = "\n" end
    return table.concat(out)
  end)
  return write(dir, "doc.yaml", parts)
end

local function prose_file(dir, bytes)
  local R = rng(19)
  local ends = { ". ", ". ", "? ", "! ", ".  " }
  local parts = fill(bytes, function()
    local para = {}
    for _ = 1, 2 + R(6) do
      local s = phrase(R, 3 + R(12))
      para[#para + 1] = s:sub(1, 1):upper() .. s:sub(2) .. ends[R(#ends)]
    end
    local text = table.concat(para)
    local lines, line = {}, ""
    for w in text:gmatch("%S+") do
      if #line + #w + 1 > 72 then
        lines[#lines + 1] = line
        line = w
      else
        line = line == "" and w or line .. " " .. w
      end
    end
    lines[#lines + 1] = line
    return table.concat(lines, "\n") .. "\n\n"
  end)
  return write(dir, "prose.txt", parts)
end

local function words_line(dir, bytes)
  local R = rng(23)
  local seps = { " ", " ", ", ", ",", ";", "\t", " - ", ": " }
  local parts = fill(bytes, function(i)
    local w = R(8) == 1 and tostring(R(100000)) or word(R)
    return w .. seps[R(#seps)]
  end)
  parts[#parts + 1] = "end\n"
  return write(dir, "words.csv", parts)
end

local MB = { "caf\195\169", "na\195\175ve", "e\204\129", "\230\188\162\229\173\151", "\227\129\174\227\129\191", "\240\159\152\128", "\239\188\161\239\188\162", "\208\159\209\128\208\184\208\178\208\181\209\130", "x\204\129\204\130", "\240\159\145\141\240\159\143\189" }

local function multibyte_file(dir, bytes)
  local R = rng(29)
  local parts = fill(bytes, function(i)
    local out = {}
    for _ = 1, 2 + R(12) do
      out[#out + 1] = R(3) == 1 and MB[R(#MB)] or word(R)
    end
    local line = table.concat(out, R(4) == 1 and "\227\128\128" or " ")
    if i % 90 == 0 then line = line .. " " .. string.rep(MB[R(#MB)] .. word(R) .. " ", 300) end
    return line .. "\n"
  end)
  return write(dir, "multibyte.txt", parts)
end

local function mixed_eol(dir, bytes)
  local R = rng(31)
  local eols = { "\n", "\r\n", "\r", "\n" }
  local parts = fill(bytes, function() return phrase(R, 1 + R(10)) .. eols[R(#eols)] end)
  return write(dir, "mixed_eol.txt", parts)
end

local function nonl(dir, bytes)
  local R = rng(37)
  local parts = fill(bytes, function() return phrase(R, 1 + R(10)) .. "\n" end)
  parts[#parts + 1] = "last line without newline"
  return write(dir, "nonl.txt", parts)
end

local function invalid_bytes(dir, bytes)
  local R = rng(41)
  local junk = { "\255", "\254\253", "\192\128", "\237\160\128", "\248\136\128\128\128", "\128" }
  local parts = fill(bytes, function(i)
    return phrase(R, 1 + R(6)) .. (i % 3 == 0 and junk[R(#junk)] or "") .. phrase(R, 2) .. "\n"
  end)
  return write(dir, "invalid.bin", parts)
end

local function nul_bytes(dir, bytes)
  local R = rng(43)
  local parts = fill(bytes, function(i)
    return phrase(R, 1 + R(6)) .. (i % 4 == 0 and "\0\0" or "") .. phrase(R, 2) .. "\n"
  end)
  return write(dir, "nul.bin", parts)
end

M.kinds = {
  log = "many",
  json_lines = "many",
  yaml = "many",
  pretty_json = "many",
  prose = "many",
  multibyte = "many",
  crlf = "many",
  nonl = "many",
  mixed_eol = "many",
  invalid = "many",
  nul = "many",
  min_json = "one",
  words = "one",
}

-- Files that Neovim must read byte for byte (no encoding or EOL detection)
M.binary = { invalid = true, nul = true, mixed_eol = true }

local cache = {}

-- Returns the path of the named file, generating it (`bytes` long, roughly) on first use.
function M.get(dir, name, bytes)
  if cache[name] then return cache[name] end
  local path
  if name == "log" then
    path = log_file(dir, "log.txt", bytes, "\n")
  elseif name == "crlf" then
    path = log_file(dir, "crlf.txt", math.floor(bytes / 2), "\r\n")
  elseif name == "yaml" then
    path = yaml_file(dir, bytes)
  elseif name == "prose" then
    path = prose_file(dir, math.floor(bytes / 2))
  elseif name == "words" then
    path = words_line(dir, math.max(bytes, 4 * 1024 * 1024))
  elseif name == "multibyte" then
    path = multibyte_file(dir, math.floor(bytes / 2))
  elseif name == "mixed_eol" then
    path = mixed_eol(dir, 300 * 1024)
  elseif name == "nonl" then
    path = nonl(dir, 300 * 1024)
  elseif name == "invalid" then
    path = invalid_bytes(dir, 300 * 1024)
  elseif name == "nul" then
    path = nul_bytes(dir, 300 * 1024)
  elseif name == "json_lines" then
    -- one JSON document per line: log shipper output
    local R = rng(47)
    path = write(dir, "lines.jsonl", fill(math.floor(bytes / 2), function()
      local node = { t = "o", v = {} }
      for j = 1, 3 + R(5) do
        node.v[j] = { k = '"' .. word(R) .. '"', v = json_node(R, 1) }
      end
      local out = {}
      json_emit(node, false, 0, out)
      return table.concat(out) .. "\n"
    end))
  elseif name == "pretty_json" or name == "min_json" then
    local pretty, mini = json_pair(dir, bytes)
    cache.pretty_json, cache.min_json = pretty, mini
    return cache[name]
  else
    error("unknown test file " .. tostring(name))
  end
  cache[name] = path
  return path
end

-- A word that the generated files contain often
function M.pick_word(R) return word(R) end

-- Byte offsets of the starts of lines and some bytes inside them, for random start positions.
function M.starts(path, R, n)
  local f = assert(io.open(path, "rb"))
  local size = f:seek("end")
  local out = {}
  for _ = 1, n do
    local at = R(size) - 1
    f:seek("set", math.max(at - 200, 0))
    local data = f:read(400) or ""
    local rel = at - math.max(at - 200, 0)
    while rel < #data - 1 and data:byte(rel + 1) >= 0x80 and data:byte(rel + 1) < 0xC0 do
      rel, at = rel + 1, at + 1
    end
    local nl = data:sub(1, rel):find("\n[^\n]*$")
    local line_start = nl and (math.max(at - 200, 0) + nl) or 0
    out[#out + 1] = { line = line_start, inside = at }
  end
  f:close()
  return out, size
end

return M

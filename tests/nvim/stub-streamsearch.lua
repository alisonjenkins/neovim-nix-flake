-- A stand-in for the streamsearch helper, for testing how the viewer drives it: it takes the same
-- command line, reads the file in Lua, prints the matches as JSON lines and a progress line, and
-- exits 0 (found), 1 (none) or 2 (error). Run as: nvim -l stub-streamsearch.lua [options] PATTERN FILE
-- Every call is appended to $STUB_LOG, one line of arguments. The pattern SLEEP never ends.
local args = _G.arg
local o = { mode = "regex", ic = false, backward = false, from = 0, limit = 0 }
local pos = {}
local i = 1
local done_opts = false
while i <= #args do
  local a = args[i]
  if done_opts or a:sub(1, 1) ~= "-" then
    pos[#pos + 1] = a
  elseif a == "--" then
    done_opts = true
  elseif a == "--fixed" or a == "--regex" or a == "--pcre" then
    o.mode = a:sub(3)
  elseif a == "--ignore-case" or a == "--smart-case" then
    o.ic = a == "--ignore-case"
  elseif a == "--backward" then
    o.backward = true
  elseif a == "--from" or a == "--limit" or a == "--progress-ms" or a == "--index" or a == "--threads" or a == "--max-match-bytes" then
    i = i + 1
    local v = args[i]
    if a == "--from" then o.from = tonumber(v) end
    if a == "--limit" then o.limit = tonumber(v) end
  end
  i = i + 1
end
local pattern, file = pos[1], pos[2]
local log = os.getenv("STUB_LOG")
if log then
  local f = io.open(log, "a")
  f:write(table.concat(args, "\t"), "\n")
  f:close()
end
if not pattern or not file then
  io.stderr:write("usage\n")
  os.exit(2)
end
if pattern == "SLEEP" then
  while true do vim.uv.sleep(100) end
end
if pattern == "FAIL" then
  io.stderr:write("something went wrong\n")
  os.exit(2)
end
local f = assert(io.open(file, "rb"))
local data = f:read("*a")
f:close()
io.stderr:write(vim.json.encode({ scanned = #data, total = #data }), "\n")

local matches = {}
if o.mode == "fixed" then
  local text, hay = pattern, data
  if o.ic then text, hay = text:lower(), data:lower() end
  local at = 1
  while true do
    local s, e = hay:find(text, at, true)
    if not s then break end
    matches[#matches + 1] = { s - 1, e }
    at = s + 1
  end
else
  -- the whole text as lines; matches that stay inside a line
  local re = vim.regex((o.ic and "\\c" or "\\C") .. pattern)
  local off = 0
  for line in (data .. "\n"):gmatch("(.-)\n") do
    local col = 0
    while true do
      local s, e = re:match_str(line:sub(col + 1))
      if not s then break end
      matches[#matches + 1] = { off + col + s, off + col + e }
      col = col + s + math.max(e - s, 1)
    end
    off = off + #line + 1
  end
end
local sel = {}
for _, m in ipairs(matches) do
  if o.backward then
    if m[1] <= o.from then table.insert(sel, 1, m) end
  elseif m[1] >= o.from then
    sel[#sel + 1] = m
  end
end
local count = 0
for _, m in ipairs(sel) do
  io.stdout:write(vim.json.encode({ start = m[1], ["end"] = m[2] }), "\n")
  io.stdout:flush()
  count = count + 1
  if o.limit > 0 and count >= o.limit then break end
end
os.exit(count > 0 and 0 or 1)

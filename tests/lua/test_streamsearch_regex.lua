#!/usr/bin/env lua
-- Tests for streamsearch_regex.lua. With STREAMSEARCH_BIN set, every
-- translation that should match is also run through the real helper.

local script_dir = arg[0]:match("(.*/)")
if script_dir then
  package.path = script_dir .. "/../../lua/?.lua;" .. package.path
else
  package.path = "../../lua/?.lua;" .. package.path
end
local tr = require("streamsearch_regex").translate

local failures = 0
local function check(cond, msg)
  if not cond then
    failures = failures + 1
    io.stderr:write("FAIL: " .. msg .. "\n")
  end
end

local function same(vim_pat, opts, want_pattern, want_mode, want_case)
  local r, why = tr(vim_pat, opts)
  if not r then
    check(false, vim_pat .. " -> nil (" .. tostring(why) .. ")")
    return
  end
  check(r.pattern == want_pattern, vim_pat .. " pattern " .. r.pattern .. " want " .. want_pattern)
  check(r.mode == want_mode, vim_pat .. " mode " .. r.mode .. " want " .. want_mode)
  check(r.case == (want_case or "sensitive"), vim_pat .. " case " .. r.case)
end

local function refuses(vim_pat, opts, fragment)
  local r, why = tr(vim_pat, opts)
  check(r == nil, vim_pat .. " should be untranslatable")
  check(why and why:find("untranslatable", 1, true) and why:find(fragment, 1, true),
    vim_pat .. " reason " .. tostring(why))
end

-- literals become the fixed path
same("foo", nil, "foo", "fixed")
same([[a\.b\*c\/d]], nil, "a.b*c/d", "fixed")
same("a+b?(c)|d{1}", nil, "a+b?(c)|d{1}", "fixed")
same("caf\xc3\xa9", nil, "caf\xc3\xa9", "fixed")
same([[\<foo\>]], nil, [[\b{start}foo\b{end}]], "regex")
same([[\<foo\>]], { engine = "pcre" }, [[\b(?=\w)foo\b(?<=\w)]], "pcre")

-- quantifiers, groups, alternation
same([[\(ab\)\{2,3}]], nil, "(ab){2,3}", "regex")
same([[a\{-1,}]], nil, "a{1,}?", "regex")
same([[a\{3}]], nil, "a{3}", "regex")
same([[a\{,4}]], nil, "a{0,4}", "regex")
same([[a\{-}]], nil, "a*?", "regex")
same([[a\+b\=c\?]], nil, "a+b?c?", "regex")
same([[\%(ab\|cd\)e]], nil, "(?:ab|cd)e", "regex")
same("a.*b", nil, "a.*b", "regex")
same("*a", nil, "*a", "fixed")
same("[abc]x", nil, "[abc]x", "regex")
same("[^a-c]", nil, "[^a-c]", "regex")
same("[]x]", nil, "[\\]x]", "regex")
same([=[[\t\]]]=], nil, "[\\t\\]]", "regex")
same("[a", nil, "[a", "fixed")

-- very magic
same([[\v<(foo|bar)>]], nil, [[\b{start}(foo|bar)\b{end}]], "regex")
same([[\va{2,3}b+]], nil, "a{2,3}b+", "regex")
same([[\v\(x\)]], nil, "(x)", "fixed")

-- classes and anchors
same([[\d\+\s\w]], nil, "[0-9]+[ \\t][0-9A-Za-z_]", "regex")
same("^foo$", nil, "^foo$", "regex")
same("a^b$c", nil, "a^b$c", "fixed")
same([[\(^a\|b$\)]], nil, "(^a|b$)", "regex")
same([[a\_.b]], nil, "a(?s:.)b", "regex")
same([[a\_sb]], nil, "a[ \\t\\n]b", "regex")
same([[\n]], nil, "\n", "fixed")

-- case
same([[\cfoo]], nil, "foo", "fixed", "ignore")
same([[\Cfoo]], { ignorecase = true }, "foo", "fixed", "sensitive")
same("foo", { ignorecase = true }, "foo", "fixed", "ignore")
same("foo", { ignorecase = true, smartcase = true }, "foo", "fixed", "ignore")
same("Foo", { ignorecase = true, smartcase = true }, "Foo", "fixed", "sensitive")
same([[\Sa]], { ignorecase = true, smartcase = true }, "[^ \\t]a", "regex", "ignore")

-- pcre-only
same([[a\zsb]], { engine = "pcre" }, "a\\Kb", "pcre")
same([[\(a\)\1]], { engine = "pcre" }, "(a)\\1", "pcre")

-- untranslatable: caller falls back to vim.regex
refuses([[a\zsb]], nil, "\\zs")
refuses([[a\zeb]], nil, "\\ze")
refuses([[\(a\)\1]], nil, "back-reference")
refuses([[foo\@=]], nil, "look-around")
refuses([[\%V]], nil, "\\%V")
refuses("~", nil, "~")
refuses([[\Vfoo]], nil, "\\V")
refuses([[\k\+]], nil, "\\k")
refuses([[a\{x}]], nil, "malformed")
refuses("", nil, "empty")

if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end

local bin = os.getenv("STREAMSEARCH_BIN")
if not bin then
  print("translation tests passed (engine tests skipped: STREAMSEARCH_BIN unset)")
  os.exit(0)
end

local tmp = os.tmpname()
local sample = "foo bar\nFOO Bar\nfoobar foo_bar\n  indent\nabab ab\nx1y22z333\ncost: $5.00 (approx)\n"
local f = assert(io.open(tmp, "wb"))
f:write(sample)
f:close()

local function find_all(vim_pat, opts)
  local r = assert(tr(vim_pat, opts))
  local flags = { fixed = "--fixed", regex = "--regex", pcre = "--pcre" }
  local cmd = { bin, flags[r.mode], "--progress-ms", "0" }
  if r.case == "ignore" then
    cmd[#cmd + 1] = "-i"
  end
  cmd[#cmd + 1] = "--"
  cmd[#cmd + 1] = "'" .. r.pattern:gsub("'", "'\\''") .. "'"
  cmd[#cmd + 1] = tmp
  local p = assert(io.popen(table.concat(cmd, " ")))
  local got = {}
  for line in p:lines() do
    local s, e = line:match('"start":(%d+),"end":(%d+)')
    got[#got + 1] = sample:sub(s + 1, e)
  end
  p:close()
  return table.concat(got, "|")
end

local function e2e(vim_pat, opts, want)
  local got = find_all(vim_pat, opts)
  check(got == want, vim_pat .. " matched [" .. got .. "] want [" .. want .. "]")
end

e2e([[\<foo\>]], nil, "foo")
e2e([[\cfoo]], nil, "foo|FOO|foo|foo")
e2e([[\(ab\)\{2,}]], nil, "abab")
e2e([[\v<\d+>]], nil, "5|00")
e2e([[\d\+]], nil, "1|22|333|5|00")
e2e([[^FOO]], nil, "FOO")
e2e([[bar$]], nil, "bar|bar")
e2e([[\$5\.00 (\(\w\+\))]], nil, "$5.00 (approx)")
e2e([[o\zsb]], { engine = "pcre" }, "b")
os.remove(tmp)

if failures > 0 then
  io.stderr:write(failures .. " failure(s)\n")
  os.exit(1)
end
print("all streamsearch_regex tests passed")

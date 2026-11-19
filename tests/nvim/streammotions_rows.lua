-- The command matrix of the stream viewer: one row per command class. A row with chk nav, txt,
-- edit or search is run differentially (the same keys in stock Neovim and in the viewer, see
-- streammotions_lib.lua); chk misc and scale rows are probes written by hand in streammotions_misc.lua
-- and streammotions_scale.lua; chk doc rows have no test (out of scope, only documented).
-- docs/streamview-motions.md is generated from this file and a test report.
--
-- Fields: id, grp, cmd, expect (Vim semantics), applies (both|many|one), scope (yes|limits: ..|no: ..),
-- budget, rank (1 = used daily, 5 = rare), owner, chk, cases (curated key strings), rand (seeded
-- random sequences: pool, len, pre, post, glue, n), many/one (file names), at (start policy),
-- spec (what to compare besides the cursor: regs, marks, text), tol (cursor tolerance, fraction of size).
local MANY = { "log", "json_lines", "yaml" }
local ONE = { "min_json", "words" }
local JSON_MANY = { "pretty_json", "json_lines" }
local TEXT_MANY = { "log", "prose", "yaml" }
local REGS = { '"', "0", "1", "-", "a", "b" }

local OWNER = {
  mot = "navigation", wrd = "navigation", fnd = "navigation", sen = "navigation", mat = "navigation",
  scr = "navigation", jmp = "navigation", mrk = "navigation", vis = "navigation", opr = "navigation",
  txo = "navigation", ins = "navigation", und = "navigation", exr = "navigation", uni = "robustness",
  sea = "search", sub = "search", wri = "save", rob = "robustness", win = "robustness", dsp = "robustness",
  can = "robustness", fld = "robustness", x = "navigation",
}

local rows = {}

local function row(id, o)
  o.id = id
  o.grp = id:match("^(%a+)")
  o.chk = o.chk or "nav"
  o.applies = o.applies or "both"
  o.scope = o.scope or "yes"
  o.owner = o.owner or OWNER[o.grp]
  if o.chk == "nav" or o.chk == "txt" or o.chk == "edit" or o.chk == "search" then
    if o.applies ~= "one" and not o.many then o.many = MANY end
    if o.applies ~= "many" and not o.one then o.one = ONE end
    if o.applies == "one" then o.many = nil end
    if o.applies == "many" then o.one = nil end
  end
  rows[#rows + 1] = o
end

local function ops(id, o)
  o.chk = o.chk or "txt"
  o.spec = o.spec or { regs = REGS, text = true }
  row(id, o)
end

local function edit(id, o)
  o.chk = "edit"
  o.spec = o.spec or { regs = REGS, text = true }
  row(id, o)
end

local MOTIONS = {
  "h", "l", "j", "k", "3l", "7h", "2j", "5k", "0", "^", "$", "g_", "w", "b", "e", "ge", "W", "B", "E", "gE",
  "3w", "2b", "fe", "Fa", "t,", "T ", ";", ",", "%", "(", ")", "{", "}", "[[", "]]", "gg", "G", "H", "M", "L",
  "+", "-", "<CR>", "10|", "gm", "gM", "20j", "15k", "100l", "50h", "zt", "zb", "zz",
}

---------------------------------------------------------------------------------------------------
-- Char and line motions
---------------------------------------------------------------------------------------------------

row("mot.hl", {
  cmd = "h l {N}h {N}l", rank = 1, budget = "<50 ms for any N within the line",
  expect = "Move by characters (not bytes) inside the line; stop at the line ends; {N} clamps. In a multi-GB single line the cursor walks the whole line.",
  cases = { "l", "5l", "h", "40l", "300h", "3000l", "$h", "0l" },
  rand = { n = 10, len = { 1, 4 }, pool = { "l", "3l", "h", "7h", "40l", "130h", "1000l", "$", "0" } },
})
row("mot.jk", {
  cmd = "j k {N}j {N}k <Down> <Up>", rank = 1, budget = "<100 ms for N up to a window; <1 s for N = 1e6 lines",
  expect = "Move by lines keeping the wanted column; stop at the first and last line. On a single line it does nothing (beep).",
  cases = { "j", "k", "5j", "40j", "500j", "2000j", "50k", "jjjkk" },
  rand = { n = 10, len = { 1, 4 }, pool = { "j", "k", "3j", "9k", "25j", "70k", "300j", "1100k" } },
})
row("mot.bigcount", {
  cmd = "100000l 1000000j 99999999l", rank = 2, budget = "<1 s regardless of the count (no per-line loop)",
  expect = "Counts larger than the file clamp at the file end; the cost must not grow with the count.",
  cases = { "100000l", "99999999l", "100000j", "99999999j", "100000k", "99999999h" },
  scope = "yes",
})
row("mot.lineends", {
  cmd = "0 ^ $ g_ | gm gM {N}$ {N}|", rank = 2, budget = "<50 ms; $ in a multi-GB line must not read the whole line unless it has to",
  expect = "0 first column, ^ first non-blank, $ last character (with count, N-1 lines down), g_ last non-blank, N| screen column N, gm half a screen width, gM half the text width.",
  cases = { "$", "0", "^", "g_", "3$", "3g_", "40|", "gm", "gM", "50gM", "$0", "$^" },
  rand = { n = 8, len = { 1, 3 }, pool = { "$", "0", "^", "g_", "gM", "20|", "2$", "l", "j" } },
})
row("mot.linewise", {
  cmd = "+ - <CR> _ {N}+ {N}-", rank = 4, applies = "many", budget = "<100 ms",
  expect = "Move by lines to the first non-blank.",
  cases = { "+", "-", "<CR>", "5+", "30-", "_", "3_", "$+" },
  rand = { n = 6, len = { 1, 3 }, pool = { "+", "-", "<CR>", "7+", "20-", "_" } },
})
row("mot.curswant", {
  cmd = "curswant stickiness: $ then j/k; {N}| then j/k", rank = 2, applies = "many", budget = "<100 ms",
  expect = "After $ the cursor stays at line ends on j/k; after l/h the wanted column is the cursor's column and survives short lines. Must also survive a window/slice move.",
  cases = { "$jjj", "40|jjjkk", "30ljjjj", "$20jk", "50|100j50k", "0j$k" },
  rand = { n = 8, len = { 2, 5 }, pool = { "$", "j", "k", "30l", "40|", "10j", "13k", "0" } },
})
row("mot.screenline", {
  cmd = "gj gk g0 g^ g$", rank = 4, budget = "<100 ms",
  expect = "With nowrap these behave like j k 0 ^ $.",
  cases = { "gj", "gk", "g0", "g^", "g$", "5gj", "$gj" },
})

---------------------------------------------------------------------------------------------------
-- Words and f/t
---------------------------------------------------------------------------------------------------

row("wrd.w", {
  cmd = "w b e ge {N}w {N}b {N}e", rank = 1, budget = "<50 ms per word step; {N}=1000 <500 ms",
  expect = "Word motions cross line ends, blank lines, window edges and slice cuts exactly like in a loaded buffer; a word is never split at a slice edge.",
  cases = { "w", "b", "e", "ge", "3w", "5b", "4e", "5ge", "200w", "150b", "wwbb", "$b", "0ge" },
  rand = { n = 14, len = { 1, 5 }, pool = { "w", "b", "e", "ge", "2w", "7b", "13e", "4ge", "60w", "45b", "j", "k", "$", "0" } },
})
row("wrd.W", {
  cmd = "W B E gE {N}W", rank = 2, budget = "<50 ms per step",
  expect = "WORD motions (blank separated) with the same boundary rules as w b e ge.",
  cases = { "W", "B", "E", "gE", "3W", "9B", "5E", "7gE", "300W", "WWBB" },
  rand = { n = 10, len = { 1, 4 }, pool = { "W", "B", "E", "gE", "4W", "12B", "j", "$", "0" } },
})
row("wrd.cross", {
  cmd = "w b crossing slice cuts, line caps and NUL/long runs", rank = 2, budget = "<100 ms per step",
  expect = "A word that straddles a viewer slice, block, line_cap or segment edge is one word.",
  at = "edge",
  cases = { "w", "b", "e", "ge", "W", "B", "E", "gE", "3w", "3b", "wwwwwwww", "bbbbbbbb" },
  rand = { n = 10, len = { 1, 4 }, pool = { "w", "b", "e", "ge", "W", "B", "3w", "3b", "l", "h", "10l", "10h" } },
})
row("fnd.ft", {
  cmd = "f F t T {char}", rank = 1, budget = "<100 ms when the char is near; <seconds per GB when far",
  expect = "Find on the current line only (the whole line, however long); a miss leaves the cursor and cancels a pending operator.",
  cases = { "fe", "Fa", "t,", "T ", 'f"', "f{", "F}", "tZ", "fQ", "2f ", "3t,", "$F ", "fkafk" },
  rand = { n = 12, len = { 1, 4 }, pool = { "fe", "Fa", "t,", "T ", 'f"', "f{", "F}", "t:", "3fa", "2Fe", "5t ", "l", "h", "20l" } },
})
row("fnd.repeat", {
  cmd = "; , with counts after f F t T", rank = 1, budget = "<100 ms per repeat",
  expect = "; repeats in the same direction, , reverses; t then ; moves on past the adjacent match (cpo without ;).",
  cases = { "fe;", "fe;;;", "fe,", "t,;", "t,;;,", "3fe;", "Fa;;", "fe3;", "te;,;", "f ;;;,,", "5;" },
  rand = { n = 12, len = { 2, 6 }, pool = { "fe", "Fa", "t,", "T ", "ft", ";", ",", ";", "2;", "3," } },
})
row("fnd.multibyte", {
  cmd = "f/t with a multibyte target", rank = 3, many = { "multibyte" }, one = {}, applies = "many", budget = "<100 ms",
  expect = "The target is a whole character, found by character not byte; combining marks stay with their base.",
  cases = { "f\195\169", "t\195\169", "f\230\188\162", "F\230\188\162", "f\240\159\152\128", ";", "f\195\169;;", "t\195\169;," },
  rand = { n = 8, len = { 1, 3 }, pool = { "f\195\169", "t\195\169", "f\230\188\162", "F\208\159", "l", "w", ";", "," } },
})

---------------------------------------------------------------------------------------------------
-- Sentences, paragraphs, sections, brackets
---------------------------------------------------------------------------------------------------

row("sen.sentence", {
  cmd = "( ) {N}( {N})", rank = 4, many = { "prose", "log" }, one = { "words" }, budget = "<200 ms for N up to 10",
  expect = "Move to sentence starts; paragraph and blank-line breaks are sentence breaks.",
  cases = { ")", "(", "3)", "4(", "))))", "((((", "10)", "$)", "0(" },
  rand = { n = 8, len = { 1, 4 }, pool = { ")", "(", "3)", "2(", "w", "j" } },
})
row("sen.paragraph", {
  cmd = "{ } {N}{ {N}}", rank = 3, many = { "prose", "log", "yaml" }, applies = "many", budget = "<200 ms; with no blank line in a GB it scans to the file end (cancellable)",
  expect = "Move to the next/previous blank line; the last paragraph ends at the file end.",
  cases = { "}", "{", "3}", "4{", "}}}}", "{{{{", "50}", "50{", "G{", "gg}" },
  rand = { n = 8, len = { 1, 4 }, pool = { "}", "{", "2}", "3{", "j", "k", "10j" } },
})
row("sen.paragraph1", {
  cmd = "{ } on a single line", rank = 3, many = {}, one = ONE, applies = "one", budget = "<50 ms",
  expect = "A single line is one paragraph: } goes to its last character, { to its first.",
  cases = { "}", "{", "$}", "$h{", "20l}", "l{" },
})
row("sen.section", {
  cmd = "[[ ]] [] ][", rank = 5, many = { "pretty_json", "yaml" }, applies = "many", budget = "<200 ms",
  expect = "Section motions: a '{' / '}' in column 0 starts/ends a section; without any they go to the file ends.",
  cases = { "]]", "[[", "][", "[]", "2]]", "3[[", "G[[", "gg]]" },
})
row("sen.unmatched", {
  cmd = "[( [{ ]) ]} {N}[{", rank = 2, many = JSON_MANY, one = { "min_json" }, budget = "<200 ms near; cancellable scan, memory bounded, for far enclosing brackets",
  expect = "Jump to the enclosing unmatched bracket: the jq-like way up and down a JSON tree (]} is the end of the enclosing object).",
  cases = { "[{", "]}", "[(", "])", "2[{", "3]}", "f:[{", "f:]}", "5l[{]}", "[{[{", "]}]}" },
  rand = { n = 10, len = { 1, 3 }, pool = { "[{", "]}", "2[{", "2]}", "f:", "fa", "w", "20l", "j" } },
  at = "inside",
})
row("mat.pct", {
  cmd = "% on ( ) [ ] { } (and C comments)", rank = 1, many = JSON_MANY, one = { "min_json" },
  budget = "<200 ms if the pair is within a few MB; unbounded nesting scans are memory-bounded and cancellable (scale.mat.*)",
  expect = "Jump to the matching bracket, ignoring none (matchpairs); nesting counted across lines/slices; no match: stay. In minified JSON the match can be GBs away.",
  cases = { "f{%", "f[%", "f}%", "f]%", "f{%%", "f{%%%", "f(%", "f[%f{%", "%", "$%", "f{lf{%", "f{%x" },
  rand = { n = 12, len = { 1, 4 }, pool = { "f{%", "f[%", "F}%", "F]%", "%", "f{", "f[", "3l", "w", "fa" } },
  at = "inside",
})
row("mat.pct_text", {
  cmd = "% in logs and YAML (brackets inside text)", rank = 3, many = { "log", "yaml" }, one = { "words" }, budget = "<200 ms",
  expect = "Same as above; the first bracket at or after the cursor on the line is used; unbalanced brackets: no move.",
  cases = { "f(%", "f[%", "f{%", "f)%", "f]%", "f}%", "%", "$%" },
  rand = { n = 8, len = { 1, 3 }, pool = { "f(%", "f[%", "f{%", "j", "k", "%", "w" } },
})

---------------------------------------------------------------------------------------------------
-- Screen and scrolling
---------------------------------------------------------------------------------------------------

row("scr.HML", {
  cmd = "H M L {N}H {N}L", rank = 3, applies = "many", budget = "<50 ms",
  expect = "Top, middle, bottom line of the window (with count: N-th line from top/bottom, respecting scrolloff).",
  cases = { "H", "M", "L", "3H", "3L", "jjjH", "LjH", "ML", "10H", "10L" },
})
row("scr.zt", {
  cmd = "zt zz zb z<CR> z. z- zt/zb with counts", rank = 3, applies = "many", budget = "<50 ms",
  expect = "Scroll the window so the cursor line is at the top/center/bottom; the cursor does not move; z<CR> z. z- also go to the first non-blank.",
  cases = { "ztH", "zzH", "zbH", "z<CR>", "z.", "z-", "5jztk", "5jzbH", "5jzzH", "zbL", "ztM", "zzjH" },
})
row("scr.page", {
  cmd = "<C-d> <C-u> <C-f> <C-b> {N}<C-d> {N}<C-f> <PageDown>", rank = 1, applies = "many", budget = "<100 ms each, also N = 100",
  expect = "Half/full page scroll moving the cursor along; at the ends beep or stop; a count sets 'scroll' (C-d, C-u) or repeats (C-f, C-b).",
  cases = { "<C-d>", "<C-u>", "<C-f>", "<C-b>", "<C-d><C-d><C-u>", "<C-f><C-f><C-b>", "3<C-d>", "2<C-f>", "<C-f>H", "<C-f>L", "<C-d>jj<C-u>", "20<C-f>" },
  rand = { n = 10, len = { 1, 5 }, pool = { "<C-d>", "<C-u>", "<C-f>", "<C-b>", "j", "k", "5<C-d>", "2<C-f>", "3<C-b>", "H", "L", "G", "gg" } },
})
row("scr.line", {
  cmd = "<C-e> <C-y> {N}<C-e>", rank = 4, applies = "many", budget = "<50 ms",
  expect = "Scroll the text one line; the cursor moves only when it would leave the window.",
  cases = { "<C-e>", "<C-y>", "5<C-e>", "5<C-e>H", "30<C-e>", "30<C-e>M", "5<C-e>3<C-y>", "jjj<C-e><C-e><C-e><C-e>" },
})
row("scr.hscroll", {
  cmd = "zl zh zL zH zs ze {N}zl", rank = 3, budget = "<50 ms; zL in a multi-GB line is a window slide",
  expect = "Scroll the text sideways ('nowrap'); the cursor moves with the view when it would be left outside; zs/ze put the cursor column at the left/right edge.",
  cases = { "zl", "zh", "10zl", "50zl", "zL", "zH", "zLzH", "200zl", "zs", "ze", "$zs", "$ze", "40lzs", "100lze" },
  rand = { n = 8, len = { 1, 3 }, pool = { "zl", "zh", "10zl", "zL", "zH", "zs", "ze", "50l", "$", "0" } },
})
row("scr.scrolloff", {
  cmd = ":set scrolloff=N / sidescrolloff=N then j k l h", rank = 4, budget = "<100 ms",
  expect = "The window keeps N lines/columns around the cursor; the cursor offset is still exact.",
  cases = { ":set so=5<CR>20jH", ":set so=5<CR>10jLk", ":set so=999<CR>5jH", ":set siso=10<CR>200lzsh", ":set so=3 siso=5<CR>jjjjjjjjjjkk" },
})

---------------------------------------------------------------------------------------------------
-- Jumps in the file
---------------------------------------------------------------------------------------------------

row("jmp.gg_G", {
  cmd = "gg G (and <C-Home> <C-End>)", rank = 1, budget = "<300 ms at any file size",
  expect = "gg: first line, first non-blank. G: last line, first non-blank; both are exact. In a single line file G also goes to column 1 of that line.",
  cases = { "gg", "G", "Ggg", "ggG", "jjGk", "GkkgG" },
  rand = { n = 6, len = { 1, 3 }, pool = { "gg", "G", "j", "k", "$", "w" } },
})
row("jmp.NG", {
  cmd = "{N}G {N}gg :{N} :$ :1 :+N :-N", rank = 1, applies = "many", budget = "<300 ms with a line index, else a cancellable scan",
  expect = "Go to line N (absolute, by newline count); N beyond the end clamps to the last line.",
  cases = { "100G", "5000G", "1G", "99999999G", "250gg", ":300<CR>", ":$<CR>", ":1<CR>", ":+20<CR>", ":-5<CR>", "800G:+5<CR>", "800G:-5<CR>" },
  rand = { n = 8, len = { 1, 2 }, pool = { "7G", "1000G", "12345G", ":500<CR>", ":$<CR>", "G", "gg", "j" } },
})
row("jmp.NG1", {
  cmd = "{N}G :{N} on a single-line file", rank = 3, many = {}, one = ONE, applies = "one", budget = "<50 ms",
  expect = "Every line number is clamped to line 1; the cursor goes to its first non-blank.",
  cases = { "5G", ":5<CR>", ":$<CR>", "G", "$5G" },
})
row("jmp.pct", {
  cmd = "{N}%", rank = 2, budget = "<300 ms",
  expect = "Go to the line N percent through the file. Vim uses line counts; for a file larger than memory a byte percentage is accepted (cursor within 1 percent of the same place, at a line start).",
  scope = "limits: byte percentages instead of line percentages",
  tol = 0.01,
  cases = { "50%", "10%", "90%", "1%", "100%", "99%", "33%" },
})
row("jmp.go", {
  cmd = "{N}go :goto N", rank = 3, budget = "<300 ms",
  expect = "Go to byte N of the file (1-based): the cursor lands exactly on that byte, in any line, however long.",
  cases = { "1000go", "1go", "5000000go", "99999999go", ":goto 2500<CR>", ":goto 1500000<CR>", "300go5l", "300go$" },
  rand = { n = 8, len = { 1, 2 }, pool = { "1000go", "123456go", "2000000go", "l", "w", "$", "j" } },
})

---------------------------------------------------------------------------------------------------
-- Marks, jumplist, changelist
---------------------------------------------------------------------------------------------------

row("mrk.set", {
  cmd = "ma 'a `a (and :marks) across window moves", rank = 2, budget = "<50 ms",
  expect = "A mark remembers an absolute position; jumping back to it works after the window or slice moved away and after edits before it.",
  spec = { marks = { "a", "b" } },
  cases = { "ma50jmb`a", "ma50jmb'b", "maGgg`a", "ma5l500j`a", "majjjjjmbggG`b`a", "ma$gg'a", "ma3000j`a", "ma200wmb`a`b" },
  rand = { n = 8, len = { 2, 5 }, pool = { "ma", "mb", "`a", "`b", "'a", "'b", "100j", "50k", "G", "gg", "20l", "5w" } },
})
row("mrk.auto", {
  cmd = "'' `` '. `. `[ `] `< `> '^ `^", rank = 3, budget = "<50 ms",
  expect = "'' and `` return to the position before the last jump; `. to the last change; `[ `] to the ends of the last change or yank; `< `> to the last visual area.",
  spec = { marks = { "[", "]", "<", ">", ".", "^", '"' } },
  cases = { "G``", "50jgg''", "xG`.", "50jyyG`[", "3wyw`]", "vjj<Esc>G`<", "vjj<Esc>G`>", "ihello<Esc>G`^", "5jG``G``" },
})
row("mrk.jumplist", {
  cmd = "<C-o> <C-i> <Tab> :jumps", rank = 2, budget = "<100 ms",
  expect = "The jumplist holds absolute positions (G gg {N}G / ? n N % ( ) { } `a ' are jumps); <C-o>/<C-i> walk it.",
  cases = { "Ggg<C-o>", "Ggg<C-o><C-o>", "Ggg<C-o><C-i>", "100G200G300G<C-o><C-o>", "}}}<C-o><C-o>", "G50k<C-o>", "3G5G7G<C-o><C-o><C-i>" },
  rand = { n = 8, len = { 2, 6 }, pool = { "G", "gg", "300G", "40%", "<C-o>", "<C-i>", "}", "{", "j" } },
})
row("mrk.changelist", {
  cmd = "g; g, :changes", rank = 4, budget = "<100 ms",
  expect = "Walk the positions of the last changes, also those made before moving the window away.",
  spec = { text = true },
  cases = { "x50jx50jg;g;", "x50jx50jg;g;g,", "xGxg;g;", "ihi<Esc>40jahi<Esc>gg2g;", "xjxjxjg;g;g;" },
})

---------------------------------------------------------------------------------------------------
-- Visual mode and operators
---------------------------------------------------------------------------------------------------

ops("vis.select", {
  cmd = "v V <C-v> with motions, o O, gv, then an operator", rank = 1, budget = "<200 ms for a window-sized selection; selections of any size stream",
  expect = "The selection is anchored at an absolute position; motions (including window/slice moves) extend it; o/O swap ends; gv reselects; the operator acts on the whole selection.",
  cases = { "vjjd", "vwwwy", "Vjjjd", "Vjjjy", "v$d", "vjd", "v5ey", "vjjhd", "vjjokd", "v$hd", "v5jhy", "Vjj<Esc>gvd", "v50jy", "V50jd", "vGd", "vggd", "v3}d", "v%d" },
  rand = { n = 14, len = { 1, 4 }, pre = { "v", "V" }, post = { "d", "y", "c<Esc>", "~", "U" }, pool = { "j", "k", "l", "h", "w", "b", "e", "$", "0", "5j", "9k", "fe", "t,", "}", "{", "G", "gg", "o" } },
})
ops("vis.block", {
  cmd = "<C-v> block selections with $, I, A, c, o O, r", rank = 4, applies = "many", budget = "<300 ms for blocks of up to a window",
  expect = "Rectangular selection by display columns; I/A insert on every line; $ extends to each line's end.",
  cases = { "<C-v>jjd", "<C-v>3jlly", "<C-v>3jI#<Esc>", "<C-v>3j$A;<Esc>", "<C-v>3jlcX<Esc>", "<C-v>3jrx", "<C-v>3jlod", "<C-v>j$d", "<C-v>5jOd" },
})
ops("opr.motion", {
  cmd = "d y c > < = gu gU g~ g? ! + motion", rank = 1, budget = "<300 ms for a window-sized range; the cost of a bigger range is streaming",
  expect = "The operator acts on the exact text between the cursor and the motion's target, whatever distance, in registers and in the file.",
  cases = { "dw", "d3w", "db", "de", "d$", "d0", "d^", "dfe", "dte", "dFa", "dTa", "d%", "d}", "d{", "d)", "dgg", "dG", "d5j", "d50k", "d500j", "yw", "y$", "y}", "yG", "y200j", "cwfoo<Esc>", "c$bar<Esc>", "gUw", "guw", "g~w", "gUU", "d/{W}<CR>", ">j", "<j", "=j", "dd", "yy", "cc" },
  rand = { n = 24, len = { 1, 1 }, glue = true, pre = { "d", "y", "c", "gU", "gu", "g~", ">", "<" }, pool = { "w", "b", "e", "ge", "W", "B", "E", "3w", "2b", "$", "0", "^", "g_", "fe", "te", "Fa", "Ta", "%", "}", "{", ")", "(", "5j", "9k", "40j", "200k", "G", "gg", "l", "h", "j", "k", "iw", "aw", "i(", "a{", "i\"" } },
})
ops("opr.line", {
  cmd = "dd yy cc >> << == ~ gUU guu g~~ J gJ with counts", rank = 1, applies = "many", budget = "<300 ms; {N} up to a window",
  expect = "Linewise operators on N lines, exact in file and registers; at the file end, N is clamped.",
  cases = { "dd", "3dd", "yy", "5yy", "cc", "2ccX<Esc>", ">>", "3>>", "<<", "==", "gUU", "guu", "g~~", "J", "5J", "gJ", "4gJ", "20dd", "100yy", "500dd", "Gdd", "Gddp" },
  rand = { n = 10, len = { 1, 3 }, pool = { "dd", "yy", "3dd", "2yy", "p", "P", "J", "u", "j", "k", "G", "gg", ">>", "<<" } },
})
ops("opr.char", {
  cmd = "x X s S C D r{c} ~ R", rank = 1, budget = "<100 ms",
  expect = "Character edits act on characters, with counts; at a line end x deletes backwards (X) only with 'whichwrap'; r with a count replaces N chars.",
  cases = { "x", "X", "5x", "3X", "sfoo<Esc>", "Sfoo<Esc>", "Cfoo<Esc>", "D", "3D", "rZ", "3rZ", "~", "5~", "$x", "$X", "0X", "$s!<Esc>", "xxxx", "Rabc<Esc>", "3Rab<Esc>" },
  rand = { n = 16, len = { 1, 4 }, pool = { "x", "X", "3x", "rZ", "~", "3~", "D", "l", "h", "w", "j", "$", "0", "." } },
})
ops("opr.put", {
  cmd = "p P gp gP ]p [p with registers and counts", rank = 2, budget = "<300 ms for window-sized text",
  expect = "Put the register after/before the cursor; linewise puts go on the next/previous line; counts repeat; the cursor ends as in Vim.",
  cases = { "ywp", "ywP", "yyp", "yyP", "3yyp", "yyjp", "yw3p", "ddp", "ddP", "xp", "yyGp", "yy50jp", "yw$p", "yiwwP", "yy2gp", "yy2gP", "\"ayw\"ap", "\"ayy\"aP", "yy]p", "\"byy\"bp\"bp" },
  rand = { n = 10, len = { 2, 4 }, pool = { "yw", "yy", "dd", "dw", "p", "P", "j", "k", "3p", "gp", "x", "w", "50j" } },
})
ops("opr.dot", {
  cmd = ". repeat (with counts, after insert, after visual)", rank = 2, budget = "<300 ms",
  expect = "Repeat the last change at the cursor, also across window/slice moves and after a motion by many lines.",
  cases = { "dw.", "dw..", "dw3.", "3dw.", "x.", "xx..", "ihi<Esc>.", "ihi<Esc>j.", "Ahi<Esc>j.j.", "cwX<Esc>w.", "cwX<Esc>2w.", "vjd.", "dd.", "dd50j.", "J.", "~.", ">>.", "A;<Esc>j.j." },
  rand = { n = 10, len = { 2, 6 }, pool = { "dw", "x", "dd", ".", "j", "w", "cwX<Esc>", "A;<Esc>", "3.", "20j", "J", "~" } },
})
ops("opr.macro", {
  cmd = "qa ... q @a @@ {N}@a (recording and playing)", rank = 3, budget = "<1 s for {N} = 100 on window-sized steps",
  expect = "Macros play any of the commands in this table, also past the end of the window (a failing motion aborts the macro).",
  spec = { regs = { "a", "b", '"' }, text = true },
  cases = { "qaA;<Esc>jq3@a", "qaxjq5@a", "qadwjq@a@@", "qa0f,r;jq10@a", "qaddq@a", "qa0wcwX<Esc>jq20@a", "qaA;<Esc>jq1000@a", "qa3wxq@a", "qqxq@q" },
})
ops("opr.registers", {
  cmd = "\"ayy \"Ayy \"_d \"0 \"1-\"9 \"- \". \": \"/ \"% <C-r>{reg} (named, numbered, small delete)", rank = 2, budget = "<100 ms",
  expect = "A yank sets \"0; a delete of a line or more shifts \"1-\"9; a small delete goes to \"-; named registers append with uppercase.",
  spec = { regs = { '"', "0", "1", "2", "3", "-", "a", "b", "/", "." }, text = true },
  cases = { "yy", "dd", "ddddyy", "dw", "\"ayy\"Ayy", "\"ayw\"Ayw", "\"_dd", "dwddyw", "yyjddp", "d3wd2ddd", "\"ayy5j\"byy", "ihi<Esc>", "/{W}<CR>" },
})
ops("opr.bigyank", {
  cmd = "y{N}j y} yG yank large ranges into a register", rank = 3, budget = "<2 s for 100k lines; a range over edit_warn goes to a temp file instead (see scale.yank.*)",
  expect = "The register holds exactly the yanked text; a range larger than memory is refused cleanly or kept on disk, never truncated silently.",
  spec = { regs = { '"', "0" } },
  cases = { "y1000j", "y5000j", "yG", "y}", "yy1000j", "ygg", "y100000j", "\"ay2000j", "\"Ay2000j\"ap" },
})
ops("opr.join", {
  cmd = "J gJ {N}J (and joins of a long line with the next)", rank = 3, applies = "many", budget = "<100 ms",
  expect = "Join lines with one space (J) or none (gJ); N lines; trailing/leading whitespace rules as in Vim.",
  cases = { "J", "gJ", "3J", "5gJ", "JJJ", "$J", "VjjJ", "Vjjj gJ" },
})
ops("opr.incr", {
  cmd = "<C-a> <C-x> {N}<C-a> g<C-a> (numbers in logs)", rank = 3, budget = "<100 ms",
  expect = "Find the next number on the line at or after the cursor and add/subtract N (hex, binary and signs per 'nrformats').",
  cases = { "<C-a>", "<C-x>", "5<C-a>", "100<C-x>", "w<C-a>", "$<C-a>", "f=<C-a>", "Vj<C-a>", "VG<C-a>", "Vjjg<C-a>" },
})

---------------------------------------------------------------------------------------------------
-- Text objects
---------------------------------------------------------------------------------------------------

ops("txo.word", {
  cmd = "iw aw iW aW (with d y c v and counts)", rank = 1, budget = "<100 ms",
  expect = "The word under the cursor with or without surrounding blanks; boundaries work across slice cuts.",
  cases = { "diw", "daw", "diW", "daW", "d3aw", "ciwX<Esc>", "yiw", "yaw", "viwd", "vawd", "viwiwiwd", "wdiw", "ldaw", "$daw", "$diw", "0daW" },
  at = "inside",
  rand = { n = 10, len = { 1, 1 }, glue = true, pre = { "d", "y", "c", "v" }, pool = { "iw", "aw", "iW", "aW", "2iw", "3aw" }, post = { "" } },
})
ops("txo.sentence", {
  cmd = "is as ip ap", rank = 4, many = { "prose", "log" }, one = { "words" }, budget = "<200 ms",
  expect = "A sentence/paragraph with or without trailing white space/blank lines.",
  cases = { "dis", "das", "dip", "dap", "yis", "yap", "d2ap", "vipd", "vapd", "cipX<Esc>" },
  at = "inside",
})
ops("txo.brackets", {
  cmd = "i( a( ib ab i{ a{ iB aB i[ a[ i< a<", rank = 1, many = JSON_MANY, one = { "min_json" }, budget = "<200 ms; the object may be MBs; unbounded ones are memory-bounded and cancellable",
  expect = "The text inside/around the innermost enclosing pair (counts select outer pairs); works in pretty and minified JSON where the pair spans many MB.",
  cases = { "di{", "da{", "di[", "da[", "ci{X<Esc>", "yi{", "ya{", "d2i{", "d3a[", "vi{d", "va{d", "di(", "da(", "dib", "dab", "diB", "daB", "di<", "da<", "f:di{", "f[di[", "f}di{", "f{da{" },
  at = "inside",
  rand = { n = 12, len = { 1, 2 }, pre = { "d", "y", "v" }, pool = { "i{", "a{", "i[", "a[", "2i{", "i(", "a(", "ib", "iB", "f{", "f[", "f:", "fa" } },
})
ops("txo.quotes", {
  cmd = "i\" a\" i' a' i` a`", rank = 1, many = JSON_MANY, one = { "min_json" }, budget = "<100 ms (a quoted string is one line, may be long)",
  expect = "Text inside/around the quotes on the current line; backslash-escaped quotes do not end the string; the cursor may be before the first quote.",
  cases = { "di\"", "da\"", "ci\"X<Esc>", "yi\"", "vi\"d", "va\"d", "f:di\"", "di'", "da'", "di`", "0di\"", "$di\"", "f\"di\"", "f\\di\"", "2di\"" },
  at = "inside",
  rand = { n = 10, len = { 1, 2 }, pre = { "d", "y", "c" }, glue = true, pool = { "i\"", "a\"", "i'", "a'", "i`", "2i\"" } },
})
ops("txo.tag", {
  cmd = "it at", rank = 5, many = { "log" }, one = {}, applies = "many", budget = "<200 ms",
  expect = "Inner/around the innermost tag block.",
  cases = { "dit", "dat", "vitd" },
  scope = "yes",
})

---------------------------------------------------------------------------------------------------
-- Insert mode, undo, ex ranges, substitute (edit class)
---------------------------------------------------------------------------------------------------

edit("ins.open", {
  cmd = "i a I A o O gi gI with typed text", rank = 1, budget = "<50 ms per key, any file size, at any slice edge",
  expect = "Typing inserts at the exact position; the file bytes after saving equal what Vim would write; at a slice edge no byte is lost or duplicated.",
  at = "edge",
  cases = { "ihello<Esc>", "ahello<Esc>", "Ihello<Esc>", "Ahello<Esc>", "ohello<Esc>", "Ohello<Esc>", "3ihi<Esc>", "gIhi<Esc>", "jgihi<Esc>", "A\195\169\230\188\162<Esc>", "i<CR><Esc>", "A<CR>x<Esc>" },
  rand = { n = 12, len = { 1, 3 }, pool = { "ihi<Esc>", "A;<Esc>", "ox<Esc>", "Ox<Esc>", "I#<Esc>", "j", "k", "w", "5l", "$", "0" } },
})
edit("ins.keys", {
  cmd = "<BS> <Del> <C-w> <C-u> <C-h> <CR> <Tab> <C-t> <C-d> in insert mode", rank = 2, budget = "<50 ms per key",
  expect = "Editing keys work on text on both sides of the window's seams; <C-w>/<C-u> never delete past the insert start unless backspace allows; <BS> at column 1 joins lines.",
  at = "edge",
  cases = { "Afoo<BS><BS>x<Esc>", "A foo bar<C-w>x<Esc>", "A foo bar<C-u>x<Esc>", "i<BS><Esc>", "0i<BS>x<Esc>", "A<CR>new<Esc>", "A<Tab>x<Esc>", "i<Del><Esc>", "A<C-t>x<Esc>", "I<C-d>x<Esc>", "ix<C-h><C-h><C-h><Esc>", "jI<BS>x<Esc>" },
})
edit("ins.ctrl", {
  cmd = "<C-o> <C-r>{reg} <C-v>{code} <C-k> <C-a> <C-@> <C-y> <C-e> <C-n> (completion off)", rank = 4, budget = "<50 ms",
  expect = "Same effect as in Vim; keyword completion (<C-n> <C-p> <C-x>) is not offered/needed in the viewer (it would scan the file) and must not hang.",
  at = "edge",
  cases = { "A<C-o>0x<Esc>", "yiwA <C-r>\"<Esc>", "A<C-v>065<Esc>", "A<C-v>u00e9<Esc>", "A<C-k>e:<Esc>", "ihi<Esc>o<C-a><Esc>", "jA<C-y><Esc>", "kA<C-e><Esc>", "A<C-r>=1+2<CR><Esc>" },
})
edit("und.basic", {
  cmd = "u <C-r> U g- g+ {N}u :undo N :earlier :later", rank = 1, budget = "<100 ms",
  expect = "Undo/redo restore exact text and move the cursor to the change; counts undo N changes; U undoes the latest changes on one line.",
  cases = { "xu", "xxxuu", "xxxuu<C-r>", "dwu", "dwjdwuu<C-r><C-r>", "ddu", "3ddu", "ihi<Esc>u", "xxxU", "xxxUU", "xxxg-g-", "xxxg-g-g+", "xxx2u", "x:undo 0<CR>", "xxx:earlier 1<CR>", "xx:earlier 1<CR>:later 1<CR>" },
  rand = { n = 12, len = { 3, 8 }, pool = { "x", "dw", "dd", "u", "<C-r>", "ihi<Esc>", "j", "k", "w", "p", "U" } },
})
edit("und.across", {
  cmd = "undo/redo after moving the window or slice away from the change", rank = 1, budget = "<300 ms",
  expect = "u brings the changed place back into view with the cursor on it, exactly as Vim does (cursor offset equal), even if the change was hundreds of MB away; redo likewise.",
  at = "edge",
  cases = { "xGu", "xGgguu<C-r>", "dd100jddgguu", "dd100jddggu<C-r>", "ihi<Esc>500jx5000jxuuu", "x500j50kxuu<C-r><C-r>", "A;<Esc>300jA;<Esc>ggu", "dw3000jdwuu" },
})
edit("exr.ranges", {
  cmd = ":100,200d :.,+10y :'a,'bd :5,10> :%y :$d :1,3j :2,4m0 :t. :.,$d :%d", rank = 2, applies = "many", budget = "<2 s for 100k lines; whole-file ranges stream",
  expect = "A line range names real file lines; the command acts on exactly them; % means the whole file, never just the visible window.",
  scope = "limits: whole-file and huge ranges stream or are refused loudly, never applied to the window only",
  cases = { ":100,110d<CR>", ":.,+10y<CR>", ":.,+10d<CR>", ":5,10>3<CR>", ":$d<CR>", ":1,3j<CR>", ":2,4m0<CR>", ":2,4t.<CR>", ":.,$d<CR>", ":%y<CR>", ":%d<CR>", ":100,400y a<CR>", ":'a,'bd<CR>", "ma10jmb:'a,'bd<CR>", ":300,310w! /dev/null<CR>:1,5d<CR>", ":50,60normal Ax<CR>", ":%normal Ax<CR>", ":%j<CR>", ":2000,2100y<CR>:$put<CR>" },
})
edit("sub.s", {
  cmd = ":s/pat/rep/[flags] on a line and on ranges (:%s, :.,+9s, & g& :&& :~)", rank = 1, budget = "<1 s per 100 MB scanned; a single line is rewritten in a streaming pass",
  expect = "Vim regex semantics with flags g i I e n and backrefs; counts and the cursor end as in Vim; & repeats on the line.",
  scope = "limits: regex subset on huge ranges; '\\n' and multi-line patterns on huge ranges refused",
  cases = { ":s/{W}/X/<CR>", ":s/{W}/X/g<CR>", ":%s/{W}/X/g<CR>", ":.,+9s/e/E/g<CR>", ":%s/\\<{W}\\>/<&>/g<CR>", ":s/\\(a\\)\\(b\\)/\\2\\1/g<CR>", ":s/a\\+/-/g<CR>", "&", "g&", ":s/e/E/<CR>j&", ":s/e/E/<CR>j:&&<CR>", ":%s/e/E/gn<CR>", ":s/{W}//e<CR>", ":%s/e$//e<CR>", ":%s/^/> /<CR>", ":%s/\\s\\+$//e<CR>" },
})
edit("sub.g", {
  cmd = ":g/pat/d :g/pat/normal ... :v/pat/d :g/pat/s//x/ :g/pat/m0 :g/pat/t.", rank = 2, applies = "many", budget = "<1 s per 100 MB scanned",
  expect = "Run an ex command on every matching line of the file (:g/ERROR/d, :v/ERROR/d keep only matches); marks by line, so deletes do not shift targets.",
  scope = "limits: d, y/yank into a register, s, normal, w >> file; other commands streaming-refused",
  cases = { ":g/{W}/d<CR>", ":v/{W}/d<CR>", ":g/ERROR/d<CR>", ":v/ERROR/d<CR>", ":g/WARN/normal Ax<CR>", ":g/svc\\[1/s/req/REQ/<CR>", ":g/^$/d<CR>", ":g/ERROR/y A<CR>", ":g/ERROR/t.<CR>", ":g!/INFO/d<CR>" },
})

---------------------------------------------------------------------------------------------------
-- Search (async in the viewer)
---------------------------------------------------------------------------------------------------

row("sea.fwd", {
  chk = "search", cmd = "/pat ?pat n N {N}n {N}/pat (literal text)", rank = 1,
  budget = "near match <200 ms; absent pattern: GB/s scan, progress shown, cancellable (scale.sea.*)",
  expect = "The cursor lands on the first byte of the match after/before the cursor; n/N repeat in the same/opposite direction; wraps around (wrapscan) with a message; no match: cursor stays.",
  cases = { "/{W}<CR>", "?{W}<CR>", "/{W}<CR>n", "/{W}<CR>nn", "/{W}<CR>nN", "?{W}<CR>nn", "/{W}<CR>3n", "2/{W}<CR>", "/ZZZZ<CR>", "?ZZZZ<CR>", "/{W}<CR>/{W}<CR>", "G/{W}<CR>", "G?{W}<CR>", "/ <CR>", "/e<CR>nnn", "$/{W}<CR>", "$?{W}<CR>" },
  rand = { n = 14, len = { 1, 4 }, pool = { "/{W}<CR>", "?{W}<CR>", "n", "N", "2n", "j", "w", "G", "gg", "20j" } },
})
row("sea.offset", {
  chk = "search", cmd = "/pat/e /pat/e+1 /pat/b-1 /pat/+2 /pat/;/pat2/ ?pat?e", rank = 4,
  budget = "as sea.fwd",
  expect = "Search offsets move the landing position from the match start/end or by lines; ; chains searches.",
  scope = "limits: byte offsets b/e/s and line offsets; ; chains",
  cases = { "/{W}/e<CR>", "/{W}/e+1<CR>", "/{W}/e-1<CR>", "/{W}/b+1<CR>", "/{W}/+1<CR>", "/{W}/-1<CR>", "/{W}/;/{W}/<CR>", "?{W}?e<CR>", "/{W}/e<CR>n", "/{W}/s+2<CR>" },
})
row("sea.star", {
  chk = "search", cmd = "* # g* g# (word under the cursor)", rank = 2,
  budget = "as sea.fwd",
  expect = "Search for the keyword under the cursor as a whole word (* #) or a part (g* g#); the cursor lands on the next/previous match; n/N continue.",
  cases = { "*", "#", "g*", "g#", "**", "*N", "#n", "w*", "3*", "wwg*n", "$*", "$#" },
  rand = { n = 10, len = { 1, 4 }, pool = { "*", "#", "g*", "g#", "n", "N", "w", "j" } },
})
row("sea.regex", {
  chk = "search", cmd = "/\\vfoo|bar /\\<word\\> /a.*b /\\d\\+ /\\cfoo /^pat /pat$", rank = 2,
  budget = "as sea.fwd; no catastrophic backtracking on a GB line (match length is bounded)",
  expect = "Vim regex search: classes, anchors, alternation, ignorecase, whole word.",
  scope = "limits: regex with bounded match length across blocks; backrefs and lookbehind refused",
  cases = { "/\\<{W}\\>/<CR>", "/\\v(e|a)t<CR>", "/\\d\\+<CR>", "/\\cWARN<CR>", "/^2026<CR>", "/status=200$<CR>", "/a.*b<CR>", "/[0-9]\\{3}<CR>", "/\\(ka\\|to\\)\\+<CR>", "/\\%>5l{W}<CR>" },
})
row("sea.options", {
  chk = "search", cmd = ":set ignorecase smartcase wrapscan hlsearch incsearch", rank = 4,
  budget = "as sea.fwd", expect = "The options change what / ? n N match as in Vim.",
  scope = "limits: ignorecase and smartcase; wrapscan; hlsearch only for the window",
  cases = { ":set ic<CR>/WARN<CR>", ":set ic scs<CR>/warn<CR>", ":set ic scs<CR>/Warn<CR>", ":set nows<CR>G/{W}<CR>", ":set nows<CR>G?{W}<CR>nn", ":set nows<CR>/{W}<CR>nnnn" },
})
row("sea.operator", {
  chk = "search", cmd = "d/pat y/pat c/pat v/pat then an operator; d/pat/e", rank = 3,
  budget = "as sea.fwd plus the edit", spec = { regs = REGS, text = true },
  expect = "A search is a motion: the operator acts from the cursor to the match start (exclusive) or end (with /e), across any distance.",
  cases = { "d/{W}<CR>", "y/{W}<CR>", "c/{W}<CR>X<Esc>", "v/{W}<CR>d", "d/{W}/e<CR>", "d?{W}<CR>", "dn", "d/{W}<CR>.", "y/{W}<CR>P" },
})
row("sea.visual", {
  chk = "search", cmd = "search extends a visual selection", rank = 4,
  budget = "as sea.fwd", spec = { regs = REGS, text = true },
  expect = "In visual mode / extends the selection to the match.",
  cases = { "v/{W}<CR>y", "V/{W}<CR>y", "v?{W}<CR>y", "v/{W}<CR>nd", "vnd" },
})

---------------------------------------------------------------------------------------------------
-- Text encodings and line ends (the file bytes must survive an edit)
---------------------------------------------------------------------------------------------------

edit("uni.multibyte", {
  cmd = "motions and edits on multibyte text: accents, CJK (wide), emoji, combining marks", rank = 2, applies = "many",
  many = { "multibyte" }, budget = "<100 ms",
  expect = "Cursor steps over whole characters (a base character with its combining marks is one); cuts of long lines never split a character; x r ~ cw act on whole characters.",
  cases = { "l", "5l", "$h", "wwwx", "rZ", "~", "xp", "dw", "cw\195\169<Esc>", "A\195\169<Esc>", "5lx", "vey", "fe;x", "$x", "vlld", "3~", "yl$p" },
  rand = { n = 12, len = { 1, 5 }, pool = { "l", "h", "w", "b", "e", "x", "~", "rZ", "j", "k", "$", "0", "dw", "yl", "p", "u" } },
})
edit("uni.invalid", {
  cmd = "invalid UTF-8 bytes (0xFF, overlongs, surrogates, stray continuation) in text", rank = 3, applies = "many",
  many = { "invalid" }, budget = "<100 ms",
  expect = "Navigation and editing never fail on invalid bytes; saving leaves every untouched byte as it was (no replacement characters).",
  cases = { "x", "5lx", "$x", "A!<Esc>", "dd", "w", "jx", "rZ", "~", "ddp", "J", "yyp", "fx;x", "3wD" },
  rand = { n = 10, len = { 1, 4 }, pool = { "l", "w", "b", "x", "dd", "j", "k", "$", "rZ", "p", "u" } },
})
edit("uni.crlf", {
  cmd = "CRLF files: $ A x J dd o yyp :s", rank = 1, applies = "many", many = { "crlf" }, budget = "<100 ms",
  expect = "The CR is part of the line end, never the text: $ is on the last visible character, J and dd keep the other lines CRLF, new lines get CRLF; the saved bytes keep CRLF everywhere.",
  cases = { "$x", "A;<Esc>", "x", "J", "dd", "o<Esc>", "Ofoo<Esc>", "ddp", "yyp", "5J", "$a!<Esc>", ":s/e/E/<CR>", ":%s/e$//e<CR>", "3dd", "Gdd", "GA!<Esc>", "ggddGp" },
  rand = { n = 10, len = { 1, 4 }, pool = { "x", "dd", "J", "A;<Esc>", "o<Esc>", "j", "k", "$", "p", "u", "yy" } },
})
edit("uni.mixed", {
  cmd = "mixed LF, CRLF and lone CR line ends", rank = 4, applies = "many", many = { "mixed_eol" }, budget = "<100 ms",
  expect = "Each line keeps its own end on save, except those that Vim itself changes (a CR alone is text in Vim).",
  cases = { "x", "dd", "J", "A;<Esc>", "yyp", "ddjp", "$x", "3x", "jjdd", "Gdd", "Gp" },
})
edit("uni.nul", {
  cmd = "NUL bytes inside lines", rank = 4, applies = "many", many = { "nul" }, budget = "<100 ms",
  expect = "NUL is shown as ^@ and edits keep it as NUL (Vim stores it as NL in memory and writes it back as NUL).",
  cases = { "x", "$x", "dd", "l", "fx", "wx", "A!<Esc>", "yyp", "jdd" },
})
edit("uni.nonl", {
  cmd = "no newline at the end of the file: G o A x dd yyp P", rank = 2, applies = "many", many = { "nonl" }, budget = "<100 ms",
  expect = "The missing final newline stays missing unless the edit adds a line after it (as with 'nofixeol'); dd on the last line removes it cleanly.",
  cases = { "Gx", "GA!<Esc>", "Gdd", "Go<Esc>", "GddP", "GyyP", "Gyyp", "G$x", "ggJ", "G:s/last/LAST/<CR>", "GddGp", "Gdd:$<CR>x" },
})

---------------------------------------------------------------------------------------------------
-- Hand-written probes (chk = misc): save/quit states, folds, display, splits, takeover, cancel
---------------------------------------------------------------------------------------------------

row("fld.off", {
  chk = "misc", cmd = "zf zF zo zc za zR zM zd zE [z ]z zj zk :fold", rank = 4, budget = "<50 ms",
  expect = "Folds are off in the viewer: a fold made of window lines would hide lines that the file does not group; the commands do nothing.",
  scope = "no: folding is forced off",
})
row("dsp.opts", {
  chk = "misc", cmd = "'wrap' 'list' 'conceallevel' 'spell' 'number' 'foldenable' in the viewer window", rank = 3, budget = "n/a",
  expect = "nowrap (a 1 GB line must not be laid out), nolist, no conceal, no spell, no line numbers (window rows are not file lines), no folds.",
})
row("dsp.longline", {
  chk = "misc", cmd = "display of a very long line; :set list; $ 0", rank = 2, budget = "<1.5 s for $ and 0 with 'list' set",
  expect = "A line longer than the cap is shown cut with a marker; the cut never splits a character; no option makes Neovim lay out the whole line.",
})
row("dsp.unicode", {
  chk = "misc", cmd = "wide, combining and emoji text is shown exactly", rank = 3, budget = "n/a",
  expect = "Lines that fit the cap are shown byte for byte.",
})
row("win.split", {
  chk = "misc", cmd = ":split :vsplit <C-w>s <C-w>v then keys in either window, :q", rank = 3, budget = "<100 ms",
  expect = "Decision: splits of the viewer buffer are allowed and show the same slice (one offset per buffer); no error, the other window stays valid after one closes. Independent scrolling per window is out of scope: start a second Neovim on the file.",
  scope = "limits: both windows show the same slice",
})
row("wri.w", {
  chk = "misc", cmd = ":w :write", rank = 1, budget = "streams at disk speed; <3 s per 100 MB",
  expect = "Writes the logical text atomically (temp file and rename); no temp file is left; the file mode is kept.",
})
row("wri.wq", { chk = "misc", cmd = ":wq :wq!", rank = 1, budget = "as :w", expect = "Writes, then quits with status 0." })
row("wri.x", { chk = "misc", cmd = ":x :exit", rank = 3, budget = "as :w", expect = "Writes only when modified, then quits; an unmodified file is not touched." })
row("wri.ZZ", { chk = "misc", cmd = "ZZ", rank = 2, budget = "as :w", expect = "Same as :x." })
row("wri.qbang", { chk = "misc", cmd = ":q! ZQ :qa!", rank = 2, budget = "<1 s", expect = "Quits at once and discards the edits; the file is untouched." })
row("wri.q_modified", { chk = "misc", cmd = ":q :quit with unsaved edits", rank = 1, budget = "<100 ms", expect = "Refuses with E37, stays open, file untouched." })
row("wri.update", { chk = "misc", cmd = ":update :up", rank = 4, budget = "as :w", expect = "Writes only if modified." })
row("wri.saveas", {
  chk = "misc", cmd = ":w other :w! other :saveas", rank = 2, budget = "as :w",
  expect = "Writes the logical text to a new file; an existing file needs !; the original is untouched.",
})
row("wri.range", {
  chk = "misc", cmd = ":100,200w out  :.,+99w >> out  :'a,'bw out", rank = 2, budget = "<2 s for 1M lines",
  expect = "Writes exactly the named file lines (not the window) to another file: the way to cut a piece out of a huge log.",
  scope = "limits: whole-file line numbers need an index or a scan (cancellable)",
})
row("wri.perm", {
  chk = "misc", cmd = ":w on a read-only file", rank = 3, budget = "<100 ms",
  expect = "Refuses like Vim (E45) unless !; the file is not replaced by a rename over it.",
})
row("wri.symlink", {
  chk = "misc", cmd = ":w on a file opened through a symlink", rank = 3, budget = "as :w",
  expect = "The target file is rewritten and the link stays a link.",
})
row("rob.takeover.argv", {
  chk = "misc", cmd = "nvim hugefile", rank = 1, budget = "<500 ms to the first screen",
  expect = "A file above the size threshold opens in the viewer instead of being read.",
})
row("rob.takeover.edit", { chk = "misc", cmd = ":e hugefile", rank = 1, budget = "<500 ms", expect = "Same, from inside Neovim." })
row("rob.takeover.split", {
  chk = "misc", cmd = ":sp hugefile :badd :b :vs", rank = 2, budget = "<500 ms",
  expect = "Same for every way a buffer for the file is made; a small file still opens normally.",
})
row("rob.truncate", {
  chk = "misc", cmd = "the file shrinks under the open viewer", rank = 3, budget = "<100 ms per key",
  expect = "No Lua error on any key; the window shows what is still there; saving is refused or warns that the file changed.",
})
row("rob.deleted", { chk = "misc", cmd = "the file is deleted under the open viewer", rank = 4, budget = "<100 ms", expect = "No error; the open file stays readable; :w recreates it or refuses cleanly." })
row("rob.empty", { chk = "misc", cmd = "an empty file with every key", rank = 3, budget = "<100 ms", expect = "No error from any command." })
row("rob.dir", { chk = "misc", cmd = ":StreamView directory", rank = 5, budget = "<100 ms", expect = "An error message, nothing else." })
row("can.search", {
  chk = "misc", cmd = "<C-c> during / (a scan with no match)", rank = 1, budget = "stops in <1.5 s",
  expect = "The scan stops, the cursor stays, 'Search cancelled' is shown; the editor is responsive throughout.",
})
row("can.search_back", { chk = "misc", cmd = "<C-c> during ?", rank = 2, budget = "<1.5 s", expect = "As above." })
row("can.again", { chk = "misc", cmd = "a new search right after a cancel", rank = 2, budget = "as the search", expect = "Works and lands exactly." })
row("can.quit", {
  chk = "misc", cmd = ":qa! while a scan runs", rank = 2, budget = "<1 s",
  expect = "Neovim exits at once with status 0; no job outlives it.",
})
row("x.follow", {
  chk = "misc", cmd = ":StreamFollow (tail -f)", rank = 2, budget = "<1 s from append to display",
  expect = "New data at the end of the file appears and the window follows; any motion stops it.",
})
row("x.fileinfo", {
  chk = "misc", cmd = "<C-g> g<C-g> the winbar: where am I", rank = 3, budget = "n/a",
  expect = "The byte offset, the size and the percentage are shown (line numbers are not known).",
  scope = "limits: byte offset instead of line number",
})
row("x.reload", { chk = "misc", cmd = ":e! :checktime", rank = 3, budget = "<100 ms", expect = "Re-reads the state of the file without error; the end of a grown file is reachable." })
row("ins.completion", {
  chk = "misc", cmd = "<C-n> <C-p> <C-x><C-l> in insert mode", rank = 4, budget = "<2 s",
  expect = "Completion is off or bounded: it must not scan the whole file or hang.",
  scope = "limits: completion is off",
})

---------------------------------------------------------------------------------------------------
-- Scale probes (chk = scale): the time budget and peak memory on planted huge files
---------------------------------------------------------------------------------------------------

local function scale(id, cmd, expect, budget, rank, extra)
  local o = { chk = "scale", owner = id:find("search") and "search" or "navigation", cmd = cmd, expect = expect, budget = budget, rank = rank, scope = "yes", applies = id:find("^scale1") and "one" or "many" }
  for k, v in pairs(extra or {}) do
    o[k] = v
  end
  row(id, o)
end

scale("scale.G", "G on 64 MB / 2 GB of short lines", "Last line, exact.", "1 s / 3 s", 1)
scale("scale.gg", "G then gg", "Back to byte 0.", "1 s / 3 s", 1)
scale("scale.NG", "{N}G for N in the millions", "Line N, exact (needs a line index or a scan).", "3 s / 30 s", 1)
scale("scale.colon", ":{N}", "As {N}G.", "3 s / 30 s", 1)
scale("scale.dollar", ":$", "Last line.", "1 s / 3 s", 2)
scale("scale.pct", "50%", "The middle of the file (+-1 percent).", "1 s / 3 s", 2)
scale("scale.go", "{B}go", "Byte B exactly.", "1 s / 3 s", 3)
scale("scale.jN", "100000j", "100000 lines down, exact, not a per-line loop in Lua.", "5 s / 15 s", 1)
scale("scale.kN", "G then 100000k", "100000 lines up from the end.", "5 s / 15 s", 2)
scale("scale.pages", "200 times <C-f>", "200 pages down, each as in Vim.", "5 s / 8 s", 1)
scale("scale.search", "/{literal} for a number near the end", "Exact landing; progress shown; memory flat.", "5 s / 60 s", 1)
scale("scale.search_back", "G then ?{literal}", "Exact landing backwards.", "5 s / 60 s", 2)
scale("scale.paragraph", "} in a file without blank lines", "Last character of the file (a scan to the end).", "5 s / 60 s", 3)
scale("scale.paragraph_back", "G then {", "First line.", "5 s / 60 s", 3)
scale("scale.yank", "y100000j", "The register holds exactly the 100001 lines.", "3 s / 10 s", 3)
scale("scale.edit", "{N}G then ihi<Esc>", "The edit is held as a piece (size +2); memory flat.", "3 s / 10 s", 1)
scale("scale1.dollar", "$ in a 64 MB / 1 GB single line", "Last character of the line.", "1 s / 3 s", 1)
scale("scale1.zero", "$ then 0", "Back at byte 0.", "1 s / 3 s", 1)
scale("scale1.bigl", "{K}l (K = 30 MB / 500 MB)", "Byte K exactly.", "2 s / 6 s", 1)
scale("scale1.fq", "fQ for a char 40 MB away", "Lands on it.", "3 s / 10 s", 1)
scale("scale1.fq_repeat", "fQ;", "The second Q.", "3 s / 10 s", 2)
scale("scale1.Fq", "$ then FQ", "The last Q.", "3 s / 10 s", 2)
scale("scale1.pct", "% from a ( whose ) is 49 MB / 850 MB away", "Lands on the ), memory-bounded.", "5 s / 60 s", 1)
scale("scale1.pct_back", "% twice", "Back on the (.", "10 s / 120 s", 2)
scale("scale1.unmatched", "% on a ( that never closes", "Cursor stays; bounded scan.", "5 s / 60 s", 2)
scale("scale1.search", "/MARKER42", "Exact landing.", "3 s / 30 s", 1)
scale("scale1.search_back", "$ then ?MARKER42", "Exact landing backwards.", "3 s / 30 s", 2)
scale("scale1.go", "{K}go", "Byte K exactly in the middle of the line.", "1 s / 3 s", 3)
scale("scale1.gg_G", "{K}l then G", "G on a single line stays in its column (nostartofline).", "1 s / 3 s", 2)
scale("scale1.xdel", "{K}l then x", "Deletes one byte (size -1), memory flat.", "2 s / 6 s", 2)
scale("scale1.w", "1000000w (64 MB only)", "One million words on, 3 bytes each.", "3 s", 2)
scale("scale1.e", "1000000e (64 MB only)", "One million word ends on.", "3 s", 3)
scale("scale1.yank", "{K}l then y$ (64 MB only)", "The register holds the 8 MB tail exactly.", "3 s", 3)
scale("scale.cancel", "<C-c> during a scan of a 2 GB file (2 GB only)", "Stops in 1.5 s, cursor unchanged, memory flat.", "1.5 s", 1)

---------------------------------------------------------------------------------------------------
-- Documented only
---------------------------------------------------------------------------------------------------

local function doc(id, cmd, expect, scope, rank)
  row(id, { chk = "doc", cmd = cmd, expect = expect, scope = scope, rank = rank, applies = "both", budget = "n/a" })
end

doc("x.filter", ":%!jq . / :{range}!cmd / !{motion}", "Pipe a range through a shell command and replace it.", "no: needs the whole range in memory; use jq/sed on the file, then reopen", 3)
doc("x.number", ":set number relativenumber", "Absolute / relative file line numbers in the margin.", "no: window rows are not file lines; the winbar shows the byte offset", 2)
doc("x.read", ":r file / :r !cmd", "Insert a file or command output at the cursor.", "limits: small inputs only (held as one piece)", 5)
doc("x.sort", ":sort :sort!", "Sort lines of a range.", "no: sorting a huge range is `sort` on the file", 5)
doc("x.clip", "\"+y \"+p <C-r>+ with huge text", "Clipboard registers.", "limits: bounded by the register size limit; larger yanks are refused", 3)
doc("x.multiwin", "independent views (different offsets) of one file in two windows", "Two windows scroll independently.", "no: one offset per buffer (see win.split); start a second Neovim", 3)
doc("x.tags", ":tag <C-]> K gd gf in a huge file", "Navigate by tags, definitions, filenames.", "limits: work on the window text only (gf, K); tags/LSP are not attached", 5)

return rows

-- Generates docs/streamview-motions.md and the first version of streammotions_status.lua from the
-- rows and a directory of JSON reports (STREAM_REPORT of a run of every streammotions check).
-- Usage: nvim -l tests/nvim/streammotions_doc.lua <report dir> <doc|status>
local dir, what = arg[1], arg[2]
local test_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
local rows = dofile(test_dir .. "/streammotions_rows.lua")

local report = {}
for name in vim.fs.dir(dir) do
  if name:match("%.json$") then
    local f = assert(io.open(dir .. "/" .. name, "rb"))
    for id, r in pairs(vim.json.decode(f:read("*a"))) do
      report[id] = r
    end
    f:close()
  end
end

local GROUP_WHY = {
  mot = "keys act on the window's own lines: counts, wanted column and line ends do not continue past the window or the cut segments of a long line",
  wrd = "word motions stop at the window edge and at a cut segment of a long line",
  fnd = "f/t search only the displayed (cut) part of the line",
  sen = "sentence, paragraph and section motions only see the window",
  mat = "% only sees the window; a pair beyond it is not found",
  scr = "window scrolling is replaced by line shifts that do not move the cursor as Vim does",
  jmp = "line numbers, byte offsets and G on a long line are not supported by the window model",
  mrk = "marks and the jumplist hold window rows, not absolute offsets",
  vis = "the selection lives in window rows and is lost when the window is redrawn",
  opr = "operators act on the window text only, not on the true range",
  txo = "text objects only see the window",
  ins = "edits at window and segment edges are not joined with the neighbouring text",
  und = "undo restores text but not the cursor place as Vim does",
  exr = "ex ranges and % act on the window rows, not file lines",
  sub = "ex substitute and :g act on the window only",
  sea = "the search is a literal scan that does not land on the match and has no offsets, regex or options",
  uni = "line ends and bytes outside the window model are not kept as Vim keeps them",
  fld = "folds are not forced off",
  wri = "the save path differs from Vim in this state",
  can = "scan cancel or quit behaves differently from the spec",
  rob = "the case is not handled",
  x = "not implemented",
  dsp = "option not forced",
  scale = "too slow, wrong, or a window-only answer at this size",
  scale1 = "single-line navigation at this size is not implemented",
}

local function reason(row, id, r)
  local why = GROUP_WHY[row.grp] or GROUP_WHY[row.id:match("^(%a+)")] or "differs from Vim"
  if row.chk == "scale" then why = GROUP_WHY[row.id:match("^(scale1?)")] end
  if id:find("@1$") then why = "a single line is cut into segments the motion cannot cross (" .. why .. ")" end
  if r.detail and r.detail:find("cannot place", 1, true) then why = why .. "; no way to put the cursor at an absolute byte offset" end
  return (string.format("audit row %s: %s", id, why):gsub('"', "'"))
end

local function find_row(id)
  local base = id:gsub("@1$", ""):gsub("@big$", "")
  for _, row in ipairs(rows) do
    if row.id == base then return row end
  end
end

if what == "status" then
  local ids = vim.tbl_keys(report)
  table.sort(ids)
  local out = {
    "-- Status of every streammotions test id: pass (default, may be left out), xfail (known to fail:",
    "-- reported as XFAIL, the check stays green) or skip (not run). An xfail that passes prints XPASS and",
    "-- fails the check with STREAM_STRICT=1: flip it to \"pass\" (or delete the line) when you fix it.",
    "-- Format: [\"id\"] = { status, owner area, one-line reason }",
    "return {",
  }
  for _, id in ipairs(ids) do
    local r, row = report[id], find_row(id)
    if row and not r.ok then
      out[#out + 1] = string.format('  ["%s"] = { "xfail", "%s", "%s" },', id, row.owner, reason(row, id, r))
    end
  end
  out[#out + 1] = "}"
  io.write(table.concat(out, "\n"), "\n")
  return
end

-- doc
local function today(id)
  local r = report[id]
  if not r then return nil end
  local c = r.counts
  if r.ok then return "ok" end
  if c and c.failed == c.total then return "unsupported" end
  if c and c.total > 1 then return string.format("partial (%d/%d)", c.total - c.failed, c.total) end
  return "wrong"
end

local function today_col(row)
  local parts = {}
  local a, b = today(row.id), today(row.id .. "@1")
  local big = today(row.id .. "@big")
  if row.chk == "scale" then
    parts[1] = a and ("64 MB " .. a) or nil
    parts[#parts + 1] = big and ("big " .. big) or nil
  elseif a and b then
    parts[1] = (a == b) and a or ("lines: " .. a .. "; one line: " .. b)
  else
    parts[1] = a or b
  end
  if #parts == 0 then return row.chk == "doc" and "n/a" or "not run" end
  return table.concat(parts, "; ")
end

local function esc(s) return (tostring(s):gsub("|", "\\|"):gsub("\n", " ")) end

local function ids_of(row)
  local ids = { row.id }
  if row.one and row.many then ids[#ids + 1] = row.id .. "@1" end
  if row.one and not row.many then ids = { row.id .. "@1" } end
  if row.chk == "scale" then ids = { row.id, row.id .. "@big" } end
  return table.concat(ids, ", ")
end

local counts = { ok = 0, partial = 0, unsupported = 0, wrong = 0, notrun = 0, doc = 0 }
local per_row = {}
for _, row in ipairs(rows) do
  local t = today_col(row)
  local kind
  if t == "n/a" then
    kind = "doc"
  elseif t == "not run" then
    kind = "notrun"
  else
    local good = t:find("ok") ~= nil
    local part = t:find("partial") ~= nil
    local bad = t:find("unsupported") ~= nil or t:find("wrong") ~= nil
    kind = (good and not part and not bad) and "ok" or (bad and not good and not part) and "unsupported" or "partial"
  end
  counts[kind] = counts[kind] + 1
  per_row[row] = { text = t, kind = kind }
end

local out = {}
local function w(s) out[#out + 1] = s end

w("# Stream viewer: motions and commands audit")
w("")
w("Generated by `tests/nvim/streammotions_doc.lua` from `tests/nvim/streammotions_rows.lua` and a run of the")
w("`streammotions-*` flake checks. Do not edit the tables by hand: change the rows, rerun the checks, regenerate.")
w("")
w("The viewer shows a window of lines of a file that does not fit in memory. A user of such a file (multi-GB")
w("logs, YAML, minified JSON on ONE line) types the same commands as in any file and expects Vim's result. Each")
w("row below is a class of commands, what Vim does, what the viewer does today (measured against the build this")
w("was generated from), whether it belongs in the viewer, and the test that pins it.")
w("")
w("## Reading the table")
w("")
w("- **Rank**: how likely a heavy log/JSON/YAML user types it. 1 = daily, 5 = rare. Implementers: do rank 1 and 2 first.")
w("- **Applies**: `many` = a huge file of many lines, `one` = a huge single line, `both`.")
w("- **Today**: `ok`, `partial (pass/total cases)`, `unsupported` (every case fails), `wrong` (a probe fails). Rows with a")
w("  single-line variant show both (`one line:`); the test id of that variant ends in `@1`; scale tests end in `@big` for 2 GB / 1 GB.")
w("- **Scope**: `yes`; `limits: ...` (in scope with a stated limit); `no: ...` (out of scope, with the reason).")
w("- **Test id**: the key in `tests/nvim/streammotions_status.lua` (`pass`, `xfail`, `skip`). Flip an id to `pass` when you fix it.")
w("")
w("## How the tests work")
w("")
w("- Differential rows (`chk` nav, txt, edit, search): the same keys run in a stock Neovim (`--clean`, the file loaded")
w("  whole) and in the viewer, in two child Neovims, from the same absolute byte offset, on files of a few MB. The viewer's")
w("  `block`, `slice`, `head` and `window_budget` are set to 1-256 KB (the defaults are 256 KB, 2 MB, 64 KB and 16 MB) so that every motion crosses block edges and the slice of a 1 MB line slides. Compared: absolute byte")
w("  offset of the cursor, mode, visual anchor, registers, marks, and for edits the whole resulting text (sha256).")
w("  Sequences are curated per row plus seeded random ones (`STREAM_SEED`, `STREAM_CASES` percent); a failure prints the")
w("  shrunk key sequence, file, start offset, configuration and seed.")
w("- Probes (`misc`, `scale`): hand-written checks of save/quit states, takeover, cancel, folds, display and the time and")
w("  peak memory budgets on planted 64 MB (and, in `streammotions-scale-huge`, 2 GB / 1 GB sparse) files.")
w("- Seams the tests use that the viewer keeps: `require('streamview').cursor_offset(S)` (absolute cursor byte),")
w("  `.place(S, byte)` (cursor to an absolute byte, waits for the scan), `S.job` non-nil while a scan or save runs,")
w("  `.render`, `.state`, `S.r:get`, `S.r.size`; `streamnav.lua` pins the first two. A visual anchor or a mark is read from")
w("  the rows (`S.entries[lnum].from` + the byte column).")
w("")
w("## Decisions")
w("")
w("- `:g`, `:s` and ex ranges on huge files: in scope as streaming passes for `d y s normal t w`; a command that cannot stream is refused with a message, never applied to the window only (`%` means the whole file).")
w("- Splits of the viewer buffer: allowed, both windows show the same slice (`win.split`). Independent views: out of scope.")
w("- Folds: forced off (`fld.off`). Line numbers: not shown, the winbar shows the byte offset (`x.number`, `x.fileinfo`).")
w("- `{N}%` is a byte percentage within 1 percent of Vim's line percentage (`jmp.pct`).")
w("- Insert-mode completion is off (`ins.completion`). Filters (`:%!cmd`) are out of scope.")
w("- A scan that can take long (search, `%`, `}` over GBs) runs in slices, shows progress, is cancelled with `<C-c>`, keeps memory bounded and never blocks the editor (`can.*`, `scale.*`).")
w("")
w("## Summary")
w("")
w(string.format("%d command classes: %d ok, %d partial, %d unsupported/wrong, %d documented only, %d not run.",
  #rows, counts.ok, counts.partial, counts.unsupported + counts.wrong, counts.doc, counts.notrun))
w("")
w("### Most likely used and not (fully) supported today")
w("")
w("| # | Rank | Command | Today | Test id |")
w("|---|---|---|---|---|")
local broken = {}
for _, row in ipairs(rows) do
  local k = per_row[row].kind
  if row.chk ~= "doc" and (k == "partial" or k == "unsupported" or k == "wrong") and not row.scope:find("^no") then broken[#broken + 1] = row end
end
table.sort(broken, function(a, b)
  if a.rank ~= b.rank then return a.rank < b.rank end
  return a.id < b.id
end)
for i = 1, math.min(15, #broken) do
  local row = broken[i]
  w(string.format("| %d | %d | `%s` | %s | %s |", i, row.rank, esc(row.cmd), esc(per_row[row].text), ids_of(row)))
end
w("")
w("## Matrix")
w("")
local groups = {
  { "mot", "Character and line motions" }, { "wrd", "Word motions" }, { "fnd", "f F t T ; ," }, { "sen", "Sentences, paragraphs, sections" },
  { "mat", "Bracket matching" }, { "scr", "Screen and scrolling" }, { "jmp", "Jumps in the file" }, { "mrk", "Marks, jumplist, changelist" },
  { "vis", "Visual mode" }, { "opr", "Operators, registers, repeat, macros" }, { "txo", "Text objects" }, { "ins", "Insert mode" },
  { "und", "Undo and redo" }, { "exr", "Ex ranges" }, { "sub", "Substitute and :g" }, { "sea", "Search" }, { "uni", "Encodings and line ends" },
  { "fld", "Folds" }, { "dsp", "Display" }, { "win", "Windows" }, { "wri", "Write and quit" }, { "rob", "Takeover and robustness" },
  { "can", "Cancel and quit while scanning" }, { "x", "Other things a log/JSON/YAML user does" }, { "scale", "Scale budgets" },
}
for _, g in ipairs(groups) do
  local any = false
  for _, row in ipairs(rows) do
    local grp = row.grp == "scale1" and "scale" or row.grp
    if grp == g[1] then
      if not any then
        any = true
        w("### " .. g[2])
        w("")
        w("| Rank | Command | Expected (Vim) | Applies | Today | Scope | Test id | Perf budget |")
        w("|---|---|---|---|---|---|---|---|")
      end
      w(string.format("| %d | `%s` | %s | %s | %s | %s | %s | %s |", row.rank, esc(row.cmd), esc(row.expect), row.applies,
        esc(per_row[row].text), esc(row.scope), ids_of(row), esc(row.budget or "")))
    end
  end
  if any then w("") end
end

io.write(table.concat(out, "\n"), "\n")

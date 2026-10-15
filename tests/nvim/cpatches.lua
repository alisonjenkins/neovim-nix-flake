-- Regression tests for the Neovim C patches applied in flake.nix (PRs on alisonjenkins/neovim). The expectations are computed here,
-- independently of Neovim, so the file passes on stock Neovim and on the patched build alike.
-- Each assertion sits next to a control that exercises the same path on small input.
local h = dofile(os.getenv("TEST_DIR") .. "/harness.lua")
local tmp = os.getenv("TMPDIR") or "/tmp"

local function slurp(path)
  local f = assert(io.open(path, "rb"))
  local data = f:read("*a")
  f:close()
  return data
end

local function spit(path, data)
  local f = assert(io.open(path, "wb"))
  f:write(data)
  f:close()
end

-- Fixed-seed PRNG (xorshift32) so a failure reproduces.
local function prng(seed)
  local state = seed
  return function(n)
    state = bit.bxor(state, bit.lshift(state, 13))
    state = bit.bxor(state, bit.rshift(state, 17))
    state = bit.bxor(state, bit.lshift(state, 5))
    state = bit.band(state, 0x7fffffff)
    return state % n + 1
  end
end

---------------------------------------------------------------------------------------------------
-- 0001: readfile() grows its line buffer in place
---------------------------------------------------------------------------------------------------

-- Split "data" on "\n" the way a unix-format read does. Returns lines and whether the last line
-- was terminated.
local function split_unix(data)
  local lines, pos = {}, 1
  while pos <= #data do
    local nl = data:find("\n", pos, true)
    if not nl then
      lines[#lines + 1] = data:sub(pos)
      return lines, false
    end
    lines[#lines + 1] = data:sub(pos, nl - 1)
    pos = nl + 1
  end
  return lines, true
end

-- Read "data" back through :edit and through :write; both must reproduce the source exactly.
local function check_roundtrip(name, data, opts)
  opts = opts or {}
  local src = tmp .. "/rt-src.txt"
  local dst = tmp .. "/rt-dst.txt"
  spit(src, data)
  vim.cmd("silent! %bwipeout!")
  vim.o.fileformats = opts.fileformats or "unix"
  vim.o.fixeol = false
  vim.cmd("silent edit " .. vim.fn.fnameescape(src))

  local expected, terminated = split_unix(data)
  if opts.dos then
    for i, l in ipairs(expected) do expected[i] = l:gsub("\r$", "") end
  end
  local got = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  if #data == 0 then expected = { "" } end
  local same = #got == #expected
  if same then
    for i = 1, #got do
      if got[i] ~= expected[i] then
        same = false
        h.check(false, name .. ": line " .. i .. " matches the source",
          string.format("got %d bytes, want %d bytes", #got[i], #expected[i]))
        break
      end
    end
  end
  h.check(same, name .. ": " .. #expected .. " lines read back", "got " .. #got .. " lines")
  h.check(vim.bo.endofline == terminated or #data == 0, name .. ": trailing newline state kept")
  if opts.dos then h.check(vim.bo.fileformat == "dos", name .. ": CRLF file detected as dos") end

  vim.cmd("silent write! " .. vim.fn.fnameescape(dst))
  h.check(slurp(dst) == data, name .. ": written back byte for byte")
end

local function lines_of(n, make) -- n lines separated by "\n", the last one terminated
  local t = {}
  for i = 1, n do t[i] = make(i) end
  return table.concat(t, "\n") .. "\n"
end

local function readfile_steps()
  local rnd = prng(20241015)
  local mb = 1024 * 1024
  return {
    function()
      -- controls: short files
      check_roundtrip("control, short lines", "alpha\nbeta\ngamma\n")
      check_roundtrip("control, no trailing newline", "alpha\nbeta")
      check_roundtrip("control, empty file", "")
      check_roundtrip("control, empty lines", "\n\n\nx\n\n")
    end,
    function()
      check_roundtrip("1 MB line", string.rep("a", mb) .. "\n")
      check_roundtrip("1 MB line, no trailing newline", string.rep("a", mb))
      check_roundtrip("20 MB line", string.rep("0123456789abcdef", 20 * mb / 16) .. "\n")
      check_roundtrip("20 MB line, no trailing newline", string.rep("0123456789abcdef", 20 * mb / 16))
    end,
    function()
      -- A multibyte sequence will straddle every read chunk boundary
      check_roundtrip("5 MB line of 2-byte chars", string.rep("\xc3\xa9", 5 * mb / 2) .. "\n")
      check_roundtrip("5 MB line of 3-byte chars", string.rep("\xe4\xb8\xad", 5 * mb / 3) .. "\n")
      check_roundtrip("5 MB line of 4-byte chars", string.rep("\xf0\x9f\x98\x80", 5 * mb / 4) .. "\n")
    end,
    function()
      -- Lines around the sizes where the read buffer fills up
      local sizes = {}
      for _, k in ipairs({ 12, 13, 14, 15, 16, 17, 18, 20 }) do
        for _, d in ipairs({ -2, -1, 0, 1, 2 }) do sizes[#sizes + 1] = 2 ^ k + d end
      end
      local t = {}
      for i, n in ipairs(sizes) do t[i] = string.rep(string.char(97 + i % 26), n) end
      check_roundtrip("lines at buffer-size boundaries", table.concat(t, "\n") .. "\n")
      check_roundtrip("lines at buffer-size boundaries, no trailing newline", table.concat(t, "\n"))
    end,
    function()
      check_roundtrip("200000 mid-size lines", lines_of(200000, function(i) return string.rep("m", 40 + i % 60) end))
      check_roundtrip("random line lengths 0..3000", lines_of(5000, function() return string.rep("r", rnd(3001) - 1) end))
      check_roundtrip("a long line between short ones",
        "head\n" .. string.rep("z", 3 * mb) .. "\ntail\n")
    end,
    function()
      check_roundtrip("NUL byte inside a long line", string.rep("a", mb) .. "\0" .. string.rep("b", mb) .. "\n")
      check_roundtrip("NUL byte lines", "a\0b\n\0\n\0\0\0\nend\n")
      check_roundtrip("CRLF, unix fileformats (CR stays in the line)", "one\r\ntwo\r\n" .. string.rep("c", mb) .. "\r\n")
      check_roundtrip("CRLF, long lines", "one\r\ntwo\r\n" .. string.rep("c", 3 * mb) .. "\r\n" .. "end\r\n",
        { dos = true, fileformats = "dos,unix" })
      check_roundtrip("CRLF, control", "one\r\ntwo\r\n", { dos = true, fileformats = "dos,unix" })
    end,
  }
end

---------------------------------------------------------------------------------------------------
-- 0002: Insert mode measures the line only when 'textwidth' and the "l" flag need it
---------------------------------------------------------------------------------------------------

local function with_buffer(line, setup)
  vim.cmd("enew!")
  vim.bo.textwidth = 0
  vim.bo.formatoptions = "tcq"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { line })
  if setup then setup() end
  vim.cmd("normal! $")
end

local function type_keys(keys) vim.api.nvim_feedkeys(vim.keycode(keys), "xt", false) end

local function insert_cases()
  local long = string.rep("x", 40)
  local tail = " tail words that go on"
  -- With "l", a line already longer than 'textwidth' when Insert started is not broken. Without
  -- it the line is broken at blanks. A short line is broken either way. The tail breaks after
  -- "go" because "tail words that go on" is 21 cells and 'textwidth' is 20.
  local long_kept = { long .. tail }
  local long_broken = { long, "tail words that go", "on" }
  local short_broken = { "short tail words", "that go on" }
  return {
    { "late, long line, with l: not broken", long, "A<Cmd>setlocal textwidth=20 formatoptions+=l<CR>", long_kept },
    { "late, long line, without l: broken", long, "A<Cmd>setlocal textwidth=20<CR>", long_broken },
    { "late, short line, with l: broken", "short", "A<Cmd>setlocal textwidth=20 formatoptions+=l<CR>", short_broken },
    { "late, short line, without l: broken", "short", "A<Cmd>setlocal textwidth=20<CR>", short_broken },
    { "early, long line, with l: not broken", long, "A", long_kept, "textwidth=20 formatoptions+=l" },
    { "early, long line, without l: broken", long, "A", long_broken, "textwidth=20" },
    { "early, short line, with l: broken", "short", "A", short_broken, "textwidth=20 formatoptions+=l" },
    { "early, short line, without l: broken", "short", "A", short_broken, "textwidth=20" },
    { "no textwidth, long line: never broken", long, "A", long_kept, "formatoptions+=l" },
    { "no textwidth, short line: never broken", "short", "A", { "short" .. tail }, "formatoptions+=l" },
  }, tail
end

local function insert_steps()
  local cases, tail = insert_cases()
  return {
    function()
      for _, c in ipairs(cases) do
        local name, line, keys, want, early = unpack(c)
        with_buffer(line, early and function() vim.cmd("setlocal " .. early) end)
        type_keys(keys .. tail .. "<Esc>")
        local got = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        h.check(vim.deep_equal(got, want), "insert, " .. name, vim.inspect(got))
      end
    end,
    function()
      -- Appending to a very long line must land at the end
      local path = tmp .. "/insert-long.txt"
      spit(path, string.rep("a", 5 * 1024 * 1024) .. "\n")
      vim.cmd("silent edit " .. vim.fn.fnameescape(path))
      vim.bo.textwidth = 0
      local started = vim.uv.hrtime()
      type_keys("Axyz<Esc>")
      local ms = (vim.uv.hrtime() - started) / 1e6
      local line = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
      h.check(#line == 5 * 1024 * 1024 + 3 and line:sub(-4) == "axyz", "insert at the end of a 5 MB line lands there")
      -- Not sensitive to patch 0002: stock Neovim also takes a few ms for 5 MB. Guards only
      -- against a catastrophic (quadratic) regression.
      h.check(ms < 2000, "insert at the end of a 5 MB line is not catastrophically slow", string.format("%.0f ms", ms))
      with_buffer("short")
      type_keys("Axyz<Esc>")
      h.check(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == "shortxyz", "insert at the end of a short line (control)")
    end,
  }
end

---------------------------------------------------------------------------------------------------
-- 0003: column measuring skips runs of printable ASCII
---------------------------------------------------------------------------------------------------

-- A line is a list of clusters: { text, kind }. Widths come from the kind, not from Neovim.
local CJK = { "\xe4\xb8\xad", "\xe6\x96\x87", "\xe5\xad\x97" }
local EMOJI = "\xf0\x9f\x98\x80"
local COMBINING = "\xcc\x81" -- U+0301, zero cells, attaches to the character before it
local BOUNDARY_RUNS = { 6, 7, 8, 9, 14, 15, 16, 17, 22, 23, 24, 25 }

local function gen_line(rnd)
  local clusters = {}
  local function add(text, kind) clusters[#clusters + 1] = { text = text, kind = kind } end
  local function ascii_run(n)
    for _ = 1, n do add(string.char(31 + rnd(95)), "ascii") end -- 0x20 to 0x7e
  end
  for _ = 1, rnd(6) do
    local pick = rnd(14)
    if pick <= 6 then
      local n = rnd(3) == 1 and BOUNDARY_RUNS[rnd(#BOUNDARY_RUNS)] or rnd(71) - 1
      ascii_run(n)
    elseif pick == 7 then
      add("\t", "tab")
    elseif pick == 8 then
      -- 0x01 to 0x1f except TAB and NL, shown as ^A
      local code = rnd(29)
      add(string.char(code >= 9 and code + 2 or code), "ctrl")
    elseif pick == 9 then
      add("\x7f", "del")
    elseif pick == 10 then
      add(CJK[rnd(#CJK)], "wide")
    elseif pick == 11 then
      add(EMOJI, "wide")
    elseif pick == 12 then
      add(rnd(2) == 1 and "\xff" or "\xfe", "invalid")
    elseif pick == 13 then
      -- a combining mark right after an ASCII run, or after a wide character
      ascii_run(rnd(20))
      local last = clusters[#clusters]
      if last and last.kind == "ascii" then last.text = last.text .. COMBINING end
    else
      ascii_run(BOUNDARY_RUNS[rnd(#BOUNDARY_RUNS)])
      add("\t", "tab")
    end
  end
  local last = clusters[#clusters]
  if last and last.kind == "wide" and rnd(2) == 1 then last.text = last.text .. COMBINING end
  return clusters
end

local function line_text(clusters)
  local t = {}
  for i, c in ipairs(clusters) do t[i] = c.text end
  return table.concat(t)
end

-- Cells taken by one cluster starting at display column "col" (0-based).
local function cluster_width(c, col, ts, tab_expands)
  if c.kind == "ascii" then return 1 end
  if c.kind == "tab" then return tab_expands and (ts - col % ts) or 2 end
  if c.kind == "ctrl" or c.kind == "del" or c.kind == "wide" then return 2 end
  return 4 -- invalid byte, shown as <ff>
end

-- Layout of a line: per-cluster start column, width and byte offset, plus the total width.
local function layout(clusters, ts, tab_expands, col0)
  local col, byte, out = col0, 0, {}
  for i, c in ipairs(clusters) do
    local w = cluster_width(c, col, ts, tab_expands)
    out[i] = { start = col, width = w, byte = byte }
    col = col + w
    byte = byte + #c.text
  end
  return out, col
end

-- What the cells of one cluster look like on screen: one entry per cell, false where the entry is
-- not comparable (the right half of a wide character).
local function cluster_cells(c, w, tab_expands, tab_lead)
  if c.kind == "ascii" then return { c.text } end
  if c.kind == "wide" then return { c.text, false } end
  if c.kind == "tab" then
    if not tab_expands then return { "^", "I" } end
    local cells = {}
    for i = 1, w do cells[i] = tab_lead and (i == 1 and tab_lead or "-") or " " end
    return cells
  end
  if c.kind == "ctrl" then return { "^", string.char(c.text:byte() + 64) } end
  if c.kind == "del" then return { "^", "?" } end
  local hex = string.format("<%02x>", c.text:byte())
  return { hex:sub(1, 1), hex:sub(2, 2), hex:sub(3, 3), hex:sub(4, 4) }
end

local function setup_window(opts)
  vim.g.snacks_indent = false -- its guides overdraw leading blanks and tabs
  vim.cmd("enew!")
  vim.cmd("silent! only!")
  vim.wo.wrap = false
  vim.wo.number = false
  vim.wo.signcolumn = "no"
  vim.wo.foldcolumn = "0"
  vim.wo.statuscolumn = ""
  vim.wo.list = opts.list or false
  vim.wo.listchars = opts.listchars or "nbsp:+"
  vim.wo.breakindent = false
  vim.wo.showbreak = ""
  vim.wo.linebreak = false
  vim.wo.cursorline = false
  vim.o.ambiwidth = "single"
  vim.o.sidescroll = opts.sidescroll or 0
  vim.o.sidescrolloff = 0
  vim.bo.tabstop = opts.ts
  vim.bo.vartabstop = ""
  vim.bo.textwidth = 0
end

local function describe(clusters)
  return vim.inspect(line_text(clusters))
end

local function check_measures(opts, nlines, seed)
  local rnd = prng(seed)
  local fails = 0
  local name = string.format("%s ts=%d", opts.label, opts.ts)
  local tab_expands = (not opts.list) or opts.listchars_has_tab
  local tab_lead = opts.list and opts.listchars_has_tab and ">" or nil
  setup_window(opts)
  local screen_cells = 0
  for n = 1, nlines do
    local clusters = gen_line(rnd)
    local text = line_text(clusters)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { text })
    local lay, total = layout(clusters, opts.ts, tab_expands, 0)
    local function fail(what, got, want)
      fails = fails + 1
      if fails <= 5 then
        h.check(false, name .. ": " .. what .. " for line " .. n, string.format("got %s, want %s, line %s", got, want, describe(clusters)))
      end
    end

    local sdw = vim.fn.strdisplaywidth(text)
    if sdw ~= total then fail("strdisplaywidth", sdw, total) end
    local _, total_from3 = layout(clusters, opts.ts, tab_expands, 3)
    local sdw3 = vim.fn.strdisplaywidth(text, 3)
    if sdw3 ~= total_from3 - 3 then fail("strdisplaywidth from column 3", sdw3, total_from3 - 3) end

    vim.fn.cursor(1, #text + 1)
    local vc = vim.fn.virtcol("$")
    if vc ~= total + 1 then fail("virtcol('$')", vc, total + 1) end

    -- cursor at a few clusters, including the first and the last
    local picks = { 1, #clusters }
    for _ = 1, 3 do picks[#picks + 1] = rnd(math.max(#clusters, 1)) end
    for _, i in ipairs(picks) do
      local c, l = clusters[i], lay[i]
      if c then
        vim.fn.cursor(1, l.byte + 1)
        local vcol = vim.fn.virtcol(".")
        local want_end = l.start + l.width
        if vcol ~= want_end then fail("virtcol('.') on cluster " .. i, vcol, want_end) end
      end
    end

    -- horizontal scroll: what is on screen must be the reference cells shifted by leftcol
    if total > 0 then
      local wanted = { 0, 7, 8, 9, 15, 16, 17, rnd(total) - 1, total - 1 }
      for _, want_left in ipairs({ wanted[rnd(7)], wanted[8], wanted[9] }) do
        vim.cmd("normal! 0")
        vim.fn.winrestview({ leftcol = 0 })
        if want_left > 0 then vim.cmd("normal! " .. want_left .. "zl") end
        vim.cmd("redraw")
        local leftcol = vim.fn.winsaveview().leftcol
        if want_left == 0 and leftcol ~= 0 then fail("leftcol after 0zl", leftcol, 0) end
        -- cell table of the whole line
        local cells = {}
        for i, c in ipairs(clusters) do
          local cc = cluster_cells(c, lay[i].width, tab_expands, tab_lead)
          for k = 1, lay[i].width do cells[lay[i].start + k] = cc[k] end
        end
        local info = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
        local width = info.width - info.textoff
        for s = 1, width do
          local idx = leftcol + s
          local want = cells[idx]
          if want ~= nil and want ~= false then
            -- the first column can be the cut-off tail of a wide cluster or a tab
            local edge = (s == 1 and leftcol > 0) or (s == width)
            local got = vim.fn.screenstring(info.winrow, info.wincol + info.textoff + s - 1)
            screen_cells = screen_cells + 1
            if got ~= want and not edge then
              fail(string.format("screen cell %d at leftcol %d", s, leftcol), vim.inspect(got), vim.inspect(want))
              break
            end
          end
        end
      end
    end
  end
  h.check(fails == 0, name .. ": " .. nlines .. " generated lines measure as the reference (" .. screen_cells .. " screen cells compared)")
end

-- ascii_print_run() works in 4096-byte chunks, so runs that end at, just before and just after a
-- chunk edge, with a different lead in front, must still measure right. A run is a count here:
-- widths are arithmetic, not a table per character.
local function check_long_runs(label)
  local TS = 8
  local leads = { { "", 0 }, { "\t", 8 }, { "\xe5\xad\x97", 2 }, { "\1", 2 } }
  local terms = { -- text, cells at a given column, whether it attaches to the run's last character
    { "", function() return 0 end },
    { "\t", function(col) return TS - col % TS end },
    { "\2", function() return 2 end },
    { "\x7f", function() return 2 end },
    { "\xe4\xb8\xad", function() return 2 end },
    { "\xff", function() return 4 end },
    { "\xcc\x81", function() return 0 end, true },
  }
  local lens = { 4094, 4095, 4096, 4097, 4098, 8190, 8191, 8192, 8193, 8194, 20000 }
  local pattern = "abcdefgh"
  setup_window({ ts = TS })
  local fails, compared, lines = 0, 0, 0
  for _, len in ipairs(lens) do
    local run = string.rep(pattern, math.ceil(len / 8)):sub(1, len)
    for _, lead in ipairs(leads) do
      for _, term in ipairs(terms) do
        lines = lines + 1
        local text = lead[1] .. run .. term[1]
        local lw = lead[2]
        local total = lw + len + term[2](lw + len)
        local function fail(what, got, want)
          fails = fails + 1
          if fails <= 5 then
            h.check(false, string.format("%s: %s (run %d, lead %q, term %q)", label, what, len, lead[1], term[1]),
              string.format("got %s, want %s", got, want))
          end
        end
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { text })
        local sdw = vim.fn.strdisplaywidth(text)
        if sdw ~= total then fail("strdisplaywidth", sdw, total) end
        vim.fn.cursor(1, #text + 1)
        local vc = vim.fn.virtcol("$")
        if vc ~= total + 1 then fail("virtcol('$')", vc, total + 1) end
        -- the run's last character (with its combining mark, if any) and the chunk edges
        local edges = { len, 4095, 4096, 4097, 8192 }
        for _, e in ipairs(edges) do
          if e <= len then
            vim.fn.cursor(1, #lead[1] + e)
            local v = vim.fn.virtcol(".")
            if v ~= lw + e then fail("virtcol('.') at run character " .. e, v, lw + e) end
          end
        end
        for _, want_left in ipairs({ 4095, 4096, 4097, 8192 }) do
          if want_left < total - 1 then
            vim.cmd("normal! 0")
            vim.fn.winrestview({ leftcol = 0 })
            vim.cmd("normal! " .. want_left .. "zl")
            vim.cmd("redraw")
            local info = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
            if want_left <= total - 100 and info.leftcol ~= want_left then fail("leftcol after zl", info.leftcol, want_left) end
            for s = 2, info.width - info.textoff - 1 do
              local i = info.leftcol + s - lw -- index into the run
              if i >= 1 and i < len then -- the last character may carry a combining mark
                local got = vim.fn.screenstring(info.winrow, info.wincol + info.textoff + s - 1)
                local want = pattern:sub((i - 1) % 8 + 1, (i - 1) % 8 + 1)
                compared = compared + 1
                if got ~= want then
                  fail(string.format("screen cell %d at leftcol %d", s, want_left), vim.inspect(got), vim.inspect(want))
                  break
                end
              end
            end
          end
        end
      end
    end
  end
  h.check(fails == 0, label .. ": " .. lines .. " lines with long ASCII runs measure as the reference (" .. compared .. " screen cells compared)")
end

local function measure_steps()
  local modes = {
    { label = "plain", ts = 8 },
    { label = "plain", ts = 3 },
    { label = "list without tab in listchars", ts = 8, list = true, listchars = "nbsp:+" },
    { label = "list with tab:>-", ts = 8, list = true, listchars = "tab:>-", listchars_has_tab = true },
    { label = "list with tab:>-", ts = 3, list = true, listchars = "tab:>-", listchars_has_tab = true },
  }
  local steps = {}
  for i, m in ipairs(modes) do
    steps[#steps + 1] = function() check_measures(m, 450, 1000 + i) end
  end
  steps[#steps + 1] = function() check_long_runs("runs of 4094..20000 bytes") end
  return steps
end

-- Wrapped lines with 'showbreak' and 'breakindent': every screen row after the first loses the
-- width of the showbreak string and of the line's indent. Printable ASCII only, so the row count
-- follows from the length alone.
local function check_wrapped(opts, nlines, seed)
  local rnd = prng(seed)
  local name = "wrap, " .. opts.label
  vim.cmd("enew!")
  vim.cmd("silent! only!")
  vim.wo.wrap = true
  vim.wo.number = false
  vim.wo.signcolumn = "no"
  vim.wo.foldcolumn = "0"
  vim.wo.statuscolumn = ""
  vim.wo.list = false
  vim.wo.linebreak = false
  vim.wo.breakindent = opts.breakindent
  vim.wo.showbreak = opts.showbreak
  vim.bo.tabstop = 8
  local info = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
  local width = info.width - info.textoff
  local fails = 0
  for n = 1, nlines do
    local indent = opts.breakindent and rnd(11) - 1 or 0
    local len = rnd(3) == 1 and BOUNDARY_RUNS[rnd(#BOUNDARY_RUNS)] * rnd(30) or rnd(400)
    local body = {}
    for i = 1, len do body[i] = string.char(32 + rnd(94)) end
    local text = string.rep(" ", indent) .. "x" .. table.concat(body)
    local cells = #text
    local later = width - #opts.showbreak - indent
    local rows = cells <= width and 1 or 1 + math.ceil((cells - width) / later)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { text })
    local got = vim.api.nvim_win_text_height(0, { start_row = 0, end_row = 0 }).all
    if got ~= rows then
      fails = fails + 1
      if fails <= 5 then
        h.check(false, name .. ": screen rows for a line of " .. cells .. " cells, indent " .. indent, string.format("got %d, want %d", got, rows))
      end
    end
    local extra = (rows - 1) * (#opts.showbreak + indent)
    local sdw = vim.fn.strdisplaywidth(text)
    vim.fn.cursor(1, #text + 1)
    local vc = vim.fn.virtcol("$")
    if sdw ~= cells + extra or vc ~= cells + extra + 1 then
      fails = fails + 1
      if fails <= 5 then
        h.check(false, name .. ": width of a line of " .. cells .. " cells, indent " .. indent,
          string.format("strdisplaywidth %d, virtcol('$') %d, want %d and %d", sdw, vc, cells + extra, cells + extra + 1))
      end
    end
  end
  h.check(fails == 0, name .. ": " .. nlines .. " generated lines match the reference")
end

local function wrap_steps()
  return {
    function() check_wrapped({ label = "control, no showbreak or breakindent", showbreak = "", breakindent = false }, 300, 2001) end,
    function() check_wrapped({ label = "showbreak", showbreak = ">> ", breakindent = false }, 300, 2002) end,
    function() check_wrapped({ label = "breakindent", showbreak = "", breakindent = true }, 300, 2003) end,
    function() check_wrapped({ label = "showbreak and breakindent", showbreak = ">> ", breakindent = true }, 300, 2004) end,
  }
end

local steps = {}
vim.list_extend(steps, readfile_steps())
vim.list_extend(steps, insert_steps())
vim.list_extend(steps, measure_steps())
vim.list_extend(steps, wrap_steps())

h.run(steps, 280000)

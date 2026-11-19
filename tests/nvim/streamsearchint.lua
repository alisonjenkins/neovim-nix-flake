-- The stream viewer's search driven end to end by the real streamsearch binary (the one on the
-- wrapper's PATH, not the stand-in of streamnav.lua): / ? n N with literal text and Vim regexes,
-- 'ignorecase', a pattern the translator refuses, :StreamSearchAll, <C-c>, and a match inside a long
-- line, on a file of a few MB and on a 1 GB sparse file with planted text.
local h = dofile(os.getenv("TEST_DIR") .. "/harness.lua")
local tmp = os.getenv("TMPDIR") or "/tmp"
local uv = vim.uv
local sv = require("streamview")
local Search = require("streamview_search")

local MB = 1024 * 1024

local function write(name, data)
  local path = tmp .. "/" .. name
  local f = assert(io.open(path, "wb"))
  f:write(data)
  f:close()
  return path
end

local function open(path)
  vim.cmd("StreamView! " .. vim.fn.fnameescape(path))
  return sv.state()
end

local function eq(a, b, name)
  h.check(vim.deep_equal(a, b), name, vim.inspect(a):sub(1, 200) .. " ~= " .. vim.inspect(b):sub(1, 200))
end

local function rss_mb()
  local f = io.open("/proc/self/status")
  local text = f:read("*a")
  f:close()
  return tonumber(text:match("VmRSS:%s*(%d+)")) / 1024
end

-- Every start of `needle` in `text` (0-based), overlapping ones included
local function find_all(text, needle)
  local out, at = {}, 1
  while true do
    local s = text:find(needle, at, true)
    if not s then break end
    out[#out + 1] = s - 1
    at = s + 1
  end
  return out
end

-- The calls to the helper: the stand-in is not used here, so every one runs the packaged binary
local calls = {}
local real_run = Search.run_helper
Search.run_helper = function(argv, handlers)
  calls[#calls + 1] = argv
  return real_run(argv, handlers)
end

local function helper_used_since(n)
  return #calls > n
end

local input
vim.ui.input = function(_, cb) cb(input) end

local function wait_for(fn, ms)
  vim.wait(ms or 120000, fn, 5)
  return fn()
end

-- / or ?, then waits for the search to end. Returns the time it took in ms.
local function prompt(V, key, pat)
  input = pat
  h.notes = {}
  local started = uv.hrtime()
  vim.cmd("normal " .. key)
  wait_for(function() return V.job == nil end)
  return (uv.hrtime() - started) / 1e6
end

local function again(V, key)
  h.notes = {}
  local started = uv.hrtime()
  vim.cmd("normal " .. key)
  wait_for(function() return V.job == nil end)
  return (uv.hrtime() - started) / 1e6
end

-- The cursor has reached `pos` (the move to a match of a long line can be a job of its own)
local function at(V, pos)
  return wait_for(function() return V.job == nil and sv.cursor_abs(V) == pos end, 60000)
end

local function cursor_is(V, pos, name)
  at(V, pos)
  eq(sv.cursor_abs(V), pos, name)
end

local timings = {}
local function timing(name, ms) timings[#timings + 1] = string.format("%s %.0f ms", name, ms) end

-- A file of a few MB: numbered lines, NEEDLE on every 10000th, "needle" on two others, a 2 MB line
-- with a mark in the middle, and a last line
local text
local A, VA
local needles, lowers, longmark

local steps = {
  function()
    -- A message printed while Neovim starts leaves a hit-enter prompt that takes the first keys
    vim.api.nvim_input("\r")
  end,

  function()
    h.capture_notify()
    local exe = vim.fn.exepath("streamsearch")
    h.check(exe ~= "", "streamsearch is on the wrapper's PATH", vim.env.PATH)
    h.check(Search.helper() ~= nil, "and the viewer finds it")

    local lines = {}
    for i = 1, 70000 do
      local tag = i % 10000 == 0 and " NEEDLE" or ((i == 15000 or i == 45000) and " needle" or "")
      lines[i] = string.format("row %05d filler filler filler filler%s", i, tag)
    end
    lines[#lines + 1] = string.rep("x", 1300 * 1024) .. " LONGMARK " .. string.rep("y", 700 * 1024)
    lines[#lines + 1] = "tail NEEDLE"
    text = table.concat(lines, "\n") .. "\n"
    A = write("search-int.txt", text)
    needles = find_all(text, "NEEDLE")
    lowers = find_all(text, "needle")
    longmark = find_all(text, "LONGMARK")[1]
    h.check(#text > 3 * MB and #needles == 8, "the planted file is a few MB with 8 NEEDLE", tostring(#text))
    sv.opts.editable = false
    VA = open(A)
    h.check(VA ~= nil, "it opens in the viewer")
  end,

  function()
    -- / and n and N with literal text
    local V = VA
    sv.head(V)
    local n = #calls
    local ms = prompt(V, "/", "NEEDLE")
    timing("literal / on 4 MB", ms)
    h.check(helper_used_since(n), "a literal search runs the helper")
    eq(calls[n + 1][1], vim.fn.exepath("streamsearch"), "the packaged binary")
    h.check(vim.tbl_contains(calls[n + 1], "--fixed"), "as --fixed", table.concat(calls[n + 1], " "))
    cursor_is(V, needles[1], "/ finds the first NEEDLE")
    again(V, "n")
    cursor_is(V, needles[2], "n finds the next")
    again(V, "n")
    cursor_is(V, needles[3], "and the next")
    again(V, "N")
    cursor_is(V, needles[2], "N goes back one")
    prompt(V, "?", "NEEDLE")
    cursor_is(V, needles[1], "? finds the one before the cursor")
    h.check(vim.tbl_contains(calls[#calls], "--backward"), "with --backward")
    again(V, "N")
    cursor_is(V, needles[2], "N after ? looks forward from the cursor")
    h.check(#h.notes_matching("not found") == 0, "without a not-found message")
    again(V, "n")
    cursor_is(V, needles[1], "n after ? keeps going up")
    prompt(V, "/", "NEEDLE")
    cursor_is(V, needles[2], "/ turns the direction down again")

    -- the last one, and none after it
    for _ = 1, #needles do
      again(V, "n")
    end
    cursor_is(V, needles[#needles], "n stops at the last NEEDLE")
    h.check(#h.notes_matching("Pattern not found") > 0, "and says there is no more")

    prompt(V, "/", "not-in-this-file-anywhere")
    h.check(#h.notes_matching("Pattern not found") > 0, "a pattern that is not there is reported")
    cursor_is(V, needles[#needles], "and the cursor stays")
    eq(V.job, nil, "with no job left")
  end,

  function()
    -- Vim regexes through the translator
    local V = VA
    sv.head(V)
    local n = #calls
    prompt(V, "/", [[row 3\d000 ]])
    h.check(helper_used_since(n) and vim.tbl_contains(calls[n + 1], "--regex"), "a Vim regex runs the helper as --regex", table.concat(calls[n + 1] or {}, " "))
    h.check(vim.tbl_contains(calls[n + 1], "row 3[0-9]000 "), "with the translated pattern")
    cursor_is(V, find_all(text, "row 30000 ")[1], [[/row 3\d000 ]])

    sv.head(V)
    prompt(V, "/", [[\<LONGMARK\>]])
    eq(at(V, longmark), true, [[\<LONGMARK\> is found in the 2 MB line]])
    h.check(vim.tbl_contains(calls[#calls], [[\b{start}LONGMARK\b{end}]]), "translated word boundaries", table.concat(calls[#calls], " "))

    sv.head(V)
    prompt(V, "/", [[row 6\d\{4} filler]])
    cursor_is(V, find_all(text, "row 60000 filler")[1], [[a \{4} count]])

    -- a pattern the translator refuses is searched on the window by vim.regex
    sv.head(V)
    n = #calls
    prompt(V, "/", [[row \zs30000]])
    eq(#calls, n, [[\zs is not given to the helper]])
    cursor_is(V, find_all(text, "row 30000")[1] + #"row ", "and the Lua scan puts the cursor at the \\zs")

    sv.head(V)
    n = #calls
    prompt(V, "/", [[LONGMARK\&x*LONGMARK]])
    eq(#calls, n, [[\& is not given to the helper]])
    eq(at(V, longmark), true, "and a match in the long line is found")

    -- an invalid pattern is an error, not a search
    h.notes = {}
    n = #calls
    prompt(V, "/", [[row \(unclosed]])
    eq(#calls, n, "an invalid pattern does not start the helper")
    h.check(#h.notes_matching("Search failed") > 0, "and is reported", vim.inspect(h.notes))
  end,

  function()
    -- 'ignorecase'
    local V = VA
    local saved = { vim.o.ignorecase, vim.o.smartcase }
    vim.o.ignorecase, vim.o.smartcase = false, false
    sv.head(V)
    prompt(V, "/", "needle")
    cursor_is(V, lowers[1], "without ignorecase / needle finds only the lower case one")
    vim.o.ignorecase = true
    sv.head(V)
    local n = #calls
    prompt(V, "/", "needle")
    cursor_is(V, needles[1], "with ignorecase it finds NEEDLE first")
    h.check(helper_used_since(n) and vim.tbl_contains(calls[n + 1], "--ignore-case"), "the helper got --ignore-case", table.concat(calls[n + 1] or {}, " "))
    again(V, "n")
    cursor_is(V, lowers[1], "and n goes on to needle between them")
    sv.head(V)
    prompt(V, "/", [[\cnEeDlE]])
    cursor_is(V, needles[1], [[\c asks for it in the pattern]])
    vim.o.smartcase = true
    sv.head(V)
    prompt(V, "/", "Needle")
    h.check(#h.notes_matching("Pattern not found") > 0, "smartcase with a capital makes the search case sensitive")
    vim.o.ignorecase, vim.o.smartcase = saved[1], saved[2]
  end,

  function()
    -- :StreamSearchAll
    local V = VA
    sv.head(V)
    local shown
    local choose = 2
    local real_select = vim.ui.select
    vim.ui.select = function(items, _, cb)
      shown = items
      cb(items[choose])
    end
    vim.cmd("StreamSearchAll NEEDLE 4")
    wait_for(function() return shown ~= nil end, 60000)
    vim.ui.select = real_select
    h.check(shown ~= nil and #shown >= 4, ":StreamSearchAll lists matches")
    local got = {}
    for i = 1, 4 do
      got[i] = shown and shown[i] and shown[i].pos
    end
    eq(got, { needles[1], needles[2], needles[3], needles[4] }, "they are the first four NEEDLE")
    h.check(shown[5] and shown[5].more, "with an entry asking for more")
    at(V, needles[2])
    cursor_is(V, needles[2], "and the one picked is where the cursor goes")
  end,

  function()
    -- <C-c> cancels a search that is running
    local V = VA
    sv.head(V)
    input = "no-such-text-" .. string.rep("z", 40)
    h.notes = {}
    local before = #calls
    vim.cmd("normal /")
    h.check(V.job ~= nil, "a helper search is a running job")
    h.check(helper_used_since(before), "of the helper")
    local cancel = vim.fn.maparg("<C-c>", "n", false, true)
    h.check(cancel.callback ~= nil, "<C-c> is mapped in the viewer")
    cancel.callback()
    eq(V.job, nil, "<C-c> ends the job")
    wait_for(function() return #h.notes_matching("Search cancelled") > 0 end, 5000)
    h.check(#h.notes_matching("Search cancelled") > 0, "and reports it")
    local function helper_running()
      local handle = uv.fs_scandir("/proc")
      while handle do
        local name = uv.fs_scandir_next(handle)
        if not name then break end
        if name:match("^%d+$") then
          local f = io.open("/proc/" .. name .. "/cmdline", "rb")
          if f then
            local cmd = f:read("*a")
            f:close()
            if cmd:find("no-such-text-", 1, true) then return true end
          end
        end
      end
      return false
    end
    h.check(wait_for(function() return not helper_running() end, 5000), "the helper process is gone")
    prompt(V, "/", "NEEDLE")
    h.check(sv.cursor_abs(V) == needles[1] or sv.cursor_abs(V) == needles[2], "a search after a cancel works", tostring(sv.cursor_abs(V)))
  end,

  function()
    -- a few MB is the file; a window of the long line is what the cursor sits in
    local V = VA
    sv.head(V)
    prompt(V, "/", "LONGMARK")
    eq(at(V, longmark), true, "a literal match in a 2 MB line puts the cursor on it")
    local row = vim.api.nvim_get_current_line()
    h.check(row:find("LONGMARK", 1, true) ~= nil, "and the slice of the line shown holds it")
    again(V, "n")
    h.check(#h.notes_matching("Pattern not found") > 0, "n finds no second one")
    prompt(V, "?", " LONGMARK")
    eq(at(V, longmark - 1), true, "a backward search finds a match that starts in the middle of the line")
    vim.cmd("silent! %bwipeout!")
  end,

  -- the 1 GB file: one line of NUL bytes with three planted marks
  function()
    if not h.sparse_supported(tmp) then return h.skip("search a 1 GB file: no sparse files here") end
    local size = 1024 * MB
    local planted = { [300 * MB] = "PLANTED-A", [700 * MB] = "planted-b", [size - 20] = "PLANTED-C" }
    local path = tmp .. "/search-int-big.bin"
    local fd = assert(uv.fs_open(path, "w", 420))
    uv.fs_ftruncate(fd, size)
    for off, t in pairs(planted) do
      uv.fs_write(fd, t, off)
    end
    uv.fs_write(fd, "\n", size - 1)
    uv.fs_close(fd)

    local V = open(path)
    h.check(V ~= nil, "a 1 GB file opens")
    local saved = { vim.o.ignorecase, vim.o.smartcase }
    vim.o.ignorecase, vim.o.smartcase = false, false
    local base = rss_mb()
    local peak = base
    local timer = uv.new_timer()
    timer:start(50, 50, function() peak = math.max(peak, rss_mb()) end)

    sv.head(V)
    local n = #calls
    local ms = prompt(V, "/", "PLANTED-A")
    timing("literal / in a 1 GB line", ms)
    h.check(helper_used_since(n), "the search runs the helper")
    eq(at(V, 300 * MB), true, "/ finds a mark 300 MB into the line")
    again(V, "n")
    h.check(#h.notes_matching("Pattern not found") > 0, "n finds no second PLANTED-A")

    vim.o.ignorecase = true
    sv.head(V)
    ms = prompt(V, "/", "planted")
    eq(at(V, 300 * MB), true, "with ignorecase / planted finds the first")
    ms = again(V, "n")
    timing("n over 400 MB of the line", ms)
    eq(at(V, 700 * MB), true, "n finds the next, 400 MB on")
    again(V, "n")
    eq(at(V, size - 20), true, "and the one at the end")
    ms = again(V, "N")
    eq(at(V, 700 * MB), true, "N goes back to the middle one")
    ms = prompt(V, "?", "planted")
    eq(at(V, 300 * MB), true, "? from there finds the first")

    -- a regex
    vim.o.ignorecase = false
    sv.head(V)
    n = #calls
    ms = prompt(V, "/", [==[PLANTED-[B-C]]==])
    timing("regex / in a 1 GB line", ms)
    h.check(helper_used_since(n) and vim.tbl_contains(calls[n + 1], "--regex"), "a regex runs the helper", table.concat(calls[n + 1] or {}, " "))
    eq(at(V, size - 20), true, "and skips the lower case b to PLANTED-C")

    -- :StreamSearchAll over the line
    vim.o.ignorecase = true
    sv.head(V)
    local shown
    local real_select = vim.ui.select
    vim.ui.select = function(items, _, cb)
      shown = items
      cb(nil)
    end
    vim.cmd("StreamSearchAll planted 5")
    wait_for(function() return shown ~= nil end, 120000)
    vim.ui.select = real_select
    local got = {}
    for i, it in ipairs(shown or {}) do
      got[i] = it.pos
    end
    eq(got, { 300 * MB, 700 * MB, size - 20 }, ":StreamSearchAll lists the three in a 1 GB line")

    -- <C-c> in the middle of a scan of the whole line
    h.notes = {}
    sv.head(V)
    input = "absent-" .. string.rep("q", 30)
    n = #calls
    local started = uv.hrtime()
    vim.cmd("normal /")
    h.check(V.job ~= nil, "a search of a 1 GB line is a running job")
    sv.cancel(V)
    local took = (uv.hrtime() - started) / 1e6
    eq(V.job, nil, "<C-c> ends it")
    timing("cancel", took)
    h.check(took < 2000, "within 2 s", string.format("%.0f ms", took))
    wait_for(function() return #h.notes_matching("Search cancelled") > 0 end, 5000)
    h.check(#h.notes_matching("Search cancelled") > 0, "and reports it")

    timer:stop()
    timer:close()
    io.stdout:write(string.format("      1 GB search: RSS %.0f MB at the start, %.0f MB at the peak; %s\n", base, peak, table.concat(timings, ", ")))
    h.check(peak - base < 300, "memory stays flat while the helper scans 1 GB", string.format("%.0f MB growth", peak - base))
    vim.o.ignorecase, vim.o.smartcase = saved[1], saved[2]
    vim.cmd("silent! %bwipeout!")
    os.remove(path)
  end,
}

h.run(steps, 900000)

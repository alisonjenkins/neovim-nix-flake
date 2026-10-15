-- Big buffers must be marked so per-buffer scanners skip them, and the global search options and
-- smear-cursor must follow the current buffer and keep the user's own settings. Runs in a throwaway
-- repo; no LSP-backed filetypes.
local h = dofile(os.getenv("TEST_DIR") .. "/harness.lua")
local tmp = os.getenv("TMPDIR") or "/tmp"

local function write(name, lines)
  local path = tmp .. "/" .. name
  vim.fn.writefile(lines, path)
  return path
end

local function repeated(n, line)
  local lines = {}
  for i = 1, n do lines[i] = line end
  return lines
end

local small = write("small.conf", repeated(10, string.rep("a", 99)))
local big = write("big.conf", repeated(20000, string.rep("a", 99))) -- about 2 MB
local long_line = write("long.conf", { string.rep("a", 600 * 1024) }) -- under 1 MB, one line

-- smartcolumn (scope = "file") measures every line with strdisplaywidth. Its autocmds only run
-- from the event loop, so call them directly and count the measurements instead.
local measured = 0
local strdisplaywidth = vim.fn.strdisplaywidth
vim.fn.strdisplaywidth = function(...)
  measured = measured + 1
  return strdisplaywidth(...)
end
local function smartcolumn_measurements()
  measured = 0
  for _, au in ipairs(vim.api.nvim_get_autocmds({ group = "SmartColumn" })) do
    au.callback({ buf = vim.api.nvim_get_current_buf(), event = au.event })
  end
  return measured
end

local function smear() return require("smear_cursor") end

local steps = {
  function()
    vim.cmd("edit " .. vim.fn.fnameescape(small))
    h.check(vim.b.bigfile == nil, "a small file is not marked bigfile")
    h.check(vim.bo.modeline, "a small file keeps modeline on")
    h.check(vim.o.incsearch, "incsearch is on in a small file")
    h.check(vim.o.inccommand ~= "", "inccommand is on in a small file", vim.o.inccommand)
    h.check(smartcolumn_measurements() > 0, "smartcolumn measures a small file (control)")
    h.check(smear().enabled == true, "smear-cursor is on in a small file (control)")
    vim.o.inccommand = "split" -- the user's own choice, different from the default
  end,

  function()
    vim.cmd("edit " .. vim.fn.fnameescape(big))
    h.check(vim.b.bigfile == true, "a file over 1 MB is marked bigfile")
    h.check(not vim.bo.modeline, "modeline is off for a big file")
    h.check(vim.b.sleuth_automatic == 0, "vim-sleuth detection is off for a big file")
    h.check(not vim.o.incsearch, "incsearch is off in a big file")
    h.check(vim.o.inccommand == "", "inccommand is off in a big file", vim.o.inccommand)
    h.check(smartcolumn_measurements() == 0, "smartcolumn does not measure a big file")
  end,
  {
    what = "smear-cursor to switch off in the big file",
    ["until"] = function() return smear().enabled == false end,
  },

  function()
    vim.cmd("buffer #")
    h.check(vim.o.incsearch, "incsearch is back on in a small file")
    h.check(vim.o.inccommand == "split", "the user's inccommand is kept", vim.o.inccommand)
    h.check(vim.bo.modeline, "modeline is back on in a small file")
    h.check(smear().enabled == true, "smear-cursor is back on after a big file")
    smear().enabled = false -- toggled off by hand; leaving a big buffer must not turn it on
    vim.cmd("buffer #")
  end,
  function()
    h.check(smear().enabled == false, "smear-cursor stays off in a big file")
    vim.cmd("buffer #")
  end,
  function()
    h.check(smear().enabled == false, "smear-cursor stays off if it was off before", tostring(smear().enabled))
    smear().enabled = true
    vim.cmd("edit " .. vim.fn.fnameescape(long_line))
  end,

  {
    what = "snacks to mark the long-line file",
    ["until"] = function() return vim.b.bigfile == true end,
  },
  function()
    h.check(vim.b.disable_autoformat == true, "format on save is off for a long-line file")
    h.check(not vim.o.incsearch, "incsearch is off in a long-line file")
    h.check(vim.o.inccommand == "", "inccommand is off in a long-line file", vim.o.inccommand)
    h.check(smartcolumn_measurements() == 0, "smartcolumn does not measure a long-line file")
  end,
}

h.run(steps, 60000)

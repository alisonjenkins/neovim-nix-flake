-- Regression tests for the Neovim C patches in patches/neovim/. The expectations are computed here,
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
local steps = readfile_steps()

h.run(steps, 280000)

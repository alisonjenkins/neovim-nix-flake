-- Navigation inside lines of any length for the stream viewer: finding where a line starts and ends
-- without a limit (big chunks, memory bounded, remembering what was scanned) and UTF-8 alignment.
-- Everything here works in absolute byte offsets of the file as the viewer shows it.
local N = {}

local ffi = require("ffi")
local u8 = ffi.typeof("const uint8_t*")

local opts -- the viewer's options (scan_chunk, fact_min, max_facts)

function N.setup(viewer_opts) opts = viewer_opts end

local function mtime_key(st) return string.format("%d.%09d", st.mtime.sec, st.mtime.nsec) end

-- First entry of the sorted list whose end is >= x
local function first_ending_at_or_after(list, x)
  local lo, hi = 1, #list + 1
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    if list[mid].b < x then lo = mid + 1 else hi = mid end
  end
  return lo
end

-- Adds the methods to the viewer's Reader class.
function N.install(Reader)
  ---------------------------------------------------------------------------------------------
  -- UTF-8
  ---------------------------------------------------------------------------------------------

  -- Start and length of the valid UTF-8 character that has bytes on both sides of `pos`, or nil
  -- when `pos` is at a character boundary (or among bytes that do not form a character).
  function Reader:straddle(pos)
    if pos <= 0 or pos >= self.size then return nil end
    local from = math.max(0, pos - 3)
    local s = self:get(from, pos - from + 1)
    local at = #s
    local b = s:byte(at)
    if not b or b < 0x80 or b >= 0xC0 then return nil end
    for k = at - 1, 1, -1 do
      local c = s:byte(k)
      if c >= 0xC2 and c <= 0xF4 then
        local need = c >= 0xF0 and 4 or c >= 0xE0 and 3 or 2
        if k + need > at then return from + k - 1, need end
        return nil
      elseif c < 0x80 or c >= 0xC0 then
        return nil
      end
    end
  end

  -- `pos`, moved back to the start of the character it is inside
  function Reader:align_down(pos)
    return (self:straddle(pos)) or pos
  end

  -- `pos`, moved forward to the end of the character it is inside
  function Reader:align_up(pos)
    local start, need = self:straddle(pos)
    return start and start + need or pos
  end

  ---------------------------------------------------------------------------------------------
  -- Stretches known to hold no "\n". Scanning a line of many MB for its ends is the expensive
  -- part of showing it, so what was scanned is remembered: { a, b, lc, rc } is [a, b) without a
  -- newline, lc: the byte before a is a newline (or a is 0), rc: the byte at b is one (or b is
  -- the end of the file). Entries are kept sorted and disjoint; edits and growth drop them all.
  ---------------------------------------------------------------------------------------------

  function Reader:free_cover(x)
    local list = self.free
    local e = list[first_ending_at_or_after(list, x + 1)]
    if e and e.a <= x then return e end
  end

  function Reader:note_free(a, b, lc, rc)
    if b <= a then return end
    if a == 0 then lc = true end
    if b >= self.size then rc = true end
    local list = self.free
    local lo = first_ending_at_or_after(list, a)
    local na, nb, nlc, nrc = a, b, lc, rc
    local j = lo
    while j <= #list and list[j].a <= b do
      local e = list[j]
      if e.a < na then
        na, nlc = e.a, e.lc
      elseif e.a == na then
        nlc = nlc or e.lc
      end
      if e.b > nb then
        nb, nrc = e.b, e.rc
      elseif e.b == nb then
        nrc = nrc or e.rc
      end
      j = j + 1
    end
    -- a short stretch costs less to scan again than to keep
    if j == lo and nb - na < opts.fact_min then return end
    for _ = lo + 1, j - 1 do
      table.remove(list, lo + 1)
    end
    if j > lo then
      list[lo] = { a = na, b = nb, lc = nlc, rc = nrc }
    else
      table.insert(list, lo, { a = na, b = nb, lc = nlc, rc = nrc })
    end
    if #list > opts.max_facts then self.free = {} end
  end

  ---------------------------------------------------------------------------------------------
  -- Where a line starts and ends. so: { budget = bytes to scan at most, tick = fn(bytes) that is
  -- called between chunks and may yield }. They return nil (and a reason) when the budget ran out
  -- or a read came back short; what was scanned is remembered, so a later call goes on from there.
  ---------------------------------------------------------------------------------------------

  -- Offset of the first "\n" at or after `from`, or the size of the file when there is none.
  function Reader:line_end(from, so)
    so = so or {}
    local size = self.size
    if from >= size then return size end
    local lim = math.min(size, from + self.bs)
    local nl = self:find_nl(from, lim)
    if nl then return nl end
    local start, q, scanned = from, lim, lim - from
    while true do
      if q >= size then
        self:note_free(start, size, false, true)
        return size
      end
      local known = self:free_cover(q)
      if known then
        if known.rc then
          self:note_free(start, known.b, false, true)
          return known.b
        end
        q = known.b
      else
        if so.budget and scanned >= so.budget then
          self:note_free(start, q, false, false)
          return nil, "budget"
        end
        local hi = math.min(size, q + opts.scan_chunk)
        local after = self.free[first_ending_at_or_after(self.free, q + 1)]
        if after and after.a > q and after.a < hi then hi = after.a end
        local data = self:raw(q, hi)
        if #data < hi - q then
          self:note_free(start, q, false, false)
          return nil, "short read"
        end
        local i = data:find("\n", 1, true)
        if i then
          local p = q + i - 1
          self:note_free(start, p, false, true)
          return p
        end
        scanned = scanned + (hi - q)
        q = hi
        if so.tick then
          self:note_free(start, q, false, false)
          so.tick(q - from)
        end
      end
    end
  end

  -- Start of the line that has the byte at `off` (a "\n" belongs to the line it ends). so.nl_at_off:
  -- the byte at `off` is a "\n" (walking back from a line start), which completes what is remembered.
  function Reader:line_start(off, so)
    so = so or {}
    local rc = so.nl_at_off == true
    if off <= 0 then return 0 end
    off = math.min(off, self.size)
    local lo = math.max(0, off - self.bs)
    local nl = self:find_nl_back(off, lo)
    if nl then return nl + 1 end
    if lo == 0 then return 0 end
    local top, q, scanned = off, lo, off - lo
    local chunk = self.bs * 4
    while true do
      if q <= 0 then
        self:note_free(0, top, true, rc)
        return 0
      end
      local known = self:free_cover(q - 1)
      if known then
        if known.lc then
          self:note_free(known.a, top, true, rc)
          return known.a
        end
        q = known.a
      else
        if so.budget and scanned >= so.budget then
          self:note_free(q, top, false, rc)
          return nil, "budget"
        end
        local lo2 = math.max(0, q - chunk)
        -- the stretch just before q that is already known need not be read again
        local list = self.free
        local before = list[first_ending_at_or_after(list, q) - 1]
        if before and before.b > lo2 and before.b <= q - 1 then lo2 = before.b end
        local data = self:raw(lo2, q)
        if #data < q - lo2 then
          self:note_free(q, top, false, rc)
          return nil, "short read"
        end
        local i = data:reverse():find("\n", 1, true)
        if i then
          local p = q - i
          self:note_free(p + 1, top, true, rc)
          return p + 1
        end
        scanned = scanned + (q - lo2)
        q = lo2
        chunk = math.min(chunk * 4, opts.scan_chunk)
        if so.tick then
          self:note_free(q, top, false, rc)
          so.tick(off - q)
        end
      end
    end
  end
end


---------------------------------------------------------------------------------------------------
-- Motions along a line, in absolute bytes. Each takes e = { r = reader, pos = byte of the cursor's
-- character, ls = start of its line } and so = scan options (budget, tick: as for line_end), and
-- returns the byte to go to, or nil and why: "fail" (nowhere to go: the cursor stays), "budget"
-- (scan again as a job), "short read". A newline ends every motion but the ones that cross lines.
---------------------------------------------------------------------------------------------------

local function chunk_first() return 4096 end

-- Scanning for bytes of a set is a loop over the bytes, which LuaJIT compiles: about a byte per
-- nanosecond, where a Lua pattern with a character class costs ten times that. A set is a table of
-- 256 flags.
local function set_of(pred)
  local t = ffi.new("uint8_t[256]")
  for b = 0, 255 do
    if pred(b) then t[b] = 1 end
  end
  return t
end

local function is_sp(b) return b == 32 or b == 9 or b == 13 or b == 12 or b == 11 end
local function is_kw(b) return (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 95 or b >= 128 end

-- the bytes that end a run of a class
local NOT_IN = {
  sp = set_of(function(b) return not is_sp(b) end),
  kw = set_of(function(b) return not is_kw(b) end),
  bigkw = set_of(function(b) return is_sp(b) or b == 10 end),
  pu = set_of(function(b) return is_kw(b) or is_sp(b) or b == 10 end),
  blank_or_nl = set_of(function(b) return not (is_sp(b) or b == 10) end),
}

local function first_in(data, set)
  local p = ffi.cast(u8, data)
  for i = 0, #data - 1 do
    if set[p[i]] ~= 0 then return i + 1 end
  end
end

local function last_in(data, set)
  local p = ffi.cast(u8, data)
  for i = #data - 1, 0, -1 do
    if set[p[i]] ~= 0 then return i + 1 end
  end
end

-- First byte at or after `from` that is in `set` (the size of the file when none is)
local function fwd_find(r, from, set, so)
  local size, pos, chunk, scanned = r.size, from, chunk_first(), 0
  while pos < size do
    if so and so.budget and scanned >= so.budget then return nil, "budget" end
    local hi = math.min(size, pos + chunk)
    local data = r:raw(pos, hi)
    if #data < hi - pos then return nil, "short read" end
    local i = first_in(data, set)
    if i then return pos + i - 1 end
    scanned = scanned + #data
    pos = hi
    chunk = math.min(chunk * 4, opts.scan_chunk)
    if so and so.tick then so.tick(pos - from) end
  end
  return size
end

-- Last byte before `before` that is in `set` (-1 when none is)
local function bwd_find(r, before, set, so)
  local pos, chunk, scanned = math.min(before, r.size), chunk_first(), 0
  local start = pos
  while pos > 0 do
    if so and so.budget and scanned >= so.budget then return nil, "budget" end
    local lo = math.max(0, pos - chunk)
    local data = r:raw(lo, pos)
    if #data < pos - lo then return nil, "short read" end
    local i = last_in(data, set)
    if i then return lo + i - 1 end
    scanned = scanned + #data
    pos = lo
    chunk = math.min(chunk * 4, opts.scan_chunk)
    if so and so.tick then so.tick(start - pos) end
  end
  return -1
end

local function byte_at(r, a)
  if a < 0 or a >= r.size then return nil end
  return r:get(a, 1):byte()
end

-- Length of the character that starts with byte b (1 for bytes that start none)
local function clen(b)
  if not b or b < 0xC2 then return 1 end
  return b >= 0xF0 and 4 or b >= 0xE0 and 3 or 2
end

local function next_char(r, a)
  local len = clen(byte_at(r, a))
  if len > 1 then
    -- only if the continuation bytes are there
    local s = r:get(a + 1, len - 1)
    if #s ~= len - 1 or s:find("[^\128-\191]") then len = 1 end
  end
  return a + len
end

local function prev_char(r, a)
  if a <= 0 then return 0 end
  return r:align_down(a - 1)
end

local function cls(b, big)
  if not b then return "eof" end
  if b == 10 then return "nl" end
  if b == 32 or b == 9 or b == 13 or b == 12 or b == 11 then return "sp" end
  if big then return "kw" end
  if (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 95 or b >= 128 then return "kw" end
  return "pu"
end

local function run_pat(c, big)
  if c == "kw" and big then return NOT_IN.bigkw end
  return NOT_IN[c]
end

-- Index (1-based) of the k-th character start in `s` (k >= 1), or nil and how many there are
local function nth_start(s, k)
  local p = ffi.cast(u8, s)
  local c = 0
  for i = 0, #s - 1 do
    local b = p[i]
    if b < 128 or b >= 192 then
      c = c + 1
      if c == k then return i + 1 end
    end
  end
  return nil, c
end

-- Index of the k-th character start counted from the end of `s`, or nil and how many there are
local function nth_start_back(s, k)
  local p = ffi.cast(u8, s)
  local c = 0
  for i = #s - 1, 0, -1 do
    local b = p[i]
    if b < 128 or b >= 192 then
      c = c + 1
      if c == k then return i + 1 end
    end
  end
  return nil, c
end

local function trim_partial(s)
  local n = #s
  for k = 1, math.min(3, n) do
    local b = s:byte(n - k + 1)
    if b < 0x80 then return s end
    if b >= 0xC0 then return k < clen(b) and s:sub(1, n - k) or s end
  end
  return s
end

function N.next_char(r, a) return next_char(r, a) end

function N.prev_char(r, a) return prev_char(r, a) end

-- "sp", "kw", "pu", "nl" or "eof": the kind of the character at `a`
function N.class_at(r, a, big) return cls(byte_at(r, a), big) end

-- n characters to the right; stops on the last character of the line. Also returns how many
-- characters it moved over.
function N.right(e, n, so)
  local r = e.r
  local p, remaining, scanned = e.pos, n, 0
  local chunk = opts.scan_chunk
  while true do
    if so and so.budget and scanned >= so.budget then return nil, "budget" end
    local hi = math.min(r.size, p + chunk + 4)
    local data = r:raw(p, hi)
    if #data == 0 then return e.pos end
    local nl = data:find("\n", 1, true)
    local complete = nl ~= nil or hi >= r.size
    local body = nl and data:sub(1, nl - 1) or (complete and data or trim_partial(data:sub(1, chunk)))
    -- the character the cursor is on is the first of the body: the target is the (remaining + 1)-th
    local i, total = nth_start(body, remaining + 1)
    if i then return p + i - 1, n end
    if complete then
      if #body == 0 then return p, n - remaining end
      local last = nth_start_back(body, 1)
      return p + (last or 1) - 1, n - remaining + total - 1
    end
    remaining = remaining - total
    p = p + #body
    scanned = scanned + #body
    if so and so.tick then so.tick(p - e.pos) end
  end
end

-- n characters to the left; stops at the start of the line
function N.left(e, n, so)
  local r = e.r
  local p, remaining, scanned = e.pos, n, 0
  local chunk = opts.scan_chunk
  while p > e.ls do
    if so and so.budget and scanned >= so.budget then return nil, "budget" end
    local lo = math.max(e.ls, p - chunk)
    local body = r:raw(lo, p)
    local j, total = nth_start_back(body, remaining)
    if j then return lo + j - 1 end
    remaining = remaining - total
    p = lo
    scanned = scanned + #body
    if so and so.tick then so.tick(e.pos - p) end
  end
  return e.ls
end

-- first non-blank of the line
function N.first_nonblank(e, so)
  local p, why = fwd_find(e.r, e.ls, NOT_IN.sp, so)
  if not p then return nil, why end
  if byte_at(e.r, p) == 10 or p >= e.r.size then return math.max(e.ls, prev_char(e.r, p)) end
  return p
end

-- `n` words forward (w, or W when big). eol: for an operator, where the last word moved over ends
-- at the end of the line the motion stops there, not at the first word of the next line.
function N.word_forward(e, n, big, so, eol)
  local r = e.r
  local p = e.pos
  for i = 1, n do
    local last = eol and i == n
    local b0 = byte_at(r, p)
    if b0 == nil then break end
    if b0 == 10 then
      -- on an empty line: on to the next
      p = p + 1
      if last then return p end
    else
      -- always at least one character
      local c = cls(b0, big)
      p = next_char(r, p)
      if last and byte_at(r, p) == 10 then return p end
      if c ~= "sp" then
        local q, why = fwd_find(r, p, run_pat(c, big), so)
        if not q then return nil, why end
        p = q
        if last and byte_at(r, p) == 10 then return p end
      end
    end
    while true do
      local q, why = fwd_find(r, p, NOT_IN.sp, so)
      if not q then return nil, why end
      p = q
      local b = byte_at(r, p)
      if b == 10 then
        p = p + 1
        local b3 = byte_at(r, p)
        if b3 == 10 or b3 == nil then break end -- an empty line is a word
      else
        break
      end
    end
    if p >= r.size then break end
  end
  if p >= r.size then
    -- the end of the file: an operator takes everything up to it
    if eol then return byte_at(r, r.size - 1) == 10 and r.size - 1 or r.size end
    p = math.max(prev_char(r, r.size), 0)
    if byte_at(r, p) == 10 then p = prev_char(r, p) end
  end
  return p
end

-- `n` word ends forward (e, or E). stay: the first is the end of the word the cursor is on (cw).
function N.word_end(e, n, big, so, stay)
  local r = e.r
  local p = e.pos
  for i = 1, n do
    if not (stay and i == 1) then p = next_char(r, p) end
    local q, why = fwd_find(r, p, NOT_IN.blank_or_nl, so)
    if not q then return nil, why end
    p = q
    if p >= r.size then break end
    local c = cls(byte_at(r, p), big)
    local q2, why2 = fwd_find(r, p, run_pat(c, big), so)
    if not q2 then return nil, why2 end
    p = prev_char(r, q2)
  end
  if p >= r.size then
    p = prev_char(r, r.size)
    if byte_at(r, p) == 10 then p = prev_char(r, p) end
  end
  return p
end

-- skips blanks backward from p (inclusive); stops on an empty line. Returns the new p.
local function back_over_blanks(r, p, big, so)
  while true do
    local b = byte_at(r, p)
    if cls(b, big) == "sp" then
      local q, why = bwd_find(r, p + 1, NOT_IN.sp, so)
      if not q then return nil, why end
      if q < 0 then return 0 end
      p = r:align_down(q)
    elseif b == 10 then
      if p == 0 or byte_at(r, p - 1) == 10 then return p end -- an empty line is a word
      p = prev_char(r, p)
    else
      return p
    end
  end
end

-- `n` words backward (b, or B)
function N.word_back(e, n, big, so)
  local r = e.r
  local p = e.pos
  for _ = 1, n do
    if p <= 0 then break end
    local why
    p, why = back_over_blanks(r, prev_char(r, p), big, so)
    if not p then return nil, why end
    local b = byte_at(r, p)
    if b ~= 10 and p > 0 then
      local q, why2 = bwd_find(r, p, run_pat(cls(b, big), big), so)
      if not q then return nil, why2 end
      p = q < 0 and 0 or r:align_up(q + 1)
    end
  end
  return p
end

-- `n` word ends backward (ge, or gE)
function N.word_end_back(e, n, big, so)
  local r = e.r
  local p = e.pos
  for _ = 1, n do
    if p <= 0 then break end
    local c = cls(byte_at(r, p), big)
    if c ~= "sp" and c ~= "nl" then
      local q, why = bwd_find(r, p, run_pat(c, big), so)
      if not q then return nil, why end
      p = q < 0 and 0 or r:align_down(q)
    else
      p = prev_char(r, p)
    end
    local why
    p, why = back_over_blanks(r, p, big, so)
    if not p then return nil, why end
  end
  return p
end

-- The `n`-th occurrence of the character `ch` (its UTF-8 bytes) in the line, forward or back from
-- the cursor. till: stop before it (t, T). again: this is a repeat (; ,), which does not stay
-- before the same occurrence again.
function N.find_char(e, ch, n, forward, till, again, so)
  local r = e.r
  local len = #ch
  local found = 0
  if forward then
    if byte_at(r, e.pos) == 10 then return nil, "fail" end -- on an empty line
    local start = next_char(r, e.pos)
    if till and again then start = start + 1 end
    local pos, chunk, scanned = start, chunk_first(), 0
    local carry = ""
    while pos < r.size do
      if so and so.budget and scanned >= so.budget then return nil, "budget" end
      local hi = math.min(r.size, pos + chunk)
      local data = r:raw(pos, hi)
      if #data < hi - pos then return nil, "short read" end
      local nl = data:find("\n", 1, true)
      local body = nl and data:sub(1, nl - 1) or data
      local text = carry .. body
      local base = pos - #carry
      local init = 1
      while true do
        local i = text:find(ch, init, true)
        if not i then break end
        found = found + 1
        if found == n then
          local at = base + i - 1
          if till then return prev_char(r, at) end
          return at
        end
        init = i + len
      end
      if nl then return nil, "fail" end
      carry = len > 1 and body:sub(-(len - 1)) or ""
      scanned = scanned + #data
      pos = hi
      chunk = math.min(chunk * 4, opts.scan_chunk)
      if so and so.tick then so.tick(pos - start) end
    end
    return nil, "fail"
  end
  -- backward: reverse the text and the character, so that the first hit is the nearest
  local rev_ch = ch:reverse()
  local stop = e.pos
  if till and again then stop = stop - 1 end
  local pos, chunk, scanned = stop, chunk_first(), 0
  local carry = ""
  while pos > e.ls do
    if so and so.budget and scanned >= so.budget then return nil, "budget" end
    local lo = math.max(e.ls, pos - chunk)
    local data = r:raw(lo, pos)
    if #data < pos - lo then return nil, "short read" end
    local rev = data:reverse()
    local text = carry .. rev
    local init = 1
    while true do
      local i = text:find(rev_ch, init, true)
      if not i then break end
      found = found + 1
      if found == n then
        -- i is the index in the reversed text of the first byte of the reversed character
        local at = pos - (i - 1) - len + #carry
        if till then return next_char(r, at) end
        return at
      end
      init = i + len
    end
    carry = len > 1 and rev:sub(-(len - 1)) or ""
    scanned = scanned + #data
    pos = lo
    chunk = math.min(chunk * 4, opts.scan_chunk)
    if so and so.tick then so.tick(stop - pos) end
  end
  return nil, "fail"
end


---------------------------------------------------------------------------------------------------
-- Counting lines. Moving n lines through the file counts newlines in big chunks (a compiled loop
-- over the bytes), and absolute line numbers rest on checkpoints (a line start and its number)
-- every few MB, kept as the file is walked and saved in the cache directory.
---------------------------------------------------------------------------------------------------

local is_nl = ffi.new("uint8_t[256]")
is_nl[10] = 1

-- Number of "\n" in `data` (a loop without a branch per byte, so that it runs at the same speed
-- whether newlines are dense or rare), and the 1-based index of the last one
local function count_nl(data)
  local p = ffi.cast(u8, data)
  local c = 0
  for i = 0, #data - 1 do
    c = c + is_nl[p[i]]
  end
  if c == 0 then return 0, nil end
  for i = #data - 1, 0, -1 do
    if p[i] == 10 then return c, i + 1 end
  end
end

-- 1-based index of the k-th "\n" of `data`
local function nth_nl(data, k)
  local p = ffi.cast(u8, data)
  local c = 0
  for i = 0, #data - 1 do
    if p[i] == 10 then
      c = c + 1
      if c == k then return i + 1 end
    end
  end
end

-- 1-based index of the k-th "\n" of `data` counted from its end
local function nth_nl_back(data, k)
  local p = ffi.cast(u8, data)
  local c = 0
  for i = #data - 1, 0, -1 do
    if p[i] == 10 then
      c = c + 1
      if c == k then return i + 1 end
    end
  end
end

function N.install_lines(Reader)
  -- Checkpoints: sorted by offset (and by line number), { off, line }, line 1 at offset 0.
  function Reader:checkpoint(off, line)
    local list = self.lidx
    local last = list[#list]
    if last and off <= last.off then return end
    if last and off - last.off < opts.checkpoint_gap then return end
    list[#list + 1] = { off = off, line = line }
  end

  -- The checkpoint with the largest line number that is at most `line` (or offset `off`)
  function Reader:best_checkpoint(line, off)
    local list = self.lidx
    local lo, hi = 1, #list
    while lo < hi do
      local mid = math.ceil((lo + hi) / 2)
      local c = list[mid]
      if (line and c.line <= line) or (off and c.off <= off) then lo = mid else hi = mid - 1 end
    end
    return list[lo]
  end

  -- Start of the line n lines after the line that starts at p (p must be a line start), and how
  -- many lines it really moved: fewer at the end of the file, where the last line is the end.
  -- line0: the number of the line at p, when known; then checkpoints are kept on the way.
  function Reader:lines_forward(p, n, so, line0)
    so = so or {}
    local size = self.size
    if n <= 64 then
      -- a few lines: line by line, which uses what is known about long lines
      local cur, moved = p, 0
      while moved < n do
        local e, why = self:line_end(cur, so)
        if not e then return nil, why end
        if e + 1 >= size then break end
        cur, moved = e + 1, moved + 1
        if line0 then self:checkpoint(cur, line0 + moved) end
      end
      if line0 and moved < n then self.nlines = line0 + moved end
      return cur, moved
    end
    local pos, need, cur, scanned, moved = p, n, p, 0, 0
    while need > 0 and pos < size do
      if so.budget and scanned >= so.budget then return nil, "budget" end
      local hi = math.min(size, pos + opts.scan_chunk)
      local data = self:raw(pos, hi)
      if #data < hi - pos then return nil, "short read" end
      -- the newline that ends the file starts no line
      local body = (hi >= size and data:byte(#data) == 10) and data:sub(1, #data - 1) or data
      local c, last = count_nl(body)
      if c < need then
        need = need - c
        moved = moved + c
        if last then
          cur = pos + last
          if line0 then self:checkpoint(cur, line0 + moved) end
        else
          self:note_free(cur, hi, true, false) -- the line goes on through this chunk
        end
        scanned = scanned + #data
        pos = hi
        if so.tick then so.tick(pos - p) end
      else
        local idx = nth_nl(body, need)
        cur = pos + idx
        if line0 then self:checkpoint(cur, line0 + n) end
        return cur, n
      end
    end
    if line0 then self.nlines = line0 + moved end
    return cur, moved
  end

  -- Start of the line n lines before the line that starts at p, and how many lines it moved
  function Reader:lines_backward(p, n, so)
    so = so or {}
    if p <= 0 or n <= 0 then return p, 0 end
    if n <= 64 then
      local cur, moved = p, 0
      while moved < n and cur > 0 do
        local ls, why = self:line_start(cur - 1, { budget = so.budget, tick = so.tick, nl_at_off = true })
        if not ls then return nil, why end
        cur, moved = ls, moved + 1
      end
      return cur, moved
    end
    local pos, need, scanned = p, n + 1, 0
    while pos > 0 do
      if so.budget and scanned >= so.budget then return nil, "budget" end
      local lo = math.max(0, pos - opts.scan_chunk)
      local data = self:raw(lo, pos)
      if #data < pos - lo then return nil, "short read" end
      local c = count_nl(data)
      if c < need then
        need = need - c
        scanned = scanned + #data
        pos = lo
        if so.tick then so.tick(p - pos) end
      else
        return lo + nth_nl_back(data, need), n
      end
    end
    return 0, math.min(n + 1 - need, n)
  end

  -- Start of line number `line` (1-based; the last line if there are fewer)
  function Reader:line_offset(line, so)
    if line <= 1 then return 0, 1 end
    local c = self:best_checkpoint(line, nil)
    local off, moved = self:lines_forward(c.off, line - c.line, so, c.line)
    if not off then return nil, moved end
    return off, c.line + moved
  end

  -- Number of the line that starts at `off` (a line start); nil when it is not cheap to know:
  -- the nearest checkpoint must be within the budget
  function Reader:line_number(off, so)
    local c = self:best_checkpoint(nil, off)
    if off - c.off > ((so and so.budget) or math.huge) then return nil, "budget" end
    local pos, count = c.off, c.line - 1
    while pos < off do
      local hi = math.min(off, pos + opts.scan_chunk)
      local data = self:raw(pos, hi)
      if #data < hi - pos then return nil, "short read" end
      count = count + count_nl(data)
      pos = hi
      if so and so.tick then so.tick(pos - c.off) end
    end
    return count + 1
  end

  -- The checkpoints of a file that has not been edited are kept between sessions, keyed by what
  -- identifies the file's contents; any change gives another key, so a stale one is never read.
  function Reader:index_path()
    local st = self.stat
    local key = vim.fn.sha256(string.format("%s|%d|%d|%d|%s", self.path, st.ino, st.dev, st.size, mtime_key(st)))
    return vim.fs.joinpath(vim.fn.stdpath("cache"), "streamview", key:sub(1, 32) .. ".json")
  end

  function Reader:index_load()
    if self.lidx_loaded or not self:pristine() or #self.log > 0 then return end
    self.lidx_loaded = true
    local f = io.open(self:index_path(), "r")
    if not f then return end
    local ok, data = pcall(vim.json.decode, f:read("*a"))
    f:close()
    local st = self.stat
    if not ok or type(data) ~= "table" or data.size ~= st.size or data.mtime ~= mtime_key(st) or data.ino ~= st.ino then return end
    local list = { { off = 0, line = 1 } }
    for i = 1, #data.off do
      list[#list + 1] = { off = data.off[i], line = data.line[i] }
    end
    self.lidx, self.nlines = list, data.nlines
  end

  function Reader:index_save()
    if not self:pristine() or #self.log > 0 or #self.lidx < 2 then return end
    local st = self.stat
    local offs, lines = {}, {}
    for i = 2, #self.lidx do
      offs[#offs + 1] = self.lidx[i].off
      lines[#lines + 1] = self.lidx[i].line
    end
    local path = self:index_path()
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = io.open(path, "w")
    if not f then return end
    f:write(vim.json.encode({ size = st.size, mtime = mtime_key(st), ino = st.ino, nlines = self.nlines, off = offs, line = lines }))
    f:close()
  end
end

return N

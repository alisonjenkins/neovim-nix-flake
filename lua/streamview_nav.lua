-- Navigation inside lines of any length for the stream viewer: finding where a line starts and ends
-- without a limit (big chunks, memory bounded, remembering what was scanned) and UTF-8 alignment.
-- Everything here works in absolute byte offsets of the file as the viewer shows it.
local N = {}

local opts -- the viewer's options (scan_chunk, fact_min, max_facts)

function N.setup(viewer_opts) opts = viewer_opts end

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

-- First byte at or after `from` that matches `pat` (the size of the file when none does)
local function fwd_find(r, from, pat, so)
  local size, pos, chunk, scanned = r.size, from, chunk_first(), 0
  while pos < size do
    if so and so.budget and scanned >= so.budget then return nil, "budget" end
    local hi = math.min(size, pos + chunk)
    local data = r:raw(pos, hi)
    if #data < hi - pos then return nil, "short read" end
    local i = data:find(pat)
    if i then return pos + i - 1 end
    scanned = scanned + #data
    pos = hi
    chunk = math.min(chunk * 4, opts.scan_chunk)
    if so and so.tick then so.tick(pos - from) end
  end
  return size
end

-- Last byte before `before` that matches `pat` (-1 when none does)
local function bwd_find(r, before, pat, so)
  local pos, chunk, scanned = math.min(before, r.size), chunk_first(), 0
  local start = pos
  while pos > 0 do
    if so and so.budget and scanned >= so.budget then return nil, "budget" end
    local lo = math.max(0, pos - chunk)
    local data = r:raw(lo, pos)
    if #data < pos - lo then return nil, "short read" end
    local i = data:reverse():find(pat)
    if i then return pos - i end
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

-- patterns for the first byte that is not in a run of the class
local NOT_IN = {
  sp = "[^ \t\r\f\v]",
  kw = "[^%w_\128-\255]",
  bigkw = "[ \t\r\f\v\n]",
  pu = "[%w_\128-\255 \t\r\f\v\n]",
  blank_or_nl = "[^ \t\r\f\v\n]",
}

local function run_pat(c, big)
  if c == "kw" and big then return NOT_IN.bigkw end
  return NOT_IN[c]
end

local function count_chars(s)
  return select(2, s:gsub("[^\128-\191]", ""))
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

-- Index (1-based) in `s` of the k-th character start (k >= 1), or nil
local function nth_start(s, k)
  if not s:find("[\128-\255]") then return k <= #s and k or nil end
  if count_chars(s) < k then return nil end
  local lo, hi = 1, #s
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    if count_chars(s:sub(1, mid)) >= k then hi = mid else lo = mid + 1 end
  end
  return lo
end

-- n characters to the right; stops on the last character of the line
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
    local i = nth_start(body, remaining + 1)
    if i then return p + i - 1 end
    if complete then
      if #body == 0 then return p end
      local last = body:match(".*()[^\128-\191]")
      return p + (last or 1) - 1
    end
    remaining = remaining - count_chars(body)
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
    local rev = body:reverse()
    local j = nth_start(rev, remaining)
    if j then return p - j end
    remaining = remaining - count_chars(rev)
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

-- `n` words forward (w, or W when big)
function N.word_forward(e, n, big, so)
  local r = e.r
  local p = e.pos
  for _ = 1, n do
    local c = cls(byte_at(r, p), big)
    if c == "eof" then break end
    if c == "nl" then
      p = p + 1
    elseif c ~= "sp" then
      local q, why = fwd_find(r, p, run_pat(c, big), so)
      if not q then return nil, why end
      p = q
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
    p = math.max(prev_char(r, r.size), 0)
    if byte_at(r, p) == 10 then p = prev_char(r, p) end
  end
  return p
end

-- `n` word ends forward (e, or E)
function N.word_end(e, n, big, so)
  local r = e.r
  local p = e.pos
  for _ = 1, n do
    p = next_char(r, p)
    local q, why = fwd_find(r, p, NOT_IN.blank_or_nl, so)
    if not q then return nil, why end
    p = q
    if p >= r.size then break end
    local c = cls(byte_at(r, p), big)
    local q2, why2 = fwd_find(r, p, run_pat(c, big), so)
    if not q2 then return nil, why2 end
    p = prev_char(r, q2)
  end
  if p >= r.size then p = prev_char(r, r.size) end
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

return N

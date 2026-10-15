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

return N

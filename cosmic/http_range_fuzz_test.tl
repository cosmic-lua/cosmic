--- Fuzz properties for [`Http.range`] and [`Http.none_match`], which
--- read headers any client sends a handler of [`Http.serve`]: each is
--- total; a span always lies within the representation, and a range is
--- read as a span or unsatisfiable only where it is one well-formed
--- range, as a reading of the grammar written apart from the module's
--- says; and an entity tag matches itself, weak or strong, in any list
--- of well-formed tags. `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs
--- (build/fuzz/init.tl).

local Fuzz = require("build.fuzz")
local Http = require("cosmic.http")

local UNITS <const> = { "bytes", "bytes", "bytes", "Bytes", "BYTES", "items", "", "bytes " }
local SPACES <const> = { "", "", "", " ", "\t", "  " }
local DIGITS <const> = { "0", "1", "9", "00", "10", "99", "1000", "9223372036854775807",
  "9223372036854775808", "18446744073709551616", "000000000000000000000000000000000001" }
local SIZES <const> = { 0, 1, 2, 10, 100, 1000, math.maxinteger - 1, math.maxinteger }

--- A count, as digits: a small one drawn, or one of the counts at the
--- edges of the integers.
local function draw_digits(src: Fuzz.Source): string
  if src:int(0, 1) == 0 then return tostring(src:int(0, 120)) end
  return Fuzz.pick(src, DIGITS)
end

--- One range-spec in one of its three forms, or something near one.
local function draw_spec(src: Fuzz.Source): string
  local form = src:int(1, 7)
  if form <= 3 then
    -- A digit appended makes a count no less, so half of these hold
    -- their last at or past their first.
    local first = draw_digits(src)
    local last = src:int(0, 1) == 0 and first .. tostring(src:int(0, 9)) or draw_digits(src)
    return first .. "-" .. last
  end
  if form == 4 then return draw_digits(src) .. "-" end
  if form == 5 then return "-" .. draw_digits(src) end
  if form == 6 then return Fuzz.pick(src, { "-", "", "+1-2", "1-2-3", "a-b", "-+1" }) end
  return Fuzz.bytes(src, 6)
end

--- A Range header, sometimes edited, then the size it is read against.
local function gen_range(src: Fuzz.Source): string
  -- Mostly one range, and that one mostly after `=` with no space: a
  -- header with more, or a space there, is ignored.
  local elements: {string} = { (src:int(0, 3) == 0 and Fuzz.pick(src, SPACES) or "") .. draw_spec(src) }
  while src:int(0, 2) == 0 and Fuzz.more(src, #elements - 1, 2) do
    local spec = src:int(0, 2) == 0 and draw_spec(src) or ""
    elements[#elements + 1] = Fuzz.pick(src, SPACES) .. spec .. Fuzz.pick(src, SPACES)
  end
  local header = Fuzz.pick(src, SPACES) ..
    (src:int(0, 2) == 0 and Fuzz.pick(src, UNITS) or "bytes") .. "=" .. table.concat(elements, ",")
  if src:int(0, 3) == 0 then header = Fuzz.mutate(src, header, 3) end
  local size = src:int(0, 2) == 0 and Fuzz.pick(src, SIZES) or src:int(0, 200)
  return Fuzz.pack({ header, tostring(size) })
end

--- `s` without the spaces and tabs at either end.
local function trim(s: string): string
  return (s:gsub("^[ \t]+", ""):gsub("[ \t]+$", ""))
end

--- Whether the count in digits `a` is less than `b`'s: each padded with
--- zeros to the other's length and compared as text.
local function less(a: string, b: string): boolean
  local width = math.max(#a, #b)
  return ("0"):rep(width - #a) .. a < ("0"):rep(width - #b) .. b
end

--- The count in `digits` where it fits an integer, or nil.
local function small(digits: string): integer | nil
  local bare = digits:match("^0*(%d*)$")
  if #bare > 18 then return nil end
  return math.tointeger(tonumber(bare ~= "" and bare or "0"))
end

--- The one range-spec of `header` where it is one well-formed bytes
--- range, by RFC 9110's grammar: its first and last digits ("" for a
--- form without one); nil otherwise.
local function well_formed(header: string): string, string
  local unit, set = trim(header):match("^([^=]*)=(.*)$")
  if unit == nil or unit:lower() ~= "bytes" or set:match("^[ \t]") then return nil, nil end
  local specs: {string} = {}
  for element in (set .. ","):gmatch("([^,]*),") do
    if trim(element) ~= "" then specs[#specs + 1] = trim(element) end
  end
  if #specs ~= 1 then return nil, nil end
  local first, last = specs[1]:match("^([0-9]+)%-([0-9]*)$")
  if first ~= nil then
    if last ~= "" and less(last, first) then return nil, nil end
    return first, last
  end
  local suffix = specs[1]:match("^%-([0-9]+)$")
  if suffix == nil then return nil, nil end
  return "", suffix
end

-- Any header read against any size answers whole, unsatisfiable, or a
-- span within the representation, and a span or unsatisfiable only for
-- one well-formed range: where its counts fit an integer, the span the
-- RFC's arithmetic gives.
local function test_reading_a_range_is_total_and_within_the_representation(tmp: string)
  Fuzz.run({
    name = "http range total",
    dir = tmp,
    gen = gen_range,
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local header, size = fields[1], math.tointeger(tonumber(fields[2])) as integer
      local r = Http.range(header, size)
      local first, last = well_formed(header)
      Fuzz.label(r.kind)
      if r.kind == "whole" then
        if r.first ~= nil or r.last ~= nil then return false, "a whole range has bounds" end
        if first ~= nil and not (first == "" and size == 0 and (small(last) or 1) > 0) then
          return false, "a well-formed range was ignored"
        end
        return true, ""
      end
      if first == nil then return false, r.kind .. " for a range that is not one well-formed range" end
      if r.kind == "unsatisfiable" then
        if r.first ~= nil or r.last ~= nil then return false, "an unsatisfiable range has bounds" end
        local a, n = small(first), small(last)
        if first == "" and (n == nil or n > 0) or first ~= "" and a ~= nil and a < size then
          return false, "a range holding a byte is unsatisfiable"
        end
        return true, ""
      end
      if r.kind ~= "span" then return false, "kind " .. tostring(r.kind) end
      if not (0 <= r.first and r.first <= r.last and r.last <= size - 1) then
        return false, ("span %d-%d of %d bytes"):format(r.first, r.last, size)
      end
      local a, b = small(first), small(last)
      if first == "" then
        Fuzz.label("suffix")
        if b ~= nil and (r.first ~= size - math.min(b, size) or r.last ~= size - 1) then
          return false, "the suffix's span differs"
        end
      elseif a ~= nil and (b ~= nil or last == "") then
        local want_last = last == "" and size - 1 or math.min(b, size - 1)
        if want_last < size - 1 or last == "" then Fuzz.label("bounded") else Fuzz.label("clamped") end
        if r.first ~= a or r.last ~= want_last then return false, "the span differs" end
      end
      return true, ""
    end,
    requires = { "whole", "span", "unsatisfiable", "suffix", "bounded", "clamped" },
    shares = { span = 0.1 },
  })
end

--- Bytes an opaque tag may hold, a comma and a slash among them.
local ETAGC <const> = { "a", "v1", ",", "W", "/", "*", "\x80", "~", "!", " x", "" }

--- An opaque tag's bytes: some drawn from what a tag may hold, and now
--- and then a byte it may not, which makes no tag.
local function draw_opaque(src: Fuzz.Source): string
  local parts: {string} = {}
  while Fuzz.more(src, #parts, 3) do
    parts[#parts + 1] = src:int(0, 7) == 0 and string.char(src:int(0, 255)) or Fuzz.pick(src, ETAGC)
  end
  return table.concat(parts)
end

--- One entity tag as fields: whether it is weak, and its opaque bytes.
local function draw_tag(src: Fuzz.Source): string
  return (src:int(0, 1) == 0 and "W" or "S") .. draw_opaque(src)
end

--- A server's tag, then a list of tags, one of them now and then the
--- server's own, each followed by what parts it from the next: a
--- comma, with spaces and empty elements around it, or none.
local function gen_none_match(src: Fuzz.Source): string
  local own = draw_tag(src)
  local fields: {string} = { own }
  while Fuzz.more(src, #fields // 2, 4) do
    fields[#fields + 1] = src:int(0, 2) == 0 and ((src:int(0, 1) == 0 and "W" or "S") .. own:sub(2)) or
      draw_tag(src)
    fields[#fields + 1] = Fuzz.pick(src, SPACES) .. Fuzz.pick(src, { ",", ",", ", ,", "" }) ..
      Fuzz.pick(src, SPACES)
  end
  return Fuzz.pack(fields)
end

--- Whether `opaque` is what an opaque tag holds between its quotes.
local function opaque_ok(opaque: string): boolean
  return opaque:find('^[\x21\x23-\x7e\x80-\xff]*$') ~= nil
end

--- The tag `field` writes, as a server sends it.
local function tag_of(field: string): string
  return (field:sub(1, 1) == "W" and "W/" or "") .. '"' .. field:sub(2) .. '"'
end

-- A tag matches itself in every list of well-formed tags, weak or
-- strong, and only where its opaque part is in the list; any header,
-- edited or not, answers without raising.
local function test_none_match_finds_a_tag_in_any_list_of_tags(tmp: string)
  Fuzz.run({
    name = "http none_match",
    dir = tmp,
    gen = gen_none_match,
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local own = fields[1]
      if not opaque_ok(own:sub(2)) then
        Fuzz.label("no tag")
        local ok = pcall(Http.none_match, "*", tag_of(own))
        if ok then return false, "an etag that is no entity tag was taken" end
        return true, ""
      end
      local etag = tag_of(own)
      for _, weak in ipairs({ "W", "S" }) do
        if not Http.none_match(tag_of(weak .. own:sub(2)), etag) then
          return false, "a tag did not match itself, weak or strong"
        end
      end
      local parts: {string} = {}
      local every_ok, listed = true, false
      for i = 2, #fields, 2 do
        local tag, separator = fields[i], fields[i + 1] or ""
        if not opaque_ok(tag:sub(2)) then every_ok = false end
        -- What follows the last tag is a list's trailing space and empty elements.
        if i + 1 < #fields and not separator:find(",", 1, true) then every_ok = false end
        if tag:sub(2) == own:sub(2) then listed = true end
        parts[#parts + 1] = tag_of(tag) .. separator
      end
      local header = table.concat(parts)
      local got = Http.none_match(header, etag)
      if every_ok and #parts > 0 then
        Fuzz.label(listed and "listed" or "unlisted")
        if got ~= listed then
          return false, ("%q in %q: %s"):format(etag, header, tostring(got))
        end
      else
        Fuzz.label("malformed list")
      end
      return true, ""
    end,
    requires = { "listed", "unlisted", "malformed list", "no tag" },
  })
end

-- Any bytes as an If-None-Match header answer without raising.
local function test_none_match_is_total_over_any_header(tmp: string)
  Fuzz.run({
    name = "http none_match total",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      local base = '"v1", W/"x,y" , *'
      return src:int(0, 1) == 0 and Fuzz.mutate(src, base, 6) or Fuzz.bytes(src, 24)
    end,
    check = function(input: string): boolean, string
      local got = Http.none_match(input, '"v1"')
      Fuzz.label(got and "matched" or "unmatched")
      return true, ""
    end,
    requires = { "matched", "unmatched" },
  })
end

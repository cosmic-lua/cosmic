#!/usr/bin/env cosmic
-- Tests for the compact layout of cosmic.literal's writer.
--
-- The compact layout hands the value to a C encoder asked to refuse the
-- reader's domain itself, so what these tests state is the property that
-- makes it usable at all: it admits the values the default layout
-- admits, hands the rest to that layout or refuses them by the same key
-- path, and what it writes is what `parse` reads back. The default
-- layout is asserted unchanged alongside, because every committed file
-- in the tree is written by it.

local literal = require("cosmic.literal")

--- Format a value in one layout, failing the test with the writer's own
--- message when it refuses.
local function written(value: any, opts?: literal.FormatOptions): string
  local text, err = literal.format(value, opts)
  assert(text, "expected a literal, got: " .. tostring(err))
  return text
end

--- Format a value expecting refusal, and return the message.
local function refused(value: any, opts?: literal.FormatOptions): string
  local text, err = literal.format(value, opts)
  assert(not text, "expected a refusal, got: " .. tostring(text))
  return err
end

--- A nested payload with one of every value kind the grammar admits.
local function payload(): {string: any}
  return {
    alpha = {count = 1, flag = true, name = "a b"},
    beta = "x\ny",
    gamma = 42,
    delta = -0.5,
    empty = {},
    deep = {inner = {leaf = "z"}},
  }
end

--- Compare two values for structural equality, tables included.
--- @param a any One value
--- @param b any The other
--- @return boolean True when they are the same value
local function deep_equals(a: any, b: any): boolean
  if a is {string: any} and b is {string: any} then
    for k, v in pairs(a) do
      if not deep_equals(v, b[k]) then
        return false
      end
    end
    for k in pairs(b) do
      if a[k] == nil then
        return false
      end
    end
    return true
  end
  return a == b
end

-- The default layout writes every committed pin and every ratchet
-- floor in this repo, so an option argument that changed its output by
-- one byte would rewrite files nobody asked to rewrite.
local function test_default_layout_is_the_pin_layout()
  local implicit = written(payload())
  local explicit = written(payload(), {layout = "pin"})
  assert(implicit == explicit, "default layout differs from \"pin\"")
  assert(implicit:sub(1, 9) == "return {\n", "pin layout is not multi-line")
end
test_default_layout_is_the_pin_layout()

-- The point of the layout: what it writes, `parse` reads back as the
-- value that went in.
local function test_compact_round_trips()
  local value = payload()
  local text = written(value, {layout = "compact"})
  local back, err = literal.parse(text)
  assert(back, "compact output is not a literal: " .. tostring(err))
  assert(deep_equals(value, back), "compact round trip changed the value")
end
test_compact_round_trips()

-- One line, and smaller than the layout it is an alternative to.
local function test_compact_is_one_line_and_smaller()
  local value = payload()
  local compact = written(value, {layout = "compact"})
  local pin = written(value)
  assert(compact:sub(1, 8) == "return {", "compact does not start the table")
  assert(select(2, compact:gsub("\n", "")) == 1, "compact is not one line")
  assert(#compact < #pin, "compact is not smaller: " .. #compact .. " vs " .. #pin)
end
test_compact_is_one_line_and_smaller()

-- The values the C encoder writes without complaint, and what each
-- would become if nothing checked it first: `0/0` and `math.huge` are
-- arithmetic the reader refuses, an array or a non-string key is
-- outside the grammar, and a function or a cycle becomes a hex-address
-- STRING that parses -- the pair that would corrupt data silently.
--- One value both layouts must refuse, and what to call it in the
--- failure message.
local record Case
  name: string
  value: any
end

local function test_compact_refuses_what_pin_refuses()
  local cyclic: {string: any} = {}
  cyclic.self = cyclic
  local cases: {Case} = {
    {name = "nan", value = {x = 0 / 0}},
    {name = "inf", value = {x = math.huge}},
    {name = "-inf", value = {x = -math.huge}},
    {name = "array", value = {1, 2, 3}},
    {name = "mixed keys", value = {[1] = "a", b = "c"}},
    {name = "boolean key", value = {[true] = "a"}},
    {name = "function", value = {x = print}},
    {name = "cycle", value = cyclic},
  }
  for _, case in ipairs(cases) do
    local compact = refused(case.value, {layout = "compact"})
    local pin = refused(case.value)
    assert(compact == pin, case.name .. ": compact says \"" .. compact ..
      "\", pin says \"" .. pin .. "\"")
  end
end
test_compact_refuses_what_pin_refuses()

-- A non-table is refused before either writer sees it.
local function test_compact_refuses_a_non_table()
  local err = refused("just a string", {layout = "compact"})
  assert(err == refused("just a string"), "compact differs on a non-table")
  assert(err:find("not a literal table", 1, true), "unexpected: " .. err)
end
test_compact_refuses_a_non_table()

-- A layout nobody implements is refused by name rather than silently
-- treated as the default.
local function test_unknown_layout_is_refused()
  local err = refused(payload(), {layout = "yaml"})
  assert(err:find("yaml", 1, true), "the message does not name the layout: " .. err)
  assert(err:find("compact", 1, true), "the message does not name a real layout: " .. err)
end
test_unknown_layout_is_refused()

-- What the C encoder writes is only useful if the reader reads it, and
-- the two do not agree everywhere: bytes that need escaping, keys that
-- are not identifiers, and the ends of the numeric range are where an
-- encoder and a parser drift apart. Each of these is asserted to come
-- back as itself, whichever layout was asked for.
local function test_both_layouts_round_trip_the_awkward_values()
  local cases: {Case} = {
    {name = "escapes", value = {x = "a\nb\tc\rd\\e\"f'g"}},
    {name = "nul byte", value = {x = "a\0b"}},
    {name = "high bytes", value = {x = "\xff\xfe\x80"}},
    {name = "utf8", value = {x = "héllo ✓ 🌍"}},
    {name = "empty string", value = {[""] = ""}},
    {name = "odd keys", value = {["a b"] = 1, ["1x"] = 2, ["a.b"] = 3, ["a\nb"] = 4}},
    {name = "reserved keys", value = {["end"] = 1, ["nil"] = 2, ["function"] = 3}},
    {name = "int edges", value = {a = math.maxinteger, b = math.mininteger, c = 0}},
    {name = "float edges", value = {a = 0.1, b = 1e300, c = 5e-324, d = -0.0, e = 1 / 3}},
    {name = "nested edges", value = {outer = {["while"] = {x = math.mininteger}}}},
  }
  for _, case in ipairs(cases) do
    for _, layout in ipairs({"pin", "compact"}) do
      local text = written(case.value, {layout = layout})
      local back, err = literal.parse(text)
      assert(back, case.name .. " (" .. layout .. ") is not a literal: " ..
        tostring(err) .. "\n  " .. text)
      assert(deep_equals(case.value, back),
        case.name .. " (" .. layout .. ") changed the value:\n  " .. text)
    end
  end
end
test_both_layouts_round_trip_the_awkward_values()

-- A value the C encoder cannot spell is written in the pin layout
-- rather than refused: the compact layout asks for smaller output, it
-- does not narrow what the writer accepts.
local function test_compact_falls_back_to_pin_when_it_cannot_spell()
  local cases: {Case} = {
    {name = "reserved key", value = {["end"] = 1}},
    {name = "mininteger", value = {x = math.mininteger}},
    {name = "nested reserved key", value = {a = {["nil"] = true}}},
  }
  for _, case in ipairs(cases) do
    local compact = written(case.value, {layout = "compact"})
    assert(compact == written(case.value),
      case.name .. ": expected the pin layout, got:\n  " .. compact)
  end
  -- and the neighbouring cases that look similar do NOT fall back:
  -- an identifier key that merely contains a keyword, and the float of
  -- the same magnitude as the integer that has no literal spelling.
  local near: {string: any} = {ending = 1, x = -(2.0 ^ 63)}
  local compact = written(near, {layout = "compact"})
  assert(compact ~= written(near), "fell back where it did not have to")
  assert(select(2, compact:gsub("\n", "")) == 1, "the fallback test lost its subject")
end
test_compact_falls_back_to_pin_when_it_cannot_spell()

--- A value nested `depth` tables deep, with a scalar in the innermost
--- table when `leaf` is true.
local function nested(depth: integer, leaf: boolean): {string: any}
  local top: {string: any} = {}
  local cur = top
  for _ = 2, depth do
    local next_level: {string: any} = {}
    cur.a = next_level
    cur = next_level
  end
  if leaf then
    cur.x = 1
  end
  return top
end

-- Where the two layouts stop accepting nesting, which is the one place
-- their domains differ. The C encoder counts a table's contents one
-- level below the table, so it stops one level shallower than the pin
-- renderer: at the limit the value is written in the pin layout, and
-- past it both refuse with the same message.
local function test_compact_hands_the_deepest_nesting_to_pin()
  local limit = nested(32, true)
  local compact = written(limit, {layout = "compact"})
  assert(compact == written(limit), "the deepest value did not take the pin layout")
  local back, err = literal.parse(compact)
  assert(back, "the deepest value is not a literal: " .. tostring(err))
  assert(deep_equals(limit, back), "the deepest value did not round trip")

  -- one level shallower still encodes, so the test has a real subject
  local under = nested(31, true)
  local shallower = written(under, {layout = "compact"})
  assert(shallower ~= written(under), "fell back one level too early")
  assert(select(2, shallower:gsub("\n", "")) == 1, "the nesting test lost its subject")

  -- and once the pin renderer stops too, both layouts refuse by the
  -- same message: the handoff never turns a refusal into output
  local over = nested(34, true)
  assert(refused(over, {layout = "compact"}) == refused(over),
    "the layouts disagree past the nesting limit")
end
test_compact_hands_the_deepest_nesting_to_pin()

-- Sorted output is what makes committed data diff as the rows that
-- moved, so the same value must serialize to the same bytes.
local function test_compact_is_deterministic()
  local first = written(payload(), {layout = "compact"})
  for _ = 1, 8 do
    assert(written(payload(), {layout = "compact"}) == first,
      "compact output is not deterministic")
  end
end
test_compact_is_deterministic()

-- Every byte, in both layouts, in both positions a string can hold.
-- The writers spell strings through two different encoders -- `%q` in
-- the pin layout, `cosmo.EncodeLua` in the compact one -- and a byte
-- either spells the way `parse` reads or it does not, so the domain is
-- the 256 of them and the test is the sweep. Byte 27 is why this
-- exists: the C encoder writes it `\e`, which `parse` refuses, and the
-- compact writer now hands such a string to the pin layout instead.
-- The failure message names the byte, the layout and the position, so
-- the next byte an encoder spells its own way is reported by name.
local function test_every_byte_round_trips()
  for b = 0, 255 do
    local char = string.char(b)
    for _, layout in ipairs({"pin", "compact"}) do
      local opts: literal.FormatOptions = {layout = layout}
      local where = "byte " .. tostring(b) .. " in the " .. layout .. " layout"

      local as_value: {string: any} = {x = char}
      local value_back, verr = literal.parse(written(as_value, opts))
      assert(value_back, where .. " as a value: " .. tostring(verr))
      assert(deep_equals(as_value, value_back), where .. " as a value: changed")

      local as_key: {string: any} = {[char] = 1}
      local key_back, kerr = literal.parse(written(as_key, opts))
      assert(key_back, where .. " as a key: " .. tostring(kerr))
      assert(deep_equals(as_key, key_back), where .. " as a key: changed")
    end
  end
end
test_every_byte_round_trips()

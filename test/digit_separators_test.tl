--- Proves the digit separators patch/tl's 38a through 38l add. A `_`
--- between two digits of a number literal's digit run is read into the
--- literal (`1_000_000`, `3.141_592`, `0xFF_FF`, `6.02e2_3`), the
--- literal's value and its integer-or-float type are those of the text
--- without them, and the emitted Lua holds the text without them, since
--- Lua reads none. A `_` anywhere else in a literal -- trailing, doubled,
--- beside `.`, `x`, an exponent's letter or its sign -- is refused at the
--- literal, naming it and the rule.
---
--- Separators are for source literals alone: `tonumber("1_000")` is
--- still nil.

local teal = require("build.teal")

local built = assert(teal.load())

--- The Lua `source` compiles to, or nil and every error the compile
--- reported, one to a line, each with its line and column.
local function compiled(source: string): string | nil, string
  local code, result = built.gen(source, nil, nil, "tl")
  local troubles: {string} = {}
  for _, list in ipairs({ result.syntax_errors, result.type_errors }) do
    for _, e in ipairs(list) do
      troubles[#troubles + 1] = e.y .. ":" .. e.x .. ": " .. e.msg
    end
  end
  if code == nil or #troubles > 0 then
    return nil, table.concat(troubles, "\n")
  end
  return code, ""
end

--- What `local x = <literal>` gives x, and the Lua that wrote it.
local function value_of(literal: string): any, string
  local code, trouble = compiled("local x = " .. literal .. "\nreturn x\n")
  assert(code ~= nil, literal .. " should compile, but: " .. trouble)
  local chunk = assert(load(code, "=" .. literal))
  return chunk(), code
end

local function test_a_separated_literal_has_the_value_without_its_separators()
  local cases: {{string, any}} = {
    { "1_000_000", 1000000 },
    { "0_7", 7 },
    { "3.141_592", 3.141592 },
    { "1_000.5", 1000.5 },
    { ".5_5", 0.55 },
    { "6.02e2_3", 6.02e23 },
    { "1e1_0", 1e10 },
    { "1E+1_0", 1e10 },
    { "0xFF_FF", 0xFFFF },
    { "0x1_e5", 0x1e5 },
    { "0x1.8_0p1_0", 0x1.80p10 },
  }
  for _, case in ipairs(cases) do
    local literal, want = case[1], case[2]
    local got, code = value_of(literal)
    assert(got == want, literal .. " should be " .. tostring(want) .. ", but is " .. tostring(got))
    assert(math.type(got) == math.type(want), literal .. " should be " ..
        tostring(math.type(want)) .. ", but is " .. tostring(math.type(got)))
    assert(not code:find("_", 1, true), literal .. " should be emitted without its separators: " .. code)
  end
end

--- The literal's type is that of the text without its separators: an
--- integer where it has no point or exponent, a number otherwise.
local function test_a_separated_literal_types_as_its_digits_do()
  local code, trouble = compiled("local i: integer = 1_000\nlocal h: integer = 0xFF_FF\n" ..
      "local f: number = 1_000.0\nprint(i, h, f)\n")
  assert(code ~= nil, "1_000 and 0xFF_FF should be integers, but: " .. trouble)
  local float_code, float_trouble = compiled("local i: integer = 1_000.0\nprint(i)\n")
  assert(float_code == nil and float_trouble:find("got number, expected integer", 1, true),
    "1_000.0 should be a number, not an integer, but: " .. tostring(float_trouble))
end

--- A separated literal is a constant where one is read: a tuple's
--- index picks its member's type.
local function test_a_separated_index_picks_a_tuple_member()
  local code, trouble = compiled("local pair: {string, integer} = { \"a\", 1 }\n" ..
      "local n: integer = pair[0_2]\nreturn n\n")
  assert(code ~= nil, "pair[0_2] should be pair's integer member, but: " .. trouble)
end

--- A scale written with separators divides as the plain one does.
local function test_a_scale_with_separators_compiles()
  local code, trouble = compiled([[
local start = 5
local function elapsed_ms(now: integer): number
   return (now - start) / 1_000_000
end
return elapsed_ms(2_000_005)
]])
  assert(code ~= nil, "a scale written 1_000_000 should compile, but: " .. trouble)
  local chunk = assert(load(code, "=scale"))
  assert(chunk() == 2.0)
end

--- Every `_` not between two digits of its literal is refused at the
--- literal, naming it and the rule; where the literal ends its
--- statement, that is the only error.
local function test_a_misplaced_separator_is_refused_at_its_literal()
  for _, literal in ipairs({ "1_", "1__0", "1_.5", "1._5", "0x_FF", "0xF_", "1_e5", "1e_5",
      "1e+_5", "1e5_", "0x1_p4", "0x1p_4", "0x1_.8", ".5_", "0x1p+_4" }) do
    local code, trouble = compiled("local x = " .. literal .. "\nlocal y = 2\nprint(x, y)\n")
    local want = "1:11: malformed number '" .. literal .. "': a '_' in a number goes between two digits"
    assert(code == nil and trouble == want, literal .. " should be refused with\n" .. want ..
        "\nbut got\n" .. tostring(trouble))
  end
end

--- A name after a number's dot is a field, not a separator: `t._5`.
local function test_a_name_after_a_dot_is_still_a_field()
  local code, trouble = compiled("local t = { _5 = 1 }\nreturn t._5\n")
  assert(code ~= nil, "t._5 should index a field, but: " .. trouble)
  local chunk = assert(load(code, "=field"))
  assert(chunk() == 1)
end

--- Separators belong to source literals: Lua's own reading of a string
--- takes none.
local function test_tonumber_takes_no_separator()
  assert(tonumber("1_000") == nil)
  assert(1_000 == 1000 and math.type(1_000) == "integer")
end

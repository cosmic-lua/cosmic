local Number = require("cosmic.number")

local function refused(text: string, base?: integer): string
  local ok, why = pcall(function(): integer
    local value = Number.integer(text, base)
    return value
  end)
  assert(not ok, ("%q was accepted as %s"):format(text, tostring(why)))
  return tostring(why)
end

local function test_integer_reads_decimal_text()
  assert(Number.integer("0") == 0)
  assert(Number.integer("7") == 7)
  assert(Number.integer("8080") == 8080)
  assert(Number.integer("-12") == -12)
  assert(Number.integer("007") == 7)
  assert(math.type(Number.integer("5")) == "integer")
end

local function test_integer_reads_the_ends_of_the_range()
  assert(Number.integer("9223372036854775807") == math.maxinteger)
  assert(Number.integer("-9223372036854775808") == math.mininteger)
  assert(Number.integer("-9223372036854775807") == math.mininteger + 1)
end

local function test_integer_refuses_one_past_each_end_of_the_range()
  assert(refused("9223372036854775808"):find("outside what an integer holds", 1, true))
  assert(refused("-9223372036854775809"):find("outside what an integer holds", 1, true))
  assert(refused("99999999999999999999"):find("outside what an integer holds", 1, true))
end

local function test_integer_reads_other_bases_in_either_case()
  assert(Number.integer("ff", 16) == 255)
  assert(Number.integer("FF", 16) == 255)
  assert(Number.integer("0755", 8) == 493)
  assert(Number.integer("-101", 2) == -5)
  assert(Number.integer("z", 36) == 35)
  assert(Number.integer("7fffffffffffffff", 16) == math.maxinteger)
  assert(Number.integer("-8000000000000000", 16) == math.mininteger)
end

local function test_integer_does_not_wrap_in_another_base()
  -- tonumber("ffffffffffffffff", 16) is -1.
  assert(refused("ffffffffffffffff", 16):find("outside what an integer holds", 1, true))
  assert(refused("8000000000000000", 16):find("outside what an integer holds", 1, true))
  assert(refused("10000000000000000", 16):find("outside what an integer holds", 1, true))
end

local function test_integer_refuses_text_that_is_not_digits()
  assert(refused(""):find("has no digits", 1, true))
  assert(refused("-"):find("has no digits", 1, true))
  for _, text in ipairs({ "+1", " 1", "1 ", "1_000", "0x10", "1.0", "1e3", "--1", "1-", "\0", "12a" }) do
    assert(refused(text):find("is no base 10 digit", 1, true), text)
  end
end

local function test_integer_refuses_a_digit_past_the_base()
  assert(refused("8", 8):find("no base 8 digit", 1, true))
  assert(refused("2", 2):find("no base 2 digit", 1, true))
  assert(refused("g", 16):find("no base 16 digit", 1, true))
end

local function test_integer_names_the_text_and_the_place_in_its_error()
  local why = refused("12x4")
  assert(why:find('"12x4"', 1, true) and why:find('"x" at 3', 1, true), why)
  assert(why:find("cosmic.number_test:", 1, true), why)
end

local function test_integer_refuses_a_base_outside_2_to_36()
  assert(refused("1", 1):find("base 1 is not 2 to 36", 1, true))
  assert(refused("1", 37):find("base 37 is not 2 to 36", 1, true))
  assert(refused("1", 0):find("base 0 is not 2 to 36", 1, true))
  assert(refused("1", -10):find("base -10 is not 2 to 36", 1, true))
end

local function test_integer_agrees_across_the_length_that_tonumber_reads_and_the_one_it_does_not()
  -- 18 decimal digits and 15 hex digits are read by `tonumber`, more by
  -- the digit loop; leading zeros push a small value into the loop.
  assert(Number.integer("999999999999999999") == 999999999999999999)
  assert(Number.integer("0000000000000000000000012") == 12)
  assert(Number.integer("-0000000000000000000000012") == -12)
  assert(Number.integer("0000000000000000000000fF", 16) == 255)
  assert(Number.integer("fffffffffffffff", 16) == 0xfffffffffffffff)
  assert(refused("0000000000000000000000x1", 16):find('"x" at 23', 1, true))
  assert(refused("999999999999999999 "):find("is no base 10 digit", 1, true))
end

--- `value` (not negative) written in `base`, by repeated division.
local function written(value: integer, base: integer): string
  local digits = "0123456789abcdefghijklmnopqrstuvwxyz"
  if value == 0 then return "0" end
  local out = ""
  while value > 0 do
    local at = value % base + 1
    out = digits:sub(at, at) .. out
    value = value // base
  end
  return out
end

local function test_integer_reads_back_what_every_base_writes()
  for base = 2, 36 do
    for _, value in ipairs({ 0, 1, base - 1, base, 255, 123456789, math.maxinteger // 3, math.maxinteger }) do
      assert(Number.integer(written(value, base), base) == value, ("%d in base %d"):format(value, base))
      assert(Number.integer("-" .. written(value, base), base) == -value, ("-%d in base %d"):format(value, base))
    end
  end
end

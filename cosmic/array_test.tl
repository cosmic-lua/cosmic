local Array = require("cosmic.array")

local function refused(xs: {integer}, i: integer): string
  local ok, why = pcall(function(): integer
    local element = Array.at(xs, i)
    return element
  end)
  assert(not ok, ("at(%d) was accepted as %s"):format(i, tostring(why)))
  return tostring(why)
end

local function test_at_reads_each_element_from_1_to_the_length()
  local xs = { 10, 20, 30 }
  assert(Array.at(xs, 1) == 10)
  assert(Array.at(xs, 2) == 20)
  assert(Array.at(xs, 3) == 30)
  assert(Array.at(xs, #xs) == 30)
end

local function test_at_reads_an_element_of_any_type()
  assert(Array.at({ "a", "b" }, 2) == "b")
  assert(Array.at({ false }, 1) == false)
end

local function test_at_refuses_an_index_past_either_end_with_the_index_and_the_length()
  local why = refused({ 1, 2, 3 }, 4)
  assert(why:find("at(4) is outside the array of 3 (1 to 3)", 1, true), why)
  assert(refused({ 1, 2, 3 }, 0):find("at(0) is outside", 1, true))
  assert(refused({ 1, 2, 3 }, -1):find("at(-1) is outside", 1, true))
end

local function test_at_says_so_when_the_array_is_empty()
  assert(refused({}, 1):find("at(1) reads an empty array", 1, true))
end

local function test_at_blames_its_caller()
  local why = refused({ 1 }, 2)
  assert(why:find("cosmic.array_test:", 1, true), why)
end

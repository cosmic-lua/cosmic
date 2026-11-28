--- The checker's rewrites ([`Codes.Rewrite`]) and what [`Rewrite.apply`] makes of them: each puts its error right, so
--- the program it makes is checked with no error, and runs as the one written meant.
local Programs = require("lang.check_programs")
local Rewrite = require("lang.rewrite")
local Test = require("cosmic.test")

Test.policy{}

--- The edits the checker's errors of `source` hold, and how many errors it has.
local function edits_of(source: string): {Rewrite.Edit}, integer
  local r = Programs.run(source)
  local out: mut {Rewrite.Edit} = {}
  for _, e in ipairs(r.errors) do
    local w = e.rewrite
    if w ~= nil then
      out[#out + 1] = Rewrite.edit(tostring(e.code), e.y, e.x, e.offset, e.length, w)
    end
  end
  return out, #r.errors
end

--- `source` with every error rewritten: it must have errors, each with a rewrite, and the text made must check with
--- none. Returns the text made and the lines that tell of it.
local function rewritten(source: string): string, {string}
  local edits, errors = edits_of(source)
  assert(errors > 0 and #edits == errors, source .. ": " .. tostring(#edits) .. " rewrites of " .. tostring(errors) ..
      " errors")
  -- In rounds, as the agent's worker and `cosmic fix` make them: each round's text is checked again.
  local applied = Rewrite.rounds(source, function(text: string): {Rewrite.Edit}
    local found, count = edits_of(text)
    assert(#found == count, text .. ": " .. tostring(#found) .. " rewrites of " .. tostring(count) .. " errors")
    return found
  end, 4)
  local text = applied.text
  local again = Programs.run(text)
  assert(#again.errors == 0 and #again.before == 0, text .. ": " .. Programs.codes(again) .. " " ..
      table.concat(again.before, " "))
  return text, Rewrite.told("a.tl", applied.made)
end

local function test_a_number_or_boolean_in_concat_is_written_with_tostring()
  local text, told = rewritten("local n = 1\nlocal b = n > 0\nlocal s = \"a\" .. n .. \"b\" .. b .. (n + 1)\nprint(s)\n")
  assert(text == "local n = 1\nlocal b = n > 0\nlocal s = \"a\" .. tostring(n) .. \"b\" .. tostring(b) .. " ..
      "tostring((n + 1))\nprint(s)\n", text)
  assert(#told == 3 and told[1] == "a.tl:3:18: concat_type: `n` -> `tostring(n)`", table.concat(told, "\n"))
  -- `..` binds less tightly than `+`, so the sum is the operand, whole.
  local sum = rewritten("local n = 1\nprint(\"a\" .. n + 1)\n")
  assert(sum == "local n = 1\nprint(\"a\" .. tostring(n + 1))\n", sum)
end

local function test_an_optional_boolean_condition_is_tested_with_equals_true()
  local source = "local function f(): boolean? return nil end\nlocal function g(v: boolean?)\n" ..
    "  if v then print(1) end\n  while f() do end\n  if not v then print(2) end\n  assert(v)\n" ..
    "  local w = v or true\n  print(w)\nend\ng(f())\n"
  local text = rewritten(source)
  assert(text == "local function f(): boolean? return nil end\nlocal function g(v: boolean?)\n" ..
      "  if v == true then print(1) end\n  while f() == true do end\n  if not (v == true) then print(2) end\n" ..
      "  assert(v == true)\n  local w = v or true\n  print(w)\nend\ng(f())\n", text)
end

--- A value that may be nil, read where Lua raises for nil (an operand of an ordering, arithmetic or `..`, or what is
--- indexed), is taken with `!`, which raises there too.
local function test_a_value_that_may_be_nil_where_lua_raises_is_taken_with_must()
  local text = rewritten("local function g(m: {string: integer}, t: {string}, a: string, b: string): string\n" ..
      "  if m[a] > m[b] then return t[1]:upper() end\n  return \"n\" .. t[2] .. tostring(m[a] + 1)\nend\n" ..
      "print(g({}, {}, \"a\", \"b\"))\n")
  assert(text == "local function g(m: {string: integer}, t: {string}, a: string, b: string): string\n" ..
      "  if m[a]! > m[b]! then return t[1]!:upper() end\n  return \"n\" .. t[2]! .. tostring(m[a]! + 1)\nend\n" ..
      "print(g({}, {}, \"a\", \"b\"))\n", text)
end

--- A union that holds a boolean and another type is no `boolean?`: `"a"` holds as a condition and is not `true`, so
--- there is no rewrite.
local function test_a_union_with_a_boolean_has_no_rewrite()
  local edits, errors = edits_of("local function g(x: string | boolean | nil)\n  if x then print(1) end\n  assert(x)\nend\n" ..
      "g(\"a\")\n")
  assert(errors == 2 and #edits == 0, tostring(errors) .. " errors, " .. tostring(#edits) .. " rewrites")
end

--- The left of an `and` is the value of the whole where it fails: `nil` there is not `false`, so no rewrite is made.
--- Nor of the call `assert` is given alone, whose other values `==` would drop.
local function test_a_function_defined_on_a_value_that_may_be_nil_has_no_rewrite()
  local edits, errors = edits_of("local record R\n  m: function(): integer\nend\nlocal r: R? = nil\n" ..
      "function r.m(): integer return 1 end\n")
  assert(errors >= 1 and #edits == 0, tostring(errors) .. " errors, " .. tostring(#edits) .. " rewrites")
end

local function test_an_optional_boolean_that_and_or_assert_passes_on_has_no_rewrite()
  local edits, errors = edits_of("local function g(v: boolean?): integer?\n  return v and 1\nend\nprint(g(nil))\n")
  assert(errors == 1 and #edits == 0, tostring(errors))
  local called, called_errors = edits_of("local function f(): boolean?, string return nil, \"\" end\nassert(f())\n")
  assert(called_errors == 1 and #called == 0, tostring(called_errors))
end

--- `c and x or y` is `if c then x else y end` where `x` is never false or nil; the `if` is written whole, with its `end`.
local function test_a_ternary_whose_middle_is_never_false_is_written_as_an_if_expression()
  local text, told = rewritten("local a = true\nlocal n: string = \"q\"\nlocal s = a and n or \"z\"\nprint(s)\n")
  assert(text == "local a = true\nlocal n: string = \"q\"\nlocal s = if a then n else \"z\" end\nprint(s)\n", text)
  assert(told[1] == "a.tl:3:11: and_ternary: `a and n or \"z\"` -> `if a then n else \"z\" end`", told[1])
  -- as an argument, and over several lines
  local called = rewritten("local a = true\nprint(a and \"x\" or \"y\")\nprint(a and\n  \"x\" or \"y\")\n")
  assert(called == "local a = true\nprint(if a then \"x\" else \"y\" end)\nprint(if a then \"x\" else \"y\" end)\n", called)
  -- a middle that may be false or nil keeps the refusal: the `if` expression answers it differently
  local edits, errors = edits_of("local function pick(a: boolean, b: boolean | string): string | boolean\n  return a and b or \"z\"\nend\nprint(pick(true, false))\n")
  assert(errors >= 1 and #edits == 0, tostring(errors) .. " errors, " .. tostring(#edits) .. " rewrites")
  assert(Programs.codes(Programs.run("local function pick(a: boolean, b: boolean | string): string | boolean\n" ..
      "  return a and b or \"z\"\nend\nprint(pick(true, false))\n")):find("and_ternary", 1, true) ~= nil, "no and_ternary")
  local maybe, maybe_errors = edits_of("local a = true\nlocal n: string? = nil\nlocal s = a and n or \"z\"\nprint(s)\n")
  assert(maybe_errors >= 1 and #maybe == 0, tostring(maybe_errors) .. " errors, " .. tostring(#maybe) .. " rewrites") -- a comment inside would be dropped by the `if` written again, so none is offered
  local commented, commented_errors = edits_of("local a = true\nlocal s = a and -- why\n  \"x\" or \"y\"\nprint(s)\n")
  assert(commented_errors == 1 and #commented == 0, tostring(commented_errors) .. " errors, " .. tostring(#commented) .. " rewrites")
end

--- A range shorter than the string it is tested against is made as long as the string.
local function test_a_range_shorter_than_its_string_is_made_as_long()
  local text, told = rewritten("local line = \"local function test_x\"\n" ..
      "if line:sub(1, 19) == \"local function test_\" then print(line) end\n")
  assert(text == "local line = \"local function test_x\"\n" ..
      "if line:sub(1, 20) == \"local function test_\" then print(line) end\n", text)
  assert(told[1] == "a.tl:2:4: compare_disjoint: `line:sub(1, 19) == \"local function test_\"` -> " ..
      "`line:sub(1, 20) == \"local function test_\"`", told[1])
  -- the string first, a range from the end, and `~=`
  local from_end = rewritten("local l = \"abc\"\nprint(\"_test.tl\" ~= l:sub(-3))\n")
  assert(from_end == "local l = \"abc\"\nprint(\"_test.tl\" ~= l:sub(-8))\n", from_end) -- none where a comment stands inside the test
  local edits, errors = edits_of("local l = \"abc\"\nprint(\"_test.tl\" ~= -- the suffix\n  l:sub(-3))\n")
  assert(errors == 1 and #edits == 0, tostring(errors) .. " errors, " .. tostring(#edits) .. " rewrites")
end

--- A view that a local of the text declares and the text writes is declared `mut` where it is made.
local function test_a_written_view_is_declared_mut_where_it_is_made()
  local text, told = rewritten("local sums: {string: integer} = {}\nlocal list: {string} = {}\nsums[\"a\"] = 0\n" ..
      "list[#list + 1] = \"x\"\nprint(sums, list)\n")
  assert(text == "local sums: mut {string: integer} = {}\nlocal list: mut {string} = {}\nsums[\"a\"] = 0\n" ..
      "list[#list + 1] = \"x\"\nprint(sums, list)\n", text)
  assert(#told == 2 and told[1]:find("view_written", 1, true) ~= nil, table.concat(told, "\n"))
  -- a parameter is declared by its caller: a choice, no rewrite
  local edits, errors = edits_of("local function f(t: {string})\n  t[#t + 1] = \"x\"\nend\nf({})\n")
  assert(errors >= 1 and #edits == 0, tostring(errors) .. " errors, " .. tostring(#edits) .. " rewrites")
  -- a local made from a view needs a copy, not `mut`: that would swap this error for view_as_mut
  local copied, copy_errors = edits_of("local function f(p: {string}): {string}\n  local copy: {string} = p\n" ..
      "  copy[#copy + 1] = \"x\"\n  return copy\nend\nprint(f({}))\n")
  assert(copy_errors >= 1 and #copied == 0, tostring(copy_errors) .. " errors, " .. tostring(#copied) .. " rewrites")
end

local function test_overlapping_and_repeated_edits_are_made_once()
  local text = "abcdef"
  local applied = Rewrite.apply(text, {
    { code = "x", y = 1, x = 3, offset = 3, length = 2, before = "[", after = "]" },
    { code = "x", y = 1, x = 1, offset = 1, length = 4, before = "(", after = ")" },
    { code = "x", y = 1, x = 1, offset = 1, length = 4, before = "(", after = ")" },
    { code = "x", y = 1, x = 6, offset = 6, length = 1, before = "<", after = ">" },
  })
  assert(applied.text == "(abcd)e<f>" and #applied.made == 2, applied.text)
end

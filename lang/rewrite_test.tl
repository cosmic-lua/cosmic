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
      out[#out + 1] = { code = tostring(e.code), y = e.y, x = e.x, offset = e.offset, length = e.length,
        before = w.before, after = w.after }
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
  local applied = Rewrite.apply(source, edits)
  local again = Programs.run(applied.text)
  assert(#again.errors == 0 and #again.before == 0, applied.text .. ": " .. Programs.codes(again) .. " " ..
      table.concat(again.before, " "))
  return applied.text, Rewrite.told("a.tl", applied.made)
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

--- A union that holds a boolean and another type is no `boolean?`: `"a"` holds as a condition and is not `true`, so
--- there is no rewrite.
local function test_a_union_with_a_boolean_has_no_rewrite()
  local edits, errors = edits_of("local function g(x: string | boolean | nil)\n  if x then print(1) end\n  assert(x)\nend\n" ..
      "g(\"a\")\n")
  assert(errors == 2 and #edits == 0, tostring(errors) .. " errors, " .. tostring(#edits) .. " rewrites")
end

--- The left of an `and` is the value of the whole where it fails: `nil` there is not `false`, so no rewrite is made.
--- Nor of the call `assert` is given alone, whose other values `==` would drop.
local function test_an_optional_boolean_that_and_or_assert_passes_on_has_no_rewrite()
  local edits, errors = edits_of("local function g(v: boolean?): integer?\n  return v and 1\nend\nprint(g(nil))\n")
  assert(errors == 1 and #edits == 0, tostring(errors))
  local called, called_errors = edits_of("local function f(): boolean?, string return nil, \"\" end\nassert(f())\n")
  assert(called_errors == 1 and #called == 0, tostring(called_errors))
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

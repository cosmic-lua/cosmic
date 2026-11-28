--- An empty table with no declared type takes its type from the first thing stored in it: `rows[#rows + 1] = row`,
--- `seen[name] = true` or `table.insert(rows, row)`. A table read before any store has no type, and is refused as before.
local Programs = require("lang.check_programs")
local Test = require("cosmic.test")

Test.policy{ grants = { { path = "lang/stdlib.d.tl", letters = "r" }, { path = "lang/prelude.d.tl", letters = "r" } } }

local refused = Programs.says

--- Checks that `source` has no error.
local function accepted(source: string)
  local r = Programs.run(source)
  local first = r.errors[1]
  assert(#r.before == 0 and first == nil, table.concat(r.before, " ") .. (if first ~= nil then first.msg else "" end) ..
      " in\n" .. source)
end

--- The type `name` is shown as in `source`.
local function typed(source: string, name: string, display: string)
  local got = Programs.type_of(source, name)
  assert(got == display, name .. " is " .. got .. ", wanted " .. display)
end

local function test_an_append_gives_the_array_of_the_value()
  typed("local out = {}\nout[#out + 1] = \"a\"\n", "out", "mut {string}")
  typed("local out = {}\nfor i = 1, 3 do\n  out[#out + 1] = i\nend\n", "out", "mut {integer}")
end

local function test_a_keyed_store_gives_the_map_of_the_key_and_value()
  typed("local seen = {}\nseen[\"k\"] = true\n", "seen", "mut {string: boolean}")
end

local function test_the_first_store_may_read_the_table_it_fills()
  typed("local counts = {}\nfor _, w in ipairs({\"a\"}) do\n  counts[w] = (counts[w] or 0) + 1\nend\n", "counts",
    "mut {string: integer}")
end

local function test_a_key_may_be_asked_before_the_first_store()
  typed("local seen = {}\nlocal w = \"a\"\nif not seen[w] then\n  seen[w] = true\nend\n", "seen", "mut {string: boolean}")
  refused("local seen = {}\nlocal w = \"a\"\nprint(seen[w])\n", "literal_needs_type")
end

local function test_a_held_read_is_only_a_test()
  refused("local seen = {}\nlocal function get(k: string): integer\n  return seen[k] or 0\nend\nseen[\"a\"] = \"s\"\nprint(get)\n",
    "literal_needs_type")
  accepted("local seen = {}\nlocal w = \"a\"\nif seen[w] == nil then\n  seen[w] = 1\nend\n")
end

local function test_a_store_that_cannot_be_typed_is_refused()
  refused("local t = {}\nlocal k: string? = nil\nt[k] = 1\n", "literal_needs_type")
  refused("local m = {}\nm[#m + 1] = m\n", "literal_needs_type", "holds the table itself")
  refused("local t = {}\nt[#t + 2] = 1\nt[1] = \"s\"\n", "literal_needs_type")
end

local function test_table_insert_gives_the_array_of_the_value()
  typed("local out = {}\ntable.insert(out, 1)\n", "out", "mut {integer}")
end

local function test_a_comparator_takes_the_element_type()
  accepted("local rows = {}\nfor i = 1, 3 do\n  rows[#rows + 1] = { n = i, name = \"a\" }\nend\n" ..
      "table.sort(rows, function(a, b) return a.n > b.n end)\nprint(#rows)\n")
  accepted("local rows = {}\ntable.insert(rows, { n = 1 })\ntable.sort(rows, function(a, b) return a.n > b.n end)\n")
end

local function test_a_later_store_is_checked_against_the_first()
  refused("local m = {}\nm[\"a\"] = 1\nm[\"b\"] = \"s\"\n", "not_assignable", "`\"s\"` is `string`, where `integer` is wanted")
end

local function test_a_table_read_before_a_store_has_no_type()
  refused("local a = {}\nprint(#a)\n", "literal_needs_type", "`a` is read before anything is stored in it")
  refused("local a = {}\na.x = 1\n", "literal_needs_type", "`a` is read before anything is stored in it")
  refused("local b = {}\nb[1] = nil\n", "literal_needs_type", "the first value stored in this table is `nil`")
end

local function test_a_table_never_used_is_left_as_it_is()
  accepted("local seen = {}\nprint(1)\n")
  accepted("local function f()\n  local unused = {}\nend\nf()\n")
end

local function test_one_of_several_locals_may_be_unfilled()
  typed("local total, out = 0, {}\nout[#out + 1] = \"a\"\nprint(total)\n", "out", "mut {string}")
  typed("local total, out = 0, {}\nout[#out + 1] = \"a\"\nprint(total)\n", "total", "integer")
  typed("local a, b = {}, {}\na[1] = 1\nb[\"x\"] = true\n", "b", "mut {string: boolean}")
  refused("local a, b = {}, 2\nprint(#a, b)\n", "literal_needs_type", "`a` is read before anything is stored in it")
end

local function test_a_passed_table_takes_the_type_the_parameter_wants()
  accepted("local function fill(t: mut {string})\n  t[#t + 1] = \"a\"\nend\nlocal out = {}\nfill(out)\n")
end

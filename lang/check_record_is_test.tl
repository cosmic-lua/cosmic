--- `v is R` for a record `R`: told at run time by `type(v) == "table"` where `R` is the one table `v` may be, and by
--- the tag field where `v` is a tagged union of records.
local Programs = require("lang.check_programs")
local Test = require("cosmic.test")

Test.policy{ grants = { { path = "lang/stdlib.d.tl", letters = "r" }, { path = "lang/prelude.d.tl", letters = "r" } } }

local refused = Programs.says

local SHAPES <const> = "local record Circle\n  kind: \"circle\"\n  r: number\nend\nlocal record Square\n  kind: \"square\"\n" ..
  "  s: number\nend\nlocal type Shape = Circle | Square\n"

local function test_a_record_of_a_tagged_union_is_told_by_its_tag()
  Programs.stands(SHAPES .. "local function area(s: Shape): number\n  if s is Circle then\n    return s.r\n  end\n" ..
      "  return s.s\nend\nprint(area({ kind = \"circle\", r = 2 }))\nprint(area({ kind = \"square\", s = 3 }))\n", "2,3")
  -- a value that is no name is read once
  Programs.stands(SHAPES .. "local n = 0\nlocal function get(): Shape\n  n = n + 1\n  return { kind = \"square\", s = 1 }\nend\n" ..
      "print(get() is Square)\nprint(get() is Circle)\nprint(n)\n", "true,false,2")
end

local function test_a_chain_of_is_over_every_record_ends_the_function()
  Programs.stands(SHAPES .. "local function area(s: Shape): number\n  if s is Circle then\n    return s.r\n" ..
      "  elseif s is Square then\n    return s.s\n  end\nend\nprint(area({ kind = \"square\", s = 3 }))\n", "3")
end

local function test_the_one_table_a_value_may_be_is_told_by_its_kind()
  Programs.stands("local record R\n  n: integer\nend\nlocal function f(v?: R | string): integer\n  if v is R then\n" ..
      "    return v.n\n  end\n  return 0\nend\nprint(f({ n = 4 }))\nprint(f(\"s\"))\nprint(f(nil))\n", "4,0,0")
end

local function test_a_record_no_tag_tells_from_the_other_tables_is_refused()
  local untagged = Programs.run("local record P\n  x: integer\nend\nlocal record Q\n  y: integer\nend\n" ..
      "local function f(v: P | Q): integer\n  if v is P then\n    return v.x\n  end\n  return 0\nend\n")
  assert(table.concat(untagged.before, " ") == "untagged_union", table.concat(untagged.before, " "))
  assert(Programs.codes(untagged) == "is_on_record", Programs.codes(untagged))
  -- an array beside the record is a table no tag tells from it
  refused("local record P\n  x: integer\nend\nlocal function f(v: P | {string}): integer\n  if v is P then\n" ..
      "    return v.x\n  end\n  return 0\nend\nprint(f({ x = 1 }))\n", "is_on_record", "a record leaves nothing to test")
  refused("local record P\n  x: integer\nend\nlocal function f(v: any): integer\n  if v is P then\n    return 1\n  end\n" ..
      "  return 0\nend\nprint(f(1))\n", "is_on_record", "a record leaves nothing to test")
end

local function test_an_alias_of_a_union_of_records_is_refused_and_each_record_is_told_apart()
  local three = SHAPES .. "local record Dot\n  kind: \"dot\"\nend\nlocal type Round = Circle | Dot\n"
  refused(three .. "local function round(v: Circle | Square | Dot): boolean\n  return v is Round\nend\n" ..
      "print(round({ kind = \"dot\" }))\n", "is_on_record", "an alias of a union is tested for each member",
    "test each record apart (`v is A or v is B`)")
  Programs.stands(three .. "local function round(v: Circle | Square | Dot): boolean\n  return v is Circle or v is Dot\nend\n" ..
      "print(round({ kind = \"dot\" }))\nprint(round({ kind = \"square\", s = 1 }))\n", "true,false")
end

local function test_a_tag_of_several_strings_and_a_test_inside_other_operators()
  local source = "local enum Round\n  \"circle\"\n  \"oval\"\nend\nlocal record Curve\n  kind: Round\nend\n" ..
    "local record Box\n  kind: \"box\"\nend\nlocal function f(v: Curve | Box, b: boolean): boolean\n" ..
    "  return v is Box or (b and not (v is Curve))\nend\n" ..
    "print(f({ kind = \"oval\" }, false))\nprint(f({ kind = \"box\" }, true))\nprint(f({ kind = \"circle\" }, true))\n"
  Programs.stands(source, "false,true,false")
end

local function test_a_class_among_the_tables_is_told_by_its_tag_too()
  -- a class value carries its fields, the tag among them
  Programs.stands("local class C\n  kind: \"c\"\nend\nlocal record R\n  kind: \"r\"\nend\nlocal function f(v: C | R): string\n" ..
      "  if v is R then\n    return \"r\"\n  end\n  return \"c\"\nend\nprint(f({ kind = \"r\" }))\n", "r")
end

local function test_a_tag_that_may_change_or_be_missing_tells_nothing()
  local r = Programs.run("local record A\n  mut kind: \"a\"\nend\nlocal record B\n  kind: \"b\"\nend\n" ..
      "local function f(v: A | B): boolean\n  return v is A\nend\n")
  assert(table.concat(r.before, " ") == "untagged_union", table.concat(r.before, " "))
  assert(Programs.codes(r) == "is_on_record", Programs.codes(r))
end

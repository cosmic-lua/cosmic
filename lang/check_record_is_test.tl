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

local GRANTS <const> = "local record Path\n  path: string\n  letters: string\nend\nlocal record Calls\n" ..
  "  calls: string\nend\nlocal record Connect\n  connect: string\n  port?: integer\nend\n" ..
  "local type Grant = Path | Calls | Connect\n"

local function test_a_record_is_told_by_a_field_no_other_record_declares()
  Programs.stands(GRANTS .. "local function said(g: Grant): string\n  if g is Path then\n    return g.path\n" ..
      "  elseif g is Calls then\n    return g.calls\n  end\n  return g.connect\nend\n" ..
      "local list: {Grant} = { { path = \"/tmp\", letters = \"r\" }, { calls = \"fork\" }, { connect = \"h\" } }\n" ..
      "for _, g in ipairs(list) do\n  print(said(g))\nend\n", "/tmp,fork,h")
  -- a literal is the one record that declares every field it names
  Programs.stands(GRANTS .. "local function connects(g: Grant): boolean\n  return g is Connect\nend\n" ..
      "print(connects({ connect = \"h\", port = 1 }))\nprint(connects({ path = \"/\", letters = \"r\" }))\n", "true,false")
  -- a value that is no name is read once
  Programs.stands(GRANTS .. "local n = 0\nlocal function get(): Grant\n  n = n + 1\n  return { calls = \"x\" }\nend\n" ..
      "print(get() is Calls)\nprint(get() is Path)\nprint(n)\n", "true,false,2")
end

local function test_a_field_another_record_declares_or_that_may_be_nil_tells_nothing()
  -- `port` is omittable, and `path` is in both, so `Near` has no field of its own
  local r = Programs.run("local record Far\n  path: string\n  far: boolean\nend\nlocal record Near\n" ..
      "  path: string\n  port?: integer\nend\nlocal function f(v: Far | Near): boolean\n  return v is Near\nend\n")
  assert(table.concat(r.before, " ") == "untagged_union", table.concat(r.before, " "))
  assert(Programs.codes(r) == "is_on_record", Programs.codes(r))
  -- a field typed to hold nil, a `mut` one and a method another record has tell nothing either
  local held = Programs.run("local record A\n  a: string?\nend\nlocal record B\n  mut b: string\nend\n" ..
      "local function f(v: A | B): boolean\n  return v is A\nend\n")
  assert(table.concat(held.before, " ") == "untagged_union", table.concat(held.before, " "))
  local method = Programs.run("local record A\n  a: string\nend\nlocal record B\n  b: string\n" ..
      "  a: function(self: B): string\nend\nlocal function f(v: A | B): boolean\n  return v is A\nend\n")
  assert(table.concat(method.before, " ") == "untagged_union", table.concat(method.before, " "))
  -- a map beside the records may hold any field
  local mapped = Programs.run("local record A\n  a: string\nend\nlocal record B\n  b: string\nend\n" ..
      "local function f(v: A | B | {string: string}): boolean\n  return v is A\nend\n")
  assert(table.concat(mapped.before, " ") == "untagged_union", table.concat(mapped.before, " "))
end

local function test_a_record_no_tag_tells_from_the_other_tables_is_refused()
  local untagged = Programs.run("local record P\n  x: integer\nend\nlocal record Q\n  x: integer\n  y: integer\nend\n" ..
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

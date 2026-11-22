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
  refused("local record P\n  x: integer\nend\nlocal function f(v: P | {string}): integer\n  if v is P then\n" ..
      "    return v.x\n  end\n  return 0\nend\nprint(f({ x = 1 }))\n", "is_on_record", "whose tables no tag field tells apart",
    "give each record of the union a fixed field of its own string literal type (`kind: \"p\"`)")
  refused("local record P\n  x: integer\nend\nlocal function f(v: any): integer\n  if v is P then\n    return 1\n  end\n" ..
      "  return 0\nend\nprint(f(1))\n", "is_on_record", "a record leaves nothing to test")
end

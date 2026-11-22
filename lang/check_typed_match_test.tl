--- Tests of a typed `match`: each arm tests the value for a type as `is` does, takes what the arms before it leave of
--- that type, and binds its name to it there. The arms take every type the value may have, and an arm that takes nothing
--- is refused. Every program the checker takes is also run as the Lua [`lang.codegen`] writes ([`Programs.execute`]).
local Programs = require("lang.check_programs")
local Test = require("cosmic.test")

Test.policy{ grants = { { path = "lang/stdlib.d.tl", letters = "r" }, { path = "lang/prelude.d.tl", letters = "r" } } }

local SHAPES <const> = "local record Circle\n  kind: \"circle\"\n  r: number\nend\nlocal record Square\n  kind: \"square\"\n" ..
  "  s: number\nend\nlocal type Shape = Circle | Square\n"

local KIND <const> = "local enum Kind\n  \"a\"\n  \"b\"\nend\n"

-- arms -------------------------------------------------------------------------------------------------------

local function test_each_arm_takes_its_type_and_binds_its_name()
  Programs.stands(SHAPES .. "local function area(v: Shape): number\n  match v do\n  | Circle c then\n    return c.r * c.r\n" ..
      "  | Square q then\n    return q.s * q.s\n  end\nend\nprint(area({ kind = \"circle\", r = 2 }), area({ kind = \"square\", s = 3 }))\n",
    "4\t9")
  Programs.stands("local function f(v: string | integer | boolean): string\n  match v do\n  | string s then\n    return \"s\" .. s\n" ..
      "  | integer n then\n    return tostring(n + 1)\n  | boolean then\n    return \"b\"\n  end\nend\n" ..
      "print(f(\"x\"), f(1), f(false))\n", "sx\t2\tb")
  -- The value may be any expression, and is evaluated once.
  Programs.stands("local n = 0\nlocal function next(): integer | string\n  n = n + 1\n  return n\nend\nmatch next() do\n" ..
      "| integer i then\n  print(i)\n| string s then\n  print(s)\nend\nprint(n)\n", "1,1")
end

local function test_an_arm_of_an_enum_string_takes_it_and_the_place_narrows()
  Programs.stands(KIND .. "local function f(k: Kind): integer\n  match k do\n  | \"a\" then\n    return 1\n  | \"b\" then\n" ..
      "    return 2\n  end\nend\nprint(f(\"a\"), f(\"b\"))\n", "1\t2")
  -- The value, where it is a place, has the arm's type in the arm.
  Programs.stands("local function f(v: integer | string): integer\n  match v do\n  | integer then\n    return v + 1\n" ..
      "  | string then\n    return #v\n  end\nend\nprint(f(1), f(\"abc\"))\n", "2\t3")
end

local function test_a_wildcard_takes_what_the_arms_before_it_leave()
  Programs.stands("local function f(v: integer | string | boolean): string\n  match v do\n  | integer then\n    return \"i\"\n" ..
      "  | _ then\n    local rest: string | boolean = v\n    return tostring(rest)\n  end\nend\nprint(f(1), f(true))\n",
    "i\ttrue")
  Programs.stands("local function f(v: any): string\n  match v do\n  | string s then\n    return s\n  | _ then\n" ..
      "    return \"?\"\n  end\nend\nprint(f(\"x\"), f(1))\n", "x\t?")
end

local function test_a_record_the_value_may_be_as_its_only_table_is_told_by_its_type()
  Programs.stands("local record R\n  n: integer\nend\nlocal function f(v: R | string): integer\n  match v do\n" ..
      "  | R r then\n    return r.n\n  | string s then\n    return #s\n  end\nend\nprint(f({ n = 4 }), f(\"ab\"))\n", "4\t2")
end

local function test_an_arm_may_be_a_union_an_optional_nil_a_boolean_or_any()
  Programs.stands("local function f(v: integer | string | boolean): string\n  match v do\n  | integer | string x then\n" ..
      "    return tostring(x)\n  | boolean then\n    return \"b\"\n  end\nend\nprint(f(1), f(\"s\"), f(true))\n", "1\ts\tb")
  -- A union in parentheses may be the first arm.
  Programs.stands("local function f(v: integer | string | boolean): string\n  match v do\n  | (integer | string) x then\n" ..
      "    return tostring(x)\n  | boolean then\n    return \"b\"\n  end\nend\nprint(f(2), f(false))\n", "2\tb")
  Programs.stands("local function f(v: string?): string\n  match v do\n  | nil then\n    return \"none\"\n  | string s then\n" ..
      "    return s\n  end\nend\nprint(f(nil), f(\"x\"))\n", "none\tx")
  Programs.stands("local function f(v: boolean | string): string\n  match v do\n  | true then\n    return \"yes\"\n" ..
      "  | false then\n    return \"no\"\n  | string s then\n    return s\n  end\nend\nprint(f(true), f(false), f(\"s\"))\n",
    "yes\tno\ts")
  Programs.stands("local function f(v: integer | string): string\n  match v do\n  | integer n then\n    return tostring(n)\n" ..
      "  | any x then\n    return \"any \" .. tostring(x)\n  end\nend\nprint(f(1), f(\"s\"))\n", "1\tany s")
  -- `integer` before `number`: a float reaches the second arm.
  Programs.stands("local function f(v: number): string\n  match v do\n  | integer then\n    return \"i\"\n  | number then\n" ..
      "    return \"n\"\n  end\nend\nprint(f(1), f(1.5))\n", "i\tn")
end

local function test_records_are_told_by_their_tags_in_any_order_and_matches_nest()
  local three = SHAPES:gsub("local type Shape = Circle | Square\n", "") ..
    "local record Dot\n  kind: \"dot\"\nend\nlocal type Shape = Circle | Square | Dot\n"
  Programs.stands(three .. "local function f(v: Shape): string\n  match v do\n  | Dot then\n    return \"d\"\n  | Square q then\n" ..
      "    return \"s\" .. tostring(q.s)\n  | Circle c then\n    return \"c\" .. tostring(c.r)\n  end\nend\n" ..
      "print(f({ kind = \"circle\", r = 1 }), f({ kind = \"square\", s = 2 }), f({ kind = \"dot\" }))\n", "c1\ts2\td")
  Programs.stands("local function f(v: integer | string, w: boolean | string): string\n  match v do\n  | integer then\n" ..
      "    match w do\n    | boolean then\n      return \"ib\"\n    | string then\n      return \"is\"\n    end\n" ..
      "  | string then\n    return \"s\"\n  end\nend\nprint(f(1, true), f(1, \"x\"), f(\"a\", true))\n", "ib\tis\ts")
  -- A match of value lists and a typed match in one program.
  Programs.stands("local function ok(): (true, integer) | (false, string)\n  return true, 3\nend\nmatch ok() do\n" ..
      "| (true, n) then\n  match n do\n  | integer i then\n    print(i)\n  end\n| (false, why) then\n  print(why)\nend\n", "3")
end

-- coverage ---------------------------------------------------------------------------------------------------

local function test_a_match_takes_every_type_the_value_may_have()
  Programs.says(SHAPES .. "local function f(v: Shape)\n  match v do\n  | Circle c then\n    print(c.r)\n  end\nend\nf({ kind = \"circle\", r = 1 })\n",
    "match_missing", "this `match` takes no arm for `Square`, which `v` may be", "add the arm `| Square v then ...`")
  Programs.says(KIND .. "local function f(k: Kind)\n  match k do\n  | \"a\" then\n    print(1)\n  end\nend\nf(\"a\")\n",
    "match_missing", "no arm for `\"b\"`")
  -- A value that may be anything needs `| _`.
  Programs.says("local function f(v: any)\n  match v do\n  | string s then\n    print(s)\n  end\nend\nf(1)\n", "match_missing")
  -- Without every type taken, the function may end with no return.
  Programs.says("local function f(v: integer | string): integer\n  match v do\n  | integer n then\n    return n\n  end\nend\nprint(f(1))\n",
    "match_missing missing_return")
end

local function test_an_arm_that_takes_nothing_is_refused()
  Programs.says("local function f(v: integer | string)\n  match v do\n  | integer then\n    print(1)\n  | integer then\n    print(2)\n" ..
      "  | string then\n    print(3)\n  end\nend\nf(1)\n", "match_redundant", "the arms before it take every `integer`")
  Programs.says("local function f(v: integer | string)\n  match v do\n  | integer then\n    print(1)\n  | string then\n" ..
      "    print(2)\n  | boolean then\n    print(3)\n  end\nend\nf(1)\n", "match_redundant", "no value of it is `boolean`")
  Programs.says("local function f(v: integer | string)\n  match v do\n  | integer then\n    print(1)\n  | string then\n" ..
      "    print(2)\n  | _ then\n    print(3)\n  end\nend\nf(1)\n", "match_redundant", "the arms before it take every value")
end

local function test_an_arm_is_held_to_the_rules_of_is()
  -- A record that no tag tells from the other tables a value may be is refused as `is` refuses it.
  Programs.says("local record A\n  n: integer\nend\nlocal function f(v: any)\n  match v do\n  | A a then\n    print(a.n)\n" ..
      "  | _ then\n  end\nend\nf(1)\n", "is_on_record", "the arm `| A` cannot be told by a run-time tag")
  -- An arm of an alias of records is one arm for each.
  Programs.says(SHAPES .. "local function f(v: Shape | string)\n  match v do\n  | Shape s then\n    print(s.kind)\n" ..
      "  | string then\n  end\nend\nf(\"x\")\n", "is_on_record", "the arm `| Circle | Square`", "write an arm for each record")
end

local function test_a_name_bound_by_an_arm_is_not_seen_past_it()
  local past = Programs.run("local function f(v: integer | string)\n  match v do\n  | integer n then\n    print(n)\n" ..
      "  | string s then\n    print(s)\n  end\n  print(n)\nend\nf(1)\n")
  assert(table.concat(past.before, " ") == "unknown_variable", table.concat(past.before, " "))
end

--- Record update, `{ ...r, field = v }`: the spread copies the fields its record declares, and the fields written after
--- it replace them. What the checker accepts and refuses of it, and what the generated Lua does when it runs
--- ([`Programs.execute`]).
local Programs = require("lang.check_programs")
local Test = require("cosmic.test")
local Types = require("lang.types")

Test.policy{ grants = { { path = "lang/stdlib.d.tl", letters = "r" }, { path = "lang/prelude.d.tl", letters = "r" } } }

local HEAD <const> = "local record Config\n  host: string\n  port: integer\n  mut retries: integer\n  note: string?\n" ..
  "  tag?: string\nend\n" ..
  "local base: Config = { host = \"a\", port = 1, retries = 3, note = nil }\n"

--- The codes of checking `body` after the head.
local function codes_of(body: string, head?: string): string
  local r = Programs.run((head or HEAD) .. body)
  assert(#r.before == 0, table.concat(r.before, " ") .. " in\n" .. body)
  return Programs.codes(r)
end

--- Checks that `body` is refused with exactly `codes`, and that the first error says `msg`.
local function refused(body: string, codes: string, msg?: string, head?: string)
  local r = Programs.run((head or HEAD) .. body)
  assert(#r.before == 0, table.concat(r.before, " ") .. " in\n" .. body)
  assert(Programs.codes(r) == codes, "wanted " .. codes .. ", got " .. Programs.codes(r) .. " in\n" .. body)
  if msg ~= nil then
    local first = r.errors[1]
    assert(first ~= nil and first.msg:find(msg, 1, true) ~= nil, (if first ~= nil then first.msg else "" end) .. "\nwanted " .. msg)
  end
end

--- Checks that `body` is taken, runs, and prints `want` (the lines joined by commas).
local function prints(body: string, want: string, head?: string)
  local x = Programs.execute((head or HEAD) .. body, false)
  assert(#x.run.before == 0, table.concat(x.run.before, " ") .. " in\n" .. body)
  assert(x.ran, Programs.codes(x.run) .. " in\n" .. body)
  assert(x.fault == nil, tostring(x.fault) .. " in\n" .. x.lua)
  assert(table.concat(x.printed, ",") == want, table.concat(x.printed, ",") .. ", wanted " .. want .. " in\n" .. x.lua)
end

--- The type of the last variable called `name` after checking `body`.
local function type_of(body: string, name: string): string
  local r = Programs.run(HEAD .. body)
  assert(#r.before == 0 and Programs.codes(r) == "", table.concat(r.before, " ") .. Programs.codes(r) .. " in\n" .. body)
  local found: Types.Type? = nil
  for _, v in ipairs(r.scoped.list) do
    if v.name == name then
      found = r.result.vars[v.id] or found
    end
  end
  assert(found ~= nil, "no variable " .. name)
  return Types.display(found)
end

-- what is accepted -------------------------------------------------------------------------------------------------

local function test_a_spread_into_a_wanted_record_and_one_inferred_from_the_spread_are_the_record()
  assert(codes_of("local c: Config = { ...base, port = 2 }\nprint(c.port)\n") == "")
  assert(codes_of("local c = { ...base, port = 2 }\nprint(c.port)\n") == "")
  assert(type_of("local c = { ...base, port = 2 }\n", "c") == "Config")
  assert(codes_of("local c: Config = { ...base }\nprint(c.port)\n") == "", "a spread alone is a copy")
  assert(codes_of("local function f(c: Config): integer\n  return c.port\nend\nprint(f({ ...base, port = 3 }))\n") == "")
  assert(codes_of("local function g(): Config\n  return { ...base, host = \"b\" }\nend\nprint(g().host)\n") == "")
  assert(codes_of("local c: Config = { ...base, [\"port\"] = 2 }\nprint(c.port)\n") == "", "a constant key names a field too")
end

local function test_an_override_may_be_nil_for_a_nilable_field_and_may_set_an_omittable_one()
  assert(codes_of("local c: Config = { ...base, note = nil, tag = \"x\" }\nprint(c.tag)\n") == "")
  assert(codes_of("local c: Config = { ...base, retries = base.retries + 1 }\nprint(c.retries)\n") == "")
end

local function test_a_generic_record_is_spread_with_its_type_arguments()
  local box = "local record Box<T>\n  v: T\n  n: integer\nend\nlocal b: Box<string> = { v = \"s\", n = 1 }\n"
  assert(codes_of("local c = { ...b, n = 2 }\nprint(c.v)\n", box) == "")
  assert(codes_of("local c: Box<string> = { ...b, v = \"t\" }\nprint(c.v)\n", box) == "")
  refused("local c: Box<string> = { ...b, v = 1 }\nprint(c.v)\n", "not_assignable", "`1` is `integer`", box)
end

local function test_a_vararg_in_a_table_is_still_the_vararg()
  assert(codes_of("local function f(...: integer): {integer}\n  return { ... }\nend\nprint(#f(1, 2))\n") == "")
  assert(codes_of("local function f(...: integer): {integer}\n  return { 0, ... }\nend\nprint(#f(1, 2))\n") == "")
  prints("local function f(...: integer): {integer}\n  return { 0, ... }\nend\nprint(#f(1, 2))\n", "3")
end

-- what is refused ---------------------------------------------------------------------------------------------------

local function test_an_override_the_record_lacks_is_unknown_and_one_of_the_wrong_type_is_not_assignable()
  refused("local c: Config = { ...base, prot = 2 }\n", "literal_unknown", "`Config` has no field `prot`")
  refused("local c = { ...base, prot = 2 }\n", "literal_unknown", "`Config` has no field `prot`")
  refused("local c: Config = { ...base, port = \"x\" }\n", "not_assignable", "`\"x\"` is `string`, where `integer` is wanted")
  refused("local c = { ...base, port = \"x\" }\n", "not_assignable", "where `integer` is wanted")
  refused("local c: Config = { ...base, host = nil }\n", "nil_not_allowed")
  refused("local c: Config = { ...base, port = 1, port = 2 }\n", "literal_repeated")
end

local function test_a_spread_of_a_value_that_is_no_record_is_refused_and_says_what_it_is()
  refused("local n = 1\nlocal c = { ...n }\n", "literal_spread", "`n` is `integer`")
  refused("local s = \"x\"\nlocal c: Config = { ...s, port = 1 }\n", "literal_spread", "`s` is `string`")
  refused("local xs: {integer} = { 1 }\nlocal c = { ...xs }\n", "literal_spread", "`xs` is `{integer}`")
  refused("local xs: {integer} = { 1 }\nlocal c: {integer} = { ...xs }\n", "literal_spread")
  refused("local m: {string: integer} = {}\nlocal c = { ...m }\n", "literal_spread", "`m` is `{string: integer}`")
  refused("local c = { ...base.port }\n", "literal_spread")
  refused("local c = { ...nil }\n", "nil_not_allowed")
  refused("local c: Config = { ...{ host = \"x\", port = 1, retries = 1 }, port = 2 }\n", "literal_spread", "a table literal")
end

local function test_a_class_value_is_no_source_for_a_spread()
  local head = HEAD .. "local class Counter\n  mut n: integer\nend\nlocal k: Counter = { n = 0 }\n"
  refused("local c = { ...k }\n", "literal_spread", "`k` is `Counter`", head)
  refused("local c: Counter = { ...k }\n", "literal_spread", "`Counter`", head)
end

local function test_a_nilable_spread_must_be_narrowed_first()
  local maybe = "local function find(): Config?\n  return nil\nend\nlocal m = find()\n"
  refused(maybe .. "local c = { ...m, port = 2 }\n", "nil_not_allowed", "`m` is `Config?`")
  assert(codes_of(maybe .. "if m ~= nil then\n  local c = { ...m, port = 2 }\n  print(c.port)\nend\n") == "")
end

local function test_a_spread_is_the_first_item_and_there_is_one()
  refused("local c: Config = { ...base, ...base }\n", "literal_spread", "second spread")
  refused("local c: Config = { port = 2, ...base }\n", "literal_spread", "first item")
  refused("local c = { host = \"x\", ...base }\n", "literal_spread", "first item")
  refused("local c: Config = { ...base, ...base, port = 2 }\n", "literal_spread")
end

local function test_a_spread_makes_a_record_and_no_other_table()
  refused("local c: {Config} = { ...base }\n", "literal_spread", "a record")
  refused("local c: {string: integer} = { ...base }\n", "literal_spread", "a record")
  refused("local c: Config = { ...base, 1 }\n", "literal_shape")
  refused("local c: Config = { ...base, [\"a\" .. \"b\"] = 1 }\n", "literal_shape")
end

local function test_a_record_with_an_array_part_is_not_spread_because_the_array_would_be_lost()
  local head = "local record Row is {string}\n  label: string\nend\nlocal r: Row = { \"a\", label = \"x\" }\n"
  refused("local c = { ...r, label = \"y\" }\n", "literal_spread", "array part", head)
end

local function test_a_record_is_spread_only_as_itself_or_where_the_wanted_type_accepts_it()
  local head = HEAD .. "local record Other\n  host: string\n  port: integer\n  mut retries: integer\n  note: string?\n" ..
    "  tag?: string\nend\n"
  refused("local o: Other = { host = \"a\", port = 1, retries = 3, note = nil }\nlocal c: Config = { ...o }\n", "not_assignable",
    "`o` is `Other`, where `Config` is wanted", head)
  assert(codes_of("local u: Config | string = { ...base, port = 2 }\nprint(u)\n", head) == "")
end

-- what runs --------------------------------------------------------------------------------------------------------

local function test_the_overrides_win_the_source_is_unchanged_and_the_copy_is_a_new_table()
  prints("local c: Config = { ...base, port = 2, host = \"b\" }\n" ..
      "print(c.host, c.port, c.retries, base.host, base.port, c == base)\n", "b\t2\t3\ta\t1\tfalse")
  prints("local c = { ...base }\nprint(c.host, c.port, c.retries, c ~= base)\n", "a\t1\t3\ttrue")
  prints("local c: Config = { ...base, [\"port\"] = 9 }\nprint(c.port, base.port)\n", "9\t1")
end

local function test_only_the_declared_fields_are_copied_a_nil_stays_nil_and_a_mut_field_is_the_copys_own()
  prints("local c: Config = { ...base, tag = \"t\" }\nprint(c.note, c.tag, base.tag)\n", "nil\tt\tnil")
  prints("local c: Config = { ...base }\nc.retries = 7\nprint(c.retries, base.retries)\n", "7\t3")
end

local function test_the_spread_expression_is_evaluated_once_before_the_overrides_in_the_order_written()
  local head = HEAD .. "local trace: mut {string} = {}\n" ..
    "local function note(what: string): string\n  table.insert(trace, what)\n  return what\nend\n" ..
    "local function source(): Config\n  table.insert(trace, \"source\")\n  return base\nend\n" ..
    "local function number(n: integer): integer\n  table.insert(trace, \"n\" .. tostring(n))\n  return n\nend\n"
  prints("local c: Config = { ...source(), host = note(\"h\"), port = number(5), retries = number(6) }\n" ..
      "print(table.concat(trace, \" \"), c.host, c.port, c.retries)\n", "source h n5 n6\th\t5\t6", head)
  prints("local c = { ...source() }\nprint(#trace, c.port)\n", "1\t1", head)
  prints("local c: Config = { ...source(), port = number(2) }\nlocal d: Config = { ...c, port = number(3) }\n" ..
      "print(table.concat(trace, \" \"), d.port)\n", "source n2 n3\t3", head)
end

local function test_the_overrides_may_read_the_varargs_of_the_function_around_them()
  prints("local function with(...: integer): Config\n  return { ...base, port = #{ ... }, retries = 1 }\nend\n" ..
      "local c = with(4, 5, 6)\nprint(c.port, c.retries)\n", "3\t1")
end

local function test_a_field_named_by_a_reserved_word_of_lua_is_copied()
  local head = "local record Words\n  [\"end\"]: integer\n  goto: integer\n  n: integer\nend\n" ..
    "local w: Words = { [\"end\"] = 1, goto = 2, n = 3 }\n"
  prints("local c = { ...w, n = 4 }\nprint(c[\"end\"], c.goto, c.n)\n", "1\t2\t4", head)
end

local function test_the_lua_names_the_declared_fields_and_never_iterates_the_source()
  local x = Programs.execute(HEAD .. "local c = { ...base, port = 2 }\nprint(c.port)\n", false)
  assert(x.fault == nil and x.ran, tostring(x.fault))
  assert(not x.lua:find("pairs", 1, true), x.lua)
  assert(x.lua:find("(function(c, v1) c.port = v1 return c end)((function(s) return { host = s.host, port = s.port, retries = s.retries, note = s.note, tag = s.tag } end)(base), 2)",
    1, true), x.lua)
end

local function test_the_source_is_copied_before_an_override_runs_that_changes_it()
  -- Reading the source's fields after the overrides ran would give the copy the m of 99.
  local head = "local record Cell\n  mut n: integer\n  mut m: integer\nend\nlocal r: Cell = { n = 0, m = 2 }\n" ..
    "local function bump(): integer\n  r.m = 99\n  return 1\nend\n"
  prints("local c: Cell = { ...r, n = bump() }\nprint(c.n, c.m, r.m)\n", "1\t2\t99", head)
end

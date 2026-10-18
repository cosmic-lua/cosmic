--- The switch's gate, as data ([`lang.check_verdicts`]): the verdict table [`testdata/gate/verdicts.json`] says, for each
--- program the fork's tests pin and each input of the checker corpora, what the fork said (frozen) and what the new
--- checker says. Here the table is held to the gate: no program the fork refuses is taken without a rule, no
--- program the new checker refuses has a code without a rule, and the checker still says what the table says. The
--- programs the new checker takes that the fork refused are run, so that what makes them right is seen at run time.
local Fs = require("cosmic.fs")
local Programs = require("lang.check_programs")
local Test = require("cosmic.test")
local Translate = require("lang.translate")
local Verdicts = require("lang.check_verdicts")

Test.policy{
  grants = {
    { path = "checker/stdlib.d.tl", letters = "r" },
    { path = "checker/tl.tl", letters = "r" },
    { path = "testdata/gate", letters = "r" },
    { path = "testdata/fuzz/checker-total", letters = "r" },
    { path = "testdata/fuzz/checker-sound", letters = "r" },
  },
}

local ROWS <const> = "testdata/gate/verdicts.json"
local RULES <const> = "testdata/gate/rules.json"
local RETIRED <const> = "testdata/gate/retired.json"

local function read(path: string): string
  return (assert(Fs.read(path)))
end

local function rows(): {Verdicts.Row}
  local read_rows, trouble = Verdicts.read_rows(read(ROWS))
  assert(read_rows ~= nil, trouble)
  return read_rows
end

local function rules(): {Verdicts.Rule}
  local read_rules, trouble = Verdicts.read_rules(read(RULES))
  assert(read_rules ~= nil, trouble)
  return read_rules
end

local function retired(): {Verdicts.Retired}
  local read_retired, trouble = Verdicts.read_retired(read(RETIRED))
  assert(read_retired ~= nil, trouble)
  return read_retired
end

local function judge(): function(source: string, new_grammar?: boolean): Verdicts.Verdict
  local tl = read("checker/tl.tl")
  local prelude = tl:match("%[=====%[\n(.-)%]=====%]")
  assert(prelude ~= nil, "checker/tl.tl has no prelude")
  return Verdicts.judge(prelude, read("checker/stdlib.d.tl"))
end

local function count(list: {Verdicts.Row}, fork: string, new: string): integer
  local n = 0
  for _, row in ipairs(list) do
    if row.fork == fork and row.new == new then
      n = n + 1
    end
  end
  return n
end

--- The first of `list`, which the tests know is there.
local function first<T>(list: {T}): T
  local found = list[1]
  assert(found ~= nil, "the list is empty")
  return found
end

-- the gate -------------------------------------------------------------------------------------------------------------

local function test_every_difference_has_a_rule_and_no_program_the_fork_refuses_is_taken_without_one()
  local problems = Verdicts.problems(rows(), rules(), retired(), judge())
  assert(#problems == 0, tostring(#problems) .. " problems, the first:\n" ..
      table.concat(problems, "\n", 1, math.min(#problems, 8)))
end

local function test_the_counts_of_the_table_are_the_gates()
  local list = rows()
  -- The programs the fork's tests pin and the corpora, by what each checker says. A change to the table or to the
  -- checker that moves these is meant, and moves them here.
  assert(#list == 759, tostring(#list))
  assert(count(list, "refused", "refused") == 502, "refused by both: " .. tostring(count(list, "refused", "refused")))
  assert(count(list, "refused", "accepted") == 25, "retired: " .. tostring(count(list, "refused", "accepted")))
  assert(count(list, "accepted", "refused") == 123,
    "refused only by the new checker: " .. tostring(count(list, "accepted", "refused")))
  assert(count(list, "accepted", "accepted") == 109, "accepted by both: " .. tostring(count(list, "accepted", "accepted")))
  assert(#retired() == 25)
end

--- The table, the rules and the retired rows, changed by `change`, and the first problem the gate finds in them: the
--- test fails where it finds none.
local function problem_of(change: function({Verdicts.Row}, {Verdicts.Rule}, {Verdicts.Retired}): {Verdicts.Row}, {Verdicts.Rule},
                          {Verdicts.Retired}): string
  local list, ruled, kept = change(rows(), rules(), retired())
  local problems = Verdicts.problems(list, ruled, kept)
  assert(#problems > 0, "the change was not found")
  return first(problems)
end

--- `list` less its first member.
local function rest<T>(list: {T}): {T}
  local out: {T} = {}
  for i, each in ipairs(list) do
    if i > 1 then
      out[#out + 1] = each
    end
  end
  return out
end

local function test_a_fork_refusal_the_new_checker_takes_with_no_retired_row_is_a_problem()
  local text = problem_of(function(list: {Verdicts.Row}, ruled: {Verdicts.Rule}, kept: {Verdicts.Retired}): {Verdicts.Row}, {Verdicts.Rule}, {Verdicts.Retired}
    return list, ruled, rest(kept)
  end)
  assert(text:find("no rule in retired.json", 1, true) ~= nil, text)
end

local function test_a_fork_refusal_the_new_checker_now_takes_is_a_problem()
  local text = problem_of(function(list: {Verdicts.Row}, ruled: {Verdicts.Rule}, kept: {Verdicts.Retired}): {Verdicts.Row}, {Verdicts.Rule}, {Verdicts.Retired}
    local changed: {Verdicts.Row} = {}
    local done = false
    for i, row in ipairs(list) do
      if not done and row.fork == "refused" and row.new == "refused" then
        changed[i] = Verdicts.with_new(row, { refused = false, stage = "", codes = {}, silent = {} })
        done = true
      else
        changed[i] = row
      end
    end
    return changed, ruled, kept
  end)
  assert(text:find("no rule in retired.json", 1, true) ~= nil, text)
end

local function test_a_code_with_no_rule_is_a_problem()
  local text = problem_of(function(list: {Verdicts.Row}, ruled: {Verdicts.Rule}, kept: {Verdicts.Retired}): {Verdicts.Row}, {Verdicts.Rule}, {Verdicts.Retired}
    local changed: {Verdicts.Row} = {}
    local done = false
    for i, row in ipairs(list) do
      if not done and row.fork == "accepted" and row.new == "refused" then
        changed[i] = Verdicts.with_new(row, { refused = true, stage = row.new_stage, silent = {},
          codes = { row.new_codes, "no_such_rule" } })
        done = true
      else
        changed[i] = row
      end
    end
    return changed, ruled, kept
  end)
  assert(text:find("no_such_rule, which has no rule", 1, true) ~= nil, text)
  -- A code of the parser is a rule only through rules.json.
  local missing = problem_of(function(list: {Verdicts.Row}, ruled: {Verdicts.Rule}, kept: {Verdicts.Retired}): {Verdicts.Row}, {Verdicts.Rule}, {Verdicts.Retired}
    local without: {Verdicts.Rule} = {}
    for _, rule in ipairs(ruled) do
      if rule.code ~= "unknown_variable" then
        without[#without + 1] = rule
      end
    end
    return list, without, kept
  end)
  assert(missing:find("unknown_variable, which has no rule", 1, true) ~= nil, missing)
end

local function test_a_retired_row_needs_a_code_with_a_catalog_row_a_reason_and_a_twin_the_checker_refuses()
  local text = problem_of(function(list: {Verdicts.Row}, ruled: {Verdicts.Rule}, kept: {Verdicts.Retired}): {Verdicts.Row}, {Verdicts.Rule}, {Verdicts.Retired}
    local head = first(kept)
    local changed: {Verdicts.Retired} = { { id = head.id, code = "no_such_rule", reason = head.reason, twin = head.twin,
      twin_code = head.twin_code } }
    for _, entry in ipairs(rest(kept)) do
      changed[#changed + 1] = entry
    end
    return list, ruled, changed
  end)
  assert(text:find("no catalog row", 1, true) ~= nil, text)
  -- a twin that the checker takes
  local kept = retired()
  local head = first(kept)
  local twinned: {Verdicts.Retired} = { { id = head.id, code = head.code, reason = head.reason,
    twin = "local x = 1\nprint(x)\n", twin_code = head.twin_code } }
  for _, entry in ipairs(rest(kept)) do
    twinned[#twinned + 1] = entry
  end
  local problems = Verdicts.problems(rows(), rules(), twinned, judge())
  assert(#problems == 1 and first(problems):find("its twin is not refused with", 1, true) ~= nil, table.concat(problems, "\n"))
  -- A retired row for a program no row holds is stale.
  local stale = retired()
  stale[#stale + 1] = { id = "0000000000000000", code = "not_assignable", reason = "x", twin = "x", twin_code = "not_assignable" }
  local found = Verdicts.problems(rows(), rules(), stale)
  assert(#found == 1 and first(found):find("is retired and is in no row", 1, true) ~= nil, table.concat(found, "\n"))
end

local function test_a_retired_row_for_a_program_the_new_checker_refuses_is_stale()
  local kept = retired()
  local row: Verdicts.Row | nil = nil
  for _, each in ipairs(rows()) do
    if row == nil and each.fork == "refused" and each.new == "refused" then
      row = each
    end
  end
  assert(row ~= nil)
  local head = first(kept)
  kept[#kept + 1] = { id = row.id, code = head.code, reason = head.reason, twin = head.twin, twin_code = head.twin_code }
  local problems = Verdicts.problems(rows(), rules(), kept)
  assert(#problems == 1 and first(problems):find("is retired, and the fork does not refuse it", 1, true) ~= nil,
    table.concat(problems, "\n"))
end

local function test_a_binding_of_c_the_checker_does_not_type_yet_is_reported_and_is_no_refusal()
  -- `unchecked_binding` is a form a later piece types: the program is told so and is taken, as the pins count it.
  local v = judge()("local sys = require(\"cosmic.sys\")\nprint(sys)\n")
  assert(not v.refused and v.stage == "" and table.concat(v.codes, " ") == "unchecked_binding", table.concat(v.codes, " "))
end

local function test_a_row_is_the_digest_of_its_source()
  local text = problem_of(function(list: {Verdicts.Row}, ruled: {Verdicts.Rule}, kept: {Verdicts.Retired}): {Verdicts.Row}, {Verdicts.Rule}, {Verdicts.Retired}
    local head = first(list)
    local changed: {Verdicts.Row} = {
      {
        id = head.id, origins = head.origins, source = head.source .. " ", fork = head.fork, fork_stage = head.fork_stage,
        fork_codes = head.fork_codes, new = head.new, new_stage = head.new_stage, new_codes = head.new_codes,
      },
    }
    for _, row in ipairs(rest(list)) do
      changed[#changed + 1] = row
    end
    return changed, ruled, kept
  end)
  assert(text:find("is not the digest of its source", 1, true) ~= nil, text)
end

-- the table is what the checker says ----------------------------------------------------------------------------------

--- The rows `shard` of `shards` holds (every `shards`th), checked against what the checker says of them now.
local function holds(shard: integer, shards: integer)
  local check = judge()
  local wrong: {string} = {}
  for i, row in ipairs(rows()) do
    if i % shards == shard then
      local v = check(row.source)
      if #v.silent > 0 then
        wrong[#wrong + 1] = row.id .. " (" .. row.origins .. "): " .. table.concat(v.silent, ", ") ..
          " has type invalid and nothing is reported"
      end
      local verdict = (v.refused and "refused" or "accepted") .. " " .. v.stage .. " " .. table.concat(v.codes, " ")
      local said = row.new .. " " .. row.new_stage .. " " .. row.new_codes
      if verdict ~= said then
        wrong[#wrong + 1] = row.id .. " (" .. row.origins .. "): the table says " .. said .. ", the checker " .. verdict
      end
    end
  end
  assert(#wrong == 0, tostring(#wrong) .. " rows differ, run bin/cosmic build/gate_record.tl and read the diff:\n" ..
      table.concat(wrong, "\n", 1, math.min(#wrong, 6)))
end

local function test_the_table_is_what_the_checker_says_of_a_quarter_of_its_programs_0()
  holds(0, 4)
end

local function test_the_table_is_what_the_checker_says_of_a_quarter_of_its_programs_1()
  holds(1, 4)
end

local function test_the_table_is_what_the_checker_says_of_a_quarter_of_its_programs_2()
  holds(2, 4)
end

local function test_the_table_is_what_the_checker_says_of_a_quarter_of_its_programs_3()
  holds(3, 4)
end

local function test_every_input_of_the_corpora_is_in_the_table_once()
  local by_id: {string: Verdicts.Row} = {}
  for _, row in ipairs(rows()) do
    by_id[row.id] = row
  end
  local seen = 0
  for _, dir in ipairs({ "testdata/fuzz/checker-total", "testdata/fuzz/checker-sound" }) do
    local names = assert(Fs.list(dir))
    for _, name in ipairs(names) do
      if name:sub(-6) == ".input" then
        local path = dir .. "/" .. name
        local input = read(path)
        local row = by_id[Verdicts.id(input)]
        assert(row ~= nil, path .. " has no row: run bin/cosmic build/gate_record.tl --fork")
        assert(row.source == input and row.origins:find(path, 1, true) ~= nil, path .. " is not the source of its row")
        seen = seen + 1
      end
    end
  end
  local in_table = 0
  for _, row in ipairs(rows()) do
    if row.origins:find("testdata/fuzz/checker-", 1, true) ~= nil then
      in_table = in_table + 1
    end
  end
  assert(seen == in_table, tostring(seen) .. " inputs, " .. tostring(in_table) .. " rows")
end

-- what the new checker takes that the fork refused, run ---------------------------------------------------------------

--- Runs `source` (in the fork's grammar) as the checker's Lua: it must be taken, and it answers what it printed and the
--- error it ended with, if any.
local function run(source: string): {string}, string | nil
  local x = Programs.execute(Translate.translate(source, "t.tl").text, true)
  assert(#x.run.before == 0 and #x.run.errors == 0, "refused: " .. Programs.codes(x.run) .. "\n" .. source)
  assert(x.ran, "did not run")
  local fault = x.fault
  assert(fault == nil or fault:find("fact violated", 1, true) == nil, tostring(fault))
  return x.printed, fault
end

--- The code of the first error of `source`, in the fork's grammar.
local function refusal(source: string): string
  local r = Programs.run(Translate.translate(source, "t.tl").text)
  local codes = (table.concat(r.before, " ") .. " " .. Programs.codes(r)):gsub("^%s+", "")
  local code = codes:match("^%S+")
  assert(code ~= nil, "taken:\n" .. source)
  return code
end

local function test_a_function_that_never_returns_stands_for_one_that_may_and_the_run_never_gets_a_value_from_it()
  local printed, fault = run("local function die(): never\n  error('boom')\nend\n" ..
      "local function call(f: function(): string): string\n  return f()\nend\n" ..
      "local takes: function(f: function(): never): string = call\n" ..
      "local ok = type(takes) == 'function'\nprint(ok)\nprint(takes(die))\n")
  assert(#printed == 1 and printed[1] == "true", table.concat(printed, "|"))
  assert(fault ~= nil and fault:find("boom", 1, true) ~= nil, tostring(fault))
  -- never is a type that no value has, so a parameter of it is taken and called by no one
  local second, why = run("local function f(x: never)\n  print(x)\nend\nlocal function g(): never | nil\n  return nil\nend\n" ..
      "print(g())\nprint(f)\n")
  assert(why == nil and #second == 2 and second[1] == "nil" and tostring(second[2]):find("^function") ~= nil,
    table.concat(second, "|"))
end

local function test_the_two_programs_no_rule_of_the_plan_held_are_refused_by_the_decision_of_the_gate()
  -- The fork refuses an optional metamethod and an optional generic function, and the new checker took both for want of a
  -- rule; the decision is to refuse them (doc/plans/strict-teal.md, "an optional field is a plain value").
  assert(refusal("local record R\n  metamethod __index?: function(R, string): any\nend\n") == "optional_metamethod")
  assert(refusal("local record R\n  pick?: function<T>(T): T\nend\n") == "optional_generic")
  -- as the table says of them
  local seen = 0
  for _, row in ipairs(rows()) do
    if row.fork == "refused" and (row.new_codes:find("optional_metamethod", 1, true) ~= nil or
        row.new_codes:find("optional_generic", 1, true) ~= nil) then
      seen = seen + 1
    end
  end
  assert(seen == 2, tostring(seen))
end

local function test_a_function_that_may_return_is_still_no_function_that_never_does()
  assert(refusal("local function f(): string\n  return 's'\nend\nlocal g: function(): never = f\nprint(g)\n") ==
      "not_assignable")
  assert(refusal("local function p(a: function(): string, b: function(): never)\n  b = a\nend\nprint(p)\n") ==
      "not_assignable")
  assert(refusal("local record G\n  die: function(why: string): never\nend\n" ..
      "function G.die(why: string) print(why) end\n") == "not_assignable")
end

local function test_a_value_made_non_nil_at_a_join_is_one_at_run_time()
  local printed, fault = run("local function find(n: integer): string | nil\n  if n < 3 then return nil end\n  return 'found'\nend\n" ..
      "local function greet(name: string): string return 'hello ' .. name end\n" ..
      "local n = 0\nlocal m = find(n)\nwhile m == nil do\n  n = n + 1\n  m = find(n)\nend\nprint(greet(m))\n" ..
      "local x = find(0)\nif x == nil then\n  x = 'd'\nend\nprint(greet(x))\n" ..
      "local y = find(0)\nif not y then\n  y = 'e'\nend\nprint(greet(y))\n" ..
      "local k = 0\nlocal z = find(k)\nrepeat\n  k = k + 5\n  z = find(k)\nuntil z ~= nil\nprint(greet(z))\n")
  assert(fault == nil and #printed == 4, tostring(fault))
  assert(printed[1] == "hello found" and printed[2] == "hello d" and printed[3] == "hello e" and printed[4] == "hello found",
    table.concat(printed, "|"))
end

local function test_a_join_that_does_not_make_a_place_non_nil_is_refused()
  local head = "local function find(): string | nil return nil end\nlocal function greet(name: string): string return name end\n"
  -- the exit of the loop does not test the place, or tests it the wrong way round, or the place is assigned an optional
  assert(refusal(head .. "local m = find()\nrepeat\n  m = find()\nuntil true\nprint(greet(m))\n") == "nil_not_allowed")
  assert(refusal(head .. "local m = find()\nwhile m ~= nil do\n  m = find()\nend\nprint(greet(m))\n") == "nil_not_allowed")
  assert(refusal(head .. "local x = find()\nif x == nil then\n  x = find()\nend\nprint(greet(x))\n") == "nil_not_allowed")
  assert(refusal(head .. "local x = find()\nif x ~= nil then\n  x = find()\n  print(greet(x))\nend\n") == "narrowing_dropped")
  -- one edge assigns a value that may be nil, the other tests it: the join is the union
  assert(refusal(head .. "local x = find()\nif x == nil then\n  x = find()\nelse\n  print(greet(x))\nend\nprint(greet(x))\n") ==
      "nil_not_allowed")
end

local function test_a_fixed_field_narrows_and_the_run_reads_what_the_literal_gave()
  local printed, fault = run("local record R\n  name?: string\n  done?: function(code: integer)\nend\n" ..
      "local r: R = { name = 'ada' }\nif r.name then\n  print(r.name:upper())\nend\n" ..
      "local q: R = {}\nif q.name then\n  print('not reached')\nend\nif q.done then\n  q.done(1)\nend\n" ..
      "local record Node\n  tk?: string\n  e2?: Node\nend\n" ..
      "local function pad(owner: Node): string\n  local m = owner.e2\n  if m ~= nil and m.tk ~= nil then\n    return '.' .. m.tk\n  end\n  return ''\nend\n" ..
      "local inner: Node = { tk = 'ada' }\nlocal outer: Node = { e2 = inner }\nprint(pad(outer), pad(inner) == '')\n")
  assert(fault == nil and #printed == 2, tostring(fault) .. table.concat(printed, "|"))
  assert(printed[1] == "ADA" and printed[2] == ".ada\ttrue", table.concat(printed, "|"))
end

local function test_a_field_that_can_change_narrows_nothing_and_a_write_to_a_fixed_one_is_refused()
  local fixed = "local record R\n  name?: string\nend\nlocal r: R = {}\nif r.name then\n  r.name = 'y'\nend\n"
  -- the translator would write `mut` for the write; the grammar of the new checker is given as it is
  local r = Programs.run("local record R\n  name?: string\nend\nlocal r: R = {}\nif r.name then\n  r.name = 'y'\nend\n")
  assert(Programs.codes(r) == "field_fixed", Programs.codes(r) .. fixed)
  local mutable = Programs.run("local record R\n  mut name?: string\nend\nlocal r: R = {}\nif r.name then\n  print(r.name:upper())\nend\n")
  assert(Programs.codes(mutable) == "nil_not_allowed", Programs.codes(mutable))
  -- a call between the test and the use may change a mut field, so it is not a place; a copy is
  local copy = Programs.run("local record R\n  mut name?: string\nend\nlocal r: R = {}\nlocal n = r.name\nif n then\n  print(n:upper())\nend\n")
  assert(Programs.codes(copy) == "", Programs.codes(copy))
end

local function test_a_method_is_known_to_the_class_before_the_text_that_declares_it_and_the_interface_calls_the_value_s_own()
  local printed, fault = run("local record Store\n  db: integer\nend\n" ..
      "local mt = { __gc = function(s: Store) s:close() end }\nfunction Store:close()\n  print(self.db)\nend\n" ..
      "local s: Store = { db = 7 }\ns:close()\nprint(type(mt))\n")
  assert(fault == nil and #printed == 2 and printed[1] == "7" and printed[2] == "table", table.concat(printed, "|") .. tostring(fault))
  local called, why = run("local interface I\n  m: function(I, string): string\nend\nlocal record R is I\n  n: integer\nend\n" ..
      "function R:m(s: string): string return s .. tostring(self.n) end\n" ..
      "local record S is I\n  tag: string\nend\nfunction S:m(s: string): string return s .. self.tag end\n" ..
      "local r: R = { n = 4 }\nlocal s: S = { tag = 'z' }\nlocal all: {I} = { r, s }\n" ..
      "for _, i in ipairs(all) do\n  print(i:m('x'))\nend\n")
  assert(why == nil and #called == 2 and called[1] == "x4" and called[2] == "xz", table.concat(called, "|") .. tostring(why))
  assert(refusal("local record Store\n  db: integer\nend\nfunction Store:close()\n  print(self.db)\nend\n" ..
      "local function use(s: Store)\n  s:open()\nend\nprint(use)\n") == "field_unknown")
  assert(refusal("local interface I\n  m: function(I, string): string\nend\nlocal record R is I\n  n: integer\nend\n" ..
      "function R:m(s: string): string return s end\nlocal function use(i: I): string\n  local f = i.m\n  return f(i, 'x')\nend\n" ..
      "print(use)\n") == "interface_method_value")
  assert(refusal("local interface I\n  m: function(I, string): string\nend\nlocal record R is I\n  n: integer\nend\n" ..
      "function R:m(s: integer): string return tostring(s) end\n") == "interface_disagrees")
end

--- The codes the checker gives `source`, in the new grammar, as the test of a hole: nothing is translated, so a field
--- stays as it is written.
local function codes_of(source: string): string
  local r = Programs.run(source)
  local codes = (table.concat(r.before, " ") .. " " .. Programs.codes(r)):gsub("^%s+", ""):gsub("%s+$", "")
  return codes
end

local function test_no_second_reference_can_write_a_field_a_test_of_it_narrowed()
  local head = "local record R\n  name?: string\nend\n"
  -- through an interface that declares the field `mut`, which the record has to declare as well
  assert(codes_of("local interface I\n  mut name?: string\nend\nlocal record R is I\n  name?: string\nend\n") ==
      "interface_disagrees")
  -- a `mut` field is no place, so a test of it narrows nothing
  assert(codes_of("local interface I\n  mut name?: string\nend\nlocal record R is I\n  mut name?: string\nend\n" ..
      "local function f(r: R): string\n  if r.name then\n    local i: I = r\n    i.name = nil\n    return r.name\n  end\n" ..
      "  return ''\nend\n") == "nil_not_allowed")
  -- through a map of the record, or a cast
  assert(codes_of(head .. "local function drop(m: mut {string: string})\n  m[\"name\"] = nil\nend\n" ..
      "local function f(r: R): string\n  if r.name then\n    drop(r)\n    return r.name\n  end\n  return ''\nend\n") ==
      "record_as_map")
  assert(codes_of(head .. "local function f(r: R): string\n  if r.name then\n    local m = r as {string: string}\n" ..
      "    return r.name\n  end\n  return ''\nend\n") == "cast_refused")
  -- by assigning the field, or the local that holds the record
  assert(codes_of(head .. "local function f(r: R): string\n  if r.name then\n    r.name = nil\n    return r.name\n  end\n" ..
      "  return ''\nend\n") == "field_fixed")
  assert(codes_of(head .. "local function f(r: R, q: R): string\n  if r.name then\n    r = q\n    return r.name\n  end\n" ..
      "  return ''\nend\n") == "narrowing_dropped")
end

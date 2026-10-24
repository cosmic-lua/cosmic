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
    { path = "lang/stdlib.d.tl", letters = "r" },
    { path = "lang/prelude.d.tl", letters = "r" },
    { path = "testdata/gate", letters = "r" },
    { path = "testdata/fuzz/checker-total", letters = "r" },
    { path = "testdata/fuzz/checker-sound", letters = "r" },
  },
}

local ROWS <const> = "testdata/gate/verdicts.json"
local RULES <const> = "testdata/gate/rules.json"
local RETIRED <const> = "testdata/gate/retired.json"
local OPEN <const> = "testdata/gate/open.json"
local REFUSALS <const> = "testdata/gate/fork_refusals.json"

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

local function open_programs(): {Verdicts.Open}
  local read_open, trouble = Verdicts.read_open(read(OPEN))
  assert(read_open ~= nil, trouble)
  return read_open
end

local function refusals(): {Verdicts.Refusal}
  local read_refusals, trouble = Verdicts.read_refusals(read(REFUSALS))
  assert(read_refusals ~= nil, trouble)
  return read_refusals
end

local function judge(): function(source: string, new_grammar?: boolean): Verdicts.Verdict
  return Verdicts.judge(read("lang/prelude.d.tl"), read("lang/stdlib.d.tl"))
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
  local problems = Verdicts.problems(rows(), rules(), retired(), judge(), open_programs())
  assert(#problems == 0, tostring(#problems) .. " problems, the first:\n" ..
      table.concat(problems, "\n", 1, math.min(#problems, 8)))
end

local function test_the_counts_of_the_table_are_the_gates()
  local list = rows()
  -- The programs the fork's tests pin and the corpora, by what each checker says. A change to the table or to the
  -- checker that moves these is meant, and moves them here.
  assert(#list == 970, tostring(#list))
  assert(count(list, "refused", "refused") == 700, "refused by both: " .. tostring(count(list, "refused", "refused")))
  assert(count(list, "refused", "accepted") == 36, "retired or open: " .. tostring(count(list, "refused", "accepted")))
  assert(count(list, "accepted", "refused") == 122,
    "refused only by the new checker: " .. tostring(count(list, "accepted", "refused")))
  assert(count(list, "accepted", "accepted") == 112, "accepted by both: " .. tostring(count(list, "accepted", "accepted")))
  assert(#retired() == 36)
  -- what the fork refuses and the new checker takes is either explained by a rule or open, and nothing is both
  assert(#retired() + #open_programs() == count(list, "refused", "accepted"))
end

--- The table, the rules and the retired rows, changed by `change`, and the first problem the gate finds in them: the
--- test fails where it finds none.
local function problem_of(change: function({Verdicts.Row}, {Verdicts.Rule}, {Verdicts.Retired}): {Verdicts.Row}, {Verdicts.Rule},
                          {Verdicts.Retired}): string
  local list, ruled, kept = change(rows(), rules(), retired())
  local problems = Verdicts.problems(list, ruled, kept, nil, open_programs())
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
  local problems = Verdicts.problems(rows(), rules(), twinned, judge(), open_programs())
  assert(#problems == 1 and first(problems):find("its twin is not refused with", 1, true) ~= nil, table.concat(problems, "\n"))
  -- A retired row for a program no row holds is stale.
  local stale = retired()
  stale[#stale + 1] = { id = "0000000000000000", code = "not_assignable", reason = "x", twin = "x", twin_code = "not_assignable" }
  local found = Verdicts.problems(rows(), rules(), stale, nil, open_programs())
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
  local problems = Verdicts.problems(rows(), rules(), kept, nil, open_programs())
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
        fork_codes = head.fork_codes, fork_templates = head.fork_templates, new = head.new, new_stage = head.new_stage,
        new_codes = head.new_codes,
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

-- the fork's refusals ----------------------------------------------------------------------------------------------------

--- The table, the list of the fork's refusals and the open programs, changed by `change`, and the problems the
--- coverage of the refusals finds in them: the test fails where it finds none.
local function refusal_problem_of(change: function({Verdicts.Row}, {Verdicts.Refusal}): {Verdicts.Row}, {Verdicts.Refusal}): string
  local list, kept = change(rows(), refusals())
  local problems = Verdicts.refusal_problems(list, kept)
  assert(#problems > 0, "the change was not found")
  return table.concat(problems, "\n")
end

--- `row` with the templates `named`.
local function naming(row: Verdicts.Row, named: string): Verdicts.Row
  return {
    id = row.id, origins = row.origins, source = row.source, fork = row.fork, fork_stage = row.fork_stage,
    fork_codes = row.fork_codes, fork_templates = named, new = row.new, new_stage = row.new_stage,
    new_codes = row.new_codes,
  }
end

--- `refusal` with the reason `reason` and the words `why`.
local function reasoned(each: Verdicts.Refusal, reason: string, why: string): Verdicts.Refusal
  return { id = each.id, kind = each.kind, template = each.template, sites = each.sites, reason = reason, why = why }
end

--- The refusals that a row covers (the first of each).
local function covered_by_rows(): {string: boolean}
  local out: {string: boolean} = {}
  for _, row in ipairs(rows()) do
    for word in row.fork_templates:gmatch("%S+") do
      out[word] = true
    end
  end
  return out
end

local function test_every_refusal_of_the_fork_is_covered_by_a_row_or_says_why_it_cannot_be()
  local problems = Verdicts.refusal_problems(rows(), refusals())
  assert(#problems == 0, tostring(#problems) .. " problems, the first:\n" ..
      table.concat(problems, "\n", 1, math.min(#problems, 8)))
end

local function test_the_counts_of_the_refusals_are_the_gates()
  local list = refusals()
  local covered = covered_by_rows()
  local with_reason: {string: integer} = {}
  local rows_named = 0
  for _, each in ipairs(list) do
    if each.reason ~= "" then
      with_reason[each.reason] = (with_reason[each.reason] or 0) + 1
    end
  end
  for _, row in ipairs(rows()) do
    if row.fork_templates ~= "" then
      rows_named = rows_named + 1
    end
  end
  -- a comparison of nothing with nothing agrees: each side has its rows
  assert(#list == 287, "templates: " .. tostring(#list))
  assert(rows_named == count(rows(), "refused", "refused") + count(rows(), "refused", "accepted"),
    "the programs the fork refuses name templates: " .. tostring(rows_named))
  local n_covered = 0
  for _ in pairs(covered) do
    n_covered = n_covered + 1
  end
  assert(n_covered == 250, "templates a row covers: " .. tostring(n_covered))
  assert((with_reason["internal"] or 0) == 8 and (with_reason["unreachable"] or 0) == 20 and
      (with_reason["unproven"] or 0) == 3 and (with_reason["needs_module"] or 0) == 6,
    "reasons differ")
  assert(n_covered + 37 == #list, "a template is covered or has a reason, never both or neither")
end

local function test_a_template_no_row_covers_is_a_problem_unless_it_says_why()
  local covered = covered_by_rows()
  local text = refusal_problem_of(function(list: {Verdicts.Row}, kept: {Verdicts.Refusal}): {Verdicts.Row}, {Verdicts.Refusal}
    -- take one covered template out of every row that names it
    local id = ""
    for _, each in ipairs(kept) do
      if id == "" and each.reason == "" and covered[each.id] == true then
        id = each.id
      end
    end
    local changed: {Verdicts.Row} = {}
    for i, row in ipairs(list) do
      local named: {string} = {}
      for word in row.fork_templates:gmatch("%S+") do
        if word ~= id then
          named[#named + 1] = word
        end
      end
      changed[i] = naming(row, table.concat(named, " "))
    end
    return changed, kept
  end)
  assert(text:find("no program of the table reaches", 1, true) ~= nil and text:find("no reason is given", 1, true) ~= nil, text)
end

local function test_a_reason_for_a_template_a_row_covers_is_a_problem()
  local covered = covered_by_rows()
  local text = refusal_problem_of(function(list: {Verdicts.Row}, kept: {Verdicts.Refusal}): {Verdicts.Row}, {Verdicts.Refusal}
    local changed: {Verdicts.Refusal} = {}
    local done = false
    for i, each in ipairs(kept) do
      if not done and each.reason == "" and covered[each.id] == true then
        changed[i] = reasoned(each, "unreachable", "a program reaches it")
        done = true
      else
        changed[i] = each
      end
    end
    return list, changed
  end)
  assert(text:find("drop the reason", 1, true) ~= nil, text)
end

local function test_a_reason_that_is_none_of_the_reasons_or_says_nothing_is_a_problem()
  local function change_one(reason: string, why: string): string
    return refusal_problem_of(function(list: {Verdicts.Row}, kept: {Verdicts.Refusal}): {Verdicts.Row}, {Verdicts.Refusal}
      local changed: {Verdicts.Refusal} = {}
      local done = false
      for i, each in ipairs(kept) do
        if not done and each.reason ~= "" then
          changed[i] = reasoned(each, reason, why)
          done = true
        else
          changed[i] = each
        end
      end
      return list, changed
    end)
  end
  assert(change_one("because", "a reason"):find("is none of the reasons", 1, true) ~= nil)
  assert(change_one("internal", ""):find("does not say it", 1, true) ~= nil)
end

local function test_no_refusal_of_the_fork_is_left_unfound()
  local unproven = 0
  for _, each in ipairs(refusals()) do
    assert(each.reason ~= "unfound", each.template .. " (" .. each.sites .. ") is left unfound")
    if each.reason == "unproven" then
      unproven = unproven + 1
      assert(each.why:find("no program found: ", 1, true) == 1 and each.why:find("tried", 1, true) ~= nil,
        "unproven, and not saying what was tried: " .. each.template)
    end
  end
  assert(unproven == 3, tostring(unproven) .. " unproven")
  -- a reason that is none of the reasons is a problem, "unfound" among them
  local one: Verdicts.Refusal | nil = nil
  for _, each in ipairs(refusals()) do
    if one == nil and each.reason == "unproven" then
      one = each
    end
  end
  assert(one ~= nil)
  local told = Verdicts.refusal_problems(rows(), { reasoned(one, "unfound", one.why) })
  local found = false
  for _, line in ipairs(told) do
    found = found or line:find("`unfound` is none of the reasons", 1, true) ~= nil
  end
  assert(found, table.concat(told, "\n", 1, math.min(#told, 3)))
end

local function test_a_row_that_names_a_template_the_list_lacks_or_names_none_is_a_problem()
  local unknown = refusal_problem_of(function(list: {Verdicts.Row}, kept: {Verdicts.Refusal}): {Verdicts.Row}, {Verdicts.Refusal}
    local changed: {Verdicts.Row} = {}
    for i, row in ipairs(list) do
      if i == 1 then
        changed[i] = naming(row, row.fork_templates .. " ffffffffffff")
      else
        changed[i] = row
      end
    end
    return changed, kept
  end)
  assert(unknown:find("is no template of the list", 1, true) ~= nil, unknown)
  local none = refusal_problem_of(function(list: {Verdicts.Row}, kept: {Verdicts.Refusal}): {Verdicts.Row}, {Verdicts.Refusal}
    local changed: {Verdicts.Row} = {}
    local done = false
    for i, row in ipairs(list) do
      if not done and row.fork == "refused" then
        changed[i] = naming(row, "")
        done = true
      else
        changed[i] = row
      end
    end
    return changed, kept
  end)
  assert(none:find("the fork refuses it and no template is named", 1, true) ~= nil, none)
  local taken = refusal_problem_of(function(list: {Verdicts.Row}, kept: {Verdicts.Refusal}): {Verdicts.Row}, {Verdicts.Refusal}
    local changed: {Verdicts.Row} = {}
    local done = false
    for i, row in ipairs(list) do
      if not done and row.fork == "accepted" then
        changed[i] = naming(row, first(kept).id)
        done = true
      else
        changed[i] = row
      end
    end
    return changed, kept
  end)
  assert(taken:find("the fork takes it and names templates", 1, true) ~= nil, taken)
end

local function test_a_union_of_enums_is_told_apart_by_is_at_run_time_and_is_below_none_of_its_members()
  local head = "local enum E1\n  \"a\"\n  \"b\"\nend\nlocal enum E2\n  \"b\"\n  \"c\"\nend\n"
  local printed, fault = run(head ..
      "local function show(x: E1 | E2): string\n  if x is E1 then\n    return \"E1:\" .. x\n  else\n    return \"E2:\" .. x\n  end\nend\n" ..
      "local v: E1 = \"a\"\nlocal w: E2 = \"c\"\nlocal z: E1 | E2 = \"b\"\nprint(show(v), show(w), show(z))\n")
  assert(fault == nil and #printed == 1 and printed[1] == "E1:a\tE2:c\tE1:b", table.concat(printed, "|") .. tostring(fault))
  -- the union is below neither enum, and a test of an enum it lacks is always false
  assert(refusal(head .. "local function f(x: E1 | E2): E1\n  return x\nend\nprint(f)\n") == "not_assignable")
  assert(refusal(head .. "local enum E3\n  \"d\"\nend\nlocal function f(x: E1 | E2)\n  if x is E3 then\n    print(x)\n  end\nend\nprint(f)\n") ==
      "is_disjoint")
end

local function test_an_enum_index_reads_the_field_its_value_names_and_is_the_union_of_the_fields()
  local head = "local enum E\n  \"a\"\n  \"b\"\nend\nlocal record R\n  mut a: integer\n  mut b: string\nend\n" ..
    "local r: R = { a = 1, b = \"x\" }\n"
  local printed, fault = run(head ..
      "local function get(k: E): integer | string\n  return r[k]\nend\nprint(get(\"a\"), get(\"b\"))\n" ..
      "local k: E = \"b\"\nlocal v = r[k]\nif v is string then\n  print(v:upper())\nend\n")
  assert(fault == nil and #printed == 2 and printed[1] == "1\tx" and printed[2] == "X", table.concat(printed, "|") .. tostring(fault))
  -- the read is below neither type, a write names no one field, and a value that names no field is refused
  assert(refusal(head .. "local k: E = \"a\"\nlocal n: integer = r[k]\nprint(n)\n") == "not_assignable")
  assert(refusal(head .. "local k: E = \"a\"\nr[k] = 3\n") == "record_index")
  assert(refusal("local enum F\n  \"a\"\n  \"c\"\nend\nlocal record R\n  a: integer\n  b: string\nend\n" ..
      "local r: R = { a = 1, b = \"x\" }\nlocal k: F = \"a\"\nprint(r[k])\n") == "field_unknown")
end

-- the open programs ----------------------------------------------------------------------------------------------------

local function test_a_program_the_fork_refuses_and_the_new_checker_takes_is_retired_or_open_never_neither_or_both()
  local list, ruled, kept = rows(), rules(), retired()
  -- neither: a retired program with its entry gone, and no entry in open.json, is told as one with no rule
  local lost = Verdicts.problems(list, ruled, rest(kept), nil, open_programs())
  assert(#lost == 1 and first(lost):find("no entry in open.json", 1, true) ~= nil, table.concat(lost, "\n"))
  -- both: a retired program that is open too is told
  local also: {Verdicts.Open} = { { id = first(kept).id, kind = "permissive", why = "x" } }
  local both = Verdicts.problems(list, ruled, kept, nil, also)
  assert(#both == 1 and first(both):find("is open and retired", 1, true) ~= nil, table.concat(both, "\n"))
  -- an entry of no kind, no reason or no row is told
  local odd: {Verdicts.Open} = { { id = first(kept).id, kind = "x", why = "" }, { id = "ffffffffffffffff", kind = "permissive", why = "y" } }
  local told = table.concat(Verdicts.problems(list, ruled, kept, nil, odd), "\n")
  assert(told:find("neither unchecked nor permissive", 1, true) ~= nil and told:find("with no reason", 1, true) ~= nil and
      told:find("is open and is in no row", 1, true) ~= nil, told)
end

local function test_an_open_program_the_new_checker_refuses_is_a_problem()
  local refused: Verdicts.Row | nil = nil
  for _, row in ipairs(rows()) do
    if refused == nil and row.fork == "refused" and row.new == "refused" then
      refused = row
    end
  end
  assert(refused ~= nil)
  local open: {Verdicts.Open} = { { id = refused.id, kind = "unchecked", why = "x" } }
  local told = table.concat(Verdicts.problems(rows(), rules(), retired(), nil, open), "\n")
  assert(told:find("is open, and the fork does not refuse it or the new checker does", 1, true) ~= nil, told)
end

--- The switch waits on an empty open.json: every program the fork refuses is refused by the new checker, or is taken
--- by a rule of the plan, with a retired row and its twin.
local function test_the_switch_gate_is_met_when_no_program_is_open()
  local open = open_programs()
  assert(#open == 0, tostring(#open) .. " programs the fork refuses are taken by the new checker with no rule: testdata/gate/open.json")
  assert(#Verdicts.problems(rows(), rules(), retired(), nil, open) == 0)
end

-- the programs that stand for the refusals ------------------------------------------------------------------------------

local PROGRAMS <const> = "testdata/gate/refusal_programs.txt"

local function programs(): {Verdicts.Program}
  return Verdicts.read_programs(read(PROGRAMS))
end

--- The problems the programs have against the table, the list, the retired programs and the open ones, changed by `change`.
local function program_problem_of(change: function({Verdicts.Program}, {Verdicts.Row}): {Verdicts.Program}, {Verdicts.Row}): string
  local made, list = change(programs(), rows())
  local problems = Verdicts.program_problems(made, list, refusals(), retired(), open_programs())
  assert(#problems > 0, "the change was not found")
  return table.concat(problems, "\n")
end

local function test_every_refusal_program_is_refused_for_the_rule_it_expects_or_taken_with_its_entry()
  local made = programs()
  local problems = Verdicts.program_problems(made, rows(), refusals(), retired(), open_programs())
  assert(#problems == 0, tostring(#problems) .. " problems, the first:\n" .. table.concat(problems, "\n", 1, math.min(#problems, 8)))
  -- each side has its programs: the ones refused by a code, the ones taken
  local by: {string: integer} = {}
  for _, program in ipairs(made) do
    local kind = "code"
    if program.expected == "open" or program.expected == "retired" then
      kind = program.expected
    end
    by[kind] = (by[kind] or 0) + 1
  end
  assert(#made == 200, tostring(#made))
  assert(by["code"] == 188 and by["retired"] == 12 and by["open"] == nil, tostring(by["code"]) .. " " .. tostring(by["retired"]) ..
      " " .. tostring(by["open"]))
end

local function test_a_refusal_program_is_told_when_it_expects_what_the_new_checker_does_not_say()
  -- another code, no expectation, taken where a code is expected, refused where it is taken
  local function with_expected(want: string): string
    return program_problem_of(function(made: {Verdicts.Program}, list: {Verdicts.Row}): {Verdicts.Program}, {Verdicts.Row}
      local changed: {Verdicts.Program} = {}
      for i, program in ipairs(made) do
        if i == 1 then
          changed[i] = { template = program.template, expected = want, source = program.source }
        else
          changed[i] = program
        end
      end
      return changed, list
    end)
  end
  assert(with_expected("no_such_code"):find("expected the refusal no_such_code", 1, true) ~= nil)
  assert(with_expected(""):find("says no code", 1, true) ~= nil)
  assert(with_expected("open"):find("expected open", 1, true) ~= nil)
end

local function test_a_refusal_program_without_a_row_or_for_another_template_or_that_the_fork_takes_is_told()
  local gone = program_problem_of(function(made: {Verdicts.Program}, list: {Verdicts.Row}): {Verdicts.Program}, {Verdicts.Row}
    local changed: {Verdicts.Program} = {}
    for i, program in ipairs(made) do
      changed[i] = i == 1 and { template = program.template, expected = program.expected, source = program.source .. "\n" } or program
    end
    return changed, list
  end)
  assert(gone:find("the program has no row", 1, true) ~= nil, gone)
  local elsewhere = program_problem_of(function(made: {Verdicts.Program}, list: {Verdicts.Row}): {Verdicts.Program}, {Verdicts.Row}
    local changed: {Verdicts.Program} = {}
    local other = made[2]
    assert(other ~= nil)
    for i, program in ipairs(made) do
      if i == 1 then
        changed[i] = { template = other.template, expected = program.expected, source = program.source }
      else
        changed[i] = program
      end
    end
    return changed, list
  end)
  assert(elsewhere:find("are not that template", 1, true) ~= nil, elsewhere)
  local taken = program_problem_of(function(made: {Verdicts.Program}, list: {Verdicts.Row}): {Verdicts.Program}, {Verdicts.Row}
    local head = made[1]
    assert(head ~= nil)
    local changed: {Verdicts.Row} = {}
    for i, row in ipairs(list) do
      if row.id == Verdicts.id(head.source) then
        changed[i] = { id = row.id, origins = row.origins, source = row.source, fork = "accepted", fork_stage = "", fork_codes = "",
          fork_templates = row.fork_templates, new = row.new, new_stage = row.new_stage, new_codes = row.new_codes }
      else
        changed[i] = row
      end
    end
    return made, changed
  end)
  assert(taken:find("the fork takes the program", 1, true) ~= nil, taken)
end

local function test_the_file_of_programs_reads_in_order_with_its_templates_expectations_and_sources()
  local all = Verdicts.read_programs("# note\n=== one %s => code_a\nlocal a = 1\n=== two => open\n# a note\nlocal b = 2\nlocal c = 3\n=== bare\nx\n")
  assert(#all == 3, tostring(#all))
  for i, program in ipairs(all) do
    if i == 1 then
      assert(program.template == "one %s" and program.expected == "code_a" and program.source == "local a = 1\n")
    elseif i == 2 then
      assert(program.template == "two" and program.expected == "open" and program.source == "local b = 2\nlocal c = 3\n")
    else
      assert(program.template == "bare" and program.expected == "" and program.source == "x\n")
    end
  end
end

local function test_the_readonly_write_the_new_checker_takes_is_run_and_its_twin_is_refused()
  local printed = run("local record R\n  readonly name: string\nend\nlocal r: R = {name = \"a\"}\nr.name = \"b\"\nprint(r.name)\n")
  assert(#printed == 1 and printed[1] == "b", table.concat(printed, "|"))
  assert(codes_of("local record R\n  name: string\nend\nlocal r: R = { name = 'a' }\nr.name = 'b'\n") == "field_fixed")
end

-- TODO: put the fork's warnings in the list of its refusals, once the table's `fork` says whether a program draws one: this
-- build rejects a result with warnings (build/compilation.tl's `rejected`), but build/gate_record.tl counts the errors of
-- `syntax_errors` and `type_errors` alone, so a program the fork refuses only by a warning (a variable never read, a shadowing,
-- a hint) is a row the fork takes, and moving that moves every row's verdict and the retired rows with it. The new checker's
-- own warnings are lang/warnings.tl.

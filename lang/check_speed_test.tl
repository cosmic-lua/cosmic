--- The speed of the checker ([`lang.check`]), held to ratios and never to a clock: four times the input costs about four
--- times the time, for each shape that could cost more than its length: a chain of operators, a record of many fields
--- read many times and given in a literal, a literal of many items, a union of many tagged records read by a field
--- they share, a union of records with two tag values each told apart by a fixed number of tests (checked, and declared in
--- the second guard at the end), an `if` expression of many arms, a function of many parameters called with all of
--- them, and a run of calls each after a test of an array's length, among many narrowed places (checked, and declared in
--- the guard before the last). A chain of tests over every tag of a union, and a test of every tag joined by `or`, are held to four times the
--- members costing about the square of four (16 times) and not its cube, since each test reads what the one before
--- left.
--- The guards of [`lang.relation`] are in [`lang.relation_speed_test`]; this module does not time it apart.
local Check = require("lang.check")
local Declarations = require("lang.declarations")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")
local Scopes = require("lang.scopes")
local Speed = require("lang.speed")
local Test = require("cosmic.test")

Test.policy{ cpu_features = true }

--- `source` lowered into a program, to check again and again.
local record Prepared
  program: Declarations.Program
  input: Declarations.Input
  lowered: Declarations.Lowered
end

local function prepare(source: string): Prepared
  local parsed = Parser.parse(Lexer.lex(source, "t.tl"), "t.tl", "tl")
  local parse_error = parsed.errors[1]
  assert(#parsed.errors == 0, if parse_error ~= nil then parse_error.msg else "" end)
  local scoped = Scopes.build(parsed.chunk, "t.tl", {})
  local program = Declarations.new()
  local input: Declarations.Input = { module = "t", filename = "t.tl", chunk = parsed.chunk, scoped = scoped, dialect = "tl" }
  local lowered = program:lower(input)
  local lower_error = lowered.errors[1]
  assert(#lowered.errors == 0 and #scoped.errors == 0, if lower_error ~= nil then lower_error.msg else "" end)
  return { program = program, input = input, lowered = lowered }
end

local function check(p: Prepared)
  local result = Check.check(p.program, p.input, p.lowered)
  local first = result.errors[1]
  assert(#result.errors == 0, if first ~= nil then first.msg else "" end)
end

local FORMS <const>: {string: function(n: integer): string} = {
  ["a chain of operators"] = function(n: integer): string
    local terms: mut {string} = {}
    for i = 1, n * 50 do
      terms[i] = "a"
    end
    return "local a: integer = 1\nlocal b: integer = " .. table.concat(terms, " + ") .. "\n"
  end,
  ["a record of many fields read and given"] = function(n: integer): string
    local out: mut {string} = { "local record R\n" }
    local given: mut {string} = {}
    local reads: mut {string} = {}
    for i = 1, n * 30 do
      out[#out + 1] = "  f" .. tostring(i) .. ": integer\n"
      given[i] = "f" .. tostring(i) .. " = " .. tostring(i)
      reads[i] = "local v" .. tostring(i) .. ": integer = r.f" .. tostring(i) .. "\n"
    end
    out[#out + 1] = "end\nlocal r: R = { " .. table.concat(given, ", ") .. " }\n" .. table.concat(reads)
    return table.concat(out)
  end,
  ["a literal of many items"] = function(n: integer): string
    local items: mut {string} = {}
    for i = 1, n * 100 do
      items[i] = tostring(i)
    end
    return "local xs: {integer} = { " .. table.concat(items, ", ") .. " }\nlocal ys = { " .. table.concat(items, ", ") .. " }\n"
  end,
  ["a union of many tagged records read by a shared field"] = function(n: integer): string
    local out: mut {string} = {}
    local members: mut {string} = {}
    for i = 1, n * 8 do
      out[#out + 1] = "local enum K" .. tostring(i) .. " \"k" .. tostring(i) .. "\" end\nlocal record R" .. tostring(i) .. "\n  kind: K" .. tostring(i) ..
        "\n  value: integer\nend\n"
      members[i] = "R" .. tostring(i)
    end
    out[#out + 1] = "local type Any = " .. table.concat(members, " | ") .. "\nlocal function f(a: Any): integer\n"
    for i = 1, n * 8 do
      out[#out + 1] = "  local v" .. tostring(i) .. ": integer = a.value\n"
    end
    out[#out + 1] = "  return a.value\nend\n"
    return table.concat(out)
  end,
  ["a union of many tagged records told apart by a fixed number of tests"] = function(n: integer): string
    -- The members grow and the tests do not: each test is a scan of the members, so a check that is more than linear in the
    -- members (of one test, of the narrowing it leaves, of the tag it reports) shows as more than four times the time.
    local count = n * 4
    local out: mut {string} = {}
    local members: mut {string} = {}
    for i = 1, count do
      local at = tostring(i)
      out[#out + 1] = "local enum K" .. at .. " \"k" .. at .. "\" \"j" .. at .. "\" end\nlocal record R" .. at .. "\n  kind: K" .. at ..
        "\n  f" .. at .. ": integer\nend\n"
      members[#members + 1] = "R" .. at
    end
    out[#out + 1] = "local type Node = " .. table.concat(members, " | ") .. "\nlocal function f(a: Node): integer\n"
    for i = 1, 60 do
      local m = tostring(i % count + 1)
      out[#out + 1] = "  if a.kind == \"" .. (if i % 2 == 0 then "k" else "j" end) .. m .. "\" then\n    local v" .. tostring(i) ..
        ": integer = a.f" .. m .. "\n  end\n  if a.kind ~= \"k" .. m .. "\" then\n    local w" .. tostring(i) .. ": Node = a\n  end\n"
    end
    out[#out + 1] = "  return 1\nend\n"
    return table.concat(out)
  end,
  ["a union of many tagged records told apart by a chain of tests over every tag"] = function(n: integer): string
    -- One `if` and `elseif` for each member, like the walks over the nodes of [`lang.ast`]: the chain grows with the
    -- union, and each test selects a member and leaves the rest. Each test reads the union it leaves and is a walk of
    -- it, so the chain is quadratic in the members at best; a test that walks the members again to tell them apart, or
    -- the join of the arms that asks each pair of members whether one is below the other, makes it the cube.
    local count = n * 4
    local out: mut {string} = {}
    local members: mut {string} = {}
    for i = 1, count do
      local at = tostring(i)
      out[#out + 1] = "local enum K" .. at .. " \"k" .. at .. "\" end\nlocal record R" .. at .. "\n  kind: K" .. at ..
        "\n  f" .. at .. ": integer\nend\n"
      members[#members + 1] = "R" .. at
    end
    out[#out + 1] = "local type Node = " .. table.concat(members, " | ") .. "\nlocal function f(a: Node): integer\n"
    for i = 1, count do
      out[#out + 1] = "  " .. (if i == 1 then "if" else "elseif" end) .. " a.kind == \"k" .. tostring(i) .. "\" then\n    local v" .. tostring(i) .. ": integer = a.f" ..
        tostring(i) .. "\n"
    end
    out[#out + 1] = "  end\n  return 1\nend\n"
    return table.concat(out)
  end,
  ["a union of many tagged records told apart by one test of every tag joined by or"] = function(n: integer): string
    local count = n * 4
    local out: mut {string} = {}
    local members: mut {string} = {}
    local tests: mut {string} = {}
    for i = 1, count do
      local at = tostring(i)
      out[#out + 1] = "local enum K" .. at .. " \"k" .. at .. "\" end\nlocal record R" .. at .. "\n  kind: K" .. at ..
        "\n  f" .. at .. ": integer\nend\n"
      members[#members + 1] = "R" .. at
      tests[#tests + 1] = "a.kind == \"k" .. at .. "\""
    end
    out[#out + 1] = "local type Node = " .. table.concat(members, " | ") .. "\nlocal function f(a: Node): integer\n  if " ..
      table.concat(tests, " or ") .. " then\n    local w: Node = a\n  end\n  return 1\nend\n"
    return table.concat(out)
  end,
  ["a run of calls where many places are narrowed"] = function(n: integer): string
    -- Each call takes the facts of the lengths of arrays away, which walks the facts that are paths: the narrowed fields.
    local out: mut {string} = { "local record R\n" }
    local tests: mut {string} = {}
    for i = 1, n * 20 do
      out[#out + 1] = "  f" .. tostring(i) .. "?: integer\n"
      tests[#tests + 1] = "r.f" .. tostring(i) .. " ~= nil"
    end
    out[#out + 1] = "end\nlocal function touch()\nend\nlocal xs: {integer} = { 1 }\nlocal r: R = {}\nif #xs > 0 and " ..
      table.concat(tests, " and ") .. " then\n"
    for _ = 1, n * 20 do
      out[#out + 1] = "  touch()\n"
    end
    out[#out + 1] = "end\n"
    return table.concat(out)
  end,
  ["a run of calls where the state changes between them and many places are narrowed"] = function(n: integer): string
    -- The narrowed fields stay, but each call is preceded by a test of the length of an array that the call before it took
    -- away: the state is another one at each call and holds a fact of a length, so a flag kept on the state would be of no use
    -- and a walk of the facts at each call is the product of the calls and the narrowed places.
    local out: mut {string} = { "local record R\n" }
    local tests: mut {string} = {}
    for i = 1, n * 10 do
      out[#out + 1] = "  f" .. tostring(i) .. "?: integer\n"
      tests[#tests + 1] = "r.f" .. tostring(i) .. " ~= nil"
    end
    out[#out + 1] = "end\nlocal function touch()\nend\nlocal function run(xs: {integer}, r: R)\n  if " ..
      table.concat(tests, " and ") .. " then\n"
    for _ = 1, n * 100 do
      out[#out + 1] = "    if #xs == 0 then\n      return\n    end\n    touch()\n"
    end
    out[#out + 1] = "  end\nend\n"
    return table.concat(out)
  end,
  ["an if expression of many arms"] = function(n: integer): string
    local arms: mut {string} = {}
    for i = 1, n * 50 do
      arms[i] = (if i == 1 then "if" else "elseif" end) .. " b then " .. tostring(i)
    end
    return "local b: boolean = true\nlocal x: integer = " .. table.concat(arms, " ") .. " else 0 end\n"
  end,
  ["a function of many parameters called with all of them"] = function(n: integer): string
    local params: mut {string} = {}
    local args: mut {string} = {}
    for i = 1, n * 30 do
      params[i] = "p" .. tostring(i) .. ": integer"
      args[i] = tostring(i)
    end
    return "local function f(" .. table.concat(params, ", ") .. "): integer\n  return p1\nend\nlocal x: integer = f(" ..
      table.concat(args, ", ") .. ")\n"
  end,
}

--- Holds each of `names` to four times the input costing about four times the time.
local function hold(names: {string})
  for _, name in ipairs(names) do
    local form = assert(FORMS[name], "a form named " .. name)
    local small = prepare(form(5))
    local large = prepare(form(20))
    local ok, why = Speed.within(function()
      check(small)
    end, function()
      check(large)
    end, 10)
    assert(ok, name .. ": four times the input " .. why)
  end
end

local function test_four_times_the_input_costs_about_four_times_the_time_for_a_chain_a_record_and_a_literal()
  hold({ "a chain of operators", "a record of many fields read and given", "a literal of many items" })
end

local function test_four_times_the_input_costs_about_four_times_the_time_for_a_union_an_if_expression_and_a_call()
  hold({ "a union of many tagged records read by a shared field", "an if expression of many arms",
    "a function of many parameters called with all of them", "a run of calls where many places are narrowed" })
end

local function test_four_times_the_input_costs_about_four_times_the_time_for_a_union_of_many_tagged_records_told_apart_by_a_fixed_number_of_tests()
  hold({ "a union of many tagged records told apart by a fixed number of tests" })
end

local function test_four_times_the_members_costs_about_sixteen_times_for_a_chain_of_tests_over_every_tag_of_a_union()
  -- A chain is quadratic in the members at best, each test reading the union the ones before it left: four times the
  -- members costs 16 times, and 64 times where a test or the join of the arms asks each pair of members, or walks them
  -- again, for each test. The limits lie between what the chain and the `or` of tests cost, and what they cost then.
  local limits <const>: {string: integer} = {
    ["a union of many tagged records told apart by a chain of tests over every tag"] = 21,
    ["a union of many tagged records told apart by one test of every tag joined by or"] = 28,
  }
  for name, limit in pairs(limits) do
    local form = assert(FORMS[name])
    local small = prepare(form(5))
    local large = prepare(form(20))
    local ok, why = Speed.within(function()
      check(small)
    end, function()
      check(large)
    end, limit)
    assert(ok, name .. ": four times the members " .. why)
  end
end

local function test_four_times_the_input_costs_about_four_times_the_time_for_declaring_a_union_of_many_tagged_records()
  -- The members are read, matched for a shared tag and told apart by value when the union is declared, outside the check.
  local form = assert(FORMS["a union of many tagged records told apart by a fixed number of tests"])
  local small, large = form(6), form(24)
  local ok, why = Speed.within(function()
    prepare(small)
  end, function()
    prepare(large)
  end, 10)
  assert(ok, "four times the members " .. why)
end

local function test_four_times_the_calls_costs_about_four_times_the_time_where_the_state_changes_between_them()
  -- Each call forgets the facts of lengths that the test before it gave, so the state is another one at each, and the
  -- narrowed places are held beside. The facts of lengths are kept apart from the others: a walk of all the facts at each
  -- call costs about eight times for four times the calls, the limit lies between that and the four of a linear check.
  local form = assert(FORMS["a run of calls where the state changes between them and many places are narrowed"])
  local small = prepare(form(5))
  local large = prepare(form(20))
  local ok, why = Speed.within(function()
    check(small)
  end, function()
    check(large)
  end, 6)
  assert(ok, "four times the input " .. why)
end

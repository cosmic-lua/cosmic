--- The warnings of the new checker ([`lang.warnings`]) on small programs, one for each kind of warning and each place it
--- is left out: a name that is read, called, assigned then read, named as a type or begins with an underscore warns of
--- nothing, and the rest warn as the case says, by kind, what it declares and the line. A test the checker refuses
--- (`is_disjoint`) or a `pairs` of an array (`not_assignable`) is an error of its own, so it warns of nothing.
local Programs = require("lang.check_programs")
local Test = require("cosmic.test")

Test.policy{ cpu_features = true }

--- A program and the warnings the new checker gives it, as `kind declares name@line`, sorted.
local record Case
  name: string
  source: string
  warns: {string}
end

local CASES <const>: {Case} = {
  {
    name = "an unused local",
    source = "local x = 1\n",
    warns = { "unused variable x@1" },
  },
  {
    name = "an unused argument, function, record, alias and enum",
    source = "local function f(a: integer) end\nlocal record R\nend\nlocal type T = integer\nlocal enum E\n  \"a\"\nend\n",
    warns = { "unused argument a@1", "unused function f@1", "unused type E@5", "unused type R@2", "unused type T@4" },
  },
  {
    name = "a variable that is assigned and never read",
    source = "local x = 1\nx = 2\n",
    warns = { "variable x@1" },
  },
  {
    name = "an argument that is assigned and never read",
    source = "local function f(a: integer)\n  a = 2\nend\nf(1)\n",
    warns = { "argument a@1" },
  },
  {
    name = "names that are read, called, assigned then read, or named as types",
    source = "local record R\nend\nlocal x: R = nil\nlocal function g(): R\n  return x\nend\nlocal d: integer = 0\nlocal e = g()\nd = 1\nprint(d, e)\n",
    warns = {},
  },
  {
    name = "the control variables of loops",
    source = "for i = 1, 3 do end\nfor k, v in ipairs({ 1 }) do end\n",
    warns = { "unused variable i@1", "unused variable k@2", "unused variable v@2" },
  },
  {
    name = "a local that holds a function",
    source = "local f = function() end\n",
    warns = { "unused function f@1" },
  },
  {
    name = "names that begin with an underscore",
    source = "local _x = 1\nlocal _ = 2\n",
    warns = {},
  },
  {
    name = "a function only its own body calls",
    source = "local function f(n: integer): integer\n  return f(n)\nend\n",
    warns = { "unused function f@1" },
  },
  {
    name = "a vararg nothing reads",
    source = "local function f(...: integer) end\nf()\n",
    warns = {},
  },
  {
    name = "a method called with a dot and its receiver",
    source = "local record R\n  n: integer\n  get: function(self: R): integer\nend\nlocal r: R = { n = 1, get = function(self: R): integer return self.n end }\nprint(r.get(r))\nprint(r:get())\n",
    warns = { "hint@6" },
  },
  {
    name = "a negated test no value can pass, which the checker refuses at the test",
    source = "local x: integer = 1\nif not (x is string) then print(1) end\n",
    warns = {},
  },
  {
    name = "a test every value passes, which the checker leaves be (the types may only claim it)",
    source = "local x: integer = 1\nif x is integer then print(1) else print(2) end\n",
    warns = {},
  },
  {
    name = "pairs of an array, which the checker refuses",
    source = "local a: {integer} = { 1 }\nfor k, v in pairs(a) do print(k, v) end\n",
    warns = {},
  },
}

--- A warning as the cases spell it: its kind, what it declares and names (for the unused and unread), and its line.
local function key(kind: string, msg: string, line: integer): string
  if kind == "unused" or kind == "unread" then
    local head = msg:match("^(unused %S+ [%w_%.]+)") or msg:match("^(%S+ [%w_%.]+) ")
    return (head or msg) .. "@" .. tostring(line)
  end
  return kind .. "@" .. tostring(line)
end

local function new_warnings(source: string): {string}
  local run = Programs.run(source)
  assert(#run.before == 0, table.concat(run.before, " "))
  local out: mut {string} = {}
  for _, w in ipairs(run.result.warnings) do
    out[#out + 1] = key(w.kind, w.msg, w.y)
  end
  table.sort(out)
  return out
end

local function test_each_case_warns_as_it_says()
  for _, case in ipairs(CASES) do
    local got = new_warnings(case.source)
    assert(table.concat(got, ",") == table.concat(case.warns, ","),
      case.name .. ": the checker warns of " .. table.concat(got, ",") .. ", the case says " .. table.concat(case.warns, ","))
  end
end

local function test_a_test_no_value_passes_and_a_pairs_of_an_array_are_errors_on_their_lines()
  local test = Programs.run("local x: integer = 1\nif not (x is string) then print(1) end\n")
  local first = assert(test.errors[1])
  assert(Programs.codes(test) == "is_disjoint" and first.y == 2)
  local pairs_of_array = Programs.run("local a: {integer} = { 1 }\nfor k, v in pairs(a) do print(k, v) end\n")
  local second = assert(pairs_of_array.errors[1])
  assert(Programs.codes(pairs_of_array) == "not_assignable" and second.y == 2)
end

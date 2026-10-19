--- The warnings of the new checker ([`lang.warnings`]) against the fork's, on programs both read: where they agree, and
--- each kind of difference, pinned by name so that a change to either is seen. The fork's warnings over the whole tree are
--- compared by hand (the commit message of the driver holds the numbers); this holds the rule each count rests on.
local Programs = require("lang.check_programs")
local Test = require("cosmic.test")
local Translate = require("lang.translate")
local teal = require("build.teal")
local type compiler = require("build.compiler")

Test.policy{}

local built = assert(teal.load())

--- A program and how the new checker's warnings differ from the fork's for it.
local record Case
  name: string
  source: string
  --- What only the fork warns of, and what only the new checker warns of, as `kind declares name@line`, sorted.
  fork_only: {string}
  new_only: {string}
end

local CASES <const>: {Case} = {
  { name = "an unused local", source = "local x = 1\n", fork_only = {}, new_only = {} },
  {
    name = "an unused argument, function, record, alias and enum",
    source = "local function f(a: integer) end\nlocal record R\nend\nlocal type T = integer\nlocal enum E\n  \"a\"\nend\n",
    fork_only = {}, new_only = {},
  },
  { name = "a variable that is assigned and never read", source = "local x = 1\nx = 2\n", fork_only = {}, new_only = {} },
  {
    name = "an argument that is assigned and never read",
    source = "local function f(a: integer)\n  a = 2\nend\nf(1)\n", fork_only = {}, new_only = {},
  },
  {
    name = "names that are read, called, assigned then read, or named as types",
    source = "local record R\nend\nlocal x: R = nil\nlocal function g(): R\n  return x\nend\nlocal d: integer = 0\n" ..
      "local e = g()\nd = 1\nprint(d, e)\n",
    fork_only = {}, new_only = {},
  },
  {
    name = "the control variables of loops",
    source = "for i = 1, 3 do end\nfor k, v in ipairs({ 1 }) do end\n", fork_only = {}, new_only = {},
  },
  { name = "a local that holds a function", source = "local f = function() end\n", fork_only = {}, new_only = {} },
  { name = "names that begin with an underscore", source = "local _x = 1\nlocal _ = 2\n", fork_only = {}, new_only = {} },
  {
    name = "a function only its own body calls",
    source = "local function f(n: integer): integer\n  return f(n)\nend\n", fork_only = {}, new_only = {},
  },
  {
    name = "a vararg nothing reads", source = "local function f(...: integer) end\nf()\n",
    fork_only = { "unused argument ...@1" }, new_only = {},
  },
  {
    name = "a method called with a dot and its receiver",
    source = "local record R\n  n: integer\n  get: function(self: R): integer\nend\n" ..
      "local r: R = { n = 1, get = function(self: R): integer return self.n end }\nprint(r.get(r))\nprint(r:get())\n",
    fork_only = {}, new_only = {},
  },
  {
    name = "a negated test no value can pass, which the new checker refuses at the test",
    source = "local x: integer = 1\nif not (x is string) then print(1) end\n",
    fork_only = { "branch@2" }, new_only = {},
  },
  {
    name = "a test every value passes, which the new checker leaves be (the types may only claim it)",
    source = "local x: integer = 1\nif x is integer then print(1) else print(2) end\n",
    fork_only = {}, new_only = {},
  },
  {
    name = "pairs of an array, which the new checker refuses",
    source = "local a: {integer} = { 1 }\nfor k, v in pairs(a) do print(k, v) end\n",
    fork_only = { "hint@2" }, new_only = {},
  },
}

--- A warning as both are compared: its kind, what it declares and names (for the unused and unread), and its line.
local function key(kind: string, msg: string, line: integer): string
  if kind == "unused" or kind == "unread" then
    local head = msg:match("^(unused %S+ [%w_%.]+)") or msg:match("^(%S+ [%w_%.]+) ")
    return (head or msg) .. "@" .. tostring(line)
  end
  return kind .. "@" .. tostring(line)
end

local function fork_warnings(source: string): {string}
  local env = assert(built.new_env({ defaults = teal.defaults() }))
  teal.strip(env)
  local result = built.check_string(source, env, "case.tl", "tl")
  local out: {string} = {}
  local found: {compiler.Error} = result.warnings
  for _, w in ipairs(found) do
    local kind = tostring(w.tag)
    if kind ~= "redeclaration" and kind ~= "unknown" then
      out[#out + 1] = key(kind, w.msg, w.y)
    end
  end
  table.sort(out)
  return out
end

local function new_warnings(source: string): {string}
  local run = Programs.run(Translate.translate(source, "case.tl").text)
  assert(#run.before == 0, table.concat(run.before, " "))
  local out: {string} = {}
  for _, w in ipairs(run.result.warnings) do
    out[#out + 1] = key(w.kind, w.msg, w.y)
  end
  table.sort(out)
  return out
end

local function difference(a: {string}, b: {string}): {string}
  local seen: {string: boolean} = {}
  for _, x in ipairs(b) do
    seen[x] = true
  end
  local out: {string} = {}
  for _, x in ipairs(a) do
    if seen[x] ~= true then
      out[#out + 1] = x
    end
  end
  return out
end

local function test_the_warnings_of_the_new_checker_are_the_forks_but_for_the_pinned_differences_in_the_first_cases()
  for i = 1, 7 do
    local case = CASES[i]
    assert(case ~= nil)
    local fork, new = fork_warnings(case.source), new_warnings(case.source)
    local fork_only, new_only = difference(fork, new), difference(new, fork)
    assert(table.concat(fork_only, ",") == table.concat(case.fork_only, ",") and
        table.concat(new_only, ",") == table.concat(case.new_only, ","),
      case.name .. ": fork " .. table.concat(fork, ",") .. " / new " .. table.concat(new, ",") .. " / only the fork's " ..
        table.concat(fork_only, ",") .. " / only the new checker's " .. table.concat(new_only, ","))
  end
end

local function test_the_warnings_of_the_new_checker_are_the_forks_but_for_the_pinned_differences_in_the_last_cases()
  for i = 8, #CASES do
    local case = CASES[i]
    assert(case ~= nil)
    local fork, new = fork_warnings(case.source), new_warnings(case.source)
    local fork_only, new_only = difference(fork, new), difference(new, fork)
    assert(table.concat(fork_only, ",") == table.concat(case.fork_only, ",") and
        table.concat(new_only, ",") == table.concat(case.new_only, ","),
      case.name .. ": fork " .. table.concat(fork, ",") .. " / new " .. table.concat(new, ",") .. " / only the fork's " ..
        table.concat(fork_only, ",") .. " / only the new checker's " .. table.concat(new_only, ","))
  end
end

local function test_a_difference_the_new_checker_makes_an_error_is_one_the_cases_name()
  -- the fork's `branch` and `hint` warnings that the new checker refuses: the same lines are errors of its own
  local test = Programs.run("local x: integer = 1\nif not (x is string) then print(1) end\n")
  assert(Programs.codes(test) == "is_disjoint" and test.errors[1] ~= nil and test.errors[1].y == 2)
  local pairs_of_array = Programs.run("local a: {integer} = { 1 }\nfor k, v in pairs(a) do print(k, v) end\n")
  assert(Programs.codes(pairs_of_array) == "not_assignable" and pairs_of_array.errors[1] ~= nil and
      pairs_of_array.errors[1].y == 2)
end

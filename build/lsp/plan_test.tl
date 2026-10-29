--- What a build refuses of a document before it checks it, and the plan it compiles it by ([`build.lsp.plan`]), as the new
--- checker's reading finds it: the refusals in a build's words, at their places.
local Test = require("cosmic.test")
local plan = require("build.lsp.plan")
local syntax_read = require("build.lsp.syntax_read")

Test.policy{}

--- A module in the new grammar: a record with a `mut` field and an optional one, a class, a `mut` collection, an optional
--- parameter, and two requires.
local NEW <const> = table.concat({
  'local Fs = require("cosmic.fs")',
  'local type Json = require("cosmic.json")',
  "local record Box",
  "  mut n: integer",
  "  name?: string",
  "end",
  "local class Counter",
  "  label: string",
  "  mut count: integer",
  "  function bump(self, by: integer): integer",
  "    self.count = self.count + by",
  "    return self.count",
  "  end",
  "end",
  "local function make(xs: mut {string}, skip?: integer): Box",
  "  return { n = #xs }",
  "end",
  "return make",
  "",
}, "\n")

--- The refusals of `planned` as text, in order.
local function said(planned: plan.Planned): string
  local out = ""
  for _, refusal in ipairs(planned.refusals) do
    out = out .. (if out == "" then "" else "\n" end) .. tostring(refusal.line) .. ":" .. tostring(refusal.column) .. ": " ..
      refusal.message
  end
  return out
end

--- The requires of `planned` as text, in order.
local function required(planned: plan.Planned): string
  local out = ""
  for _, site in ipairs(planned.requires) do
    out = out .. (if out == "" then "" else " " end) .. site.name .. "@" .. tostring(site.line) .. ":" .. tostring(site.column)
  end
  return out
end

local function test_a_module_is_planned()
  local planned = syntax_read.plan_of("box.tl", NEW, "box", "module", false, false)
  assert(said(planned) == "", said(planned))
  assert(not planned.halted)
  local made = assert(planned.plan, "no plan")
  assert(made.path == "box" and made.file == "box.tl" and made.kind == "module")
  assert(made.has_top_level_return)
  assert(required(planned) == "cosmic.fs@1:20 cosmic.json@2:27", required(planned))
end

local function test_a_text_the_new_checker_does_not_parse_is_refused_with_the_parsers_words()
  local planned = syntax_read.plan_of("bad.tl", "local x: = 1\nreturn x\n", "bad", "module", false, false)
  assert(planned.plan == nil and planned.halted, "a text that does not parse has a plan")
  assert(#planned.refusals == 1, said(planned))
  local refusal = assert(planned.refusals[1])
  assert(refusal.line == 1 and refusal.column > 1, said(planned))
  assert(refusal.message:find("(", 1, true) ~= nil, refusal.message)
  assert(#planned.requires == 0)
end

--- A case: the text, the file, its kind, and what a build refuses of it.
local record Case
  name: string
  file: string
  kind: string
  text: string
  refused: string
  required: string
end

local CASES <const>: {Case} = {
  {
    name = "a clean module", file = "m.tl", kind = "module", refused = "", required = "helper@1:24",
    text = 'local helper = require("helper")\nreturn { n = helper }\n',
  },
  {
    name = "a global in a declaration file", file = "g.d.tl", kind = "decl",
    refused = "1:1: a global is not allowed in a cosmic build: it reaches other modules by no `require`, which is " ..
      "all a build's cache and its order see -- put the value in a module and `require` it",
    required = "", text = "global record G\nend\nreturn G\n",
  },
  {
    name = "a test that returns a value", file = "t_test.tl", kind = "test",
    refused = "3:1: a test file may not both define test_* functions and return its own value; remove the top-level " ..
      "return so the generated tail can hand the runner its tests",
    required = "", text = "local function test_it() assert(true) end\n\nreturn 1\n",
  },
  {
    name = "an example that returns nothing", file = "e_example.tl", kind = "example",
    refused = "1:1: an example file must return the table its Example.* functions are declared on " ..
      "(`return Example`), or the runner has nothing to call",
    required = "", text = "local record Example\nend\nfunction Example.one() end\n",
  },
  {
    name = "a policy outside a test", file = "p.tl", kind = "module",
    refused = "2:1: test.policy: only a test or example module declares what its tests read; call it in each test " ..
      "module that requires this one",
    required = 'cosmic.test@1:22', text = 'local Test = require("cosmic.test")\nTest.policy{}\nreturn {}\n',
  },
  {
    name = "requires spelt three ways, and a field called require", file = "r.tl", kind = "module", refused = "",
    required = "a@1:19 b@2:21 c@3:19",
    text = 'local a = require("a")\nlocal b = require ( "b" )\nlocal c = require([[c]])\nlocal o = { require = 1 }\n' ..
      "local n: integer = o.require\nreturn { a, b, c, n }\n",
  },
}

--- A case is refused in the words and at the place it says, and its requires are found.
local function test_a_text_is_refused_in_a_builds_words_and_its_requires_are_found()
  for _, case in ipairs(CASES) do
    local path = case.file:gsub("%.d%.tl$", ""):gsub("%.tl$", "")
    local fresh = syntax_read.plan_of(case.file, case.text, path, case.kind, false, false)
    assert(said(fresh) == case.refused, case.name .. ": " .. said(fresh))
    assert(required(fresh) == case.required, case.name .. ": " .. required(fresh))
  end
end

--- A refusal each grammar words its own way is the one the new checker words: a `global` in a program is no declaration there
--- but a syntax error ([`lang.parser`]).
local function test_a_global_in_a_program_is_a_syntax_error_of_the_new_parser()
  local planned = syntax_read.plan_of("g.tl", "global G_X: integer\nreturn {}\n", "g", "module", false, false)
  assert(planned.plan == nil and planned.halted)
  assert(#planned.refusals == 1, said(planned))
  assert(said(planned):find("global", 1, true) ~= nil, said(planned))
end

local function test_a_test_module_plans_its_tests()
  local text = "local function test_one() assert(true) end\nlocal function test_two() assert(true) end\n"
  local fresh = syntax_read.plan_of("a_test.tl", text, "a", "test", false, false)
  assert(table.concat(assert(fresh.plan).tests, ",") == "test_one,test_two")
end

--- Cosmic's own standard library holds a module to its stub; the plan of one carries it, and a module that returns nothing
--- has none.
local function test_a_standard_library_module_of_cosmics_own_tree_carries_its_stub()
  local text = "local record M\n  f: function(): integer\nend\nlocal function f(): integer\n  return 1\nend\n" ..
    "local m: M = { f = f }\nreturn m\n"
  local fresh = syntax_read.plan_of("cosmic/m.tl", text, "cosmic.m", "module", true, false)
  local stub = assert(assert(fresh.plan).stub, "no stub")
  assert(stub.pruned, "a module that returns a name of a written type has a pruned stub")
  assert(stub.text:find("return 1", 1, true) == nil, stub.text)
  local none = syntax_read.plan_of("cosmic/n.tl", "local x = 1\n", "cosmic.n", "module", true, false)
  assert(assert(none.plan).stub == nil)
  local outside = syntax_read.plan_of("lib/m.tl", text, "lib.m", "module", true, false)
  assert(assert(outside.plan).stub == nil)
end

--- A `require` given a string in place of its arguments is a call the fork's parser reads and the new one refuses.
local function test_a_require_with_no_parentheses_is_a_syntax_error_of_the_new_parser()
  local planned = syntax_read.plan_of("r.tl", 'local a = require "a"\nreturn a\n', "r", "module", false, false)
  assert(planned.plan == nil and planned.halted)
  assert(said(planned):find("string_call", 1, true) ~= nil, said(planned))
  assert(#planned.requires == 0)
end

--- A refusal worded `message (code): fix` carries its code, at the place it names; one with no code carries none.
local function test_a_refusal_carries_the_code_the_checker_words_after_its_message()
  local coded = plan.refusal_of("it.tl:2:9: unused variable b (unused_variable): name it `_` or `_b`")
  assert(coded.line == 2 and coded.column == 9 and coded.code == "unused_variable", tostring(coded.code))
  local by_line = plan.refusal_of("it.tl:3: a thing (some_code): fix it")
  assert(by_line.line == 3 and by_line.code == "some_code", tostring(by_line.code))
  local bare = plan.refusal_of("it.tl: nothing to say of a code")
  assert(bare.message == "nothing to say of a code" and bare.code == nil, tostring(bare.code))
end

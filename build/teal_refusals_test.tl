--- A program for each refusal of the fork's checker that no other program of the switch's gate reaches. The fork's
--- refusals are the templates of [`testdata/gate/fork_refusals.json`] ([`build.fork_refusals`]); the programs here are
--- [`testdata/gate/refusal_programs.txt`], `=== <template>` and a program the fork refuses with it. This test holds each
--- program to its template while the fork lives, and `bin/cosmic build/gate_record.tl --fork` puts the programs in the
--- verdict table ([`lang.check_verdicts`]), where the new checker says what it makes of each.
local type compiler = require("build.compiler")
local ForkRefusals = require("build.fork_refusals")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local Verdicts = require("lang.check_verdicts")
local teal = require("build.teal")

Test.policy{ grants = {
  { path = "checker", letters = "r" },
  { path = "testdata/gate", letters = "r" },
  { path = "build/compiler.d.tl", letters = "r" },
} }

local function programs(): {Verdicts.Program}
  return Verdicts.read_programs((assert(Fs.read("testdata/gate/refusal_programs.txt"))))
end

--- The templates of the fork's source.
local function refusals(): {ForkRefusals.Refusal}
  local made = (assert(ForkRefusals.read()))
  assert(#made.trouble == 0, table.concat(made.trouble, "\n"))
  return made.refusals
end

--- The templates the fork's messages for `source` are, in the order it gives them, each once, as `loaded` reads it. A
--- test loads one compiler for all its programs: loading one builds the checker's standard globals again, and each
--- program is given an environment of its own.
local function templates_of(loaded: compiler, source: string, list: {ForkRefusals.Refusal}): {string}
  -- the settings the tool checks under, in which `<close>` is a Lua 5.4 form the target takes
  local env = assert(loaded.new_env({ defaults = teal.defaults() }))
  local _, result = loaded.gen(source, env, nil, "tl")
  local found: {string} = {}
  local seen: {string: boolean} = {}
  local function take(errors: {compiler.Error}, kind: string)
    for _, e in ipairs(errors) do
      for _, id in ipairs(ForkRefusals.best(list, kind, e.msg)) do
        if seen[id] ~= true then
          seen[id] = true
          found[#found + 1] = id
        end
      end
    end
  end
  take(result.syntax_errors, "syntax")
  take(result.type_errors, "type")
  return found
end

--- The id of the template whose text is `template`, of either kind.
local function id_of(list: {ForkRefusals.Refusal}, template: string): string?
  for _, refusal in ipairs(list) do
    if refusal.template == template and refusal.kind ~= "internal" then
      return refusal.id
    end
  end
  return nil
end

--- Each program of the entries `first` to `last` is refused by the fork with its template.
local function hold(first: integer, last: integer): integer
  local list = refusals()
  local all = programs()
  local loaded = assert(teal.load(true))
  local held = 0
  for i, program in ipairs(all) do
    if i >= first and i <= last then
      local id = id_of(list, program.template)
      assert(id ~= nil, "no template of the fork reads: " .. program.template)
      local found = templates_of(loaded, program.source, list)
      local says = false
      for _, each in ipairs(found) do
        says = says or each == id
      end
      assert(says, "the fork does not refuse this program with `" .. program.template .. "`:\n" .. program.source)
      held = held + 1
    end
  end
  return held
end

--- The entries of the `part`th eighth of the programs.
local function eighth(part: integer): integer, integer
  local n = #programs()
  assert(n >= 8, "the file holds " .. tostring(n) .. " programs")
  return (part - 1) * n // 8 + 1, part * n // 8
end

local function test_the_first_eighth_of_the_programs_is_refused_with_their_templates()
  local first, last = eighth(1)
  assert(hold(first, last) == last - first + 1)
end

local function test_the_second_eighth_of_the_programs_is_refused_with_their_templates()
  local first, last = eighth(2)
  assert(hold(first, last) == last - first + 1)
end

local function test_the_third_eighth_of_the_programs_is_refused_with_their_templates()
  local first, last = eighth(3)
  assert(hold(first, last) == last - first + 1)
end

local function test_the_fourth_eighth_of_the_programs_is_refused_with_their_templates()
  local first, last = eighth(4)
  assert(hold(first, last) == last - first + 1)
end

local function test_the_fifth_eighth_of_the_programs_is_refused_with_their_templates()
  local first, last = eighth(5)
  assert(hold(first, last) == last - first + 1)
end

local function test_the_sixth_eighth_of_the_programs_is_refused_with_their_templates()
  local first, last = eighth(6)
  assert(hold(first, last) == last - first + 1)
end

local function test_the_seventh_eighth_of_the_programs_is_refused_with_their_templates()
  local first, last = eighth(7)
  assert(hold(first, last) == last - first + 1)
end

local function test_the_last_eighth_of_the_programs_is_refused_with_their_templates()
  local first, last = eighth(8)
  assert(hold(first, last) == last - first + 1)
end

local function test_no_program_is_in_the_file_twice()
  local seen: mut {string: boolean} = {}
  local all = programs()
  assert(#all > 0)
  for _, program in ipairs(all) do
    local key = program.template .. "\n" .. program.source
    assert(seen[key] ~= true, "a program is in the file twice, for `" .. program.template .. "`")
    seen[key] = true
  end
end

local function test_a_program_the_fork_takes_is_not_held_to_a_template()
  local list = refusals()
  local id = id_of(list, "expected a type")
  assert(id ~= nil)
  local loaded = assert(teal.load(true))
  assert(#templates_of(loaded, "local x: integer = 1\nprint(x)\n", list) == 0)
  local found = templates_of(loaded, "local x: = 1\n", list)
  assert(#found > 0)
end

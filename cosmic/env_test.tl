--- [`Env.read`] takes a name [`Env.Name`] declares and refuses any other, while [`Env.get`] takes any.
local Fs = require("cosmic.fs")
local Programs = require("lang.check_programs")
local Test = require("cosmic.test")

Test.policy{ grants = { { path = "lang/stdlib.d.tl", letters = "r" }, { path = "lang/prelude.d.tl", letters = "r" },
  { path = "cosmic/env.tl", letters = "r" } } }

--- The codes of the errors `source` has, checked against the tree's own cosmic.env.
local function codes_of(source: string): string
  local env = assert(Fs.read("cosmic/env.tl"))
  local run = Programs.standard(assert(Fs.read("lang/prelude.d.tl")), assert(Fs.read("lang/stdlib.d.tl")),
    'local Env = require("cosmic.env")\n' .. source, { ["cosmic.env"] = env })
  assert(#run.before == 0, table.concat(run.before, " "))
  return Programs.codes(run)
end

local function test_a_declared_name_is_read()
  assert(codes_of('local x: string? = Env.read("COSMIC_AUTO_BOOT")\n') == "")
end

local function test_a_misspelt_name_is_a_checker_error()
  assert(codes_of('local x = Env.read("COSMIC_AUTO_BOT")\n') == "enum_member")
end

local function test_a_name_of_a_program_outside_the_tree_is_read_by_get()
  assert(codes_of('local x: string? = Env.get("MY_OWN_SETTING")\n') == "")
end

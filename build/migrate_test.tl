--- Tests of [`build.migrate`], the removed verb: it says so, points to the project guide, and exits 2 whatever it is given.
local Migrate = require("build.migrate")

local function said(argv: {string}): integer, string
  local heard: mut {string} = {}
  local code = Migrate.main(argv, function(text: string) heard[#heard + 1] = text end)
  return code, table.concat(heard)
end

local function test_the_verb_says_it_was_removed_and_where_the_new_grammar_is_described()
  local code, text = said({ "migrate", "--check", "." })
  assert(code == 2, tostring(code))
  assert(text:find("cosmic migrate was removed", 1, true) ~= nil, text)
  assert(text:find("doc/guides/project.md", 1, true) ~= nil, text)
  assert(text:find("release", 1, true) == nil, text)
end

local function test_the_verb_exits_2_with_no_arguments_too()
  local code, text = said({ "migrate" })
  assert(code == 2 and text == Migrate.MESSAGE .. "\n", tostring(code) .. ": " .. text)
end

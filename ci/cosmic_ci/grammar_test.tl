local Grammar = require("cosmic_ci.grammar")

local function test_the_driver_environment_reads_the_new_grammar_and_keeps_the_rest()
  local base: {string:string} = { PATH = "/bin", COSMIC_GRAMMAR = "teal" }
  local made = Grammar.driver(base)
  assert(made["COSMIC_GRAMMAR"] == "new", "the grammar was not set")
  assert(made["PATH"] == "/bin", "another variable was lost")
  assert(base["COSMIC_GRAMMAR"] == "teal", "the base was changed")
  local empty: {string:string} = {}
  assert(Grammar.driver(empty)["COSMIC_GRAMMAR"] == "new", "an empty base was not given the grammar")
end

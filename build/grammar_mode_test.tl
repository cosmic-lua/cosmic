--- The tests of [`build.grammar_mode`]: the one grammar a run compiles with, and the tool string every compile key carries.
local Env = require("cosmic.env")
local GrammarMode = require("build.grammar_mode")
local Test = require("cosmic.test")
local importer = require("build.importer")

Test.policy{ cpu_features = true, env = { "COSMIC_GRAMMAR" } }

local function test_an_unset_or_empty_variable_is_the_new_grammar()
  assert(GrammarMode.of(nil) == "new" and GrammarMode.of("") == "new" and GrammarMode.of("new") == "new")
end

local function test_the_forks_grammar_is_refused_naming_the_command_that_leaves_it()
  local mode, why = GrammarMode.of("teal")
  assert(mode == nil and why:find("COSMIC_GRAMMAR=teal", 1, true) ~= nil and why:find("doc/guides/project.md", 1, true) ~= nil, why)
end

local function test_a_word_that_is_none_is_refused()
  for _, word in ipairs({ "New", "tl", "fork", " new", "new " }) do
    local mode, why = GrammarMode.of(word)
    assert(mode == nil and why:find("COSMIC_GRAMMAR=" .. word, 1, true) ~= nil, word .. ": " .. tostring(why))
  end
end

local function test_the_mode_is_the_one_the_variable_names()
  local word = Env.get("COSMIC_GRAMMAR")
  local mode, why = GrammarMode.mode()
  local want, want_why = GrammarMode.of(word)
  assert(mode == want and why == want_why)
  assert(word == nil or word == "" or word == "new")
  assert(mode == "new")
end

-- The strings the keys of compiled rows, shared compiles and verdicts are made of, for a tool, and the checked variants.
local function test_a_compile_is_keyed_by_the_tool_the_mode_and_whether_it_wraps_facts()
  assert(GrammarMode.tool("a", "new") == "a340d8fb401ad242f252858c92a6f1f4cb8242e94eb13d192dd79abc5fbb0f31")
  assert(GrammarMode.tool("a", "new", true) == "2b4f919cec47719711d74d12f19ccf2609ccd868092cb57e6612513cc6191b25")
  local kinds: mut {string: string} = {}
  local count = 0
  for _, tool in ipairs({ "a", "b" }) do
    local keys: {string} = {
      GrammarMode.tool(tool, "new"), GrammarMode.tool(tool, "new", true),
      importer.checked_tool(GrammarMode.tool(tool, "new")), importer.checked_tool(GrammarMode.tool(tool, "new"), true),
    }
    for _, key in ipairs(keys) do
      assert(kinds[key] == nil, "two compiles share the key " .. key)
      kinds[key] = tool
      count = count + 1
    end
  end
  assert(count == 8)
end

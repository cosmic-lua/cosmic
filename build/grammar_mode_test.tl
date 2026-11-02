--- The tests of [`build.grammar_mode`]: the one grammar a run compiles with, and the tool string every compile key carries.
local GrammarMode = require("build.grammar_mode")
local importer = require("build.importer")

local function test_an_unset_or_empty_variable_is_the_new_grammar()
  assert(GrammarMode.refusal_of(nil) == nil and GrammarMode.refusal_of("") == nil and GrammarMode.refusal_of("new") == nil)
end

local function test_the_forks_grammar_is_refused_naming_the_command_that_leaves_it()
  local why = GrammarMode.refusal_of("teal")
  assert(why ~= nil and why:find("COSMIC_GRAMMAR=teal", 1, true) ~= nil and why:find("doc/guides/project.md", 1, true) ~= nil, why)
end

local function test_a_word_that_is_none_is_refused()
  for _, word in ipairs({ "New", "tl", "fork", " new", "new " }) do
    local why = GrammarMode.refusal_of(word)
    assert(why ~= nil and why:find("COSMIC_GRAMMAR=" .. word, 1, true) ~= nil, word .. ": " .. tostring(why))
  end
end

-- The strings the keys of compiled rows, shared compiles and verdicts are made of, for a tool, and the checked variants.
local function test_a_compile_is_keyed_by_the_tool_and_whether_it_wraps_facts()
  assert(GrammarMode.tool("a") == "a340d8fb401ad242f252858c92a6f1f4cb8242e94eb13d192dd79abc5fbb0f31")
  assert(GrammarMode.tool("a", true) == "2b4f919cec47719711d74d12f19ccf2609ccd868092cb57e6612513cc6191b25")
  local kinds: mut {string: string} = {}
  local count = 0
  for _, tool in ipairs({ "a", "b" }) do
    local keys: {string} = {
      GrammarMode.tool(tool), GrammarMode.tool(tool, true),
      importer.checked_tool(GrammarMode.tool(tool)), importer.checked_tool(GrammarMode.tool(tool), true),
    }
    for _, key in ipairs(keys) do
      assert(kinds[key] == nil, "two compiles share the key " .. key)
      kinds[key] = tool
      count = count + 1
    end
  end
  assert(count == 8)
end

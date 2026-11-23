--- The tests of [`build.grammar_mode`]: the tool string every compile key carries.
local GrammarMode = require("build.grammar_mode")
local importer = require("build.importer")

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

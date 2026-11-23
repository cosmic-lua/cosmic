--- The system prompt: its tools, rules, project context and directory.

local agent_fixture = require("build.agent_fixture")
local Fs = require("cosmic.fs")
local Prompt = require("cosmic.agent.prompt")
local Test = require("cosmic.test")

Test.policy{ env = { "TMPDIR" } }

local scratch = agent_fixture.scratch

local function test_the_prompt_lists_tools_rules_context_and_cwd()
  local dir = scratch()
  assert(Fs.mkdirs(dir .. "/sub"))
  assert(Fs.write(dir .. "/AGENTS.md", "top rules"))
  assert(Fs.write(dir .. "/CLAUDE.md", "not read: AGENTS.md is"))
  assert(Fs.write(dir .. "/sub/CLAUDE.md", "sub rules"))
  local mine: mut {Prompt.Context} = {}
  for _, c in ipairs(Prompt.contexts(dir .. "/sub")) do
    if c.path:sub(1, #dir) == dir then mine[#mine + 1] = c end
  end
  assert(#mine == 2 and mine[1].path == dir .. "/AGENTS.md" and mine[2].content == "sub rules")
  local p = Prompt.build(dir .. "/sub", mine)
  assert(p:find("^You are a coding assistant running inside cosmic agent") ~= nil)
  assert(p:find("<tools>\n- read: Read file contents\n- bash: ", 1, true) ~= nil, p)
  assert(p:find("- Use write only for new files or complete rewrites.", 1, true) ~= nil)
  assert(p:find('<project_instructions path="' .. dir .. '/AGENTS.md">\ntop rules\n</project_instructions>', 1, true) ~= nil)
  assert(p:sub(-#dir - 17) == "<cwd>\n" .. dir .. "/sub\n</cwd>", p:sub(-80))
  assert(Prompt.build("/", {}):find("project_context", 1, true) == nil)
end

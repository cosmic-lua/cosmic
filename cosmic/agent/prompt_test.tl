--- The system prompt: its tools, rules, project context and directory.

local agent_fixture = require("build.agent_fixture")
local Fs = require("cosmic.fs")
local Prompt = require("cosmic.agent.prompt")
local Test = require("cosmic.test")
local Tools = require("cosmic.agent.tools")

Test.policy{ env = { "TMPDIR" } }

local scratch = agent_fixture.scratch

local function test_the_prompt_lists_tools_rules_and_context_by_relative_path()
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
  local p = Prompt.build(dir .. "/sub", mine, { tools = Tools.all() })
  assert(p:find("^You are a coding assistant running inside cosmic agent") ~= nil)
  assert(p:find("<tools>\n- read: Read file contents\n- bash: ", 1, true) ~= nil, p)
  assert(p:find("- Use write only for new files or complete rewrites.", 1, true) ~= nil)
  assert(p:find('<project_instructions path="../AGENTS.md">\ntop rules\n</project_instructions>', 1, true) ~= nil, p)
  assert(p:find('<project_instructions path="CLAUDE.md">\nsub rules', 1, true) ~= nil, p)
  -- No path of the machine: the same prompt in each directory, so it is read from the cache.
  assert(p:find(dir, 1, true) == nil and p:find("<cwd>", 1, true) == nil, p)
  local elsewhere = scratch()
  assert(Fs.mkdirs(elsewhere .. "/sub"))
  local theirs: {Prompt.Context} = { { path = elsewhere .. "/AGENTS.md", content = "top rules" },
    { path = elsewhere .. "/sub/CLAUDE.md", content = "sub rules" } }
  assert(Prompt.build(elsewhere .. "/sub", theirs, { tools = Tools.all() }) == p)
  assert(Prompt.where(dir) == "<cwd>\n" .. dir .. "\n</cwd>")
  -- A directory written with a trailing slash names the same files.
  assert(Prompt.build(elsewhere .. "/sub/", theirs, { tools = Tools.all() }) == p)
  assert(Prompt.build("/", {}):find("project_context", 1, true) == nil)
end

--- Code mode adds nothing to the system prompt: what a snippet may do is in the run tool's description.
local function test_code_mode_adds_no_section_to_the_prompt()
  local p = Prompt.build("/", {})
  assert(p:find("<stdlib>", 1, true) == nil and p:find("Host.", 1, true) == nil, p)
end

--- A session that offers some tools alone names those, and their rules; with no bash, files are run's.
local function test_the_prompt_names_only_the_tools_offered()
  local all = Prompt.build("/w", {}, { tools = Tools.all() })
  assert(all:find("- bash: ", 1, true) ~= nil and all:find("<rules>\n- Use bash for file operations", 1, true) ~= nil, all)
  local some = Prompt.build("/w", {}, { tools = Tools.only(Tools.all(), { "run", "read" }) })
  assert(some:find("- bash: ", 1, true) == nil and some:find("- edit: ", 1, true) == nil, some)
  assert(some:find("- run: ", 1, true) ~= nil and some:find("- read: ", 1, true) ~= nil, some)
  assert(some:find("Use run for file operations: no program runs here", 1, true) ~= nil, some)
  assert(some:find("Use bash for", 1, true) == nil and some:find("Use write only", 1, true) == nil, some)
  -- The default tools offer no bash, and the rules name none; the rules for every tool stay.
  local quiet = Prompt.build("/", {})
  assert(quiet:find("bash", 1, true) == nil and quiet:find("- Tools may run in a sandbox", 1, true) ~= nil, quiet)
  assert(Prompt.build("/", {}, { tools = {} }):find("<tools>", 1, true) == nil)
end

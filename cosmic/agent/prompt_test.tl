--- The system prompt: its tools, rules, project context and directory.

local Agent = require("cosmic.agent")
local agent_fixture = require("build.agent_fixture")
local AgentMcp = require("cosmic.agent.mcp")
local Fs = require("cosmic.fs")
local type Json = require("cosmic.json")
local Prompt = require("cosmic.agent.prompt")
local Test = require("cosmic.test")
local Tools = require("cosmic.agent.tools")

Test.policy{ env = { "TMPDIR" } }

local scratch = agent_fixture.scratch

local NO_PROPERTIES <const>: {string: Json.Value} = {}

--- A tool of the tests' own, for the model, with a rule of its own.
local NOTE <const>: Tools.Tool = { name = "note", snippet = "Note a word", guidelines = { "Note what matters." },
  description = "Notes a word.", schema = { type = "object", properties = NO_PROPERTIES },
  run = function(_: Tools.Object, _: Tools.Context): Tools.Result
    return { text = "", is_error = false }
  end }

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
  assert(p:find("<tools>\n- run: ", 1, true) ~= nil, p)
  assert(p:find("- Each tool's output is kept in sessions.db", 1, true) ~= nil, p)
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

--- Code mode adds no section to the system prompt: what a snippet may do is in the run tool's description.
local function test_code_mode_adds_no_section_to_the_prompt()
  local p = Prompt.build("/", {})
  assert(p:find("<stdlib>", 1, true) == nil and p:find("Host.find", 1, true) == nil, p)
end

--- A tool of one's own is named with its rules; where a snippet may run programs, the rules say Host.bash runs them
--- and the project's checks are to be run; where it may not, that no program runs.
local function test_the_prompt_names_the_tools_offered_and_whether_programs_run()
  local run = assert(Tools.find(Tools.all(), "run"))
  local some = Prompt.build("/w", {}, { tools = { run, NOTE } })
  assert(some:find("- run: ", 1, true) ~= nil and some:find("- note: Note a word", 1, true) ~= nil, some)
  assert(some:find("- Note what matters.", 1, true) ~= nil, some)
  assert(some:find("Use run for file operations: no program runs here", 1, true) ~= nil, some)
  local commands = Prompt.build("/w", {}, { commands = true })
  assert(commands:find("Host.bash runs a program where one is needed", 1, true) ~= nil, commands)
  assert(commands:find("Check a change with the project's own checks and tests (Host.bash)", 1, true) ~= nil, commands)
  -- By default no program runs, and the rules name no bash; the rules for every tool stay.
  local quiet = Prompt.build("/", {})
  assert(quiet:find("bash", 1, true) == nil and quiet:find("- Tools may run in a sandbox", 1, true) ~= nil, quiet)
  assert(Prompt.build("/", {}, { tools = {} }):find("<tools>", 1, true) == nil)
end

-- The whole prompt, byte for byte: the template's trim markers decide each
-- blank line, which the tests above, by parts, would not see.
local function test_the_prompt_is_exactly_its_sections()
  local note = NOTE
  local contexts: {Prompt.Context} = { { path = "/w/AGENTS.md", content = "top" }, { path = "/w/a/CLAUDE.md", content = "sub" } }
  local servers: {AgentMcp.Server} = { { name = "gh", description = "GitHub\n  tools" }, { name = "plain" } }
  local guidelines: mut {string} = {}
  for _, g in ipairs(note.guidelines) do guidelines[#guidelines + 1] = "\n- " .. g end
  local p = Prompt.build("/w/a", contexts, { tools = { note } })
  local want = "You are a coding assistant running inside cosmic agent, the coding agent of cosmic. " ..
    "Help users inspect files, run commands, and modify code.\n\n" ..
    "<tools>\n- note: " .. note.snippet .. "\n</tools>\n\n" ..
    "<rules>" .. table.concat(guidelines) ..
    "\n- Tools may run in a sandbox: where one is refused (a read-only file system, a path not there, no network), " ..
    "say so rather than working around it." ..
    "\n- No program runs here, so the project's own tests cannot: say a change is unchecked by them." ..
    "\n- Be concise in your responses\n- Show file paths clearly when working with files\n</rules>\n\n" ..
    "<project_context>\nProject-specific instructions and guidelines:\n\n" ..
    "<project_instructions path=\"../AGENTS.md\">\ntop\n</project_instructions>\n\n" ..
    "<project_instructions path=\"CLAUDE.md\">\nsub\n</project_instructions>\n</project_context>"
  assert(p == want, p)
  -- The servers follow the working directory, past the cache mark, so the system prompt is the same for any servers.
  local where = Prompt.where("/w/a", servers)
  local intro = "MCP servers a snippet of run may call: "
  local at = assert(where:find(intro, 1, true))
  local stop = assert(where:find("until cursor == nil\n", at, true))
  assert(where == "<cwd>\n/w/a\n</cwd>\n\n<mcp_servers>\n" .. where:sub(at, stop + #"until cursor == nil") ..
      "- gh: GitHub tools\n- plain\n</mcp_servers>", where)
  assert(Prompt.where("/w/a", {}) == "<cwd>\n/w/a\n</cwd>")
  -- An agent given a set of servers names them there by default.
  local s = Agent.new({ sign = agent_fixture.keyed("k"), cwd = "/w/a", mcp = AgentMcp.new(servers, "/w/a") })
  assert(s.where == where and s.system:find("mcp_servers", 1, true) == nil, s.where)
  -- No tools: no tools section, and the rules a tool brings are gone.
  local bare = Prompt.build("/w/a", {}, { tools = {} })
  assert(bare == "You are a coding assistant running inside cosmic agent, the coding agent of cosmic. " ..
      "Help users inspect files, run commands, and modify code.\n\n<rules>" ..
      "\n- Tools may run in a sandbox: where one is refused (a read-only file system, a path not there, no network), " ..
      "say so rather than working around it." ..
      "\n- No program runs here, so the project's own tests cannot: say a change is unchecked by them." ..
      "\n- Be concise in your responses\n- Show file paths clearly when working with files\n</rules>", bare)
end

--- A tool for code alone is listed apart, with its input's schema, where run is offered to the model; its rules are
--- not the model's tools'.
local function test_the_prompt_lists_the_tools_code_may_call()
  local dir = scratch()
  local none: Tools.Object = {}
  local stamp: Tools.Tool = { name = "stamp", snippet = "Stamp a word", guidelines = {}, description = "Stamps\na word.",
    schema = { type = "object", properties = none }, callers = "code",
    run = function(_: Tools.Object, _: Tools.Context): Tools.Result
      return { text = "", is_error = false }
    end }
  local run = assert(Tools.find(Tools.all(), "run"))
  local both = Prompt.build(dir, {}, { tools = { run, stamp } })
  assert(both:find("<code_tools>", 1, true) ~= nil, both)
  assert(both:find('- stamp: Stamps a word. Input: {"properties":{},"type":"object"}', 1, true) ~= nil, both)
  assert(both:find("- stamp: Stamp a word", 1, true) == nil, both)
  local alone = Prompt.build(dir, {}, { tools = { stamp } })
  assert(alone:find("<code_tools>", 1, true) == nil, alone)
end

local function test_a_prompt_that_offers_run_lists_the_modules_a_snippet_may_require()
  local run = assert(Tools.find(Tools.all(), "run"))
  local read = NOTE
  local listed = Prompt.build("/w", {}, { tools = { run }, modules = "cosmic.csv: CSV.\ncosmic.fs: Files." })
  assert(listed:find("\n\n<cosmic_modules>\nThe cosmic.* modules a snippet of run may require", 1, true) ~= nil, listed)
  assert(listed:find(":\ncosmic.csv: CSV.\ncosmic.fs: Files.\n</cosmic_modules>", 1, true) ~= nil, listed)
  -- No run, or no modules: no section.
  assert(Prompt.build("/w", {}, { tools = { read }, modules = "cosmic.csv: CSV." }):find("cosmic_modules", 1, true) == nil)
  assert(Prompt.build("/w", {}, { tools = { run }, modules = "" }):find("cosmic_modules", 1, true) == nil)
end

--- Given no modules, a prompt that offers run reads them from this binary's docs; where they cannot be read, as under
--- this test's store, it lists none rather than raise (build/agent_modules_tool_test.tl reads a built binary's).
local function test_a_prompt_whose_binary_withholds_its_docs_lists_no_modules()
  local run = assert(Tools.find(Tools.all(), "run"))
  local built = Prompt.build("/w", {}, { tools = { run } })
  assert(built:find("<cosmic_modules>", 1, true) == nil, built)
end

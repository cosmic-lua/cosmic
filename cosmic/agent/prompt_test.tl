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

local function test_the_prompt_names_the_library_but_tooling_each_with_the_start_of_its_first_sentence()
  local long = string.rep("word ", 40)
  local p = Prompt.build("/", {}, { library = {
    { module = "cosmic.fs", text = "Files and\n directories.", closed = "" },
    { module = "cosmic.web.route", text = "Routes.", closed = "" },
    { module = "cosmic.test", text = "Tests.", closed = "" },
    { module = "cosmic.long", text = long, closed = "" },
    { module = "cosmic.bare", text = "", closed = "" },
  } })
  assert(p:find("<stdlib>", 1, true) ~= nil, p)
  assert(p:find("\n- cosmic.fs: Files and directories.\n", 1, true) ~= nil, p)
  assert(p:find("cosmic.web.route:", 1, true) == nil and p:find("cosmic.test:", 1, true) == nil, p)
  local line = assert(p:match("\n(%- cosmic%.long: [^\n]*)"))
  assert(#line <= 90 + #"- cosmic.long: " and line:sub(-7) == "word...", line)
  assert(p:find("\n- cosmic.bare\n", 1, true) ~= nil, p)
  assert(Prompt.build("/", {}):find("<stdlib>", 1, true) == nil)
  -- With no space to cut at, the cut ends at a character's end.
  local wide = Prompt.build("/", {}, { library = { { module = "cosmic.wide", text = string.rep("é", 60), closed = "" } } })
  local wide_line = assert(wide:match("\n%- cosmic%.wide: ([^\n]*)"))
  assert(wide_line == string.rep("é", 43) .. "...", wide_line)
  -- The library comes before the project's instructions, the same for every project.
  local both = Prompt.build("/", { { path = "/AGENTS.md", content = "mine" } }, { library = {
    { module = "cosmic.fs", text = "Files.", closed = "" } } })
  assert(assert(both:find("<stdlib>", 1, true)) < assert(both:find("<project_context>", 1, true)), both)
end

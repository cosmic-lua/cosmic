--- @public
--- The system prompt of `cosmic agent`, built as pi builds its own: a line
--- of who the model is, the tools in a line each, the rules the tools
--- bring, the project's instructions (each AGENTS.md or CLAUDE.md from
--- the root down to the working directory). It
--- names no path of the machine, only paths relative to the working
--- directory, so sessions in other directories read it from the cache;
--- the working directory and the MCP servers, which differ from one session
--- to the next, are a block of their own after it ([`Prompt.where`]). Code mode adds no section of its own: what a
--- snippet of `run` may do is in that tool's description, so a session
--- that never runs one pays for little more than the tool.

local AgentMcp = require("cosmic.agent.mcp")
local Fs = require("cosmic.fs")
local Data = require("cosmic.agent.prompt_data")
local Text = require("cosmic.agent.prompt_text")
local WhereText = require("cosmic.agent.where_text")
local Json = require("cosmic.json")
local Tools = require("cosmic.agent.tools")

local record Prompt
  --- One file of project instructions.
  record Context
    --- The file's path.
    path: string
    --- What it holds.
    content: string
  end

  --- What a prompt holds beside the project's instructions.
  record Options
    --- The tools the model is offered, each a line and its rules; [`Tools.all`] where nil, as an agent's.
    tools?: {Tools.Tool}
    --- Whether a snippet may run programs (Host.bash), as the agent's `commands`; false where nil.
    commands?: boolean
    --- The cosmic.* modules a snippet may require, a line each, which the prompt lists where run is offered;
    --- [`Host.modules`]' from this binary's docs where nil, "" for none.
    modules?: string
    --- What a snippet loads code from, as the agent's `modules` ([`Worker.Options`]); [`Worker.MODULES`] where nil.
    --- Without `cosmic` the prompt lists no `cosmic.*` module; with `.` it says a snippet may require the working
    --- directory's own.
    loads?: {string}
  end
end

--- The instructions files that hold for `cwd`: in each directory from
--- the root down to it, its AGENTS.md, else its CLAUDE.md.
function Prompt.contexts(cwd: string): {Prompt.Context}
  local dirs: mut {string} = {}
  local dir = cwd
  while true do
    table.insert(dirs, 1, dir)
    local up = Fs.dirname(dir)
    if up == dir or up == "" then break end
    dir = up
  end
  local out: mut {Prompt.Context} = {}
  for _, d in ipairs(dirs) do
    for _, name in ipairs({ "AGENTS.md", "CLAUDE.md" }) do
      local path = (if d == "/" then "" else d end) .. "/" .. name
      local body, _ = Fs.read(path)
      if body ~= nil then
        out[#out + 1] = { path = path, content = body }
        break
      end
    end
  end
  return out
end

--- `path`, a file in `cwd` or in a directory above it, as seen from
--- `cwd`: its name, after a `../` for each directory up; `path` itself
--- where it is in neither.
local function seen_from(path: string, cwd: string): string
  local dir = Fs.dirname(path)
  local here, up = (cwd:gsub("(.)/+$", "%1")), ""
  while here ~= dir do
    local parent = Fs.dirname(here)
    if parent == here or parent == "" then return path end
    here, up = parent, up .. "../"
  end
  return up .. Fs.basename(path)
end

--- What follows the system prompt of a session in `cwd`, past its cache
--- mark: the working directory and each of `servers` (its name and what
--- it is for, which a snippet calls by `require("mcp.<name>")`), which the
--- system prompt leaves out so that it is the same in every directory and
--- for every set of servers.
function Prompt.where(cwd: string, servers?: {AgentMcp.Server}): string
  local named: mut {Data.Server} = {}
  for _, server in ipairs(servers or {}) do
    local about = server.description
    named[#named + 1] = { name = server.name, about = if about ~= nil then (about:gsub("%s+", " ")) else nil end }
  end
  return WhereText.render({ cwd = cwd, servers = if #named > 0 then named else nil end })
end

--- The system prompt for `cwd`, with `contexts` as its project's instructions (each named by its path relative to `cwd`),
--- and `options`' tools.
-- The words are the text template prompt_text.tmpl (cosmic.template); this fills its record.
function Prompt.build(cwd: string, contexts: {Prompt.Context}, options?: Prompt.Options): string
  local offered = if options ~= nil and options.tools ~= nil then options.tools else Tools.all() end
  local instructions: mut {Data.Instructions} = {}
  for _, c in ipairs(contexts) do
    instructions[#instructions + 1] = { path = seen_from(c.path, cwd), content = c.content }
  end
  local for_model: mut {Tools.Tool} = {}
  local for_code: mut {Data.CodeTool} = {}
  for _, t in ipairs(offered) do
    if Tools.for_model(t) then for_model[#for_model + 1] = t end
    if Tools.for_code(t) then
      local input, _ = Json.encode(t.schema)
      for_code[#for_code + 1] = { name = t.name, about = (t.description:gsub("%s+", " ")), input = input or "{}" }
    end
  end
  local run = Tools.find(for_model, "run") ~= nil
  local given = if options ~= nil then options.loads else nil end
  local loads = given or require("cosmic.agent.worker").MODULES
  local cosmic, tree = false, false
  for _, word in ipairs(loads) do
    if word == "cosmic" then cosmic = true elseif word == "." then tree = true end
  end
  local modules: string? = nil
  if run and cosmic then
    -- Read only where run is offered: the docs take a few tens of milliseconds to list.
    if options ~= nil and options.modules ~= nil then
      modules = options.modules
    else
      -- A binary whose store withholds its docs (a test's) raises on reading them: the prompt lists none then.
      local read, listed = pcall(require("cosmic.agent.host").modules)
      modules = if read then listed else nil end
    end
    if modules == "" or (modules ~= nil and modules:find("^host: modules: ") ~= nil) then
      modules = nil
    end
  end
  return Text.render({
    tools = if #for_model > 0 then for_model else nil end,
    code_tools = if #for_code > 0 and run then for_code else nil end,
    commands = run and options ~= nil and options.commands == true,
    run = run,
    tree = run and tree,
    cosmic = cosmic,
    instructions = if #instructions > 0 then instructions else nil end,
    modules = modules,
  })
end

return Prompt

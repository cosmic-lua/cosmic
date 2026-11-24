--- @public
--- The system prompt of `cosmic agent`, built as pi builds its own: a line
--- of who the model is, the tools in a line each, the rules the tools
--- bring, the project's instructions (each AGENTS.md or CLAUDE.md from
--- the root down to the working directory), and the MCP servers. It
--- names no path of the machine, only paths relative to the working
--- directory, so sessions in other directories read it from the cache;
--- the working directory itself is a block of its own after it
--- ([`Prompt.where`]). Code mode adds no section of its own: what a
--- snippet of `run` may do is in that tool's description, so a session
--- that never runs one pays for little more than the tool.

local AgentMcp = require("cosmic.agent.mcp")
local Fs = require("cosmic.fs")
local Data = require("cosmic.agent.prompt_data")
local Text = require("cosmic.agent.prompt_text")
local Tools = require("cosmic.agent.tools")

local record Prompt
  --- One file of project instructions.
  record Context
    --- The file's path.
    path: string
    --- What it holds.
    content: string
  end

  --- What a prompt holds beside its tools and the project's instructions.
  record Options
    --- The MCP servers a snippet may call, by `require("mcp.<name>")`.
    servers?: {AgentMcp.Server}
    --- The tools the model is offered, each a line and its rules; [`Tools.default`] where nil, as an agent's.
    tools?: {Tools.Tool}
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
--- mark: the working directory, which the system prompt leaves out so
--- that it is the same in every directory.
function Prompt.where(cwd: string): string
  return "<cwd>\n" .. cwd .. "\n</cwd>"
end

--- The system prompt for `cwd`, with `contexts` as its project's instructions (each named by its path relative to `cwd`), and `options`' MCP servers where
--- given: each server's name and what it is for, which a snippet calls by `require("mcp.<name>")`.
-- The words are the text template prompt_text.tmpl (cosmic.template); this fills its record.
function Prompt.build(cwd: string, contexts: {Prompt.Context}, options?: Prompt.Options): string
  local offered = if options ~= nil and options.tools ~= nil then options.tools else Tools.default() end
  local instructions: mut {Data.Instructions} = {}
  for _, c in ipairs(contexts) do
    instructions[#instructions + 1] = { path = seen_from(c.path, cwd), content = c.content }
  end
  local servers: mut {Data.Server} = {}
  local given: {AgentMcp.Server} = if options ~= nil and options.servers ~= nil then options.servers else {} end
  for _, server in ipairs(given) do
    local about = server.description
    servers[#servers + 1] = { name = server.name, about = if about ~= nil then (about:gsub("%s+", " ")) else nil end }
  end
  return Text.render({
    tools = if #offered > 0 then offered else nil end,
    bash = Tools.find(offered, "bash") ~= nil,
    run = Tools.find(offered, "run") ~= nil,
    instructions = if #instructions > 0 then instructions else nil end,
    servers = if #servers > 0 then servers else nil end,
  })
end

return Prompt

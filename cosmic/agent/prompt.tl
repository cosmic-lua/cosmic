--- @public
--- The system prompt of `cosmic agent`, built as pi builds its own: a line
--- of who the model is, the tools in a line each, the rules the tools
--- bring, the project's instructions (each AGENTS.md or CLAUDE.md from
--- the root down to the working directory), and the working directory.

local Fs = require("cosmic.fs")
local Tools = require("cosmic.agent.tools")

local record Prompt
  --- One file of project instructions.
  record Context
    --- The file's path.
    path: string
    --- What it holds.
    content: string
  end
end

local PREAMBLE <const> = "You are a coding assistant running inside cosmic agent, the coding agent of cosmic. " ..
  "Help users inspect files, run commands, and modify code."

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

local function section(name: string, body: string): string
  return "<" .. name .. ">\n" .. body .. "\n</" .. name .. ">"
end

--- The system prompt for `cwd`, with `contexts` as its project's
--- instructions.
function Prompt.build(cwd: string, contexts: {Prompt.Context}): string
  local tools: mut {string} = {}
  local rules: mut {string} = { "- Use bash for file operations like ls, rg, find" }
  for _, t in ipairs(Tools.list) do
    tools[#tools + 1] = "- " .. t.name .. ": " .. t.snippet
    for _, g in ipairs(t.guidelines) do rules[#rules + 1] = "- " .. g end
  end
  rules[#rules + 1] = "- Be concise in your responses"
  rules[#rules + 1] = "- Show file paths clearly when working with files"
  local parts: mut {string} = {
    PREAMBLE,
    section("tools", table.concat(tools, "\n")),
    section("rules", table.concat(rules, "\n")),
  }
  if #contexts > 0 then
    local files: mut {string} = { "Project-specific instructions and guidelines:" }
    for _, c in ipairs(contexts) do
      files[#files + 1] = "<project_instructions path=\"" .. c.path .. "\">\n" .. c.content ..
        "\n</project_instructions>"
    end
    parts[#parts + 1] = section("project_context", table.concat(files, "\n\n"))
  end
  parts[#parts + 1] = section("cwd", cwd)
  return table.concat(parts, "\n\n")
end

return Prompt

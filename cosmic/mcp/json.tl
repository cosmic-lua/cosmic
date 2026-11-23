--- The JSON the protocol sends each record of [`cosmic.mcp`] as: a tool as `tools/list` lists it, a tool's result as
--- `tools/call` answers it, and the rest, each a [`Json.Value`] for [`Json.encode`]. A program that prints or keeps
--- what a server answered writes it with these, as `cosmic mcp` does; [`cosmic.mcp.server`] sends the same.
---
---     local tools = assert(session:tools())
---     print(assert(Json.encode(McpJson.list(tools, McpJson.tool))))
--- @public

local Json = require("cosmic.json")
local Mcp = require("cosmic.mcp")
local wire = require("cosmic.mcp.wire")

local record McpJson
end

--- `t` as `tools/list` lists it.
function McpJson.tool(t: Mcp.Tool): Json.Value
  return wire.tool(t)
end

--- `r` as `tools/call` answers it.
function McpJson.tool_result(r: Mcp.ToolResult): Json.Value
  return wire.tool_result(r)
end

--- `r` as `resources/list` lists it.
function McpJson.resource(r: Mcp.Resource): Json.Value
  return wire.resource(r)
end

--- `t` as `resources/templates/list` lists it.
function McpJson.template(t: Mcp.ResourceTemplate): Json.Value
  return wire.template(t)
end

--- `c`, one of what `resources/read` answers.
function McpJson.contents(c: Mcp.ResourceContents): Json.Value
  return wire.contents(c)
end

--- `p` as `prompts/list` lists it.
function McpJson.prompt(p: Mcp.Prompt): Json.Value
  return wire.prompt(p)
end

--- `r` as `prompts/get` answers it.
function McpJson.prompt_result(r: Mcp.PromptResult): Json.Value
  return wire.prompt_result(r)
end

--- `d` as `server/discover` answers it, less its `_meta` and `resultType`.
function McpJson.discovery(d: Mcp.Discovery): Json.Value
  local caps: mut {string: Json.Value} = {}
  local c = d.capabilities
  for name, feature in pairs({ tools = c.tools, prompts = c.prompts }) do
    local entry: mut {string: Json.Value} = {}
    if feature.listChanged == true then entry["listChanged"] = true end
    caps[name] = entry
  end
  local resources = c.resources
  if resources ~= nil then
    local entry: mut {string: Json.Value} = {}
    if resources.listChanged == true then entry["listChanged"] = true end
    if resources.subscribe == true then entry["subscribe"] = true end
    caps["resources"] = entry
  end
  local out: mut {string: Json.Value} = { supportedVersions = wire.strings(d.supportedVersions), capabilities = caps }
  if d.instructions ~= nil then out["instructions"] = d.instructions end
  local info = d.serverInfo
  if info ~= nil then out["serverInfo"] = wire.implementation(info) end
  return out
end

--- `values`, each made JSON by `each` (one of the above), as a JSON array, `[]` when there are none.
function McpJson.list<T>(values: {T}, each: function(T): Json.Value): Json.Value
  return wire.list(values, each)
end

return McpJson

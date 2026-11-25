--- @public
--- The module a snippet of cosmic agent's `run` tool requires to call an MCP server's tools as typed functions: for the
--- server `notes`, `require("mcp.notes")`. Each tool is a function of the module, its arguments a record made of the
--- tool's `inputSchema`, and its result a record made of its `outputSchema` where it lists one that a record can
--- hold, or else a [`Host.Result`]:
---
---     local notes = require("mcp.notes")
---     print(notes.search({ query = "teal" }).text)
---
--- A wrong argument is refused before the snippet runs, as any type error is; a call that fails raises, as
--- [`Host.tool`] does. [`Host.declaration`] shows a server's
--- module. The worker makes it at the first snippet that requires it, from the tools the server lists then.
---
--- A schema of a shape a record cannot hold is read as [`Json.Value`]: a member whose name is no Teal name, `anyOf`,
--- `oneOf`, `allOf`, `$ref`, or a list of types other than one and "null". A member of an output that may be null is
--- optional, as the client reads a null: absent. A schema of `properties` and no `type` is an object's.

local Json = require("cosmic.json")

local record McpModule
  --- What [`McpModule.made`] makes of a server's tools.
  record Made
    --- The name a snippet requires: "mcp." and the server's name.
    module: string
    --- The Teal the checker reads of the module: its records and functions, with no code.
    teal: string
    --- Each function of the module, in the order the server listed its tool.
    functions: {Function}
  end

  --- A function of a module: its name, the tool it calls, and how.
  record Function
    --- Its name in the module: the tool's, each byte Teal cannot name with turned into `_`.
    name: string
    --- The name of the tool it calls, as the server lists it.
    tool: string
    --- Whether it returns the tool's `structuredContent` ([`Host.structured`]), not a [`Host.Result`] ([`Host.tool`]).
    structured: boolean
    --- The tool's `inputSchema`, which [`McpModule.shaped`] reads its arguments by.
    input: {string: Json.Value}
    --- The tool's description, as the server gave it: "" for none.
    description: string
    --- The Teal of the module with this function alone: its records and its line, named as in the whole module.
    teal: string
  end
end

--- The words Teal reserves, which a member or a function cannot be named: Lua's and the grammar's own
--- ([`lang.lexer`]'s `reserved`). The words that begin a declaration (`type`, `record`) stay names.
local RESERVED <const>: {string: boolean} = {
  ["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true, ["elseif"] = true, ["end"] = true,
  ["false"] = true, ["for"] = true, ["function"] = true, ["global"] = true, ["goto"] = true, ["if"] = true,
  ["in"] = true, ["local"] = true, ["nil"] = true, ["not"] = true, ["or"] = true, ["repeat"] = true,
  ["return"] = true, ["then"] = true, ["true"] = true, ["until"] = true, ["while"] = true,
  ["match"] = true, ["continue"] = true, ["mut"] = true, ["is"] = true, ["asserts"] = true, ["userdata"] = true,
  ["as"] = true,
}

--- How deep a schema is read: a value deeper is a [`Json.Value`].
local DEPTH <const> = 8

--- Whether `name` can name a member or a function.
local function teal_name(name: string): boolean
  return name:match("^[%a_][%w_]*$") ~= nil and RESERVED[name] == nil
end

--- `text` on one line: its runs of white space each a space.
local function one_line(text: string): string
  local line = text:gsub("%s+", " ")
  return (line:gsub("^ ", ""):gsub(" $", ""))
end

--- The doc comment of `schema`'s description, at `indent`, or "" for none.
local function doc_of(schema: {string: Json.Value}, indent: string): string
  local about = schema["description"]
  if not (about is string) or about == "" then return "" end
  return indent .. "--- " .. one_line(about) .. "\n"
end

--- `name` as a type's name: each part between `_` begun with a capital.
local function pascal(name: string): string
  local out = name:gsub("_(%w)", function(c: string): string return c:upper() end):gsub("^%l", string.upper)
  return (out:gsub("_", ""))
end

--- The records a module declares, in the order they are made, and the names they took; `output` while a tool's
--- output is read, where a member that may be null is optional, as the client reads a null: absent.
local record Records
  mut lines: mut {string}
  taken: mut {string: boolean}
  mut output: boolean
end

--- A name for a record from `base` that no record of `records` took.
local function fresh(records: Records, base: string): string
  local name = if base:match("^%u") ~= nil then base else "T" .. base end
  local n = 1
  local tried = name
  while records.taken[tried] == true do
    n = n + 1
    tried = name .. tostring(n)
  end
  records.taken[tried] = true
  return tried
end

--- The one type `schema` names, or nil where it names none or several, and whether it may be null. A schema of
--- `properties` and no type is an object's.
local function one_type(schema: {string: Json.Value}): (string?, boolean)
  local given = schema["type"]
  if given is string then return given, given == "null" end
  if given == nil and Json.object_of(schema["properties"]) ~= nil then return "object", false end
  local list = Json.array_of(given)
  if list == nil then return nil, false end
  local found: string? = nil
  local nullable = false
  for _, item in ipairs(list) do
    if item == "null" then
      nullable = true
    elseif item is string then
      if found ~= nil then return nil, nullable end
      found = item
    end
  end
  return found, nullable
end

--- The walk of a schema: [`Walk.type_of`] and [`Walk.record_of`] call each other.
local record Walk end

--- The record `name` of `schema`'s `properties`, declared in `records`, or nil where a member's name is no Teal name.
function Walk.record_of(records: Records, schema: {string: Json.Value}, properties: {string: Json.Value}, base: string,
                        depth: integer): string?
  local names: mut {string} = {}
  for key in pairs(properties) do
    if not teal_name(key) then return nil end
    names[#names + 1] = key
  end
  table.sort(names)
  local required: mut {string: boolean} = {}
  for _, item in ipairs(Json.array_of(schema["required"]) or {}) do
    if item is string then required[item] = true end
  end
  local name = fresh(records, base)
  local body: mut {string} = {}
  for _, key in ipairs(names) do
    local member = properties[key]
    local member_schema = Json.object_of(member) or {}
    local field_type = Walk.type_of(records, member, name .. pascal(key), depth + 1)
    local _, nullable = one_type(member_schema)
    local optional = required[key] ~= true or (records.output and nullable)
    body[#body + 1] = doc_of(member_schema, "    ") .. "    " .. key .. (if optional then "?" else "" end) .. ": " ..
      field_type .. "\n"
  end
  local declared = doc_of(schema, "  ") .. "  record " .. name .. "\n" .. table.concat(body) .. "  end\n"
  records.lines[#records.lines + 1] = declared
  return name
end

--- The Teal type of the schema `given`, a record of it declared in `records` named from `base`.
function Walk.type_of(records: Records, given: Json.Value?, base: string, depth: integer): string
  local schema = Json.object_of(given)
  if schema == nil or depth > DEPTH then return "Json.Value" end
  if schema["anyOf"] ~= nil or schema["oneOf"] ~= nil or schema["allOf"] ~= nil or schema["$ref"] ~= nil then
    return "Json.Value"
  end
  local kind = one_type(schema)
  if kind == "string" then return "string" end
  if kind == "integer" then return "integer" end
  if kind == "number" then return "number" end
  if kind == "boolean" then return "boolean" end
  if kind == "array" then
    local items = schema["items"]
    if items == nil then return "{Json.Value}" end
    return "{" .. Walk.type_of(records, items, base .. "Item", depth + 1) .. "}"
  end
  if kind == "object" then
    local properties = Json.object_of(schema["properties"])
    if properties ~= nil and next(properties) ~= nil then
      local name = Walk.record_of(records, schema, properties, base, depth)
      if name ~= nil then return name end
      return "{string: Json.Value}"
    end
    local more = schema["additionalProperties"]
    if Json.object_of(more) ~= nil then
      return "{string: " .. Walk.type_of(records, more, base .. "Value", depth + 1) .. "}"
    end
    return "{string: Json.Value}"
  end
  return "Json.Value"
end

--- `name` as a function's name: each byte that is no letter, digit or `_` a `_`, with `_` before a leading digit and
--- after a reserved word.
local function function_name(name: string): string
  local out = name:gsub("[^%w_]", "_")
  if out:match("^%d") ~= nil or out == "" then out = "_" .. out end
  if RESERVED[out] == true then out = out .. "_" end
  return out
end

--- The Teal of the module `local_name` of the MCP server `server`, holding `body`: its records and its functions.
local function module_of(server: string, local_name: string, body: string): string
  return "local Host = require(\"cosmic.agent.host\")\n" ..
    "local Json = require(\"cosmic.json\")\n\n" ..
    "--- The tools of the MCP server " .. Json.quote(server) .. ".\n" ..
    "local record " .. local_name .. "\n" .. body .. "end\n\n" ..
    "return " .. local_name .. "\n"
end

--- The module of `server`'s `tools`, as [`Host.tools`] returns them.
function McpModule.made(server: string, tools: {{string: Json.Value}}): McpModule.Made
  local local_name = if teal_name(server) then server else "server" end
  local records: Records = { lines = {}, taken = {}, output = false }
  local functions: mut {string} = {}
  local made: mut {McpModule.Function} = {}
  local used: mut {string: boolean} = {}
  for _, tool in ipairs(tools) do
    local name = tool["name"]
    if name is string then
      local base = function_name(name)
      local fn = base
      local n = 1
      while used[fn] == true do
        n = n + 1
        fn = base .. "_" .. tostring(n)
      end
      used[fn] = true
      local stem = pascal(fn)
      local first = #records.lines + 1
      local input = Json.object_of(tool["inputSchema"]) or {}
      records.output = false
      local typed = Walk.type_of(records, input, stem .. "Input", 1)
      local input_type = if typed == "Json.Value" then "{string: Json.Value}" else typed end
      local optional = true
      for _, _ in ipairs(Json.array_of(input["required"]) or {}) do optional = false end
      local output_schema = Json.object_of(tool["outputSchema"])
      records.output = true
      local output_type = if output_schema ~= nil then Walk.type_of(records, output_schema, stem .. "Output", 1) else nil end
      -- Only a record is read of `structuredContent`; any other output is read from the result, as a tool's with none.
      local structured = output_type ~= nil and output_type:match("^%u") ~= nil and output_type ~= "Json.Value"
      local answer = if structured then assert(output_type) else "Host.Result" end
      local about = doc_of(tool, "  ")
      if fn ~= name then about = about .. "  --- The tool " .. Json.quote(name) .. ".\n" end
      local line = about .. "  " .. fn .. ": function(arguments" .. (if optional then "?" else "" end) ..
        ": " .. input_type .. "): " .. answer .. "\n"
      functions[#functions + 1] = line
      local own = table.concat(records.lines, "", first, #records.lines) .. line
      local described = tool["description"]
      made[#made + 1] = { name = fn, tool = name, structured = structured, input = input,
        description = if described is string then described else "" end, teal = module_of(server, local_name, own) }
    end
  end
  local teal = module_of(server, local_name, table.concat(records.lines) .. table.concat(functions))
  return { module = "mcp." .. server, teal = teal, functions = made }
end

--- `value` as `schema` says to send it: each list it holds where the schema names an array marked one
--- ([`Json.array`]), so that an empty one goes out as `[]`, not `{}`.
function McpModule.shaped(schema: Json.Value?, value: Json.Value, depth?: integer): Json.Value
  local at = depth or 1
  local given = Json.object_of(schema)
  if given == nil or at > DEPTH or not (value is table) then return value end
  local kind = one_type(given)
  if kind == "array" then
    local list = Json.array_of(value)
    if list == nil then
      -- An empty table is no list by its items: the schema says it is one.
      local object = Json.object_of(value)
      if object ~= nil and next(object) == nil then return Json.array() end
      return value
    end
    local out: mut {Json.Value} = {}
    for i, item in ipairs(list) do out[i] = McpModule.shaped(given["items"], item, at + 1) end
    return Json.array(out)
  end
  local object = Json.object_of(value)
  if kind ~= "object" or object == nil then return value end
  local properties = Json.object_of(given["properties"]) or {}
  local out: mut {string: Json.Value} = {}
  for key, member in pairs(object) do
    local member_schema = properties[key]
    out[key] = McpModule.shaped(if member_schema ~= nil then member_schema else given["additionalProperties"] end,
      member, at + 1)
  end
  return out
end

return McpModule

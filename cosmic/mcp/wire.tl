--- What [`cosmic.mcp.server`] and [`cosmic.mcp.client`] share of the
--- wire: a JSON-RPC message read from its text, the text of a response,
--- and each record of [`cosmic.mcp`] as the JSON value it is sent as, or
--- read back from one. A value sent is built as a [`Json.Value`], field
--- by field, so an empty list goes out as `[]` and an empty object as
--- `{}`.

local Failure = require("cosmic.failure")
local Json = require("cosmic.json")
local Mcp = require("cosmic.mcp")
local Shape = require("cosmic.shape")

local record wire
  --- The parts of one JSON-RPC message.
  record Message
    --- The id, encoded as JSON (`1`, `"a"`), nil for a notification and
    --- for a response with none.
    id?: string
    method?: string
    params: any
    result: any
    error?: Error
  end

  --- A JSON-RPC error, as one arrives.
  record Error
    code: integer
    message: string
    data: any
  end

  --- What `server/discover` answers, as it arrives.
  record Discover
    supportedVersions: {string}
    capabilities: Mcp.ServerCapabilities
    instructions?: string
    _meta: any
  end

  --- How a peer names itself, as it arrives.
  record Info
    name: string
    version: string
    title?: string
    description?: string
    websiteUrl?: string
    icons?: {Mcp.Icon}
  end

  record Resources
    resources: {Mcp.Resource}
    nextCursor?: string
  end

  record Templates
    resourceTemplates: {Mcp.ResourceTemplate}
    nextCursor?: string
  end

  record Prompts
    prompts: {Mcp.Prompt}
    nextCursor?: string
  end

  record Tools
    tools: {any}
    nextCursor?: string
  end

  record Read
    contents: {Mcp.ResourceContents}
  end

  --- A tool as it arrives, its schemas not yet read as values.
  record Tool
    name: string
    title?: string
    description?: string
    inputSchema: any
    outputSchema: any
    annotations?: Mcp.ToolAnnotations
    icons?: {Mcp.Icon}
  end

  --- A tool's result as it arrives.
  record ToolResult
    content: {Mcp.Content}
    structuredContent: any
    isError?: boolean
  end

  --- A prompt, as it arrives.
  record PromptResult
    description?: string
    messages: {Mcp.PromptMessage}
  end

  --- What a result says of its kind: "complete", or "input_required"
  --- for a request the server wants more for.
  record Kind
    resultType?: string
  end
end

--- A message's fields, as JSON-RPC names them.
local record Envelope
  jsonrpc?: string
  id: any
  method?: string
  params: any
  result: any
  error: any
end

local ENVELOPE <const>: Shape.Typed<Envelope> = Shape.record_of("Envelope")
local ERROR <const>: Shape.Typed<wire.Error> = Shape.record_of("wire.Error")
local DISCOVER <const>: Shape.Typed<wire.Discover> = Shape.record_of("wire.Discover")
local RESOURCES <const>: Shape.Typed<wire.Resources> = Shape.record_of("wire.Resources")
local TEMPLATES <const>: Shape.Typed<wire.Templates> = Shape.record_of("wire.Templates")
local PROMPTS <const>: Shape.Typed<wire.Prompts> = Shape.record_of("wire.Prompts")
local TOOLS <const>: Shape.Typed<wire.Tools> = Shape.record_of("wire.Tools")
local READ <const>: Shape.Typed<wire.Read> = Shape.record_of("wire.Read")
local TOOL <const>: Shape.Typed<wire.Tool> = Shape.record_of("wire.Tool")
local TOOL_RESULT <const>: Shape.Typed<wire.ToolResult> = Shape.record_of("wire.ToolResult")
local PROMPT_RESULT <const>: Shape.Typed<wire.PromptResult> = Shape.record_of("wire.PromptResult")
local INFO <const>: Shape.Typed<wire.Info> = Shape.record_of("wire.Info")
local KIND <const>: Shape.Typed<wire.Kind> = Shape.record_of("wire.Kind")

--- The message `text` holds, or nil and a failure whose `code` is
--- JSON-RPC's for it: -32700 for text that is not JSON, -32600 for JSON
--- that is not a JSON-RPC 2.0 message.
function wire.message(text: string): (wire.Message) | (nil, Failure)
  local decoded, bad = Json.decode(text)
  if decoded == nil then return nil, Failure.coded(tostring(bad), Mcp.PARSE_ERROR) end
  local envelope, invalid = ENVELOPE:into(decoded)
  if envelope == nil then
    return nil, Failure.coded("not a JSON-RPC message: " .. invalid, Mcp.INVALID_REQUEST)
  end
  if envelope.jsonrpc ~= "2.0" then
    return nil, Failure.coded('not a JSON-RPC 2.0 message: it has no "jsonrpc": "2.0"', Mcp.INVALID_REQUEST)
  end
  local id: string? = nil
  local raw = envelope.id
  if raw ~= nil then
    if not (raw is string or math.type(raw) == "integer") then
      return nil, Failure.coded("a request id must be a string or an integer", Mcp.INVALID_REQUEST)
    end
    local text_id, _ = Json.encode_any(raw)
    id = text_id
  end
  local err: wire.Error? = nil
  if envelope.error ~= nil then
    local said, why = ERROR:into(envelope.error)
    if said == nil then
      return nil, Failure.coded("an error that is not a JSON-RPC error: " .. why, Mcp.INVALID_REQUEST)
    end
    err = said
  end
  return { id = id, method = envelope.method, params = envelope.params, result = envelope.result, error = err }
end

--- The text of the response to the request `id` (encoded) answering
--- `result`, nil where `result` holds a string that is not UTF-8.
function wire.response(id: string, result: Json.Value): string?
  local text, _ = Json.encode(result)
  if text == nil then return nil end
  return '{"jsonrpc":"2.0","id":' .. id .. ',"result":' .. text .. "}"
end

--- The text of an error response to `id` (encoded; nil where the id
--- could not be read), of `code` and `message`, and `data` where given.
function wire.error(id: string?, code: integer, message: string, data?: Json.Value): string
  local out = '{"jsonrpc":"2.0",' .. (if id ~= nil then '"id":' .. id .. "," else "" end) ..
    '"error":{"code":' .. tostring(code) .. ',"message":' .. Json.quote(message)
  if data ~= nil then out = out .. ',"data":' .. assert(Json.encode(data)) end
  return out .. "}}"
end

--- The text of the request `id` (encoded) of `method` with `params`.
function wire.request(id: string, method: string, params: Json.Value): string
  return '{"jsonrpc":"2.0","id":' .. id .. ',"method":' .. Json.quote(method) .. ',"params":' ..
    assert(Json.encode(params)) .. "}"
end

-- Records as values.

--- Sets `key` of `o` to `v`, where `v` is there.
local function put(o: mut {string: Json.Value}, key: string, v: Json.Value?)
  if v ~= nil then o[key] = v end
end

--- `list` as a JSON array of strings.
function wire.strings(list: {string}): Json.Value
  local out: mut {Json.Value} = {}
  for i, s in ipairs(list) do out[i] = s end
  return Json.array(out)
end

local strings = wire.strings

local function icons(list?: {Mcp.Icon}): Json.Value?
  if list == nil then return nil end
  local out: mut {Json.Value} = {}
  for _, icon in ipairs(list) do
    local o: mut {string: Json.Value} = { src = icon.src }
    put(o, "mimeType", icon.mimeType)
    if icon.sizes ~= nil then o["sizes"] = strings(icon.sizes) end
    put(o, "theme", icon.theme)
    out[#out + 1] = o
  end
  return Json.array(out)
end

local function annotations(a?: Mcp.Annotations): Json.Value?
  if a == nil then return nil end
  local o: mut {string: Json.Value} = {}
  if a.audience ~= nil then
    local roles: mut {string} = {}
    for i, role in ipairs(a.audience) do roles[i] = role end
    put(o, "audience", strings(roles))
  end
  put(o, "priority", a.priority)
  put(o, "lastModified", a.lastModified)
  return o
end

--- `info` as a value.
function wire.implementation(info: Mcp.Implementation): Json.Value
  local o: mut {string: Json.Value} = { name = info.name, version = info.version }
  put(o, "title", info.title)
  put(o, "description", info.description)
  put(o, "websiteUrl", info.websiteUrl)
  put(o, "icons", icons(info.icons))
  return o
end

--- `contents` as a value.
function wire.contents(contents: Mcp.ResourceContents): Json.Value
  local o: mut {string: Json.Value} = { uri = contents.uri }
  put(o, "mimeType", contents.mimeType)
  put(o, "text", contents.text)
  put(o, "blob", contents.blob)
  return o
end

--- `c` as a value.
local function content(c: Mcp.Content): Json.Value
  local o: mut {string: Json.Value} = { type = c.type }
  put(o, "text", c.text)
  put(o, "data", c.data)
  put(o, "mimeType", c.mimeType)
  put(o, "uri", c.uri)
  put(o, "name", c.name)
  put(o, "title", c.title)
  put(o, "description", c.description)
  put(o, "size", c.size)
  if c.resource ~= nil then o["resource"] = wire.contents(c.resource) end
  put(o, "annotations", annotations(c.annotations))
  return o
end

local function content_list(list: {Mcp.Content}): Json.Value
  local out: mut {Json.Value} = {}
  for i, c in ipairs(list) do out[i] = content(c) end
  return Json.array(out)
end

--- `t` as a value.
function wire.tool(t: Mcp.Tool): Json.Value
  local o: mut {string: Json.Value} = { name = t.name, inputSchema = t.inputSchema }
  put(o, "title", t.title)
  put(o, "description", t.description)
  put(o, "outputSchema", t.outputSchema)
  local a = t.annotations
  if a ~= nil then
    local hints: mut {string: Json.Value} = {}
    put(hints, "title", a.title)
    put(hints, "readOnlyHint", a.readOnlyHint)
    put(hints, "destructiveHint", a.destructiveHint)
    put(hints, "idempotentHint", a.idempotentHint)
    put(hints, "openWorldHint", a.openWorldHint)
    put(o, "annotations", hints)
  end
  put(o, "icons", icons(t.icons))
  return o
end

--- `r` as the fields of a result.
function wire.tool_result(r: Mcp.ToolResult): {string: Json.Value}
  local o: mut {string: Json.Value} = { content = content_list(r.content) }
  put(o, "structuredContent", r.structuredContent)
  put(o, "isError", r.isError)
  return o
end

--- `r` as a value.
function wire.resource(r: Mcp.Resource): Json.Value
  local o: mut {string: Json.Value} = { uri = r.uri, name = r.name }
  put(o, "title", r.title)
  put(o, "description", r.description)
  put(o, "mimeType", r.mimeType)
  put(o, "size", r.size)
  put(o, "annotations", annotations(r.annotations))
  put(o, "icons", icons(r.icons))
  return o
end

--- `t` as a value.
function wire.template(t: Mcp.ResourceTemplate): Json.Value
  local o: mut {string: Json.Value} = { uriTemplate = t.uriTemplate, name = t.name }
  put(o, "title", t.title)
  put(o, "description", t.description)
  put(o, "mimeType", t.mimeType)
  put(o, "annotations", annotations(t.annotations))
  put(o, "icons", icons(t.icons))
  return o
end

--- `p` as a value.
function wire.prompt(p: Mcp.Prompt): Json.Value
  local o: mut {string: Json.Value} = { name = p.name }
  put(o, "title", p.title)
  put(o, "description", p.description)
  if p.arguments ~= nil then
    local args: mut {Json.Value} = {}
    for _, a in ipairs(p.arguments) do
      local argument: mut {string: Json.Value} = { name = a.name }
      put(argument, "title", a.title)
      put(argument, "description", a.description)
      put(argument, "required", a.required)
      args[#args + 1] = argument
    end
    put(o, "arguments", Json.array(args))
  end
  put(o, "icons", icons(p.icons))
  return o
end

--- `r` as the fields of a result.
function wire.prompt_result(r: Mcp.PromptResult): {string: Json.Value}
  local messages: mut {Json.Value} = {}
  for _, m in ipairs(r.messages) do
    local message: {string: Json.Value} = { role = m.role, content = content(m.content) }
    messages[#messages + 1] = message
  end
  local o: mut {string: Json.Value} = { messages = Json.array(messages) }
  put(o, "description", r.description)
  return o
end

--- `values`, each made a value by `each`, as a JSON array.
function wire.list<T>(values: {T}, each: function(T): Json.Value): Json.Value
  local out: mut {Json.Value} = {}
  for i, v in ipairs(values) do out[i] = each(v) end
  return Json.array(out)
end

-- Values read back as records.

--- `what` is wrong with a server's answer: a failure of code -32603.
local function bad(what: string): Failure
  return Failure.coded("mcp: the server answered " .. what, Mcp.INTERNAL_ERROR)
end

--- Whether `result` is a final result; nil and why for one that asks
--- for more ("input_required", which this client never declared a
--- capability for) or names a kind no revision defines.
function wire.complete(result: any): (true) | (false, Failure)
  local kind, why = KIND:into(result)
  if kind == nil then return false, bad("a result that is not an object: " .. why) end
  local said = kind.resultType
  if said == nil or said == "complete" then return true end
  if said == "input_required" then
    return false, bad("that it needs input from the client, which this client does not give")
  end
  return false, bad("a result of the kind " .. Json.quote(said) .. ", which this client does not know")
end

--- The tool `value` describes, from a server, or nil and why it is not
--- one.
function wire.tool_of(value: any): (Mcp.Tool) | (nil, Failure)
  local t, why = TOOL:into(value)
  if t == nil then return nil, bad("a tool that does not fit: " .. why) end
  local input, iwhy = Json.to_object(t.inputSchema)
  if input == nil then
    return nil, bad("tool " .. Json.quote(t.name) .. " with an inputSchema that is no object: " .. tostring(iwhy))
  end
  local output: {string: Json.Value}? = nil
  if t.outputSchema ~= nil then
    local out, owhy = Json.to_object(t.outputSchema)
    if out == nil then
      return nil, bad("tool " .. Json.quote(t.name) .. " with an outputSchema that is no object: " .. tostring(owhy))
    end
    output = out
  end
  return { name = t.name, title = t.title, description = t.description, inputSchema = input, outputSchema = output,
    annotations = t.annotations, icons = t.icons }
end

--- A page of `tools/list`: its tools, not yet read, and the cursor of
--- the next.
function wire.tools(result: any): (wire.Tools) | (nil, Failure)
  local page, why = TOOLS:into(result)
  if page == nil then return nil, bad("a tool list that does not fit: " .. why) end
  return page
end

--- A tool's result, from a server.
function wire.tool_result_of(result: any): (Mcp.ToolResult) | (nil, Failure)
  local r, why = TOOL_RESULT:into(result)
  if r == nil then return nil, bad("a tool result that does not fit: " .. why) end
  local structured: Json.Value? = nil
  if r.structuredContent ~= nil then
    local v, vwhy = Json.to_value(r.structuredContent)
    if v == nil then return nil, bad("structuredContent that is not JSON: " .. tostring(vwhy)) end
    structured = v
  end
  return { content = r.content, structuredContent = structured, isError = r.isError }
end

--- How a peer names itself in `value`, nil where it does not, or not
--- as the protocol says.
function wire.implementation_of(value: any): Mcp.Implementation?
  if value == nil then return nil end
  local i, _ = INFO:into(value)
  if i == nil then return nil end
  return { name = i.name, version = i.version, title = i.title, description = i.description, websiteUrl = i.websiteUrl,
    icons = i.icons }
end

--- What `server/discover` answers, from a server.
function wire.discovery(result: any): (Mcp.Discovery) | (nil, Failure)
  local d, why = DISCOVER:into(result)
  if d == nil then return nil, bad("a discovery that does not fit: " .. why) end
  local info: Mcp.Implementation? = nil
  if d._meta ~= nil then
    local meta, _ = Json.to_object(d._meta)
    if meta ~= nil then
      info = wire.implementation_of(meta["io.modelcontextprotocol/serverInfo"])
    end
  end
  return { supportedVersions = d.supportedVersions, capabilities = d.capabilities, instructions = d.instructions,
    serverInfo = info }
end

function wire.resources(result: any): (wire.Resources) | (nil, Failure)
  local page, why = RESOURCES:into(result)
  if page == nil then return nil, bad("a resource list that does not fit: " .. why) end
  return page
end

function wire.templates(result: any): (wire.Templates) | (nil, Failure)
  local page, why = TEMPLATES:into(result)
  if page == nil then return nil, bad("a template list that does not fit: " .. why) end
  return page
end

function wire.prompts(result: any): (wire.Prompts) | (nil, Failure)
  local page, why = PROMPTS:into(result)
  if page == nil then return nil, bad("a prompt list that does not fit: " .. why) end
  return page
end

function wire.read(result: any): ({Mcp.ResourceContents}) | (nil, Failure)
  local r, why = READ:into(result)
  if r == nil then return nil, bad("resource contents that do not fit: " .. why) end
  return r.contents
end

function wire.prompt_result_of(result: any): (Mcp.PromptResult) | (nil, Failure)
  local r, why = PROMPT_RESULT:into(result)
  if r == nil then return nil, bad("a prompt that does not fit: " .. why) end
  return { description = r.description, messages = r.messages }
end

return wire

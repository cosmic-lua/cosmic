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
local String = require("cosmic.string")

local record wire
  --- Reads an event stream as it comes ([`wire.splitter`]).
  record Splitter
    --- The data of each event `chunk` completes, in order, or nil where
    --- an event is longer than a message may be.
    feed: function(chunk: string): {string}?
    --- The data of each event the stream's end completes: a CR held at
    --- the end of the last chunk, in case a LF came next, ends a line.
    finish: function(): {string}
  end

  --- What a `WWW-Authenticate: Bearer` challenge says ([`wire.challenge`]).
  record Challenge
    --- Where the server's protected resource metadata is.
    resource_metadata?: string
    --- The scopes to ask for.
    scope?: {string}
    --- Why: `invalid_token`, `insufficient_scope`.
    error?: string
  end

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

  --- The key of `_meta` that names the subscription a notice belongs to: the id of its `subscriptions/listen`.
  META_SUBSCRIPTION: string

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

  --- A result that needs input, as it arrives.
  record InputRequired
    inputRequests?: any
    requestState?: string
  end

  --- One request a server sends a client inside a result that needs input (`input_required`), for the client to
  --- answer before it asks again: `elicitation/create` here.
  record InputRequest
    method: string
    params: {string: Json.Value}
  end

  --- What a result that needs input asks: each request by its key, and the state to send back with the answers.
  record Needs
    requests: {string: InputRequest}
    state?: string
  end

  --- The params of `elicitation/create`, as they arrive.
  record ElicitParams
    mode?: string
    message: string
    requestedSchema?: any
    url?: string
  end

  --- An answer to `elicitation/create`, as it arrives.
  record ElicitResult
    action: string
    content?: any
  end

  --- What `completion/complete` completes, as it arrives: `ref/prompt` by
  --- its `name`, or `ref/resource` by its template's `uri`.
  record CompleteRef
    type: string
    name?: string
    uri?: string
  end

  record CompleteArgument
    name: string
    value: string
  end

  record CompleteContext
    arguments?: {string: string}
  end

  --- The params of `completion/complete`, as they arrive.
  record CompleteParams
    ref: CompleteRef
    argument: CompleteArgument
    context?: CompleteContext
  end

  record CompletionValues
    values: {string}
    total?: integer
    hasMore?: boolean
  end

  --- What `completion/complete` answers, as it arrives.
  record CompleteResult
    completion: CompletionValues
  end
end

--- The most requests one result that needs input may hold.
local MAX_INPUT_REQUESTS <const> = 16

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
local INPUT_REQUIRED <const>: Shape.Typed<wire.InputRequired> = Shape.record_of("wire.InputRequired")
local ELICIT_PARAMS <const>: Shape.Typed<wire.ElicitParams> = Shape.record_of("wire.ElicitParams")
local ELICIT_RESULT <const>: Shape.Typed<wire.ElicitResult> = Shape.record_of("wire.ElicitResult")
local COMPLETE_PARAMS <const>: Shape.Typed<wire.CompleteParams> = Shape.record_of("wire.CompleteParams")
local COMPLETE_RESULT <const>: Shape.Typed<wire.CompleteResult> = Shape.record_of("wire.CompleteResult")

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

--- The byte order mark a stream may start with (U+FEFF in UTF-8).
local BOM <const> = "\239\187\191"

--- The data of each whole event in `text_in`, a stream's text from an event's start.
local function events_of(text_in: string): {string}
  local out: mut {string} = {}
  local data: mut {string} = {}
  local function flush()
    if #data > 0 then
      local joined = table.concat(data, "\n")
      out[#out + 1] = joined
      data = {}
    end
  end
  -- A line ends at CRLF, LF or CR; an event, at a blank line, and one
  -- the stream ends inside is dropped, as the event stream format has it.
  local text = text_in:gsub("\r\n", "\n"):gsub("\r", "\n")
  for line in text:gmatch("([^\n]*)\n") do
    if line == "" then
      flush()
    else
      local field, value = line:match("^([^:]*):? ?(.*)$")
      if field == "data" and value ~= nil then data[#data + 1] = value end
    end
  end
  return out
end

--- The JSON-RPC messages an event stream holds, each the data of one
--- event: its `data:` lines joined by newlines.
function wire.events(body: string): {string}
  -- A byte order mark that starts the stream is not its text.
  return events_of(if body:sub(1, #BOM) == BOM then body:sub(#BOM + 1) else body end)
end

--- A reader of an event stream as it comes: each event's data once the
--- event is whole. Each chunk is looked at once, and what is held joined
--- only when an event ends, so a stream sent a byte at a time costs no
--- more than one sent whole. However the stream is cut into chunks, the
--- events are those [`wire.events`] reads of it whole.
function wire.splitter(): wire.Splitter
  -- The chunks since the last whole event, their line ends made LF, and their size.
  local parts: mut {string} = {}
  local size = 0
  -- The last byte held, so a blank line split between two chunks is found.
  local last_byte = ""
  -- A CR that ended the last chunk, which may be the first half of a CRLF.
  local cr = false
  -- The bytes the stream starts with, held until they can be told from a byte order mark; nil once they are.
  local head: string? = ""
  local function feed(given: string): {string}?
    local chunk = given
    local h = head
    if h ~= nil then
      local start = h .. given
      if #start < #BOM and BOM:sub(1, #start) == start then
        head = start
        return {}
      end
      head = nil
      chunk = if start:sub(1, #BOM) == BOM then start:sub(#BOM + 1) else start end
    end
    local c = if cr then "\r" .. chunk else chunk end
    cr = c:sub(-1) == "\r"
    if cr then c = c:sub(1, -2) end
    c = c:gsub("\r\n", "\n"):gsub("\r", "\n")
    if c == "" then return {} end
    if (last_byte .. c):find("\n\n", 1, true) == nil then
      parts[#parts + 1] = c
      size = size + #c
      last_byte = c:sub(-1)
      if size > Mcp.MAX_MESSAGE_BYTES then return nil end
      return {}
    end
    parts[#parts + 1] = c
    local text = table.concat(parts)
    local last = 0
    local at = 1
    while true do
      local found = text:find("\n\n", at, true)
      if found == nil then break end
      last = found + 1
      at = found + 1
    end
    local rest = text:sub(last + 1)
    parts = { rest }
    size = #rest
    last_byte = if rest ~= "" then rest:sub(-1) else "\n" end
    if size > Mcp.MAX_MESSAGE_BYTES then return nil end
    return events_of(text:sub(1, last))
  end
  local function finish(): {string}
    if not cr then return {} end
    cr = false
    -- The held CR ends a line. The stream is over, so nothing is held to refuse.
    return feed("\n") or {}
  end
  return { feed = feed, finish = finish }
end

--- The parameters of the `Bearer` challenge in the `WWW-Authenticate`
--- header `header`, or nil where it has none. The header is read as
--- RFC 9110 has it: challenges split by commas, each a scheme and then a
--- token68 or `name=value` parameters, a quoted value's escapes undone.
--- Only the parameters of the `Bearer` challenge are kept, so a word
--- inside another scheme's value, or another scheme's parameters, are not
--- read as its own.
function wire.challenge(header: string): wire.Challenge?
  local n = #header
  local i = 1
  -- Whether a Bearer challenge was read, and whether the parameters now read are its own.
  local found, mine = false, false
  -- Whether a scheme was just read, with no comma since: a lone token then is its token68.
  local fresh = false
  local params: mut {string: string} = {}
  local function skip(set: string)
    while i <= n and header:sub(i, i):find(set) ~= nil do i = i + 1 end
  end
  -- The quoted string at `i`, its escapes undone; one the header ends inside ends with it.
  local function quoted(): string
    local out: mut {string} = {}
    i = i + 1
    while i <= n do
      local c = header:sub(i, i)
      if c == "\\" then
        out[#out + 1] = header:sub(i + 1, i + 1)
        i = i + 2
      elseif c == '"' then
        i = i + 1
        break
      else
        out[#out + 1] = c
        i = i + 1
      end
    end
    return table.concat(out)
  end
  while i <= n do
    local before = i
    skip("[ \t]")
    if header:sub(i, i) == "," then
      fresh = false
      i = i + 1
      skip("[ \t,]")
    end
    local s, e = header:find("^[!#$%%&'*+%-.^_`|~%w]+", i)
    if s == nil or e == nil then
      -- Neither a token nor a comma: a byte no challenge holds, or a quoted string where no parameter stands,
      -- passed over whole, so no word inside it is read as a scheme.
      if i == before then
        if header:sub(i, i) == '"' then
          local _ = quoted()
        else
          i = i + 1
        end
        fresh = false
      end
    else
      local token = header:sub(s, e)
      i = e + 1
      skip("[ \t]")
      local eq = header:sub(i, i) == "="
      -- `name=value`, not the trailing `=`s of a token68 (`abc==`, `abc=` at a comma or the end).
      local param = false
      if eq then
        local after = header:find("[^ \t]", i + 1)
        param = after ~= nil and header:sub(after, after) ~= "," and header:sub(after, after) ~= "="
      end
      if param then
        i = i + 1
        skip("[ \t]")
        local value: string
        if header:sub(i, i) == '"' then
          value = quoted()
        else
          local v = header:match("^[^%s,]*", i) or ""
          i = i + #v
          value = v
        end
        local key = token:lower()
        if mine and params[key] == nil then params[key] = value end
        fresh = false
      elseif fresh then
        -- The token68 of the scheme just read, read again from its start: it may hold a `/`, which a token does
        -- not, and end in `=`s that pad it.
        local _, last = header:find("^[%w%-._~+/]+=*", s)
        if last ~= nil and last + 1 > i then i = last + 1 end
        fresh = false
      else
        mine = token:lower() == "bearer" and not found
        if mine then found = true end
        fresh = true
      end
    end
  end
  if not found then return nil end
  local scope: {string}? = nil
  local said = params["scope"]
  if said ~= nil then
    local list: mut {string} = {}
    for each in said:gmatch("%S+") do list[#list + 1] = each end
    scope = list
  end
  return { resource_metadata = params["resource_metadata"], scope = scope, error = params["error"] }
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

--- A notification of `method` with `params`, as a line's text.
function wire.notification(method: string, params: Json.Value): string
  return '{"jsonrpc":"2.0","method":' .. Json.quote(method) .. ',"params":' .. assert(Json.encode(params)) .. "}"
end

--- The params of `notifications/progress`.
local record ProgressParams
  progressToken: any
  progress: number
  total?: number
  message?: string
end

local PROGRESS_PARAMS <const>: Shape.Typed<ProgressParams> = Shape.record_of("ProgressParams")

--- `token`, a request's id or a progress token, encoded as JSON (`1`, `"a"`), as [`wire.Message.id`] is: nil where it
--- is neither a string nor an integer.
local function encoded_id(token: any): string?
  if token is string then return Json.quote(token) end
  if math.type(token) == "integer" then return tostring(token) end
  return nil
end

--- The progress `params` says, and its token encoded as JSON (`1`, `"a"`), or nil where they are not progress's.
function wire.progress_of(params: any): (Mcp.Progress, string) | (nil)
  local p, _ = PROGRESS_PARAMS:into(params)
  if p == nil then return nil end
  local encoded = encoded_id(p.progressToken)
  if encoded == nil then return nil end
  return { progress = p.progress, total = p.total, message = p.message }, encoded
end

wire.META_SUBSCRIPTION = "io.modelcontextprotocol/subscriptionId"

--- The id of the subscription a notice's `params` names in its `_meta`, encoded as JSON as [`wire.Message.id`] is,
--- or nil where it names none.
function wire.subscription_id(params: any): string?
  local p, _ = Json.to_object(params)
  if p == nil then return nil end
  local meta = Json.object_of(p["_meta"])
  if meta == nil then return nil end
  return encoded_id(meta[wire.META_SUBSCRIPTION])
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

--- Whether `result` is one that needs input from the client first (`input_required`).
function wire.needs_input(result: any): boolean
  local kind, _ = KIND:into(result)
  return kind ~= nil and kind.resultType == "input_required"
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

--- What the result that needs input, `result`, asks, or nil and why it does not fit: at least one of its requests or
--- its state, and no more than 16 requests.
function wire.needs_of(result: any): (wire.Needs) | (nil, Failure)
  local r, why = INPUT_REQUIRED:into(result)
  if r == nil then return nil, bad("a result that needs input that does not fit: " .. why) end
  local requests: mut {string: wire.InputRequest} = {}
  local count = 0
  if r.inputRequests ~= nil then
    local all, awhy = Json.to_object(r.inputRequests)
    if all == nil or Json.is_array(r.inputRequests) then
      return nil, bad("inputRequests that are not an object" .. (if all == nil then ": " .. tostring(awhy) else "" end))
    end
    for key, value in pairs(all) do
      count = count + 1
      if count > MAX_INPUT_REQUESTS then
        return nil, bad("more than " .. tostring(MAX_INPUT_REQUESTS) .. " inputRequests")
      end
      local o = Json.object_of(value)
      local method = if o ~= nil then o["method"] else nil end
      local params = if o ~= nil then Json.object_of(o["params"]) else nil end
      if not method is string or params == nil then
        return nil, bad("the input request " .. Json.quote(key) .. " with no method or params")
      end
      requests[key] = { method = method, params = params }
    end
  end
  if count == 0 and r.requestState == nil then
    return nil, bad("a result that needs input with neither inputRequests nor requestState")
  end
  return { requests = requests, state = r.requestState }
end

--- The elicitation the params of `elicitation/create` ask for, or nil and why they do not fit.
function wire.elicitation_of(params: {string: Json.Value}): (Mcp.Elicitation) | (nil, Failure)
  local p, why = ELICIT_PARAMS:into(params)
  if p == nil then return nil, bad("elicitation/create params that do not fit: " .. why) end
  local mode = p.mode or "form"
  if mode == "form" then
    local schema, _ = Json.to_object(p.requestedSchema)
    if schema == nil or p.requestedSchema == nil then
      return nil, bad("an elicitation/create form with no requestedSchema object")
    end
    return { mode = "form", message = p.message, requestedSchema = schema }
  end
  if mode == "url" then
    local url = p.url
    if url == nil or url:find("^https?://[^%s]+$") == nil then
      return nil, bad("an elicitation/create url that is not http or https")
    end
    return { mode = "url", message = p.message, url = url }
  end
  return nil, bad("an elicitation/create of the mode " .. Json.quote(mode) .. ", which this client does not know")
end

--- `e` as the request `elicitation/create`.
function wire.elicitation(e: Mcp.Elicitation): wire.InputRequest
  local params: mut {string: Json.Value} = { mode = e.mode, message = e.message }
  local schema, url = e.requestedSchema, e.url
  if schema ~= nil then params["requestedSchema"] = schema end
  if url ~= nil then params["url"] = url end
  return { method = "elicitation/create", params = params }
end

--- `e` as the result of `elicitation/create`.
function wire.elicited(e: Mcp.Elicited): Json.Value
  local out: mut {string: Json.Value} = { action = e.action }
  local given = e.content
  if given ~= nil and e.action == "accept" then out["content"] = given end
  return out
end

local ACTIONS <const>: {string: Mcp.ElicitAction} = { accept = "accept", decline = "decline", cancel = "cancel" }

--- The answer to an elicitation `value` holds, from a client, or nil and why it does not fit.
function wire.elicited_of(value: any): (Mcp.Elicited) | (nil, Failure)
  local r, why = ELICIT_RESULT:into(value)
  if r == nil then return nil, Failure.new("an elicitation answer that does not fit: " .. why) end
  local action = ACTIONS[r.action]
  if action == nil then
    return nil, Failure.new("an elicitation answer of the action " .. Json.quote(r.action))
  end
  if r.content == nil then return { action = action } end
  local fields, cwhy = Json.to_object(r.content)
  if fields == nil or Json.is_array(r.content) then
    return nil, Failure.new("an elicitation answer whose content is not an object" .. (if fields == nil then ": " .. tostring(cwhy) else "" end))
  end
  return { action = action, content = fields }
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

--- The names of the variables of the RFC 6570 URI template `template`,
--- each once, in the order they first appear: `{owner}`, `{+path}`,
--- `{?q,page}` and `{list*}` give `owner`, `path`, `q`, `page`, `list`.
function wire.template_variables(template: string): {string}
  local out: mut {string} = {}
  local seen: mut {string: boolean} = {}
  for expression in template:gmatch("{([^}]*)}") do
    local list = expression:gsub("^[+#./;?&=,!@|]", "")
    for spec in list:gmatch("[^,]+") do
      local name = spec:gsub(":%d*$", ""):gsub("%*$", "")
      if name ~= "" and seen[name] == nil then
        seen[name] = true
        out[#out + 1] = name
      end
    end
  end
  return out
end

--- The params of `completion/complete` asking `c`, or why it cannot be
--- asked: it names both of a prompt and a template, or neither.
function wire.completing(c: Mcp.Completing): ({string: Json.Value}) | (nil, Failure)
  local prompt, template = c.prompt, c.template
  local ref: {string: Json.Value}
  if prompt ~= nil and template == nil then
    ref = { type = "ref/prompt", name = prompt }
  elseif template ~= nil and prompt == nil then
    ref = { type = "ref/resource", uri = template }
  else
    return nil, Failure.new("mcp: complete: name exactly one of a prompt and a template")
  end
  local params: mut {string: Json.Value} = { ref = ref, argument = { name = c.argument, value = c.value } }
  local context = c.context
  if context ~= nil then
    local arguments: mut {string: Json.Value} = {}
    for k, v in pairs(context) do arguments[k] = v end
    params["context"] = { arguments = arguments }
  end
  return params
end

--- What the params `params` of `completion/complete` ask, or why they
--- do not fit: words for an invalid params refusal.
function wire.completing_of(params: any): (Mcp.Completing) | (nil, string)
  local p, why = COMPLETE_PARAMS:into(params)
  if p == nil then return nil, "completion/complete: " .. why end
  local ref = p.ref
  local context = if p.context ~= nil then assert(p.context).arguments else nil end
  local prompt, template: string?, string? = nil, nil
  if ref.type == "ref/prompt" then
    prompt = ref.name
    if prompt == nil then return nil, "completion/complete: a ref/prompt names no prompt" end
  elseif ref.type == "ref/resource" then
    template = ref.uri
    if template == nil then return nil, "completion/complete: a ref/resource names no uri" end
  else
    return nil, "completion/complete: a ref of no known type: " .. Json.quote(ref.type)
  end
  return { prompt = prompt, template = template, argument = p.argument.name, value = p.argument.value, context = context }
end

--- The fields of the result answering `c`: at most
--- [`Mcp.MAX_COMPLETIONS`] values, and `hasMore` where it held more.
function wire.completion(c: Mcp.Completion): {string: Json.Value}
  local values: mut {string} = {}
  for i = 1, math.min(#c.values, Mcp.MAX_COMPLETIONS) do values[i] = assert(c.values[i]) end
  local fields: mut {string: Json.Value} = { values = wire.strings(values) }
  -- A total is never below the values given, nor below 0; one left out is known where the values are cut.
  local total = c.total
  local cut = #c.values > Mcp.MAX_COMPLETIONS
  if total ~= nil and total >= 0 then
    fields["total"] = math.max(total, #c.values)
  elseif cut then
    fields["total"] = #c.values
  end
  if c.has_more == true or cut then fields["hasMore"] = true end
  return { completion = fields }
end

--- The completion a server answered, or why it does not fit.
function wire.completion_of(result: any): (Mcp.Completion) | (nil, Failure)
  local r, why = COMPLETE_RESULT:into(result)
  if r == nil then return nil, bad("a completion that does not fit: " .. why) end
  local c = r.completion
  if #c.values > Mcp.MAX_COMPLETIONS then
    return nil, bad("more than " .. String.counted(Mcp.MAX_COMPLETIONS, "completion"))
  end
  local total = c.total
  if total ~= nil and total < 0 then return nil, bad("a completion total below 0") end
  return { values = c.values, total = total, has_more = c.hasMore }
end

return wire

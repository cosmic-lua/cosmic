--- The Model Context Protocol, revision 2026-07-28: the types its
--- messages carry, its error codes, and the rules both ends share.
--- [`cosmic.mcp.server`] answers it and [`cosmic.mcp.client`] asks it,
--- each over stdio (one JSON-RPC message a line) or Streamable HTTP (one
--- POST a message).
---
--- This revision is stateless: there is no `initialize` and no
--- session. Every request names its protocol version and the client's
--- capabilities in its `_meta`, and a server answers each one on its
--- own. A peer that speaks only an earlier revision (2025-11-25 or
--- before) cannot talk to these: the server refuses its `initialize`
--- naming the version it speaks, and the client fails on such a server
--- with the reply it got.
---
--- The records here use the protocol's own field names (`inputSchema`,
--- `mimeType`, `isError`), so a field reads as the specification
--- writes it. A JSON value of no fixed shape -- a tool's schemas, its
--- structured result -- is a [`Json.Value`].
---
---     local tool: Mcp.Tool = {
---       name = "add",
---       description = "Adds two integers.",
---       inputSchema = Mcp.object_schema({ a = { type = "integer" }, b = { type = "integer" } }, { "a", "b" }),
---     }
---     local said = Mcp.text("3")
---     assert(said.type == "text" and said.text == "3")
--- @public

local Codec = require("cosmic.codec")
local Failure = require("cosmic.failure")
local Json = require("cosmic.json")
local String = require("cosmic.string")

local record Mcp
  --- Who a message is from in a prompt, or who content is for.
  enum Role
    "user"
    "assistant"
  end

  --- Hints about content, for the client to weigh; the protocol checks
  --- none of them.
  record Annotations
    --- Who the content is meant for.
    audience?: {Role}
    --- How much it matters, from 0 (least) to 1 (most).
    priority?: number
    --- When it last changed, as ISO 8601 writes a time.
    lastModified?: string
  end

  --- A picture that stands for a tool, a prompt, a resource or a peer.
  --- The protocol trusts none: a client that shows one fetches it as
  --- untrusted input, over HTTPS or from a `data:` URI only.
  record Icon
    --- An `https:` or `data:` URI.
    src: string
    --- Its media type, where `src` does not say it.
    mimeType?: string
    --- Sizes such as "48x48", or "any" for a picture that scales.
    sizes?: {string}
    --- "light" or "dark": the background the icon is drawn for.
    theme?: string
  end

  --- A client or a server, as it names itself. Nothing verifies it: it
  --- is for showing and logging, never for deciding what to allow.
  record Implementation
    --- Its name, for programs: "cosmic".
    name: string
    --- Its version, as it writes it.
    version: string
    --- Its name for people, where it differs from `name`.
    title?: string
    --- What it is, in a sentence.
    description?: string
    --- Where to read about it.
    websiteUrl?: string
    --- Pictures that stand for it.
    icons?: {Icon}
  end

  --- What one resource holds: `text`, or `blob` (the bytes in base64).
  record ResourceContents
    --- The URI of the resource read.
    uri: string
    --- Its media type, where known.
    mimeType?: string
    --- What it holds as text, for a resource that is text.
    text?: string
    --- What it holds as bytes, in base64, for one that is not text.
    blob?: string
  end

  --- What kind of [`Mcp.Content`] a block is.
  enum ContentType
    "text"
    "image"
    "audio"
    "resource_link"
    "resource"
  end

  --- One block of content in a tool's result or a prompt's message. Its
  --- `type` says which fields it has: "text" `text`; "image" and
  --- "audio" `data` (base64) and `mimeType`; "resource_link" `uri` and
  --- `name`, and the rest of a [`Mcp.Resource`]; "resource" a
  --- `resource`, embedded. [`Mcp.text`] and the others build one.
  record Content
    --- Which kind of block it is, which says the fields it has.
    type: ContentType
    --- The text of a "text" block.
    text?: string
    --- The bytes, in base64, of an "image" or "audio" block.
    data?: string
    --- The media type of an "image" or "audio" block, or of a linked resource.
    mimeType?: string
    --- The URI of the resource a "resource_link" names.
    uri?: string
    --- The name of the resource a "resource_link" names.
    name?: string
    --- The linked resource's name for people.
    title?: string
    --- What the linked resource is.
    description?: string
    --- The linked resource's size in bytes, where known.
    size?: integer
    --- The contents a "resource" block embeds.
    resource?: ResourceContents
    --- Hints about the block, for the client to weigh.
    annotations?: Annotations
  end

  --- What a tool says of its own behaviour. A client trusts none of it
  --- from a server it does not trust.
  record ToolAnnotations
    --- The tool's name for people.
    title?: string
    --- That the tool changes nothing.
    readOnlyHint?: boolean
    --- That what it changes it may destroy (where not read-only).
    destructiveHint?: boolean
    --- That calling it again with the same arguments changes nothing more.
    idempotentHint?: boolean
    --- That it reaches what lies outside the server (the web, say).
    openWorldHint?: boolean
  end

  --- A tool a server offers: a name the model calls it by, and the JSON
  --- Schema of its arguments ([`Mcp.object_schema`] writes a simple
  --- one).
  record Tool
    --- 1 to 128 of `A-Z a-z 0-9 _ - .`, unique on its server.
    name: string
    --- Its name for people.
    title?: string
    --- What it does, for the model to read.
    description?: string
    --- A JSON Schema of `"type": "object"`. A property's own schema may
    --- name `"x-mcp-header"`, which mirrors its value into an HTTP
    --- header ([`Mcp.mirrors`]).
    inputSchema: {string: Json.Value}
    --- The JSON Schema `structuredContent` holds to, where the tool
    --- answers one.
    outputSchema?: {string: Json.Value}
    --- What the tool says of its behaviour; trust none of it from a server you do not trust.
    annotations?: ToolAnnotations
    --- Pictures that stand for it.
    icons?: {Icon}
  end

  --- What a call of a tool answers. A tool that ran and failed says so
  --- here, `isError` true, for the model to read; a call the server
  --- could not make at all fails as the request.
  record ToolResult
    --- What the tool answered, block by block.
    content: {Content}
    --- The answer as a JSON value, held to the tool's `outputSchema` where it has one.
    structuredContent?: Json.Value
    --- True for a tool that ran and failed; `content` says why.
    isError?: boolean
  end

  --- How far a request has come, as a server tells a client that asked
  --- (`notifications/progress`).
  record Progress
    --- How much is done: more with each notice, whether or not `total` is known.
    progress: number
    --- How much there is to do, where the server knows.
    total?: number
    --- What is happening, for a person to read.
    message?: string
  end

  --- A resource a server offers to be read by its URI.
  record Resource
    --- The URI it is read by.
    uri: string
    --- Its name, for programs.
    name: string
    --- Its name for people.
    title?: string
    --- What it holds.
    description?: string
    --- Its media type, where known.
    mimeType?: string
    --- Its size in bytes, where known.
    size?: integer
    --- Hints about it, for the client to weigh.
    annotations?: Annotations
    --- Pictures that stand for it.
    icons?: {Icon}
  end

  --- A family of resources, by an RFC 6570 URI template.
  record ResourceTemplate
    --- The RFC 6570 template its resources' URIs fit.
    uriTemplate: string
    --- Its name, for programs.
    name: string
    --- Its name for people.
    title?: string
    --- What its resources hold.
    description?: string
    --- The media type of its resources, where they share one.
    mimeType?: string
    --- Hints about its resources, for the client to weigh.
    annotations?: Annotations
    --- Pictures that stand for it.
    icons?: {Icon}
  end

  --- One argument a prompt takes; every argument is a string.
  record PromptArgument
    --- Its name, the key of `prompts/get`'s arguments.
    name: string
    --- Its name for people.
    title?: string
    --- What it is for.
    description?: string
    --- Whether a get without it is refused.
    required?: boolean
  end

  --- A prompt a server offers: a template of messages filled in from
  --- its arguments.
  record Prompt
    --- Its name, which `prompts/get` asks for.
    name: string
    --- Its name for people.
    title?: string
    --- What it is for.
    description?: string
    --- The arguments it takes.
    arguments?: {PromptArgument}
    --- Pictures that stand for it.
    icons?: {Icon}
  end

  --- One message of a prompt.
  record PromptMessage
    --- Who the message is from.
    role: Role
    --- What it says.
    content: Content
  end

  --- What getting a prompt answers.
  record PromptResult
    --- What the prompt is for.
    description?: string
    --- The messages it fills in, in order.
    messages: {PromptMessage}
  end

  --- Whether a feature's list can change while the server runs.
  record ListChanged
    --- True where the server tells a subscriber the list changed.
    listChanged?: boolean
  end

  --- Whether the list of resources can change while the server runs, and whether a client may subscribe to one.
  record ResourcesCapability
    --- True where the server tells a subscriber the list changed.
    listChanged?: boolean
    --- True where it tells a subscriber that a resource it names changed.
    subscribe?: boolean
  end

  --- What a server can do, as `server/discover` answers it: a feature it
  --- has is present, and one it lacks is nil.
  record ServerCapabilities
    --- Present where the server offers tools.
    tools?: ListChanged
    --- Present where it offers resources.
    resources?: ResourcesCapability
    --- Present where it offers prompts.
    prompts?: ListChanged
  end

  --- What `server/discover` answers: the versions the server speaks,
  --- what it can do, and how it names itself.
  record Discovery
    --- The protocol revisions it speaks.
    supportedVersions: {string}
    --- What it can do.
    capabilities: ServerCapabilities
    --- Words for the model on how to use it.
    instructions?: string
    --- How the server names itself, nil where it does not.
    serverInfo?: Implementation
  end

  --- A tool argument mirrored into an HTTP header: `Mcp-Param-<header>`
  --- holds the value found at `path`, a chain of `properties` keys from
  --- the schema's root.
  record Mirror
    --- The name after `Mcp-Param-`.
    header: string
    --- The `properties` keys from the schema's root to the argument.
    path: {string}
  end

  --- The protocol revision these modules speak, the one they name on
  --- each request and accept on each request: "2026-07-28".
  VERSION: string

  --- JSON-RPC's code for a message that is not JSON.
  PARSE_ERROR: integer
  --- JSON-RPC's code for JSON that is not a valid request.
  INVALID_REQUEST: integer
  --- JSON-RPC's code for a method the server does not offer.
  METHOD_NOT_FOUND: integer
  --- JSON-RPC's code for parameters the method refuses.
  INVALID_PARAMS: integer
  --- JSON-RPC's code for a failure inside the server.
  INTERNAL_ERROR: integer
  --- An HTTP header disagrees with the body it came with, or one the
  --- request needs is missing.
  HEADER_MISMATCH: integer
  --- The request needs a capability the client did not declare.
  MISSING_CAPABILITY: integer
  --- The server does not speak the version the request names.
  UNSUPPORTED_VERSION: integer

  --- The most bytes of one message either end reads (4 MiB): a peer
  --- that sends more is refused, not buffered.
  MAX_MESSAGE_BYTES: integer
end

Mcp.VERSION = "2026-07-28"
Mcp.PARSE_ERROR = -32700
Mcp.INVALID_REQUEST = -32600
Mcp.METHOD_NOT_FOUND = -32601
Mcp.INVALID_PARAMS = -32602
Mcp.INTERNAL_ERROR = -32603
Mcp.HEADER_MISMATCH = -32020
Mcp.MISSING_CAPABILITY = -32021
Mcp.UNSUPPORTED_VERSION = -32022
Mcp.MAX_MESSAGE_BYTES = 4 * 1024 * 1024

--- A block of text.
function Mcp.text(text: string): Mcp.Content
  return { type = "text", text = text }
end

--- A picture, its bytes as they are (they are sent in base64), of the
--- type `mime_type`: "image/png".
function Mcp.image(bytes: string, mime_type: string): Mcp.Content
  return { type = "image", data = Codec.base64(bytes), mimeType = mime_type }
end

--- A sound, its bytes as they are, of the type `mime_type`: "audio/wav".
function Mcp.audio(bytes: string, mime_type: string): Mcp.Content
  return { type = "audio", data = Codec.base64(bytes), mimeType = mime_type }
end

--- A link to the resource `resource`, for the client to read or not.
function Mcp.link(resource: Mcp.Resource): Mcp.Content
  return { type = "resource_link", uri = resource.uri, name = resource.name, title = resource.title,
    description = resource.description, mimeType = resource.mimeType, size = resource.size,
    annotations = resource.annotations }
end

--- A resource's contents, embedded in a result.
function Mcp.embedded(contents: Mcp.ResourceContents): Mcp.Content
  return { type = "resource", resource = contents }
end

--- A tool's result of `content`: text blocks for strings, the rest as
--- given; with `failed`, a tool that ran and failed.
function Mcp.result(content: {string | Mcp.Content}, failed?: boolean): Mcp.ToolResult
  local blocks: mut {Mcp.Content} = {}
  for _, item in ipairs(content) do
    local block = if item is string then Mcp.text(item) else item end
    blocks[#blocks + 1] = block
  end
  return { content = blocks, isError = if failed == true then true else nil end }
end

--- A tool's result of `value`, as its `structuredContent` and as one
--- text block of its JSON, which a client that reads only the content
--- reads too; `text`, where given, is that block instead. Raises for a
--- value JSON cannot say.
function Mcp.structured(value: {string: Json.Value}, text?: string): Mcp.ToolResult
  local shown = text
  if shown == nil then
    local encoded, why = Json.encode(value)
    if encoded == nil then error("mcp: structuredContent: " .. tostring(why), 2) end
    shown = encoded
  end
  return { content = { Mcp.text(shown) }, structuredContent = value }
end

--- The JSON Schema of an object whose properties are `properties` and
--- of which `required` must be present; no other property is taken.
function Mcp.object_schema(properties: {string: Json.Value}, required?: {string}): {string: Json.Value}
  local schema: mut {string: Json.Value} = {
    type = "object",
    properties = properties,
    additionalProperties = false,
  }
  if required ~= nil and #required > 0 then
    local names: mut {Json.Value} = {}
    for _, name in ipairs(required) do names[#names + 1] = name end
    schema["required"] = Json.array(names)
  end
  return schema
end

-- Header values: what is safe as it is, and the base64 sentinel that
-- carries the rest.

local SENTINEL_OPEN <const> = "=?base64?"
local SENTINEL_CLOSE <const> = "?="

--- Whether `text` can be a header's value as it is: visible ASCII,
--- spaces and tabs inside it, none at either end, and not the sentinel's
--- own shape.
local function plain(text: string): boolean
  if text:find("[^\t\32-\126]") ~= nil then return false end
  if text:find("^[ \t]") ~= nil or text:find("[ \t]$") ~= nil then return false end
  if text:sub(1, #SENTINEL_OPEN) == SENTINEL_OPEN and text:sub(-#SENTINEL_CLOSE) == SENTINEL_CLOSE then
    return false
  end
  return true
end

--- `text` as an HTTP header's value: as it is where it is safe, else its
--- bytes in base64 between `=?base64?` and `?=`, as Streamable HTTP
--- carries a name or a tool argument a header cannot hold.
function Mcp.header_text(text: string): string
  if plain(text) then return text end
  return SENTINEL_OPEN .. Codec.base64(text) .. SENTINEL_CLOSE
end

--- What the header value `value` carries, [`Mcp.header_text`] undone, or
--- nil where it holds a byte no header may, or a sentinel that is not
--- base64.
function Mcp.header_read(value: string): string?
  if value:find("[^\t\32-\126]") ~= nil then return nil end
  if value:sub(1, #SENTINEL_OPEN) == SENTINEL_OPEN and #value >= #SENTINEL_OPEN + #SENTINEL_CLOSE and
      value:sub(-#SENTINEL_CLOSE) == SENTINEL_CLOSE then
    local inner = value:sub(#SENTINEL_OPEN + 1, #value - #SENTINEL_CLOSE)
    local bytes, _ = Codec.unbase64(inner)
    return bytes
  end
  return value
end

-- `x-mcp-header`: which tool arguments go into headers, and whether a
-- schema names them as the transport allows.

--- The most levels of a schema [`Mcp.mirrors`] walks: a deeper one is
--- refused, not walked.
local SCHEMA_DEPTH <const> = 32

--- The largest integer a mirrored argument may hold: 2^53 - 1.
local SAFE_INTEGER <const> = 9007199254740991

--- Keywords whose values are data, not schemas: a key there named
--- `x-mcp-header` is an instance's, not an annotation.
local DATA_KEYWORDS <const>: {string: boolean} = {
  const = true, default = true, enum = true, examples = true,
}

--- What a walk of a schema has found.
local record Walk
  mirrors: mut {Mcp.Mirror}
  --- Each header's name, lowercased, to refuse a second.
  seen: mut {string: boolean}
end

--- The walk of a schema, its functions calling each other.
local record Schema
end

--- `path` with `step` after it, a copy.
local function extended(path: {string}, step: string): {string}
  local below: mut {string} = {}
  for i, s in ipairs(path) do below[i] = s end
  below[#below + 1] = step
  return below
end

--- Walks each element of `list`, an array of a schema, none reachable.
function Schema.items(list: {Json.Value}, path: {string}, depth: integer, w: Walk): Failure?
  for _, item in ipairs(list) do
    local why = Schema.walk(item, false, path, depth + 1, w)
    if why ~= nil then return why end
  end
  return nil
end

--- Walks `object`'s `properties`, each reachable where `object` is.
function Schema.properties(props: {string: Json.Value}, reachable: boolean, path: {string}, depth: integer,
                           w: Walk): Failure?
  local names: mut {string} = {}
  for name in pairs(props) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local schema = props[name]
    if schema ~= nil then
      local why = Schema.walk(schema, reachable, extended(path, name), depth + 1, w)
      if why ~= nil then return why end
    end
  end
  return nil
end

--- Walks the schema `node`, at `path` (reached by `properties` alone
--- where `reachable`), noting each `x-mcp-header` in `w`.
function Schema.walk(node: Json.Value, reachable: boolean, path: {string}, depth: integer, w: Walk): Failure?
  if depth > SCHEMA_DEPTH then
    return Failure.new("a schema nested past " .. String.counted(SCHEMA_DEPTH, "level"))
  end
  if node is string or node is number or node is boolean or rawequal(node, Json.null) then
    return nil
  end
  if Json.is_array(node) then
    local list, _ = Json.to_array(node)
    if list == nil then return nil end
    return Schema.items(list, path, depth, w)
  end
  local object, _ = Json.to_object(node)
  if object == nil then return nil end
  local header = object["x-mcp-header"]
  if header ~= nil then
    local at = if #path > 0 then table.concat(path, ".") else "the root" end
    if not reachable or #path == 0 then
      return Failure.new("x-mcp-header at " .. at .. ", which is not reached by properties alone")
    end
    if not header is string or header == "" or header:find("^[!#$%%&'*+%-.^_`|~%w]+$") == nil then
      return Failure.new("x-mcp-header at " .. at .. " is not an HTTP header name")
    end
    local lower = header:lower()
    if w.seen[lower] == true then
      return Failure.new("x-mcp-header " .. header .. " is named twice")
    end
    local kind = object["type"]
    if not (kind == "string" or kind == "integer" or kind == "boolean") then
      return Failure.new("x-mcp-header at " .. at .. " is on a property that is not a string, an integer or a boolean")
    end
    w.seen[lower] = true
    local mirror: Mcp.Mirror = { header = header, path = path }
    w.mirrors[#w.mirrors + 1] = mirror
  end
  local keys: mut {string} = {}
  for key in pairs(object) do keys[#keys + 1] = key end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local value = object[key]
    local props: {string: Json.Value}? = nil
    if key == "properties" and not Json.is_array(value) then
      local got, _ = Json.to_object(value)
      props = got
    end
    if props ~= nil then
      local why = Schema.properties(props, reachable, path, depth, w)
      if why ~= nil then return why end
    elseif DATA_KEYWORDS[key] == nil and value ~= nil then
      local why = Schema.walk(value, false, path, depth + 1, w)
      if why ~= nil then return why end
    end
  end
  return nil
end

--- The arguments of a tool whose input schema is `schema` that go into
--- HTTP headers, in the order of their paths, or nil and why the schema
--- names one as the transport refuses: on a property that is not a
--- string, an integer or a boolean, under anything but `properties`,
--- twice, or as a name no header can have. A client drops a tool so
--- refused; a server refuses to offer it.
function Mcp.mirrors(schema: {string: Json.Value}): ({Mcp.Mirror}) | (nil, Failure)
  local w: Walk = { mirrors = {}, seen = {} }
  local why = Schema.walk(schema, true, {}, 1, w)
  if why ~= nil then return nil, Failure.new("mcp: " .. why.message) end
  return w.mirrors
end

--- The value at `path` of `arguments`, as a mirrored header carries it
--- before [`Mcp.header_text`]: a string as it is, an integer in
--- decimal, a boolean as "true" or "false". False where nothing (or
--- null) is there, and the header is left out; nil and why where what is there is not
--- one of the three, or an integer past 2^53 - 1 either way.
function Mcp.mirror_value(arguments: {string: Json.Value}, path: {string}): (string | false) | (nil, Failure)
  local node: Json.Value = arguments
  for _, step in ipairs(path) do
    if Json.is_array(node) then return false end
    local object, _ = Json.to_object(node)
    if object == nil then return false end
    local found = object[step]
    if found == nil or rawequal(found, Json.null) then return false end
    node = found
  end
  if node is string then return node end
  if node is boolean then return if node then "true" else "false" end end
  if math.type(node) == "integer" then
    local n = math.tointeger(node) or 0
    if n > SAFE_INTEGER or n < -SAFE_INTEGER then
      return nil, Failure.new("mcp: " .. table.concat(path, ".") .. " is past the integers a header carries")
    end
    return tostring(n)
  end
  return nil, Failure.new("mcp: " .. table.concat(path, ".") .. " is not a string, an integer or a boolean")
end

return Mcp

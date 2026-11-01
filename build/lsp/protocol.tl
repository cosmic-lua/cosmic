--- The Language Server Protocol as `cosmic lsp` ([`build.lsp`]) speaks it:
--- the base layer's framing (a `Content-Length` header, then a JSON-RPC
--- 2.0 body) and the shapes of the messages it reads and writes. A
--- position in a text is [`build.lsp.lines`]'s.

local Json = require("cosmic.json")
local Shape = require("cosmic.shape")
local Stream = require("cosmic.stream")
local Url = require("cosmic.url")
local plural = require("build.plural")

local record protocol
  --- A reader of framed messages.
  record Frames
    --- The next message's body: nil and "" at the end between messages,
    --- nil and why for a stream that ends inside one or holds a header
    --- the protocol does not.
    next: function(Frames): string?, string
    --- The next message's body when the bytes read already hold all of
    --- it, without reading; nil otherwise, with nothing taken.
    buffered: function(Frames): string?
    --- Whether bytes of another message are read already, or have
    --- arrived to be read: the stream's `poll` is asked, without waiting.
    waiting: function(Frames): boolean
  end

  --- What has arrived of a stream, read without waiting: nil and "" when
  --- nothing has, nil and why where the stream broke.
  type Poll = function(): string?, string

  -- What the server reads of the messages it is sent, each checked by its
  -- shape before it is read.

  --- A message's envelope: `id` and `params` are read by what the method
  --- says they are.
  record Message
    method: string?
    id: any
    params: any
  end

  record Position
    line: integer
    character: integer
  end

  record DocumentIdentifier
    uri: string
    text: string?
  end

  record ContentChange
    text: string
  end

  --- The params of every `textDocument/` method read.
  record DocumentParams
    textDocument: DocumentIdentifier
    position: Position?
    contentChanges: {ContentChange}?
  end

  record WorkspaceFolder
    uri: string
  end

  record General
    positionEncodings: {string}?
  end

  record DynamicRegistration
    dynamicRegistration: boolean?
  end

  record WorkspaceCapabilities
    didChangeWatchedFiles: DynamicRegistration?
  end

  record ClientCapabilities
    general: General?
    workspace: WorkspaceCapabilities?
  end

  record InitializeParams
    rootUri: string?
    rootPath: string?
    workspaceFolders: {WorkspaceFolder}?
    capabilities: ClientCapabilities?
  end

  -- What the server sends, encoded as it is.

  record SaveOptions
    includeText: boolean
  end

  record SyncOptions
    openClose: boolean
    change: integer
    save: SaveOptions
  end

  record CompletionOptions
    triggerCharacters: {string}
  end

  record ServerCapabilities
    positionEncoding: string
    textDocumentSync: SyncOptions
    hoverProvider: boolean
    definitionProvider: boolean
    completionProvider: CompletionOptions
    documentFormattingProvider?: boolean
  end

  record ServerInfo
    name: string
  end

  record InitializeResult
    capabilities: ServerCapabilities
    serverInfo: ServerInfo
  end

  --- A range: its `start` and its `end`, a name no record field can have.
  type Range = {string: Position}

  record Diagnostic
    range: Range
    severity: integer
    source: string
    message: string
    code: string?
  end

  record MarkupContent
    kind: string
    value: string
  end

  record Hover
    contents: MarkupContent
  end

  --- A place in a document: where a definition is.
  record Location
    uri: string
    range: Range
  end

  record TextEdit
    range: Range
    newText: string
  end

  --- One completion: `kind` is the protocol's CompletionItemKind, and `textEdit` replaces the text typed of the name.
  record CompletionItem
    label: string
    kind: integer
    detail: string?
    documentation: MarkupContent?
    sortText: string?
    textEdit: TextEdit
  end

  record CompletionList
    isIncomplete: boolean
    items: {CompletionItem}
  end

  record ResponseError
    code: integer
    message: string
  end

  record Watcher
    globPattern: string
  end

  record WatchOptions
    watchers: {Watcher}
  end

  record Registration
    id: string
    method: string
    registerOptions: WatchOptions
  end

  record RegistrationParams
    registrations: {Registration}
  end

  -- JSON-RPC's and the protocol's error codes.
  mut INVALID_REQUEST: integer
  mut METHOD_NOT_FOUND: integer
  mut INVALID_PARAMS: integer
  mut INTERNAL_ERROR: integer
  mut NOT_INITIALIZED: integer
  mut REQUEST_FAILED: integer
end

protocol.INVALID_REQUEST = -32600
protocol.METHOD_NOT_FOUND = -32601
protocol.INVALID_PARAMS = -32602
protocol.INTERNAL_ERROR = -32603
protocol.NOT_INITIALIZED = -32002
protocol.REQUEST_FAILED = -32803

local type Position = protocol.Position
local type Range = protocol.Range

--- JSON-RPC's code for a message that is not JSON.
local PARSE_ERROR <const> = -32700

--- The most header bytes ahead of a body.
local MAX_HEADER <const> = 8192
--- The largest message body taken, in bytes.
local MAX_BODY <const> = 64 * 1024 * 1024

local MESSAGE <const>: Shape.Typed<protocol.Message> = Shape.record_of("protocol.Message")

local DOCUMENT_PARAMS <const>: Shape.Typed<protocol.DocumentParams> = Shape.record_of("protocol.DocumentParams")

local INITIALIZE_PARAMS <const>: Shape.Typed<protocol.InitializeParams> = Shape.record_of("protocol.InitializeParams")

--- `body` with its header, as one message on the wire.
function protocol.frame(body: string): string
  return "Content-Length: " .. tostring(#body) .. "\r\n\r\n" .. body
end

--- What a reader of frames has read and not yet answered.
local record FrameState
  mut buffer: string
  mut ended: boolean
end

--- A message's header: where it ends (the byte its blank line starts at)
--- and the length of the body after it.
local record Header
  finish: integer
  length: integer
end

local function too_long(): string
  return "a header longer than " .. plural.count(MAX_HEADER, "byte")
end

--- The header `buffer` begins with: nil and "" while the bytes of its end
--- have not all come, nil and why for one the protocol refuses.
local function header_of(buffer: string): Header?, string
  local finish = buffer:find("\r\n\r\n", 1, true)
  if finish == nil then
    if #buffer > MAX_HEADER then return nil, too_long() end
    return nil, ""
  end
  if finish - 1 > MAX_HEADER then return nil, too_long() end
  local length: integer? = nil
  for line in buffer:sub(1, finish - 1):gmatch("[^\r\n]+") do
    local name, value = line:match("^([^:]+):%s*(.-)%s*$")
    if name == nil or value == nil then
      return nil, "a header line with no name: " .. line
    end
    if name:lower() == "content-length" then
      length = nil
      if value:match("^%d+$") ~= nil then length = math.tointeger(tonumber(value)) end
      if length == nil then
        return nil, "a Content-Length that is no length: " .. value
      end
    end
  end
  if length == nil then
    return nil, "a message with no Content-Length"
  end
  if length > MAX_BODY then
    return nil, "a message of " .. plural.count(length, "byte") .. ", over the " ..
      plural.count(MAX_BODY, "byte") .. " taken"
  end
  return { finish = finish, length = length }, ""
end

--- The messages `read` gives, one body at a time ([`protocol.Frames`]):
--- `read` answers the next chunk of the stream, as a [`Stream.Reader`]'s
--- `read` does, and `poll`, when given, what has arrived of it.
function protocol.frames_of(read: function(): string?, string, poll?: protocol.Poll): protocol.Frames
  local held: FrameState = { buffer = "", ended = false }
  --- The next chunk `read` gives: nil and "" at its end, nil and why
  --- where it breaks.
  local function more(): string?, string
    if held.ended then return nil, "" end
    local chunk, trouble = read()
    if chunk == nil then
      held.ended = true
      return nil, trouble
    end
    return chunk, ""
  end
  --- The next message's header, read until its end is in the buffer:
  --- nil and "" at the stream's end between messages.
  local function read_header(): Header?, string
    while true do
      local found, trouble = header_of(held.buffer)
      if found ~= nil then return found, "" end
      if trouble ~= "" then return nil, trouble end
      local chunk, why = more()
      if chunk == nil then
        if why ~= "" then return nil, why end
        if held.buffer:match("^%s*$") ~= nil then return nil, "" end
        return nil, "the stream ended inside a header"
      end
      held.buffer = held.buffer .. chunk
    end
  end
  return {
    next = function(_self: protocol.Frames): string?, string
      local header, trouble = read_header()
      if header == nil then return nil, trouble end
      -- The body's chunks are joined once, not one at a time: a body of
      -- many chunks would be copied once for each.
      local first = held.buffer:sub(header.finish + 4)
      local parts: mut {string} = { first }
      local have = #first
      while have < header.length do
        local chunk, why = more()
        if chunk == nil then
          if why ~= "" then return nil, why end
          return nil, "the stream ended inside a message"
        end
        parts[#parts + 1] = chunk
        have = have + #chunk
      end
      local joined = table.concat(parts)
      held.buffer = joined:sub(header.length + 1)
      return joined:sub(1, header.length), ""
    end,
    buffered = function(_self: protocol.Frames): string?
      local header, _ = header_of(held.buffer)
      if header == nil then return nil end
      local start = header.finish + 4
      if #held.buffer - start + 1 < header.length then return nil end
      local body = held.buffer:sub(start, start + header.length - 1)
      held.buffer = held.buffer:sub(start + header.length)
      return body
    end,
    waiting = function(_self: protocol.Frames): boolean
      if held.buffer:match("%S") ~= nil then return true end
      if poll == nil or held.ended then return false end
      local chunk, why = poll()
      if chunk == nil then return why ~= "" end
      held.buffer = held.buffer .. chunk
      return true
    end,
  }
end

--- The messages `reader` holds, one body at a time ([`protocol.Frames`]),
--- and what has arrived of them, as `poll` says, when given.
function protocol.frames(reader: Stream.Reader, poll?: protocol.Poll): protocol.Frames
  return protocol.frames_of(function(): string?, string return reader:read() end, poll)
end

--- The path a `file:` URI names, or nil for another scheme.
function protocol.path_of(uri: string): string?
  local rest = uri:match("^file://[^/]*(/.*)$")
  if rest == nil then return nil end
  local path, _ = Url.unescape(rest)
  return path
end

--- The `file:` URI of the absolute path `path`, each segment percent-escaped.
function protocol.uri_of(path: string): string
  local out: mut {string} = {}
  for segment in path:gmatch("[^/]+") do out[#out + 1] = Url.escape(segment) end
  return "file:///" .. table.concat(out, "/")
end

--- The segments of the absolute path `path`, the first as many of them
--- as the count answered, its `.` and `..` segments resolved and its
--- slashes collapsed, as the path reads with no symlink in it: what is a
--- link is not asked, which would read the disk.
local function segments(path: string): {string}, integer
  local kept: mut {string} = {}
  local depth = 0
  for segment in path:gmatch("[^/]+") do
    if segment == ".." then
      if depth > 0 then
        depth = depth - 1
        kept[#kept] = nil
      end
    elseif segment ~= "." then
      depth = depth + 1
      kept[#kept + 1] = segment
    end
  end
  return kept, depth
end

--- `path` below `root`, both read as [`segments`] reads them, or nil when
--- it is not below it: `<root>/../x.tl` is not, and
--- `<root>/../<root's name>/x.tl` and `<root>/./x.tl` are `x.tl`.
function protocol.below(path: string, root: string): string?
  local base, base_depth = segments(root)
  local full, depth = segments(path)
  if depth <= base_depth then return nil end
  for i = 1, base_depth do
    if full[i] ~= base[i] then return nil end
  end
  return table.concat(full, "/", base_depth + 1, depth)
end

--- The range from `start` to `finish`.
function protocol.range(start: Position, finish: Position): Range
  return { ["start"] = start, ["end"] = finish }
end

--- The notification that publishes `diagnostics`, each encoded, for `uri`.
function protocol.publication(uri: string, diagnostics: {string}): string
  return '{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":' ..
    Json.quote(uri) .. ',"diagnostics":[' .. table.concat(diagnostics, ",") .. "]}}"
end

--- The notification that shows the person `message`, of the type
--- `kind` (3 is information).
function protocol.shown(kind: integer, message: string): string
  return '{"jsonrpc":"2.0","method":"window/showMessage","params":{"type":' .. tostring(kind) ..
    ',"message":' .. Json.quote(message) .. "}}"
end

--- The response to the request `id` (encoded) answering `result` (encoded).
function protocol.response(id: string, result: string): string
  return '{"jsonrpc":"2.0","id":' .. id .. ',"result":' .. result .. "}"
end

--- The response to the request `id` (encoded) failing with `code`.
function protocol.failure(id: string, code: integer, why: string): string
  local said: protocol.ResponseError = { code = code, message = why }
  return '{"jsonrpc":"2.0","id":' .. id .. ',"error":' .. assert(Json.encode_any(said)) .. "}"
end

--- The `id` of `message`, encoded: "null" for a notification.
function protocol.id_of(message: protocol.Message): string
  local id, _ = Json.encode_any(message.id)
  return id or "null"
end

--- The message `body` holds: nil and its answer where it is not JSON
--- (-32700) or not a message (-32600).
function protocol.message_of(body: string): protocol.Message?, string
  local decoded, trouble = Json.decode(body)
  if decoded == nil and trouble ~= "" then
    return nil, protocol.failure("null", PARSE_ERROR, trouble)
  end
  local message, invalid = Shape.into(decoded, MESSAGE.spec)
  if message == nil then
    return nil, protocol.failure("null", protocol.INVALID_REQUEST, "not a message: " .. invalid)
  end
  return message, ""
end

--- The params of a `textDocument/` method, or nil and why they do not fit.
function protocol.document_params(params: any): protocol.DocumentParams?, string
  return DOCUMENT_PARAMS:into(params)
end

--- The params of `initialize`, or nil and why they do not fit.
function protocol.initialize_params(params: any): protocol.InitializeParams?, string
  return INITIALIZE_PARAMS:into(params)
end

return protocol

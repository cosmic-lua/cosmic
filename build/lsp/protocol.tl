--- The Language Server Protocol as `cosmic lsp` ([`build.lsp`]) speaks it:
--- the base layer's framing (a `Content-Length` header, then a JSON-RPC
--- 2.0 body), the shapes of the messages it reads and writes, and the
--- protocol's positions in a text.
---
--- Positions are UTF-16 units, the protocol's default, or bytes where the
--- client offers UTF-8 (`general.positionEncodings`). A line ends at
--- "\r\n", "\n" or a lone "\r".

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
    next: function(Frames): string | nil, string
    --- The next message's body when the bytes read already hold all of
    --- it, without reading; nil otherwise, with nothing taken.
    buffered: function(Frames): string | nil
    --- Whether bytes of another message are read already, or have
    --- arrived to be read: the stream's `poll` is asked, without waiting.
    waiting: function(Frames): boolean
  end

  --- What has arrived of a stream, read without waiting: nil and "" when
  --- nothing has, nil and why where the stream broke.
  type Poll = function(): string | nil, string

  -- What the server reads of the messages it is sent, each checked by its
  -- shape before it is read.

  --- A message's envelope: `id` and `params` are read by what the method
  --- says they are.
  record Message
    method: string | nil
    id: any
    params: any
  end

  record Position
    line: integer
    character: integer
  end

  record DocumentIdentifier
    uri: string
    text: string | nil
  end

  record ContentChange
    text: string
  end

  --- The params of every `textDocument/` method read.
  record DocumentParams
    textDocument: DocumentIdentifier
    position: Position | nil
    contentChanges: {ContentChange} | nil
  end

  record WorkspaceFolder
    uri: string
  end

  record General
    positionEncodings: {string} | nil
  end

  record DynamicRegistration
    dynamicRegistration: boolean | nil
  end

  record WorkspaceCapabilities
    didChangeWatchedFiles: DynamicRegistration | nil
  end

  record ClientCapabilities
    general: General | nil
    workspace: WorkspaceCapabilities | nil
  end

  record InitializeParams
    rootUri: string | nil
    rootPath: string | nil
    workspaceFolders: {WorkspaceFolder} | nil
    capabilities: ClientCapabilities | nil
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

  record ServerCapabilities
    positionEncoding: string
    textDocumentSync: SyncOptions
    hoverProvider: boolean
    documentFormattingProvider: boolean
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
    code: string | nil
  end

  record MarkupContent
    kind: string
    value: string
  end

  record Hover
    contents: MarkupContent
  end

  record TextEdit
    range: Range
    newText: string
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

  --- A text's lines as the protocol counts them: where each starts (a
  --- byte, from 1) and what it holds, without its end, which is "\r\n",
  --- "\n" or a lone "\r".
  record Lines
    starts: {integer}
    texts: {string}
  end

  -- JSON-RPC's and the protocol's error codes.
  INVALID_REQUEST: integer
  METHOD_NOT_FOUND: integer
  INVALID_PARAMS: integer
  INTERNAL_ERROR: integer
  NOT_INITIALIZED: integer
  REQUEST_FAILED: integer
end

protocol.INVALID_REQUEST = -32600
protocol.METHOD_NOT_FOUND = -32601
protocol.INVALID_PARAMS = -32602
protocol.INTERNAL_ERROR = -32603
protocol.NOT_INITIALIZED = -32002
protocol.REQUEST_FAILED = -32803

local type Lines = protocol.Lines
local type Position = protocol.Position
local type Range = protocol.Range

--- JSON-RPC's code for a message that is not JSON.
local PARSE_ERROR <const> = -32700

--- The most header bytes ahead of a body.
local MAX_HEADER <const> = 8192
--- The largest message body taken, in bytes.
local MAX_BODY <const> = 64 * 1024 * 1024

local MESSAGE <const> = Shape.record({
  method = Shape.optional(Shape.string),
  id = Shape.optional(Shape.any),
  params = Shape.optional(Shape.any),
})

local DOCUMENT_PARAMS <const>: Shape.Typed<protocol.DocumentParams> = Shape.record_of("protocol.DocumentParams")

local INITIALIZE_PARAMS <const>: Shape.Typed<protocol.InitializeParams> = Shape.record_of("protocol.InitializeParams")

--- `body` with its header, as one message on the wire.
function protocol.frame(body: string): string
  return "Content-Length: " .. tostring(#body) .. "\r\n\r\n" .. body
end

--- What a reader of frames has read and not yet answered.
local record FrameState
  buffer: string
  ended: boolean
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
local function header_of(buffer: string): Header | nil, string
  local finish = buffer:find("\r\n\r\n", 1, true)
  if finish == nil then
    if #buffer > MAX_HEADER then return nil, too_long() end
    return nil, ""
  end
  if finish - 1 > MAX_HEADER then return nil, too_long() end
  local length: integer | nil = nil
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
function protocol.frames_of(read: function(): string | nil, string, poll?: protocol.Poll): protocol.Frames
  local held: FrameState = { buffer = "", ended = false }
  --- The next chunk `read` gives: nil and "" at its end, nil and why
  --- where it breaks.
  local function more(): string | nil, string
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
  local function read_header(): Header | nil, string
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
    next = function(_self: protocol.Frames): string | nil, string
      local header, trouble = read_header()
      if header == nil then return nil, trouble end
      -- The body's chunks are joined once, not one at a time: a body of
      -- many chunks would be copied once for each.
      local first = held.buffer:sub(header.finish + 4)
      local parts: {string} = { first }
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
    buffered = function(_self: protocol.Frames): string | nil
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
  return protocol.frames_of(function(): string | nil, string return reader:read() end, poll)
end

--- The path a `file:` URI names, or nil for another scheme.
function protocol.path_of(uri: string): string | nil
  local rest = uri:match("^file://[^/]*(/.*)$")
  if rest == nil then return nil end
  local path, _ = Url.unescape(rest)
  return path
end

--- The segments of the absolute path `path`, the first as many of them
--- as the count answered, its `.` and `..` segments resolved and its
--- slashes collapsed, as the path reads with no symlink in it: what is a
--- link is not asked, which would read the disk.
local function segments(path: string): {string}, integer
  local kept: {string} = {}
  local depth = 0
  for segment in path:gmatch("[^/]+") do
    if segment == ".." then
      if depth > 0 then depth = depth - 1 end
    elseif segment ~= "." then
      depth = depth + 1
      kept[depth] = segment
    end
  end
  return kept, depth
end

--- `path` below `root`, both read as [`segments`] reads them, or nil when
--- it is not below it: `<root>/../x.tl` is not, and
--- `<root>/../<root's name>/x.tl` and `<root>/./x.tl` are `x.tl`.
function protocol.below(path: string, root: string): string | nil
  local base, base_depth = segments(root)
  local full, depth = segments(path)
  if depth <= base_depth then return nil end
  for i = 1, base_depth do
    if full[i] ~= base[i] then return nil end
  end
  return table.concat(full, "/", base_depth + 1, depth)
end

--- The lines of `text` ([`protocol.Lines`]).
function protocol.lines_of(text: string): Lines
  local starts: {integer} = {}
  local texts: {string} = {}
  local at = 1
  while true do
    local stop = text:find("[\r\n]", at)
    starts[#starts + 1] = at
    if stop == nil then
      texts[#texts + 1] = text:sub(at)
      return { starts = starts, texts = texts }
    end
    texts[#texts + 1] = text:sub(at, stop - 1)
    at = stop + 1
    if text:sub(stop, stop + 1) == "\r\n" then at = stop + 2 end
  end
end

--- How many units of `encoding` the bytes of `line` before byte `x` (from
--- 1) take: the protocol's character of that column, from 0.
local function character_of(line: string, x: integer, encoding: string): integer
  local before = line:sub(1, x - 1)
  if encoding == "utf-8" then return #before end
  local units = 0
  for _, code in utf8.codes(before, true) do
    units = units + 1
    if code >= 0x10000 then units = units + 1 end
  end
  return units
end

--- The byte (from 1) at the protocol's `character` of `line`, or one past
--- the line's end for a character past it.
function protocol.byte_of(line: string, character: integer, encoding: string): integer
  if encoding == "utf-8" then return math.min(character, #line) + 1 end
  local units = 0
  for at, code in utf8.codes(line, true) do
    if units >= character then return at end
    units = units + 1
    if code >= 0x10000 then units = units + 1 end
  end
  return #line + 1
end

--- The protocol's position of byte `offset` (from 1) of the text `lines`
--- holds; a byte of a line's end is past the line's last character.
function protocol.position(lines: Lines, offset: integer, encoding: string): Position
  local low, high = 1, #lines.starts
  while low < high do
    local middle = (low + high + 1) // 2
    if assert(lines.starts[middle]) <= offset then low = middle else high = middle - 1 end
  end
  local line = assert(lines.texts[low])
  local x = math.min(math.max(offset - assert(lines.starts[low]) + 1, 1), #line + 1)
  return { line = low - 1, character = character_of(line, x, encoding) }
end

--- The range from `start` to `finish`.
function protocol.range(start: Position, finish: Position): Range
  return { ["start"] = start, ["end"] = finish }
end

--- Where each line of `text` starts as the checker counts lines, which is
--- at "\n" alone: its columns are bytes.
function protocol.checker_starts(text: string): {integer}
  local out: {integer} = { 1 }
  local at = text:find("\n", 1, true)
  while at ~= nil do
    out[#out + 1] = at + 1
    at = text:find("\n", at + 1, true)
  end
  return out
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
  return '{"jsonrpc":"2.0","id":' .. id .. ',"error":' .. assert(Json.encode(said)) .. "}"
end

--- The `id` of `message`, encoded: "null" for a notification.
function protocol.id_of(message: protocol.Message): string
  local id, _ = Json.encode(message.id)
  return id or "null"
end

--- The message `body` holds: nil and its answer where it is not JSON
--- (-32700) or not a message (-32600).
function protocol.message_of(body: string): protocol.Message | nil, string
  local decoded, trouble = Json.decode(body)
  if decoded == nil and trouble ~= "" then
    return nil, protocol.failure("null", PARSE_ERROR, trouble)
  end
  local message, invalid: protocol.Message | nil, string = Shape.into(decoded, MESSAGE)
  if message == nil then
    return nil, protocol.failure("null", protocol.INVALID_REQUEST, "not a message: " .. invalid)
  end
  return message, ""
end

--- The params of a `textDocument/` method, or nil and why they do not fit.
function protocol.document_params(params: any): protocol.DocumentParams | nil, string
  return DOCUMENT_PARAMS:into(params)
end

--- The params of `initialize`, or nil and why they do not fit.
function protocol.initialize_params(params: any): protocol.InitializeParams | nil, string
  return INITIALIZE_PARAMS:into(params)
end

return protocol

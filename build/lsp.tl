--- `cosmic lsp`: a Language Server Protocol server for Teal, so an editor
--- shows what `cosmic fix` and `cosmic test` would refuse as it is typed.
---
--- It serves one editor over standard input and output, or, with
--- `--listen [host:]port` or `--socket <path>`, each editor that connects
--- (a session of its own per connection) until SIGINT or SIGTERM. Messages
--- are JSON-RPC 2.0 framed by a `Content-Length` header, as the protocol's
--- base layer says.
---
--- What it answers:
---
--- - Diagnostics, published as a document is opened, changed or saved:
---   the checker's syntax and type errors and its warnings, which a build
---   refuses as it refuses errors, each with [`teal.replacement`]'s hint.
---   The text is checked in memory, as the editor holds it. A `require`
---   is answered from an open document first, then the file below the
---   workspace's root (a declaration ahead of a source), then the binary's
---   own `cosmic.*` modules, so a project's modules need no build.
--- - Hover: the docs of the symbol under the cursor ([`Fs.read`], or
---   [`cosmic.fs.read`] named through the local a `require` bound), from the
---   binary's own docs and the project's last build, as `cosmic docs`.
--- - Formatting: the whole document as `cosmic fix` writes it.
---
--- Positions are UTF-16, the protocol's default, or UTF-8 where the
--- client offers it (`general.positionEncodings`).
---
--- Its `spec` (build/verb_spec.tl) is `bare`: standard output is the
--- protocol's. Complaints go to standard error as `cosmic: lsp: ...`.
---
--- TODO: go to definition and completion. tl's type report
--- (`env.report_types`, `get_types`, `symbols_in_scope`) answers both,
--- and build/compiler.d.tl declares none of it yet; waits on declaring it
--- there.

local Cli = require("cosmic.cli")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Net = require("cosmic.net")
local Shape = require("cosmic.shape")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local Stream = require("cosmic.stream")
local Url = require("cosmic.url")
local bare = require("build.bare")
local docs = require("build.docs")
local plural = require("build.plural")
local teal = require("build.teal")
local verb_spec = require("build.verb_spec")
local type compiler = require("build.compiler")

local record lsp
  --- The verb's registration: see build/verb_spec.tl.
  spec: verb_spec.Spec

  --- A document the editor holds open.
  record Document
    uri: string
    text: string
    --- The name the checker knows it by: its path below the root, or its
    --- absolute path when it is not below it.
    name: string
  end

  --- What a session is given beyond its root: what a test stands in for.
  record Options
    --- Where complaints go, without their newline: standard error when nil.
    err?: function(line: string)
    --- The databases docs are read from: [`Store.databases()`] when nil.
    store?: {Sqlite.Handle}
  end

  --- One editor's session: what it opened and what it was told.
  record Session
    --- The workspace's root, which a `require` is answered below.
    root: string
    --- "utf-16" or "utf-8": what a position's character counts.
    encoding: string
    initialized: boolean
    shut_down: boolean
    --- Set at `exit`: the exit status the session ends with.
    exit: integer | nil
    documents: {string:Document}
    --- Where complaints go, without their newline.
    err: function(line: string)
    built: compiler | nil
    env: compiler.Env | nil
    --- The globals a fresh environment has, so a check drops those an
    --- earlier text declared.
    base_globals: {string:boolean}
    --- Each project module the checker was served, by name, with its file
    --- name: dropped before each check, as its text may have changed.
    served: {string:string}
    store: {Sqlite.Handle} | nil
    view: docs.View | nil
    --- Why the docs could not be read, once they were tried.
    view_trouble: string | nil
  end

  --- A reader of framed messages.
  record Frames
    next: function(Frames): string | nil, string
  end
end

--- The most header bytes ahead of a body.
local MAX_HEADER <const> = 8192
--- The largest message body taken, in bytes.
local MAX_BODY <const> = 64 * 1024 * 1024

-- JSON-RPC's and the protocol's error codes.
local PARSE_ERROR <const> = -32700
local INVALID_REQUEST <const> = -32600
local METHOD_NOT_FOUND <const> = -32601
local INTERNAL_ERROR <const> = -32603
local NOT_INITIALIZED <const> = -32002
local REQUEST_FAILED <const> = -32803

-- What the server reads of the messages it is sent, each checked by its
-- shape before it is read.

--- A message's envelope: `id` and `params` are read by what the method
--- says they are.
local record Message
  method: string | nil
  id: any
  params: any
end

local MESSAGE <const> = Shape.record({
  method = Shape.optional(Shape.string),
  id = Shape.optional(Shape.any),
  params = Shape.optional(Shape.any),
})

local record Position
  line: integer
  character: integer
end

local record DocumentIdentifier
  uri: string
  text: string | nil
end

local record ContentChange
  text: string
end

--- The params of every `textDocument/` method read.
local record DocumentParams
  textDocument: DocumentIdentifier
  position: Position | nil
  contentChanges: {ContentChange} | nil
end

local DOCUMENT_PARAMS <const> = Shape.record_of("DocumentParams")

local record WorkspaceFolder
  uri: string
end

local record General
  positionEncodings: {string} | nil
end

local record ClientCapabilities
  general: General | nil
end

local record InitializeParams
  rootUri: string | nil
  rootPath: string | nil
  workspaceFolders: {WorkspaceFolder} | nil
  capabilities: ClientCapabilities | nil
end

local INITIALIZE_PARAMS <const> = Shape.record_of("InitializeParams")

-- What the server sends, encoded as it is.

local record SaveOptions
  includeText: boolean
end

local record SyncOptions
  openClose: boolean
  change: integer
  save: SaveOptions
end

local record ServerCapabilities
  positionEncoding: string
  textDocumentSync: SyncOptions
  hoverProvider: boolean
  documentFormattingProvider: boolean
end

local record ServerInfo
  name: string
end

local record InitializeResult
  capabilities: ServerCapabilities
  serverInfo: ServerInfo
end

--- A range: its `start` and its `end`, a name no record field can have.
local type Range = {string: Position}

local record Diagnostic
  range: Range
  severity: integer
  source: string
  message: string
  code: string | nil
end

local record MarkupContent
  kind: string
  value: string
end

local record Hover
  contents: MarkupContent
end

local record TextEdit
  range: Range
  newText: string
end

local record ResponseError
  code: integer
  message: string
end

--- `body` with its header, as one message on the wire.
function lsp.frame(body: string): string
  return "Content-Length: " .. tostring(#body) .. "\r\n\r\n" .. body
end

--- What a reader of frames has read and not yet answered.
local record FrameState
  buffer: string
  ended: boolean
end

--- The messages `reader` holds, one body at a time: nil and "" at the end
--- between messages, nil and why for a stream that ends inside one or
--- holds a header the protocol does not.
function lsp.frames(reader: Stream.Reader): lsp.Frames
  local held: FrameState = { buffer = "", ended = false }
  local function fill(): boolean, string
    if held.ended then return false, "" end
    local chunk, trouble = reader:read()
    if chunk == nil then
      held.ended = true
      return false, trouble
    end
    held.buffer = held.buffer .. chunk
    return true, ""
  end
  return {
    next = function(_self: lsp.Frames): string | nil, string
      local finish = held.buffer:find("\r\n\r\n", 1, true)
      while finish == nil do
        if #held.buffer > MAX_HEADER then
          return nil, "a header longer than " .. plural.count(MAX_HEADER, "byte")
        end
        local more, trouble = fill()
        if not more then
          if trouble ~= "" then return nil, trouble end
          if held.buffer:match("^%s*$") ~= nil then return nil, "" end
          return nil, "the stream ended inside a header"
        end
        finish = held.buffer:find("\r\n\r\n", 1, true)
      end
      local length: integer | nil = nil
      for line in held.buffer:sub(1, finish - 1):gmatch("[^\r\n]+") do
        local name, value = line:match("^([^:]+):%s*(.-)%s*$")
        if name == nil then
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
      local start = finish + 4
      while #held.buffer - start + 1 < length do
        local more, trouble = fill()
        if not more then
          if trouble ~= "" then return nil, trouble end
          return nil, "the stream ended inside a message"
        end
      end
      local body = held.buffer:sub(start, start + length - 1)
      held.buffer = held.buffer:sub(start + length)
      return body, ""
    end,
  }
end

--- The path a `file:` URI names, or nil for another scheme.
local function path_of(uri: string): string | nil
  local rest = uri:match("^file://[^/]*(/.*)$")
  if rest == nil then return nil end
  local path, _ = Url.unescape(rest)
  return path
end

--- `path` below `root`, or nil when it is not below it.
local function below(path: string, root: string): string | nil
  local prefix = root
  if prefix:sub(-1) ~= "/" then prefix = prefix .. "/" end
  if path:sub(1, #prefix) == prefix then return path:sub(#prefix + 1) end
  return nil
end

--- The lines of `text`, each without its end.
local function lines_of(text: string): {string}
  local out: {string} = {}
  for each in (text .. "\n"):gmatch("([^\n]*)\n") do
    local line = each
    if line:sub(-1) == "\r" then line = line:sub(1, -2) end
    out[#out + 1] = line
  end
  return out
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
local function byte_of(line: string, character: integer, encoding: string): integer
  if encoding == "utf-8" then return math.min(character, #line) + 1 end
  local units = 0
  for at, code in utf8.codes(line, true) do
    if units >= character then return at end
    units = units + 1
    if code >= 0x10000 then units = units + 1 end
  end
  return #line + 1
end

--- The protocol's position of byte `x` of line `y` (both from 1).
local function position(lines: {string}, y: integer, x: integer, encoding: string): Position
  local line = lines[y] or ""
  return { line = y - 1, character = character_of(line, math.max(x, 1), encoding) }
end

--- The range from `start` to `finish`.
local function range(start: Position, finish: Position): Range
  return { ["start"] = start, ["end"] = finish }
end

--- A new session, before `initialize`, answering below `root`.
function lsp.new(root: string, options?: lsp.Options): lsp.Session
  local given: lsp.Options = options or {}
  return {
    root = root,
    encoding = "utf-16",
    initialized = false,
    shut_down = false,
    exit = nil,
    documents = {},
    err = given.err or bare.err,
    built = nil,
    env = nil,
    base_globals = {},
    served = {},
    store = given.store,
    view = nil,
    view_trouble = nil,
  }
end

--- What the checker reads for a module: its text, then a close.
local record Served
  text: string
  read: function(Served, what: string): string
  close: function(Served): boolean
end

local function served(text: string): Served
  return {
    text = text,
    read = function(self: Served, _what: string): string return self.text end,
    close = function(_self: Served): boolean return true end,
  }
end

--- The text of the project module `file` below the session's root: the
--- open document of that name, else the file; nil when neither is there.
local function project_text(session: lsp.Session, file: string): string | nil
  for _, document in pairs(session.documents) do
    if document.name == file then return document.text end
  end
  local read, _ = Fs.read(session.root .. "/" .. file)
  return read
end

--- The session's checker and its environment, made on first use.
local function checker(session: lsp.Session): compiler, compiler.Env
  local built, env = session.built, session.env
  if built ~= nil and env ~= nil then return built, env end
  local loaded = assert(teal.load())
  loaded.search_module = function(name: string, _search_all: boolean): string | nil, any
    local stem = name:gsub("%.", "/")
    for _, suffix in ipairs({ ".d.tl", ".tl" }) do
      local file = stem .. suffix
      local text = project_text(session, file)
      if text ~= nil then
        session.served[name] = file
        return file, served(text)
      end
    end
    local found = teal.standard_text(name)
    if found == nil then return nil, nil end
    return stem .. ".tl", served(found.text)
  end
  local made, env_trouble = loaded.new_env({
    defaults = { feat_lax = "off", gen_compat = "off", gen_target = "5.4" },
  })
  if made == nil then error(env_trouble, 0) end
  teal.strip(made)
  for name in pairs(made.globals) do session.base_globals[name] = true end
  session.built, session.env = loaded, made
  return loaded, made
end

--- The diagnostics of `document`, each encoded.
local function diagnose(session: lsp.Session, document: lsp.Document): {string}
  local built, env = checker(session)
  -- A module served before may have changed, and a global an earlier
  -- text declared would be declared twice; the `cosmic.*` modules stay,
  -- which is most of what a check costs.
  for name, file in pairs(session.served) do
    env.modules[name] = nil
    env.module_filenames[name] = nil
    env.loaded[file] = nil
  end
  session.served = {}
  env.loaded[document.name] = nil
  for name in pairs(env.globals) do
    if session.base_globals[name] ~= true then env.globals[name] = nil end
  end
  local result = built.check_string(document.text, env, document.name, "tl")
  env.loaded[document.name] = nil
  local refused = teal.refused_type_requires(document.name, document.text, result)
  local lines = lines_of(document.text)
  local out: {string} = {}
  local none: {compiler.Error} = {}
  for _, group in ipairs({ result.syntax_errors, result.type_errors, result.warnings }) do
    for _, e in ipairs(group or none) do
      if e.filename == nil or e.filename == "" or e.filename == document.name then
        local instead = teal.replacement(e, document.text, document.name, refused)
        local message = e.msg
        if instead ~= nil then message = message .. " -- " .. instead end
        local y, x = math.max(e.y or 1, 1), math.max(e.x or 1, 1)
        local word = (lines[y] or ""):match("^[%w_]+", x) or ""
        local code: string | nil = e.code
        if code == nil then code = e.tag end
        local diagnostic: Diagnostic = {
          range = range(position(lines, y, x, session.encoding),
            position(lines, y, x + math.max(#word, 1), session.encoding)),
          -- A build refuses a warning as it does an error.
          severity = 1,
          source = "cosmic",
          message = message,
          code = code,
        }
        out[#out + 1] = assert(Json.encode(diagnostic))
      end
    end
  end
  return out
end

--- The notification that publishes `diagnostics`, each encoded, for `uri`.
local function publication(uri: string, diagnostics: {string}): string
  return '{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":' ..
    Json.quote(uri) .. ',"diagnostics":[' .. table.concat(diagnostics, ",") .. "]}}"
end

--- The document `params` names, opened as `text` when it is given.
local function document_of(session: lsp.Session, params: DocumentParams, text?: string): lsp.Document | nil
  local uri = params.textDocument.uri
  local document = session.documents[uri]
  if document == nil and text ~= nil then
    local path = path_of(uri) or uri
    document = { uri = uri, text = text, name = below(path, session.root) or path }
    session.documents[uri] = document
  elseif document ~= nil and text ~= nil then
    document.text = text
  end
  return document
end

--- The docs view, read once.
local function view_of(session: lsp.Session): docs.View | nil
  if session.view ~= nil or session.view_trouble ~= nil then return session.view end
  local sources = docs.databases(session.store or Store.databases(), session.root)
  local view, trouble = docs.view(sources.handles, sources.public)
  session.view = view
  session.view_trouble = trouble
  if view == nil then session.err("cosmic: lsp: no docs: " .. trouble) end
  return view
end

--- The dotted name under byte `x` of `line`, up to the end of the word
--- the cursor is in: [`Fs.read`] with the cursor anywhere in `Fs`'s `read`.
local function name_at(line: string, x: integer): string | nil
  local first = x
  while first > 1 do
    if line:sub(first - 1, first - 1):match("[%w_%.]") == nil then break end
    first = first - 1
  end
  local last = x
  while last <= #line do
    if line:sub(last, last):match("[%w_]") == nil then break end
    last = last + 1
  end
  local name = line:sub(first, last - 1):gsub("^%.+", "")
  if name:match("^[%a_]") == nil then return nil end
  return name
end

--- `name` with its first part read as the module a `require` in `text`
--- bound to it: [`Fs.read`] as [`cosmic.fs.read`]. Nil when no `require` did.
local function resolved(text: string, name: string): string | nil
  local head, rest = name:match("^([%a_][%w_]*)(.*)$")
  for alias, module in text:gmatch("local%s+([%a_][%w_]*)%s*=%s*require%s*%(?%s*[\"']([%w_%.]+)[\"']") do
    if alias == head then return module .. rest end
  end
  return nil
end

--- The hover for `params`, or nil when nothing is documented there.
local function hover(session: lsp.Session, params: DocumentParams): Hover | nil
  local document = document_of(session, params)
  local where = params.position
  if document == nil or where == nil then return nil end
  local line = lines_of(document.text)[where.line + 1] or ""
  local name = name_at(line, byte_of(line, where.character, session.encoding))
  if name == nil then return nil end
  local view = view_of(session)
  if view == nil then return nil end
  local queries: {string} = {}
  local through = resolved(document.text, name)
  if through ~= nil then queries[#queries + 1] = through end
  queries[#queries + 1] = name
  for _, query in ipairs(queries) do
    local found, _ = docs.exact(view, query)
    local entry: docs.Entry | nil = nil
    if found ~= nil then entry = found[1] end
    if entry ~= nil then
      local title = entry.module
      if entry.symbol ~= "" then title = title .. "." .. entry.symbol end
      local parts: {string} = { "**" .. title .. "**" }
      if entry.signature ~= "" then
        parts[#parts + 1] = "```teal\n" .. entry.signature .. "\n```"
      end
      if entry.text ~= "" then parts[#parts + 1] = entry.text end
      return { contents = { kind = "markdown", value = table.concat(parts, "\n\n") } }
    end
  end
  return nil
end

--- The edits that format `params`' document, encoded, or nil and why
--- there are none.
local function formatting(session: lsp.Session, params: DocumentParams): string | nil, string
  local document = document_of(session, params)
  if document == nil then return nil, "no such document is open" end
  local built = checker(session)
  local fixed, trouble = require("build.fix").source(built, document.text, document.name)
  if fixed == nil then return nil, trouble end
  if fixed.source == document.text then return "[]", "" end
  local lines = lines_of(document.text)
  local edit: TextEdit = {
    range = range({ line = 0, character = 0 },
      position(lines, #lines, #lines[#lines] + 1, session.encoding)),
    newText = fixed.source,
  }
  return "[" .. assert(Json.encode(edit)) .. "]", ""
end

--- The workspace's root `params` names, if any.
local function root_of(params: InitializeParams): string | nil
  local uri = params.rootUri
  local folders = params.workspaceFolders
  if uri == nil and folders ~= nil and folders[1] ~= nil then uri = folders[1].uri end
  local path = params.rootPath
  if uri ~= nil then path = path_of(uri) end
  if path == nil or path == "" then return nil end
  return (path:gsub("(.)/+$", "%1"))
end

--- The answer to `initialize`.
local function initialize(session: lsp.Session, params: InitializeParams): InitializeResult
  session.root = root_of(params) or session.root
  local capabilities = params.capabilities
  local general: General | nil = nil
  if capabilities ~= nil then general = capabilities.general end
  local offered: {string} = {}
  if general ~= nil then offered = general.positionEncodings or offered end
  for _, name in ipairs(offered) do
    if name == "utf-8" then session.encoding = "utf-8" end
  end
  session.initialized = true
  return {
    capabilities = {
      positionEncoding = session.encoding,
      textDocumentSync = { openClose = true, change = 1, save = { includeText = false } },
      hoverProvider = true,
      documentFormattingProvider = true,
    },
    serverInfo = { name = "cosmic" },
  }
end

--- The response to the request `id` (encoded) answering `result` (encoded).
local function response(id: string, result: string): string
  return '{"jsonrpc":"2.0","id":' .. id .. ',"result":' .. result .. "}"
end

--- The response to the request `id` (encoded) failing with `code`.
local function failure(id: string, code: integer, why: string): string
  local said: ResponseError = { code = code, message = why }
  return '{"jsonrpc":"2.0","id":' .. id .. ',"error":' .. assert(Json.encode(said)) .. "}"
end

--- The `id` of `message`, encoded: "null" for a notification.
local function id_of(message: Message): string
  local id, _ = Json.encode(message.id)
  return id or "null"
end

--- What `message` asks: each message to send in answer, encoded, in
--- order, a request's response among them.
local function handle(session: lsp.Session, message: Message): {string}
  local out: {string} = {}
  local method = message.method
  local id = id_of(message)
  local is_request = id ~= "null"
  if method == nil then
    -- A response to a request this server never makes.
    if not is_request then
      out[#out + 1] = failure("null", INVALID_REQUEST, "a message with no method")
    end
    return out
  end
  if method == "exit" then
    session.exit = 1
    if session.shut_down then session.exit = 0 end
    return out
  end
  if not session.initialized and method ~= "initialize" then
    if is_request then out[#out + 1] = failure(id, NOT_INITIALIZED, "initialize first") end
    return out
  end
  if session.shut_down then
    if is_request then out[#out + 1] = failure(id, INVALID_REQUEST, "the server is shut down") end
    return out
  end
  if method == "initialize" then
    local params, trouble = INITIALIZE_PARAMS:into(message.params)
    if session.initialized then
      out[#out + 1] = failure(id, INVALID_REQUEST, "initialize was already sent")
    elseif params == nil then
      out[#out + 1] = failure(id, INVALID_REQUEST, "initialize: " .. trouble)
    else
      out[#out + 1] = response(id, (assert(Json.encode(initialize(session, params)))))
    end
    return out
  end
  if method == "shutdown" then
    session.shut_down = true
    out[#out + 1] = response(id, "null")
    return out
  end
  if method:sub(1, #"textDocument/") ~= "textDocument/" then
    if is_request then out[#out + 1] = failure(id, METHOD_NOT_FOUND, "no method " .. method) end
    return out
  end
  local params, trouble = DOCUMENT_PARAMS:into(message.params)
  if params == nil then
    if is_request then out[#out + 1] = failure(id, INVALID_REQUEST, method .. ": " .. trouble) end
    return out
  end
  if method == "textDocument/didOpen" then
    local document = document_of(session, params, params.textDocument.text)
    if document ~= nil then
      out[#out + 1] = publication(document.uri, diagnose(session, document))
    end
  elseif method == "textDocument/didChange" then
    -- The server asked for whole texts, so the last is the document.
    local none: {ContentChange} = {}
    local changes = params.contentChanges or none
    local last = changes[#changes]
    if last ~= nil then
      local document = document_of(session, params, last.text)
      if document ~= nil then
        out[#out + 1] = publication(document.uri, diagnose(session, document))
      end
    end
  elseif method == "textDocument/didSave" then
    -- A document the others require may be the one saved.
    for _, document in pairs(session.documents) do
      out[#out + 1] = publication(document.uri, diagnose(session, document))
    end
  elseif method == "textDocument/didClose" then
    local document = document_of(session, params)
    if document ~= nil then
      session.documents[document.uri] = nil
      local cleared: {string} = {}
      out[#out + 1] = publication(document.uri, cleared)
    end
  elseif method == "textDocument/hover" then
    local found = hover(session, params)
    local result = "null"
    if found ~= nil then result = assert(Json.encode(found)) end
    out[#out + 1] = response(id, result)
  elseif method == "textDocument/formatting" then
    local edits, why = formatting(session, params)
    if edits == nil then
      out[#out + 1] = failure(id, REQUEST_FAILED, why)
    else
      out[#out + 1] = response(id, edits)
    end
  elseif is_request then
    out[#out + 1] = failure(id, METHOD_NOT_FOUND, "no method " .. method)
  end
  return out
end

--- The messages to send in answer to the message `body`, encoded.
local function answers(session: lsp.Session, body: string): {string}
  local message, trouble: Message | nil, string = Shape.decode_into(body, MESSAGE)
  if message == nil then
    return { failure("null", PARSE_ERROR, trouble) }
  end
  -- A fault answering one message fails that message, not the session.
  local ok, handled = pcall(handle, session, message)
  if ok then return handled end
  session.err("cosmic: lsp: " .. tostring(handled))
  local id = id_of(message)
  if id == "null" then return {} end
  return { failure(id, INTERNAL_ERROR, tostring(handled)) }
end

--- Serves `session` the messages `reader` holds, writing each answer
--- through `write`, until `exit` or the end of the stream. Answers the
--- exit status: 0 after `shutdown` then `exit`, 1 otherwise.
function lsp.serve(session: lsp.Session, reader: Stream.Reader,
                   write: function(text: string): boolean, string): integer
  local frames = lsp.frames(reader)
  while session.exit == nil do
    local body, trouble = frames:next()
    if body == nil then
      if trouble ~= "" then
        session.err("cosmic: lsp: " .. trouble)
        return 1
      end
      if session.shut_down then return 0 end
      return 1
    end
    for _, answer in ipairs(answers(session, body)) do
      local sent, why = write(lsp.frame(answer))
      if not sent then
        session.err("cosmic: lsp: " .. why)
        return 1
      end
    end
  end
  return session.exit or 1
end

local spec = Cli.verbs["lsp"].spec or {}

local usage = "cosmic lsp [--stdio] [--listen [host:]port] [--socket path]"

--- The address `--listen` names: `port` alone is the loopback's.
local function listen_address(word: string): Net.Address | nil
  local host, port = word:match("^%[(.+)%]:(%d+)$")
  if host == nil then host, port = word:match("^([^:]+):(%d+)$") end
  if host == nil then host, port = "127.0.0.1", word:match("^(%d+)$") end
  if port == nil then return nil end
  local number = math.tointeger(tonumber(port))
  if number == nil or number > 65535 then return nil end
  return Net.tcp(host, number)
end

--- Where `address` listens, as a person reads it.
local function named(address: Net.Address): string
  if address.kind == "unix" then return address.path or "" end
  return (address.host or "") .. ":" .. tostring(address.port)
end

--- Runs the command line `argv`, `lsp` at slot 1, and answers the exit
--- code.
local function run(argv: {integer:string}): integer
  local complain = bare.complainer("lsp", bare.err)
  local parsed, trouble = Flags.parse(argv, 2, spec)
  if parsed == nil then
    complain(trouble .. "; " .. usage)
    return bare.refused
  end
  if #parsed.words > 0 then
    complain("takes no words, given " .. parsed.words[1] .. "; " .. usage)
    return bare.refused
  end
  local root, root_trouble = Fs.absolute(".")
  if root == nil then
    complain(root_trouble)
    return bare.failed
  end
  local none: {string} = {}
  local listeners: {Net.Address} = {}
  for _, word in ipairs(parsed.all["--listen"] or none) do
    local address = listen_address(word)
    if address == nil then
      complain("--listen takes [host:]port, a numeric host, given " .. word)
      return bare.refused
    end
    listeners[#listeners + 1] = address
  end
  for _, path in ipairs(parsed.all["--socket"] or none) do
    listeners[#listeners + 1] = Net.unix(path)
  end
  if #listeners == 0 then
    return lsp.serve(lsp.new(root), Stream.from_fd(0), bare.out)
  end
  local ok, serve_trouble = Net.serve({
    listeners = listeners,
    serve = function(conn: Net.Conn)
      local _ = lsp.serve(lsp.new(root), conn, function(text: string): boolean, string
        return conn:write(text)
      end)
    end,
    on_ready = function(addresses: {Net.Address}, _server: Net.Server)
      for _, address in ipairs(addresses) do
        bare.err("cosmic: lsp: listening at " .. named(address))
      end
    end,
    on_stop = nil,
    on_error = nil,
  })
  if not ok then
    complain(serve_trouble)
    return bare.failed
  end
  return bare.ok
end

lsp.spec = {
  name = "lsp",
  run = run,
  bare = true,
  fresh = nil,
  recheck_on_refusal = nil,
  summarizes_failure = nil,
  program_slot = nil,
  takes = "where to listen",
  exits = "`lsp` speaks the Language Server Protocol on its standard output and " ..
    "exits 0 after `shutdown` then `exit`, 1 when the editor exits without " ..
    "`shutdown`, the stream breaks or a listener fails, 2 for a command line it refuses",
  passthrough = "it serves until its editor exits, which a case of the verb list cannot be",
  guide = "none: an editor starts it, not a person",
  tests = { "build.lsp_test" },
}

return lsp

--- One editor's session of `cosmic lsp` ([`build.lsp`]): what it opened,
--- what it was told, and its answer to each message it sends, as the
--- protocol's lifecycle holds them ([`build.lsp.protocol`]).
---
--- What it answers:
---
--- - Diagnostics, published as a document is opened, changed or saved,
---   as [`build.lsp.check`] finds them.
--- - Hover: the docs of the symbol under the cursor, from the binary's own
---   docs and the project's last build, as `cosmic docs`. A name whose
---   first part is a local bound to a `require` is looked up in the module
---   required: [`Fs.read`], with `local Fs = require("cosmic.fs")`, is
---   [`cosmic.fs.read`].
--- - Formatting: the whole document as `cosmic fix` writes it.
---
--- A save, or a change on disk the editor reports of a file it watches,
--- stages the tree again ([`build.lsp.source`]) and checks each open
--- document again. Where the editor takes a registration of the files to
--- watch, the session registers every `.tl` and `.tmpl` file at
--- `initialized`.
---
--- A message with no method answers a request of the session's own, and
--- is never answered, whatever its id.

local Json = require("cosmic.json")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local Stream = require("cosmic.stream")
local bare = require("build.bare")
local check = require("build.lsp.check")
local docs = require("build.docs")
local protocol = require("build.lsp.protocol")
local type importer = require("build.importer")

local record session
  --- What a session is given beyond its root: what a test stands in for.
  record Options
    --- Where complaints go, without their newline: standard error when nil.
    err?: function(line: string)
    --- The databases docs are read from: [`Store.databases()`] when nil.
    store?: {Sqlite.Handle}
  end

  --- One editor's session: what it opened and what it was told.
  record State
    --- The workspace's root, which a `require` is answered below.
    root: string
    --- "utf-16" or "utf-8": what a position's character counts.
    encoding: string
    initialized: boolean
    shut_down: boolean
    --- Set at `exit`: the exit status the session ends with.
    exit: integer | nil
    --- The open documents, by URI.
    documents: {string:check.Document}
    --- Where complaints go, without their newline.
    err: function(line: string)
    checker: check.Checker
    --- Whether the editor takes a registration of the files to watch.
    watch: boolean
    store: {Sqlite.Handle} | nil
    --- The docs databases, once read.
    sources: docs.Sources | nil
    view: docs.View | nil
    --- Why the docs could not be read, once they were tried.
    view_trouble: string | nil
  end
end

local type Session = session.State

--- The id of the one request the server makes, which registers the
--- files it watches: its answer is read as any response is, and dropped.
local WATCH_REQUEST <const> = 1

--- The docs databases, opened once.
local function sources_of(s: Session): docs.Sources
  local sources = s.sources
  if sources == nil then
    sources = docs.databases(s.store or Store.databases(), s.root)
    s.sources = sources
  end
  return sources
end

--- The databases a message's hint looks a name up in: the docs
--- databases of the session `held` holds.
local function hints_of(held: {Session}): importer.Hints
  return function(): {Sqlite.Handle}, {boolean}
    local s = held[1]
    if s == nil then return {}, {} end
    local sources = sources_of(s)
    return sources.handles, sources.public
  end
end

--- A new session, before `initialize`, answering below `root`.
function session.new(root: string, options?: session.Options): Session
  local given: session.Options = options or {}
  local err = given.err or bare.err
  local held: {Session} = {}
  local made: Session = {
    root = root,
    encoding = "utf-16",
    initialized = false,
    shut_down = false,
    exit = nil,
    documents = {},
    err = err,
    checker = check.new(root, err, hints_of(held)),
    watch = false,
    store = given.store,
    sources = nil,
    view = nil,
    view_trouble = nil,
  }
  held[1] = made
  return made
end

--- The document `params` names, opened as `text` when it is given.
local function document_of(s: Session, params: protocol.DocumentParams, text?: string): check.Document | nil
  local uri = params.textDocument.uri
  local document = s.documents[uri]
  if document == nil and text ~= nil then
    local path = protocol.path_of(uri) or uri
    document = check.document(uri, protocol.below(path, s.root) or path, text)
    s.documents[uri] = document
    check.opened(s.checker, document)
  elseif document ~= nil and text ~= nil then
    check.set_text(document, text)
  end
  return document
end

--- The docs view, read once.
local function view_of(s: Session): docs.View | nil
  if s.view ~= nil or s.view_trouble ~= nil then return s.view end
  local sources = sources_of(s)
  local view, trouble = docs.view(sources.handles, sources.public)
  s.view = view
  s.view_trouble = trouble
  if view == nil then s.err("cosmic: lsp: no docs: " .. trouble) end
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
local function hover(s: Session, params: protocol.DocumentParams): protocol.Hover | nil
  local document = document_of(s, params)
  local where = params.position
  if document == nil or where == nil then return nil end
  local line = protocol.lines_of(document.text).texts[where.line + 1] or ""
  local name = name_at(line, protocol.byte_of(line, where.character, s.encoding))
  if name == nil then return nil end
  local view = view_of(s)
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
local function formatting(s: Session, params: protocol.DocumentParams): string | nil, string
  local document = document_of(s, params)
  if document == nil then return nil, "no such document is open" end
  local built = check.compiler(s.checker)
  local fixed, trouble = require("build.fix").source(built, document.text, document.name)
  if fixed == nil then return nil, trouble end
  if fixed.source == document.text then return "[]", "" end
  local lines = protocol.lines_of(document.text)
  local edit: protocol.TextEdit = {
    range = protocol.range({ line = 0, character = 0 },
      protocol.position(lines, #document.text + 1, s.encoding)),
    newText = fixed.source,
  }
  return "[" .. assert(Json.encode(edit)) .. "]", ""
end

--- The workspace's root `params` names, if any.
local function root_of(params: protocol.InitializeParams): string | nil
  local uri = params.rootUri
  local folders = params.workspaceFolders
  if uri == nil and folders ~= nil and folders[1] ~= nil then uri = folders[1].uri end
  local path = params.rootPath
  if uri ~= nil then path = protocol.path_of(uri) end
  if path == nil or path == "" then return nil end
  return (path:gsub("(.)/+$", "%1"))
end

--- The answer to `initialize`.
local function initialize(s: Session, params: protocol.InitializeParams): protocol.InitializeResult
  local root = root_of(params)
  if root ~= nil and root ~= s.root then
    s.root = root
    check.close(s.checker)
    s.checker = check.new(root, s.err, hints_of({ s }))
  end
  local capabilities = params.capabilities
  local general: protocol.General | nil = nil
  if capabilities ~= nil then general = capabilities.general end
  local offered: {string} = {}
  if general ~= nil then offered = general.positionEncodings or offered end
  for _, name in ipairs(offered) do
    if name == "utf-8" then s.encoding = "utf-8" end
  end
  local workspace: protocol.WorkspaceCapabilities | nil = nil
  if capabilities ~= nil then workspace = capabilities.workspace end
  local watched: protocol.DynamicRegistration | nil = nil
  if workspace ~= nil then watched = workspace.didChangeWatchedFiles end
  s.watch = watched ~= nil and watched.dynamicRegistration == true
  s.initialized = true
  return {
    capabilities = {
      positionEncoding = s.encoding,
      textDocumentSync = { openClose = true, change = 1, save = { includeText = false } },
      hoverProvider = true,
      documentFormattingProvider = true,
    },
    serverInfo = { name = "cosmic" },
  }
end

--- The request that registers the files the server watches: every
--- module a `require` may read.
local function watch_request(): string
  local params: protocol.RegistrationParams = { registrations = { {
    id = "cosmic.watch",
    method = "workspace/didChangeWatchedFiles",
    registerOptions = { watchers = { { globPattern = "**/*.tl" }, { globPattern = "**/*.tmpl" } } },
  } } }
  return '{"jsonrpc":"2.0","id":' .. tostring(WATCH_REQUEST) ..
    ',"method":"client/registerCapability","params":' .. assert(Json.encode(params)) .. "}"
end

--- The publication of `document`'s diagnostics.
local function published(s: Session, document: check.Document): string
  return protocol.publication(document.uri, check.diagnose(s.checker, document, s.encoding))
end

--- Stages the tree again, then publishes each open document's diagnostics
--- that changed: a document may require a file saved or changed on disk.
local function republished(s: Session): {string}
  check.stale(s.checker)
  local out: {string} = {}
  for _, document in pairs(s.documents) do
    local before = document.published
    local now = check.diagnose(s.checker, document, s.encoding)
    if before == nil or table.concat(now, ",") ~= table.concat(before, ",") then
      out[#out + 1] = protocol.publication(document.uri, now)
    end
  end
  return out
end

--- What `message` asks: each message to send in answer, encoded, in
--- order, a request's response among them.
local function handle(s: Session, message: protocol.Message): {string}
  local out: {string} = {}
  local method = message.method
  -- A response, to the registration of the files watched: JSON-RPC
  -- answers none.
  if method == nil then return out end
  local id = protocol.id_of(message)
  local is_request = id ~= "null"
  if method == "exit" then
    s.exit = 1
    if s.shut_down then s.exit = 0 end
    return out
  end
  if not s.initialized and method ~= "initialize" then
    if is_request then
      out[#out + 1] = protocol.failure(id, protocol.NOT_INITIALIZED, "initialize first")
    end
    return out
  end
  if s.shut_down then
    if is_request then
      out[#out + 1] = protocol.failure(id, protocol.INVALID_REQUEST, "the server is shut down")
    end
    return out
  end
  if method == "initialize" then
    local params, trouble = protocol.initialize_params(message.params)
    if s.initialized then
      out[#out + 1] = protocol.failure(id, protocol.INVALID_REQUEST, "initialize was already sent")
    elseif params == nil then
      out[#out + 1] = protocol.failure(id, protocol.INVALID_PARAMS, "initialize: " .. trouble)
    else
      out[#out + 1] = protocol.response(id, (assert(Json.encode(initialize(s, params)))))
    end
    return out
  end
  if method == "shutdown" then
    s.shut_down = true
    out[#out + 1] = protocol.response(id, "null")
    return out
  end
  if method == "initialized" then
    if s.watch then out[#out + 1] = watch_request() end
    return out
  end
  if method == "workspace/didChangeWatchedFiles" then
    return republished(s)
  end
  if method:sub(1, #"textDocument/") ~= "textDocument/" then
    if is_request then
      out[#out + 1] = protocol.failure(id, protocol.METHOD_NOT_FOUND, "no method " .. method)
    end
    return out
  end
  local params, trouble = protocol.document_params(message.params)
  if params == nil then
    if is_request then
      out[#out + 1] = protocol.failure(id, protocol.INVALID_PARAMS, method .. ": " .. trouble)
    end
    return out
  end
  if method == "textDocument/didOpen" then
    local document = document_of(s, params, params.textDocument.text)
    if document ~= nil then out[#out + 1] = published(s, document) end
  elseif method == "textDocument/didChange" then
    -- The server asked for whole texts, so the last is the document.
    local none: {protocol.ContentChange} = {}
    local changes = params.contentChanges or none
    local last = changes[#changes]
    if last ~= nil then
      local document = document_of(s, params, last.text)
      if document ~= nil then out[#out + 1] = published(s, document) end
    end
  elseif method == "textDocument/didSave" then
    for _, publication in ipairs(republished(s)) do out[#out + 1] = publication end
  elseif method == "textDocument/didClose" then
    local document = document_of(s, params)
    if document ~= nil then
      s.documents[document.uri] = nil
      check.closed(s.checker, document)
      local cleared: {string} = {}
      out[#out + 1] = protocol.publication(document.uri, cleared)
    end
  elseif method == "textDocument/hover" then
    local found = hover(s, params)
    local result = "null"
    if found ~= nil then result = assert(Json.encode(found)) end
    out[#out + 1] = protocol.response(id, result)
  elseif method == "textDocument/formatting" then
    local edits, why = formatting(s, params)
    if edits == nil then
      out[#out + 1] = protocol.failure(id, protocol.REQUEST_FAILED, why)
    else
      out[#out + 1] = protocol.response(id, edits)
    end
  elseif is_request then
    out[#out + 1] = protocol.failure(id, protocol.METHOD_NOT_FOUND, "no method " .. method)
  end
  return out
end

--- The messages to send in answer to the message `body`, encoded.
local function answers(s: Session, body: string): {string}
  local message, refusal = protocol.message_of(body)
  if message == nil then return { refusal } end
  -- A fault answering one message fails that message, not the session.
  local ok, handled = pcall(handle, s, message)
  if ok then return handled end
  s.err("cosmic: lsp: " .. tostring(handled))
  local id = protocol.id_of(message)
  if id == "null" or message.method == nil then return {} end
  return { protocol.failure(id, protocol.INTERNAL_ERROR, tostring(handled)) }
end

--- The document the message `body` sends a whole new text of, or nil
--- when it is no `textDocument/didChange`.
local function changed_uri(body: string): string | nil
  local message, _ = protocol.message_of(body)
  if message == nil or message.method ~= "textDocument/didChange" then return nil end
  local params, _ = protocol.document_params(message.params)
  if params == nil then return nil end
  return params.textDocument.uri
end

--- A message [`session.serve`] read ahead and has yet to answer.
local record Ahead
  body: string | nil
end

--- The next message to answer: the one read ahead, else the next of
--- `frames`.
local function next_body(frames: protocol.Frames, ahead: Ahead): string | nil, string
  local body = ahead.body
  if body ~= nil then
    ahead.body = nil
    return body, ""
  end
  return frames:next()
end

--- `body`, or, when it changes a document and the bytes read already hold
--- more changes of the same document right after it, the last of them:
--- each holds the whole text, so only the last is checked. What is read
--- past them waits in `ahead`.
local function latest(frames: protocol.Frames, ahead: Ahead, body: string): string
  local uri = changed_uri(body)
  if uri == nil then return body end
  local last = body
  while true do
    local after = frames:buffered()
    if after == nil then return last end
    if changed_uri(after) ~= uri then
      ahead.body = after
      return last
    end
    last = after
  end
end

--- [`session.serve`]'s loop: its exit status.
local function served(s: Session, frames: protocol.Frames,
                      write: function(text: string): boolean, string): integer
  local ahead: Ahead = { body = nil }
  while true do
    local exit = s.exit
    if exit ~= nil then return exit end
    local body, trouble = next_body(frames, ahead)
    if body == nil then
      if trouble ~= "" then
        s.err("cosmic: lsp: " .. trouble)
        return 1
      end
      if s.shut_down then return 0 end
      return 1
    end
    for _, answer in ipairs(answers(s, latest(frames, ahead, body))) do
      local sent, why = write(protocol.frame(answer))
      if not sent then
        s.err("cosmic: lsp: " .. why)
        return 1
      end
    end
  end
end

--- Serves `s` the messages `reader` holds, writing each answer through
--- `write`, until `exit` or the end of the stream, then lets go of the
--- databases the session opened. Answers the exit status: 0 after
--- `shutdown`, at `exit` or the stream's end, and 1 at an `exit` or an
--- end with no `shutdown` before it, a stream that breaks or a write that
--- fails.
function session.serve(s: Session, reader: Stream.Reader,
                       write: function(text: string): boolean, string): integer
  local code = served(s, protocol.frames(reader), write)
  local sources = s.sources
  if sources ~= nil then
    for _, db in ipairs(sources.opened) do
      local _, _ = db:close()
    end
  end
  s.sources, s.view, s.view_trouble = nil, nil, nil
  check.close(s.checker)
  return code
end

return session

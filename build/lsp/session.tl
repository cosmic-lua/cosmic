--- One editor's session of `cosmic lsp` ([`build.lsp`]): what it opened,
--- what it was told, and its answer to each message it sends, as the
--- protocol's lifecycle holds them ([`build.lsp.protocol`]).
---
--- What it answers:
---
--- - Diagnostics, published as a document is opened, changed, saved or
---   closed, as [`build.lsp.check`] finds them, with those of the other
---   open documents that may change with it ([`build.lsp.publish`]).
--- - Hover: the docs of the symbol under the cursor ([`build.lsp.hover`]).
--- - Formatting: the whole document as `cosmic fix` writes it.
---
--- The open documents that require one whose text changed are checked
--- again once its own check is published, where what it serves them
--- changed, one at a time, while no other message waits
--- ([`build.lsp.dependents`]). A root no build was started in has its
--- documents checked against nothing: none is published, and the person
--- is shown, once, what to run there ([`source.outside`]). Where the editor
--- takes a registration of the files to watch, the session registers
--- every `.tl` and `.tmpl` file at `initialized`.
---
--- A message with no method answers a request of the session's own, and
--- is never answered, whatever its id.

local Json = require("cosmic.json")
local Sqlite = require("cosmic.sqlite")
local Stream = require("cosmic.stream")
local bare = require("build.bare")
local check = require("build.lsp.check")
local dependents = require("build.lsp.dependents")
local hover = require("build.lsp.hover")
local protocol = require("build.lsp.protocol")
local publish = require("build.lsp.publish")
local source = require("build.lsp.source")
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
    docs: hover.Docs
    --- The dependents yet to be checked again.
    queue: dependents.Queue
    --- Whether the person was shown that the root is no project.
    told_outside: boolean
  end
end

local type Session = session.State

--- The id of the one request the server makes, which registers the
--- files it watches: its answer is read as any response is, and dropped.
local WATCH_REQUEST <const> = 1

--- The databases a message's hint looks a name up in: the docs
--- databases of the session `held` holds.
local function hints_of(held: {Session}): importer.Hints
  return function(): {Sqlite.Handle}, {boolean}
    local s = held[1]
    if s == nil then return {}, {} end
    local sources = hover.sources(s.docs)
    return sources.handles, sources.public
  end
end

--- A session's checker and docs at `root`.
local function checked_at(s: Session, root: string)
  s.root = root
  s.checker = check.new(root, s.err, hints_of({ s }))
  s.docs = hover.new(root, s.checker.source, s.store, s.err)
end

--- A new session, before `initialize`, answering below `root`.
function session.new(root: string, options?: session.Options): Session
  local given: session.Options = options or {}
  local err = given.err or bare.err
  local held: {Session} = {}
  local checker = check.new(root, err, hints_of(held))
  local made: Session = {
    root = root,
    encoding = "utf-16",
    initialized = false,
    shut_down = false,
    exit = nil,
    documents = {},
    err = err,
    checker = checker,
    watch = false,
    store = given.store,
    docs = hover.new(root, checker.source, given.store, err),
    queue = dependents.new(),
    told_outside = false,
  }
  held[1] = made
  return made
end

--- The document `params` names, opened as `text` when it is given.
local function document_of(s: Session, params: protocol.DocumentParams, text?: string): check.Document | nil
  local uri = params.textDocument.uri
  local document = s.documents[uri]
  if document == nil and text ~= nil then
    local path = protocol.path_of(uri)
    local name: string | nil = nil
    if path ~= nil then name = protocol.below(path, s.root) end
    document = check.document(uri, name or path or uri, text, name == nil)
    s.documents[uri] = document
    check.opened(s.checker, document)
  elseif document ~= nil and text ~= nil then
    check.set_text(document, text)
  end
  return document
end

--- The hover for `params`, or nil when nothing is documented there.
local function hovered(s: Session, params: protocol.DocumentParams): protocol.Hover | nil
  local document = document_of(s, params)
  local where = params.position
  if document == nil or where == nil then return nil end
  return hover.at(s.docs, document.text, where, s.encoding)
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
    check.close(s.checker)
    hover.close(s.docs)
    checked_at(s, root)
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

--- What [`build.lsp.publish`] reads of `s`.
local function open_of(s: Session): publish.Open
  return { checker = s.checker, documents = s.documents, encoding = s.encoding }
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
    return publish.restaged(open_of(s))
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
    if document ~= nil then
      for _, publication in ipairs(publish.with(open_of(s), document)) do
        out[#out + 1] = publication
      end
      dependents.opened(s.queue, document)
    end
  elseif method == "textDocument/didChange" then
    -- The server asked for whole texts, so the last is the document.
    local none: {protocol.ContentChange} = {}
    local changes = params.contentChanges or none
    local last = changes[#changes]
    if last ~= nil then
      local document = document_of(s, params, last.text)
      if document ~= nil then
        for _, publication in ipairs(publish.with(open_of(s), document)) do
          out[#out + 1] = publication
        end
        dependents.changed(s.queue, document)
      end
    end
  elseif method == "textDocument/didSave" then
    for _, publication in ipairs(publish.restaged(open_of(s))) do out[#out + 1] = publication end
  elseif method == "textDocument/didClose" then
    local document = document_of(s, params)
    if document ~= nil then
      dependents.closed(s.queue, s.checker, document)
      s.documents[document.uri] = nil
      for _, publication in ipairs(publish.closed(open_of(s), document)) do
        out[#out + 1] = publication
      end
    end
  elseif method == "textDocument/hover" then
    local found = hovered(s, params)
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
  if ok then
    if not s.told_outside and source.outside(s.checker.source) then
      s.told_outside = true
      handled[#handled + 1] = protocol.shown(3, s.root .. " is not built yet, so its modules " ..
          "are not found and nothing is checked: run `cosmic test` (or `cosmic build`) there")
    end
    return handled
  end
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

--- Whether a message waits: read already, or arrived to be read.
local function waiting(frames: protocol.Frames, ahead: Ahead): boolean
  return ahead.body ~= nil or frames:waiting()
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
    -- The answers go out before the dependents of a changed document are
    -- checked, and each dependent's as it is checked: the editor shows
    -- them without waiting for those after.
    local sending = answers(s, latest(frames, ahead, body))
    local more = true
    while more do
      for _, answer in ipairs(sending) do
        local sent, why = write(protocol.frame(answer))
        if not sent then
          s.err("cosmic: lsp: " .. why)
          return 1
        end
      end
      local ok, step = pcall(dependents.next, s.queue, open_of(s), function(): boolean
        return waiting(frames, ahead)
      end)
      if ok then
        sending, more = step.publications, step.checked
      else
        s.err("cosmic: lsp: " .. tostring(step))
        sending, more = {}, true
      end
    end
  end
end

--- Serves `s` the messages `reader` holds, writing each answer through
--- `write`, and asking `poll`, when given, what has arrived of them
--- without waiting, between the dependents it checks, until `exit` or
--- the end of the stream, then lets go of the databases the session
--- opened. Answers the exit status: 0 after `shutdown`, at `exit` or the
--- stream's end, and 1 at an `exit` or an end with no `shutdown` before
--- it, a stream that breaks or a write that fails.
function session.serve(s: Session, reader: Stream.Reader,
                       write: function(text: string): boolean, string, poll?: protocol.Poll): integer
  local code = served(s, protocol.frames(reader, poll), write)
  hover.close(s.docs)
  check.close(s.checker)
  return code
end

return session

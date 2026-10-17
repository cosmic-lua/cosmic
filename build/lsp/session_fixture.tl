--- What the tests of `cosmic lsp`'s sessions share ([`build.lsp.session`]):
--- the messages an editor sends, a session served them, and what the tests
--- read of the messages it sends back.

local Json = require("cosmic.json")
local Shape = require("cosmic.shape")
local Sqlite = require("cosmic.sqlite")
local Stream = require("cosmic.stream")
local protocol = require("build.lsp.protocol")
local session = require("build.lsp.session")

local record session_fixture
  record Failed
    code: integer
    message: string
  end

  record Place
    line: integer
    character: integer
  end

  record Diagnostic
    --- Its `start` and its `end`, a name no record field can have.
    range: {string: Place}
    message: string
    code: string | nil
  end

  --- A publication's document and diagnostics.
  record Publication
    uri: string
    diagnostics: {Diagnostic}
  end

  --- Any message the server sends, but for its `result` and `params`.
  record Sent
    id: integer | nil
    method: string | nil
    error: Failed | nil
  end

  --- A publication of diagnostics.
  record PublishSent
    params: Publication
  end

  record Sync
    change: integer
  end

  record Capabilities
    positionEncoding: string
    textDocumentSync: Sync
  end

  record Info
    name: string
  end

  record Initialized
    capabilities: Capabilities
    serverInfo: Info
  end

  record InitializeSent
    result: Initialized
  end

  --- What a session answered: its exit status, the body of each message
  --- it sent, and its complaints.
  record Ran
    code: integer
    sent: {string}
    err: string
  end

  SHUTDOWN: string
  EXIT: string
end

local type Diagnostic = session_fixture.Diagnostic
local type Ran = session_fixture.Ran

local SENT <const> = Shape.record_of("session_fixture.Sent")
local PUBLISH_SENT <const> = Shape.record_of("session_fixture.PublishSent")
local INITIALIZE_SENT <const> = Shape.record_of("session_fixture.InitializeSent")

session_fixture.SHUTDOWN = '{"jsonrpc":"2.0","id":99,"method":"shutdown"}'
session_fixture.EXIT = '{"jsonrpc":"2.0","method":"exit"}'

--- `messages`, each JSON text, framed as an editor sends them.
function session_fixture.framed(messages: {string}): string
  local out: {string} = {}
  for _, message in ipairs(messages) do out[#out + 1] = protocol.frame(message) end
  return table.concat(out)
end

--- Each message body `bytes` holds.
function session_fixture.bodies(bytes: string): {string}
  local frames = protocol.frames(Stream.from_string(bytes))
  local out: {string} = {}
  while true do
    local body, trouble = frames:next()
    if body == nil then
      assert(trouble == "", trouble)
      return out
    end
    out[#out + 1] = body
  end
end

--- What a session at `root` answers `messages` with, reading docs from
--- `store` when given.
function session_fixture.served(root: string, messages: {string}, store?: {Sqlite.Handle}): Ran
  local wrote: {string} = {}
  local complaints: {string} = {}
  local s = session.new(root, {
    err = function(line: string) complaints[#complaints + 1] = line end,
    store = store,
  })
  local code = session.serve(s, Stream.from_string(session_fixture.framed(messages)),
    function(text: string): boolean, string
      wrote[#wrote + 1] = text
      return true, ""
    end)
  return { code = code, sent = session_fixture.bodies(table.concat(wrote)),
    err = table.concat(complaints, "\n") }
end

--- A session at `root` served one batch of messages after another, as an
--- editor sends them with time between: what it sent, all told.
function session_fixture.serving(root: string): function(messages: {string}): Ran
  local wrote: {string} = {}
  local complaints: {string} = {}
  local s = session.new(root, {
    err = function(line: string) complaints[#complaints + 1] = line end,
    store = nil,
  })
  return function(messages: {string}): Ran
    local code = session.serve(s, Stream.from_string(session_fixture.framed(messages)),
      function(text: string): boolean, string
        wrote[#wrote + 1] = text
        return true, ""
      end)
    return { code = code, sent = session_fixture.bodies(table.concat(wrote)),
      err = table.concat(complaints, "\n") }
  end
end

--- What the tests read of the message `body`.
function session_fixture.sent(body: string): session_fixture.Sent
  return (assert(SENT:decode_into(body)))
end

--- What the tests read of an answer to `initialize`.
function session_fixture.initialized(body: string): session_fixture.Initialized
  return (assert(INITIALIZE_SENT:decode_into(body))).result
end

--- The body of the message of `ran` answering request `id`.
function session_fixture.answer(ran: Ran, id: integer): string
  for _, body in ipairs(ran.sent) do
    local sent = session_fixture.sent(body)
    -- A request the server makes has a method; an answer has none.
    if sent.id == id and sent.method == nil then return body end
  end
  error("no answer to request " .. tostring(id) .. ": " .. table.concat(ran.sent, "\n") .. ran.err)
end

--- The code of the error the message `body` answers with.
function session_fixture.failed(body: string): integer
  local why = assert(session_fixture.sent(body).error, body)
  return why.code
end

--- Each publication `ran` sent, in order.
function session_fixture.publications(ran: Ran): {session_fixture.Publication}
  local out: {session_fixture.Publication} = {}
  for _, body in ipairs(ran.sent) do
    if session_fixture.sent(body).method == "textDocument/publishDiagnostics" then
      out[#out + 1] = assert(PUBLISH_SENT:decode_into(body)).params
    end
  end
  return out
end

--- The diagnostics of each publication `ran` sent, in order.
function session_fixture.published(ran: Ran): {{Diagnostic}}
  local out: {{Diagnostic}} = {}
  for _, publication in ipairs(session_fixture.publications(ran)) do
    out[#out + 1] = publication.diagnostics
  end
  return out
end

--- The messages of `diagnostics`, one a line.
function session_fixture.messages_of(diagnostics: {Diagnostic}): string
  local out: {string} = {}
  for _, diagnostic in ipairs(diagnostics) do out[#out + 1] = diagnostic.message end
  return table.concat(out, "\n")
end

--- The diagnostics of publication `n` of those `ran` sent.
function session_fixture.nth(ran: Ran, n: integer): {Diagnostic}
  return (assert(session_fixture.published(ran)[n], "no publication " .. tostring(n)))
end

--- How many diagnostics each publication `ran` sent holds, in order:
--- "1,0" for one then none.
function session_fixture.counts(ran: Ran): string
  local out: {string} = {}
  for _, diagnostics in ipairs(session_fixture.published(ran)) do
    out[#out + 1] = tostring(#diagnostics)
  end
  return table.concat(out, ",")
end

--- The one diagnostic of `diagnostics`.
function session_fixture.only(diagnostics: {Diagnostic}): Diagnostic
  assert(#diagnostics == 1, session_fixture.messages_of(diagnostics))
  return assert(diagnostics[1])
end

--- Where `diagnostic` starts or ends, as `side` ("start" or "end") says.
function session_fixture.edge(diagnostic: Diagnostic, side: string): session_fixture.Place
  return assert(diagnostic.range[side])
end

--- The methods of the requests of its own a session sent.
function session_fixture.requests(ran: Ran): {string}
  local out: {string} = {}
  for _, body in ipairs(ran.sent) do
    local sent = session_fixture.sent(body)
    local method = sent.method
    if method ~= nil and sent.id ~= nil then out[#out + 1] = method end
  end
  return out
end

--- The `file:` URI of `name` below `root`, encoded.
local function uri(root: string, name: string): string
  return Json.quote("file://" .. root .. "/" .. name)
end

function session_fixture.initialize(root: string, capabilities?: string): string
  return '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"rootUri":' ..
    Json.quote("file://" .. root) .. ',"capabilities":' .. (capabilities or "{}") .. "}}"
end

function session_fixture.open(root: string, name: string, text: string): string
  return '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":' ..
    uri(root, name) .. ',"languageId":"teal","version":1,"text":' .. Json.quote(text) .. "}}}"
end

function session_fixture.change(root: string, name: string, text: string): string
  return '{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":' ..
    uri(root, name) .. ',"version":2},"contentChanges":[{"text":' .. Json.quote(text) .. "}]}}"
end

--- A change of the document `name` that sends each of `texts` whole.
function session_fixture.changes(root: string, name: string, texts: {string}): string
  local quoted: {string} = {}
  for _, text in ipairs(texts) do quoted[#quoted + 1] = '{"text":' .. Json.quote(text) .. "}" end
  return '{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":' ..
    uri(root, name) .. ',"version":2},"contentChanges":[' .. table.concat(quoted, ",") .. "]}}"
end

function session_fixture.close(root: string, name: string): string
  return '{"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":' ..
    uri(root, name) .. "}}}"
end

function session_fixture.save(root: string, name: string): string
  return '{"jsonrpc":"2.0","method":"textDocument/didSave","params":{"textDocument":{"uri":' ..
    uri(root, name) .. "}}}"
end

--- The editor's word that the file `name` changed on disk.
function session_fixture.changed_on_disk(root: string, name: string): string
  return '{"jsonrpc":"2.0","method":"workspace/didChangeWatchedFiles","params":{"changes":[{"uri":' ..
    uri(root, name) .. ',"type":2}]}}'
end

--- A request `id` of `method` about the document `name` at a position.
function session_fixture.at(id: integer, method: string, root: string, name: string, line: integer,
                            character: integer): string
  return '{"jsonrpc":"2.0","id":' .. tostring(id) .. ',"method":"' .. method ..
    '","params":{"textDocument":{"uri":' .. uri(root, name) .. '},"position":{"line":' ..
    tostring(line) .. ',"character":' .. tostring(character) .. "}}}"
end

function session_fixture.format(id: integer, root: string, name: string): string
  return '{"jsonrpc":"2.0","id":' .. tostring(id) .. ',"method":"textDocument/formatting",' ..
    '"params":{"textDocument":{"uri":' .. uri(root, name) .. '},"options":{"tabSize":2,"insertSpaces":true}}}'
end

return session_fixture

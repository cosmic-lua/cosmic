--- `cosmic lsp` (build/lsp.tl): its framing, a session's answers to an
--- editor's messages, and one session over a loopback connection.

local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Shape = require("cosmic.shape")
local Sqlite = require("cosmic.sqlite")
local Stream = require("cosmic.stream")
local Test = require("cosmic.test")
local docs_fixture = require("build.docs_fixture")
local lsp = require("build.lsp")

Test.policy{ loopback = { "127.0.0.1" } }

--- A Reader that answers one byte a read, so a message arrives split at
--- every place it can be.
local record Trickle is Stream.Reader
  data: string
  at: integer
  read: function(Trickle, max_bytes?: integer): string | nil, string
  close: function(Trickle): boolean, string
end

local trickle_mt: metatable<Trickle> = { __index = Trickle }

function Trickle:read(_max_bytes?: integer): string | nil, string
  if self.at > #self.data then return nil, "" end
  self.at = self.at + 1
  return self.data:sub(self.at - 1, self.at - 1), ""
end

function Trickle:close(): boolean, string
  return true, ""
end

local function trickle(data: string): Stream.Reader
  local r: Trickle = setmetatable({ data = data, at = 1 }, trickle_mt)
  return r
end

-- What the tests read of the messages the server sends.

local record Failed
  code: integer
  message: string
end

local record Place
  line: integer
  character: integer
end

local record Span
  start: Place
end

local record Diagnostic
  range: Span
  message: string
end

local record Published
  uri: string
  diagnostics: {Diagnostic}
end

--- Any message the server sends, but for its `result`.
local record Sent
  id: integer | nil
  method: string | nil
  error: Failed | nil
  params: Published | nil
end

local SENT <const> = Shape.record_of("Sent")

local record Sync
  change: integer
end

local record Capabilities
  positionEncoding: string
  textDocumentSync: Sync
end

local record Info
  name: string
end

local record Initialized
  capabilities: Capabilities
  serverInfo: Info
end

local record InitializeSent
  result: Initialized
end

local INITIALIZE_SENT <const> = Shape.record_of("InitializeSent")

local record Markup
  value: string
end

local record Hovered
  contents: Markup
end

local record HoverSent
  result: Hovered | nil
end

local HOVER_SENT <const> = Shape.record_of("HoverSent")

local record Edit
  newText: string
end

local record FormatSent
  result: {Edit}
end

local FORMAT_SENT <const> = Shape.record_of("FormatSent")

--- `messages`, each JSON text, framed as an editor sends them.
local function framed(messages: {string}): string
  local out: {string} = {}
  for _, message in ipairs(messages) do out[#out + 1] = lsp.frame(message) end
  return table.concat(out)
end

--- Each message body `bytes` holds.
local function bodies(bytes: string): {string}
  local frames = lsp.frames(Stream.from_string(bytes))
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

--- What a session answered: its exit status, the body of each message it
--- sent, and its complaints.
local record Ran
  code: integer
  sent: {string}
  err: string
end

--- What a session at `root` answers `messages` with, reading docs from
--- `store` when given.
local function served(root: string, messages: {string}, store?: {Sqlite.Handle}): Ran
  local wrote: {string} = {}
  local complaints: {string} = {}
  local session = lsp.new(root, {
    err = function(line: string) complaints[#complaints + 1] = line end,
    store = store,
  })
  local code = lsp.serve(session, Stream.from_string(framed(messages)), function(text: string): boolean, string
    wrote[#wrote + 1] = text
    return true, ""
  end)
  return { code = code, sent = bodies(table.concat(wrote)), err = table.concat(complaints, "\n") }
end

--- The body of the message of `ran` answering request `id`.
local function answer(ran: Ran, id: integer): string
  for _, body in ipairs(ran.sent) do
    local sent = assert(SENT:decode_into(body))
    if sent.id == id then return body end
  end
  error("no answer to request " .. tostring(id) .. ": " .. table.concat(ran.sent, "\n") .. ran.err)
end

--- The code of the error the message `body` answers with.
local function failed(body: string): integer
  local sent = assert(SENT:decode_into(body))
  local why = assert(sent.error, body)
  return why.code
end

--- The diagnostics of each publication `ran` sent, in order.
local function published(ran: Ran): {{Diagnostic}}
  local out: {{Diagnostic}} = {}
  for _, body in ipairs(ran.sent) do
    local sent = assert(SENT:decode_into(body))
    local params = sent.params
    if sent.method == "textDocument/publishDiagnostics" and params ~= nil then
      out[#out + 1] = params.diagnostics
    end
  end
  return out
end

local function uri(root: string, name: string): string
  return Json.quote("file://" .. root .. "/" .. name)
end

local function initialize(root: string, capabilities?: string): string
  return '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"rootUri":' ..
    Json.quote("file://" .. root) .. ',"capabilities":' .. (capabilities or "{}") .. "}}"
end

local function open(root: string, name: string, text: string): string
  return '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":' ..
    uri(root, name) .. ',"languageId":"teal","version":1,"text":' .. Json.quote(text) .. "}}}"
end

local function change(root: string, name: string, text: string): string
  return '{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":' ..
    uri(root, name) .. ',"version":2},"contentChanges":[{"text":' .. Json.quote(text) .. "}]}}"
end

local function close(root: string, name: string): string
  return '{"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":' ..
    uri(root, name) .. "}}}"
end

--- A request `id` of `method` about the document `name` at a position.
local function at(id: integer, method: string, root: string, name: string, line: integer, character: integer): string
  return '{"jsonrpc":"2.0","id":' .. tostring(id) .. ',"method":"' .. method ..
    '","params":{"textDocument":{"uri":' .. uri(root, name) .. '},"position":{"line":' ..
    tostring(line) .. ',"character":' .. tostring(character) .. "}}}"
end

local function format(id: integer, root: string, name: string): string
  return '{"jsonrpc":"2.0","id":' .. tostring(id) .. ',"method":"textDocument/formatting",' ..
    '"params":{"textDocument":{"uri":' .. uri(root, name) .. '},"options":{"tabSize":2,"insertSpaces":true}}}'
end

local SHUTDOWN <const> = '{"jsonrpc":"2.0","id":99,"method":"shutdown"}'
local EXIT <const> = '{"jsonrpc":"2.0","method":"exit"}'

local function test_frames_split_at_every_byte()
  local bytes = framed({ '{"a":1}', '{"b":"ü"}' }) .. "Content-Length: 2\r\ncontent-type: x\r\n\r\n{}"
  local frames = lsp.frames(trickle(bytes))
  assert(frames:next() == '{"a":1}')
  assert(frames:next() == '{"b":"ü"}')
  assert(frames:next() == "{}")
  local body, trouble = frames:next()
  assert(body == nil and trouble == "", trouble)
end

local function test_frames_refuse_what_is_no_message()
  local cases: {string: string} = {
    ["Content-Type: x\r\n\r\n{}"] = "no Content-Length",
    ["Content-Length: 1x\r\n\r\n{}"] = "no length",
    ["Content-Length: 10\r\n\r\n{}"] = "ended inside a message",
    ["Content-Length: 2\r\n"] = "ended inside a header",
  }
  for bytes, said in pairs(cases) do
    local body, trouble = lsp.frames(Stream.from_string(bytes)):next()
    assert(body == nil and trouble:find(said, 1, true) ~= nil, bytes .. ": " .. trouble)
  end
end

local function test_a_type_error_is_published_where_it_is()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  local text = 'local s = "é"\nlocal n: integer = s\nreturn n\n'
  local ran = served(root, { initialize(root), open(root, "main.tl", text), SHUTDOWN, EXIT })
  assert(ran.code == 0, ran.err)
  local init = assert(INITIALIZE_SENT:decode_into(answer(ran, 1)))
  assert(init.result.capabilities.positionEncoding == "utf-16")
  assert(init.result.capabilities.textDocumentSync.change == 1)
  local diagnostics = published(ran)[1]
  assert(#diagnostics == 1, table.concat(ran.sent, "\n"))
  assert(diagnostics[1].message:find("got string, expected integer", 1, true) ~= nil, diagnostics[1].message)
  assert(diagnostics[1].range.start.line == 1)
  assert(diagnostics[1].range.start.character == 19)
  assert(answer(ran, 99):find('"result":null', 1, true) ~= nil)
end

local function test_a_column_counts_utf16_units_or_bytes_as_negotiated()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  -- "é" is two bytes and one UTF-16 unit; the error is at `nope`.
  local text = 'local _ = { "é", nope }\n'
  local wide = served(root, { initialize(root), open(root, "main.tl", text) })
  assert(published(wide)[1][1].range.start.character == 17)
  local narrow = served(root, { initialize(root, '{"general":{"positionEncodings":["utf-8","utf-16"]}}'),
    open(root, "main.tl", text) })
  local init = assert(INITIALIZE_SENT:decode_into(answer(narrow, 1)))
  assert(init.result.capabilities.positionEncoding == "utf-8")
  assert(published(narrow)[1][1].range.start.character == 18)
end

local function test_a_require_reads_an_open_document_before_the_disk()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/shapes.tl", "return { sides = 3 }\n"))
  local main = 'local shapes = require("lib.shapes")\nlocal n: integer = shapes.sides\nreturn n\n'
  local runs = published(served(root, {
    initialize(root),
    open(root, "main.tl", main),
    open(root, "lib/shapes.tl", 'return { sides = "three" }\n'),
    change(root, "main.tl", main),
    change(root, "lib/shapes.tl", "return { sides = 4 }\n"),
    change(root, "main.tl", main),
  }))
  assert(#runs == 5)
  assert(#runs[1] == 0, "the file on disk types")
  assert(#runs[3] == 1, "the open document's string is what main reads")
  assert(#runs[5] == 0, "the document's change is read again")
end

local function test_a_change_that_fixes_the_error_clears_it()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  local runs = published(served(root, {
    initialize(root),
    open(root, "main.tl", "local n: integer = 'x'\nreturn n\n"),
    change(root, "main.tl", "local n: integer = 1\nreturn n\n"),
    close(root, "main.tl"),
  }))
  assert(#runs == 3 and #runs[1] == 1 and #runs[2] == 0 and #runs[3] == 0)
end

local function test_hover_shows_the_docs_of_a_required_symbol()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  local store = docs_fixture.database(root, {
    ["cosmic/fs.tl"] = "--- Files.\nlocal Fs = {}\n--- Reads the whole of a file.\n" ..
      "function Fs.read(path: string): string return path end\nreturn Fs\n",
  })
  local text = 'local Fs = require("cosmic.fs")\nlocal _ = Fs.read\n'
  local ran = served(root, { initialize(root), open(root, "main.tl", text),
    at(2, "textDocument/hover", root, "main.tl", 1, 14),
    at(3, "textDocument/hover", root, "main.tl", 2, 0),
  }, { store })
  local shown = assert(HOVER_SENT:decode_into(answer(ran, 2)))
  local hovered = assert(shown.result, ran.err)
  local value = hovered.contents.value
  assert(value:find("cosmic.fs.read", 1, true) ~= nil and value:find("Reads the whole of a file.", 1, true) ~= nil,
    value)
  local nothing = assert(HOVER_SENT:decode_into(answer(ran, 3)))
  assert(nothing.result == nil)
end

local function test_formatting_answers_the_fixed_text()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  local ran = served(root, { initialize(root), open(root, "main.tl", "local   n =  1\nreturn n\n"),
    format(2, root, "main.tl"), open(root, "bad.tl", "local = \n"), format(3, root, "bad.tl") })
  local body = answer(ran, 2)
  local formatted = assert(FORMAT_SENT:decode_into(body))
  assert(#formatted.result == 1)
  assert(formatted.result[1].newText == "local n = 1\nreturn n\n", formatted.result[1].newText)
  assert(body:find('"end":{"character":0,"line":2}', 1, true) ~= nil, body)
  assert(failed(answer(ran, 3)) == -32803)
end

local function test_the_lifecycle_is_held_to()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  local early = served(root, { at(5, "textDocument/hover", root, "main.tl", 0, 0), EXIT })
  assert(failed(answer(early, 5)) == -32002)
  assert(early.code == 1, "exit without shutdown")
  local unknown = served(root, { initialize(root), '{"jsonrpc":"2.0","id":6,"method":"nosuch"}',
    '{"jsonrpc":"2.0","method":"$/nosuch"}', "{not json", SHUTDOWN,
    at(7, "textDocument/hover", root, "main.tl", 0, 0) })
  assert(failed(answer(unknown, 6)) == -32601)
  assert(failed(answer(unknown, 7)) == -32600)
  assert(table.concat(unknown.sent, "\n"):find('"code":-32700', 1, true) ~= nil)
  assert(unknown.code == 0, "the stream ending after shutdown")
  local broken = served(root, { initialize(root) })
  assert(broken.code == 1, "the stream ending before shutdown")
end

--- What the loopback test's two tasks leave each other.
local record Exchange
  code: integer
  sent: string
end

local function test_a_session_over_a_loopback_connection()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  local listener <close> = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
  local address = listener.address
  local exchange: Exchange = { code = -1, sent = "" }
  Poll.run(function()
    Poll.spawn(function()
      local conn <close> = assert(listener:accept(Clock.seconds(10)))
      exchange.code = lsp.serve(lsp.new(root), conn, function(text: string): boolean, string
        return conn:write(text)
      end)
    end)
    local client <close> = assert(Net.connect(address, { timeout_ns = Clock.seconds(10) }))
    assert(client:write(framed({ initialize(root), SHUTDOWN, EXIT })))
    assert(client:shutdown("write"))
    exchange.sent = assert(Stream.read_all(client))
  end)
  assert(exchange.code == 0)
  local init = assert(INITIALIZE_SENT:decode_into(bodies(exchange.sent)[1]))
  assert(init.result.serverInfo.name == "cosmic")
end

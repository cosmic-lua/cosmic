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

--- How far a [`trickle`] has read.
local record Read
  at: integer
end

--- A stream's `read` that answers one byte of `data` a call, so a
--- message arrives split at every place it can be.
local function trickle(data: string): function(): string | nil, string
  local read: Read = { at = 1 }
  return function(): string | nil, string
    if read.at > #data then return nil, "" end
    read.at = read.at + 1
    return data:sub(read.at - 1, read.at - 1), ""
  end
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

local record Diagnostic
  --- Its `start` and its `end`, a name no record field can have.
  range: {string: Place}
  message: string
end

local record Published
  uri: string
  diagnostics: {Diagnostic}
end

--- Each publication's document and diagnostics, in order.
local record Publication
  uri: string
  diagnostics: {Diagnostic}
end

--- Any message the server sends, but for its `result` and `params`.
local record Sent
  id: integer | nil
  method: string | nil
  error: Failed | nil
end

local SENT <const> = Shape.record_of("Sent")

--- A publication of diagnostics.
local record PublishSent
  params: Published
end

local PUBLISH_SENT <const> = Shape.record_of("PublishSent")

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
    -- A request the server makes has a method; an answer has none.
    if sent.id == id and sent.method == nil then return body end
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
    if sent.method == "textDocument/publishDiagnostics" then
      out[#out + 1] = assert(PUBLISH_SENT:decode_into(body)).params.diagnostics
    end
  end
  return out
end

--- Each publication `ran` sent, in order.
local function publications(ran: Ran): {Publication}
  local out: {Publication} = {}
  for _, body in ipairs(ran.sent) do
    local sent = assert(SENT:decode_into(body))
    if sent.method == "textDocument/publishDiagnostics" then
      local params = assert(PUBLISH_SENT:decode_into(body)).params
      out[#out + 1] = { uri = params.uri, diagnostics = params.diagnostics }
    end
  end
  return out
end

--- The messages of `diagnostics`, one a line.
local function messages_of(diagnostics: {Diagnostic}): string
  local out: {string} = {}
  for _, diagnostic in ipairs(diagnostics) do out[#out + 1] = diagnostic.message end
  return table.concat(out, "\n")
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

--- A change of the document `name` that sends each of `texts` whole.
local function changes(root: string, name: string, texts: {string}): string
  local quoted: {string} = {}
  for _, text in ipairs(texts) do quoted[#quoted + 1] = '{"text":' .. Json.quote(text) .. "}" end
  return '{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":' ..
    uri(root, name) .. ',"version":2},"contentChanges":[' .. table.concat(quoted, ",") .. "]}}"
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
  local frames = lsp.frames_of(trickle(bytes))
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
  local start, finish = diagnostics[1].range["start"], diagnostics[1].range["end"]
  assert(start.line == 1 and start.character == 19)
  -- The range covers the word, `s`, not the place alone.
  assert(finish.line == 1 and finish.character == 20)
  assert(answer(ran, 99):find('"result":null', 1, true) ~= nil)
end

local function test_a_column_counts_utf16_units_or_bytes_as_negotiated()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  -- "é" is two bytes and one UTF-16 unit; the error is at `nope`.
  local text = 'local _ = { "é", nope }\n'
  local wide = served(root, { initialize(root), open(root, "main.tl", text) })
  local found = published(wide)[1][1].range
  assert(found["start"].character == 17)
  assert(found["end"].character == 21, "the end is past the start, by the word `nope`")
  local narrow = served(root, { initialize(root, '{"general":{"positionEncodings":["utf-8","utf-16"]}}'),
    open(root, "main.tl", text) })
  local init = assert(INITIALIZE_SENT:decode_into(answer(narrow, 1)))
  assert(init.result.capabilities.positionEncoding == "utf-8")
  assert(published(narrow)[1][1].range["start"].character == 18)
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

--- A docs database that documents [`cosmic.fs`] and its `read`.
local function fs_docs(root: string): Sqlite.Handle
  return docs_fixture.database(root, {
    ["cosmic/fs.tl"] = "--- Files.\nlocal Fs = {}\n--- Reads the whole of a file.\n" ..
      "function Fs.read(path: string): string return path end\nreturn Fs\n",
  })
end

--- The markdown of the hover `ran` answered request `id` with, or nil.
local function hovered(ran: Ran, id: integer): string | nil
  local shown = assert(HOVER_SENT:decode_into(answer(ran, id)))
  local result = shown.result
  if result == nil then return nil end
  return result.contents.value
end

local function test_hover_shows_the_docs_of_a_required_symbol()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  -- `F` is no name the docs know: only the `require` it is bound to says
  -- it is cosmic.fs.
  local text = 'local F = require("cosmic.fs")\nlocal unknown = 1\nlocal _ = F.read, unknown\n'
  local ran = served(root, { initialize(root), open(root, "main.tl", text),
    at(2, "textDocument/hover", root, "main.tl", 2, 13),
    at(3, "textDocument/hover", root, "main.tl", 2, 19),
  }, { fs_docs(root) })
  local value = assert(hovered(ran, 2), ran.err)
  assert(value:find("cosmic.fs.read", 1, true) ~= nil and value:find("Reads the whole of a file.", 1, true) ~= nil,
    value)
  assert(hovered(ran, 3) == nil, "a name nothing documents")
end

local function test_hover_counts_utf16_units_before_the_cursor()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  -- "😀" is four bytes and two UTF-16 units, "é" two bytes and one unit.
  local text = 'local F = require("cosmic.fs")\nlocal _ = { "😀", F.read }\nlocal _ = { "é", F.read }\n'
  local ran = served(root, { initialize(root), open(root, "main.tl", text),
    -- The `r` of `read`, and the space before `F`, after the surrogate pair.
    at(2, "textDocument/hover", root, "main.tl", 1, 20),
    at(3, "textDocument/hover", root, "main.tl", 1, 17),
    -- The `r` of `read` after the two-byte character.
    at(4, "textDocument/hover", root, "main.tl", 2, 19),
  }, { fs_docs(root) })
  local after_pair = assert(hovered(ran, 2), ran.err)
  assert(after_pair:find("cosmic.fs.read", 1, true) ~= nil, after_pair)
  assert(hovered(ran, 3) == nil, "the space before F, not F")
  local after_two = assert(hovered(ran, 4), ran.err)
  assert(after_two:find("cosmic.fs.read", 1, true) ~= nil, after_two)
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
  local twice = served(root, { initialize(root), initialize(root) })
  local refusals = 0
  for _, body in ipairs(twice.sent) do
    local sent = assert(SENT:decode_into(body))
    local why = sent.error
    if why ~= nil then
      assert(why.code == -32600, body)
      refusals = refusals + 1
    end
  end
  assert(#twice.sent == 2 and refusals == 1, "the second initialize is refused")
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

local function test_each_wrong_message_has_its_code()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  local ran = served(root, { initialize(root),
    '{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":5}}',
    '{"jsonrpc":"2.0","id":3,"method":5}',
    "[1,2]",
    "{not json",
  })
  assert(failed(answer(ran, 2)) == -32602, "params that do not fit")
  local codes: {integer} = {}
  for _, body in ipairs(ran.sent) do
    local sent = assert(SENT:decode_into(body))
    local why = sent.error
    if why ~= nil and sent.id == nil then codes[#codes + 1] = why.code end
  end
  assert(table.concat(codes, ",") == "-32600,-32600,-32700", table.concat(codes, ","))
end

local function test_a_header_too_long_is_refused_whole_or_not()
  local long = "X-Long: " .. ("a"):rep(9000) .. "\r\nContent-Length: 2\r\n\r\n{}"
  local body, trouble = lsp.frames(Stream.from_string(long)):next()
  assert(body == nil and trouble:find("a header longer than", 1, true) ~= nil, trouble)
  local endless = "X-Long: " .. ("a"):rep(9000)
  local none, why = lsp.frames_of(trickle(endless)):next()
  assert(none == nil and why:find("a header longer than", 1, true) ~= nil, why)
end

local function test_a_large_body_arriving_in_pieces_is_whole()
  local text = ("x"):rep(200000)
  local body = '"' .. text .. '"'
  local frames = lsp.frames_of(trickle(lsp.frame(body)))
  assert(frames:next() == body)
end

local function test_a_lone_carriage_return_ends_a_line()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  for _, ending in ipairs({ "\r", "\r\n", "\n" }) do
    local text = "local x = 1" .. ending .. 'local n: integer = "s"' .. ending .. "return n + x" .. ending
    local diagnostics = published(served(root, { initialize(root), open(root, "main.tl", text) }))[1]
    assert(#diagnostics == 1, messages_of(diagnostics))
    local start = diagnostics[1].range["start"]
    assert(start.line == 1 and start.character == 19, tostring(ending:byte()) .. ": " ..
        tostring(start.line) .. ":" .. tostring(start.character))
  end
end

local function test_changes_already_read_are_checked_once()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  local runs = published(served(root, {
    initialize(root),
    open(root, "main.tl", "return 1\n"),
    change(root, "main.tl", "local n: integer = 'x'\nreturn n\n"),
    change(root, "main.tl", "local n: integer = 1\nreturn n\n"),
    close(root, "main.tl"),
  }))
  assert(#runs == 3, "the first change is not checked: " .. tostring(#runs))
  assert(#runs[2] == 0, messages_of(assert(runs[2])))
end

local function test_a_package_module_is_its_init()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  assert(Fs.mkdirs(root .. "/lib/shapes"))
  assert(Fs.write(root .. "/lib/shapes/init.tl", "return { sides = 3 }\n"))
  assert(Fs.write(root .. "/lib/decl.d.tl", "local record decl\n  sides: integer\nend\nreturn decl\n"))
  assert(Fs.write(root .. "/lib/decl.tl", 'return { sides = "three" }\n'))
  local main = 'local shapes = require("lib.shapes")\nlocal decl = require("lib.decl")\n' ..
    "local n: integer = shapes.sides + decl.sides\nreturn n\n"
  local diagnostics = published(served(root, { initialize(root), open(root, "main.tl", main) }))[1]
  assert(#diagnostics == 0, messages_of(diagnostics))
end

local function test_a_record_shape_is_resolved_as_a_build_does()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  local text = 'local Shape = require("cosmic.shape")\n' ..
    "local record R\n  n: integer\nend\n" ..
    'local R_SHAPE <const> = Shape.record_of("R"); local bad: integer = "x"\n' ..
    "local r = assert(R_SHAPE:into({ n = 1 }))\nlocal n: integer = r.n\nreturn n + bad\n"
  local diagnostics = published(served(root, { initialize(root), open(root, "main.tl", text) }))[1]
  assert(#diagnostics == 1, messages_of(diagnostics))
  -- At `"x"` in the text as written, not as the build's rewrite moved it.
  local start = diagnostics[1].range["start"]
  assert(start.line == 4 and start.character == 67, tostring(start.line) .. ":" .. tostring(start.character))
  -- A module required is rewritten too.
  local module = text:gsub('; local bad: integer = "x"', "")
  assert(Fs.write(root .. "/shaped.tl", (module:gsub("n %+ bad", "r"))))
  local user = 'local shaped = require("shaped")\nlocal n: integer = shaped.n\nreturn n\n'
  local through = published(served(root, { initialize(root), open(root, "user.tl", user) }))[1]
  assert(#through == 0, messages_of(through))
end

local function test_a_test_file_is_not_warned_of_its_tests()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  local text = "local function test_it() assert(true) end\n"
  local runs = published(served(root, { initialize(root), open(root, "it_test.tl", text),
    open(root, "it.tl", text) }))
  assert(#runs[1] == 0, messages_of(assert(runs[1])))
  assert(#runs[2] == 1 and runs[2][1].message:find("unused", 1, true) ~= nil,
    "a warning is published: " .. messages_of(assert(runs[2])))
end

local function test_a_closed_document_no_longer_shadows_the_file()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/shapes.tl", "return { sides = 3 }\n"))
  local main = 'local shapes = require("lib.shapes")\nlocal n: integer = shapes.sides\nreturn n\n'
  local runs = published(served(root, {
    initialize(root),
    open(root, "lib/shapes.tl", 'return { sides = "three" }\n'),
    open(root, "main.tl", main),
    close(root, "lib/shapes.tl"),
    change(root, "main.tl", main),
  }))
  assert(#runs == 4)
  assert(#runs[2] == 1, "the open document is what main reads")
  assert(#runs[4] == 0, "the file is, once the document closes: " .. messages_of(assert(runs[4])))
end

local function test_a_save_checks_every_open_document_again()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  local save = '{"jsonrpc":"2.0","method":"textDocument/didSave","params":{"textDocument":{"uri":' ..
    uri(root, "a.tl") .. "}}}"
  local sent = publications(served(root, { initialize(root), open(root, "a.tl", "return 1\n"),
    open(root, "b.tl", "return 2\n"), save }))
  assert(#sent == 4)
  local again: {string} = { sent[3].uri, sent[4].uri }
  table.sort(again)
  assert(again[1] == "file://" .. root .. "/a.tl" and again[2] == "file://" .. root .. "/b.tl",
    table.concat(again, " "))
end

--- The diagnostics of publication `n` of those `ran` sent.
local function nth(ran: Ran, n: integer): {Diagnostic}
  return (assert(published(ran)[n], "no publication " .. tostring(n)))
end

--- How many diagnostics each publication `ran` sent holds, in order:
--- "1,0" for one then none.
local function counts(ran: Ran): string
  local out: {string} = {}
  for _, diagnostics in ipairs(published(ran)) do out[#out + 1] = tostring(#diagnostics) end
  return table.concat(out, ",")
end

--- The one diagnostic of `diagnostics`.
local function only(diagnostics: {Diagnostic}): Diagnostic
  assert(#diagnostics == 1, messages_of(diagnostics))
  return assert(diagnostics[1])
end

--- Where `diagnostic` starts or ends, as `side` ("start" or "end") says.
local function edge(diagnostic: Diagnostic, side: string): Place
  return assert(diagnostic.range[side])
end

local function test_a_global_is_published_as_refused()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  local refused = only(nth(served(root, { initialize(root),
    open(root, "main.tl", "local n = 1\nglobal shared_count: integer = n\nreturn shared_count\n") }), 1))
  assert(refused.message:find("a global is not allowed in a cosmic build", 1, true) ~= nil, refused.message)
  local start = edge(refused, "start")
  assert(start.line == 1 and start.character == 0, tostring(start.line) .. ":" .. tostring(start.character))
end

local function test_a_test_file_that_returns_a_value_is_refused()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  local text = "local function test_it() assert(true) end\nreturn {}\n"
  local refused = only(nth(served(root, { initialize(root), open(root, "it_test.tl", text) }), 1))
  assert(refused.message:find("a test file may not both define test_* functions and return", 1, true) ~= nil,
    refused.message)
  assert(edge(refused, "start").line == 1, "at its return")
end

local function test_the_same_text_checks_the_same_each_time()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  -- A module that declares a global, which the document reads.
  assert(Fs.write(root .. "/g.tl", "global G_VAL: integer = 1\nreturn {}\n"))
  local reader = 'local _ = require("g")\nlocal n: integer = G_VAL\nreturn n\n'
  local declares = "global G_OWN: integer = 1\nlocal s: string = G_OWN\nreturn s\n"
  -- A request between two changes keeps the second from standing for
  -- both ([`lsp.serve`] checks only the last of changes read together).
  local between = '{"jsonrpc":"2.0","id":7,"method":"nosuch"}'
  local ran = served(root, { initialize(root),
    open(root, "m2.tl", reader), change(root, "m2.tl", reader), between, change(root, "m2.tl", reader),
    open(root, "own.tl", declares), change(root, "own.tl", declares),
  })
  assert(counts(ran) == "0,0,0,2,2", counts(ran) .. "\n" .. messages_of(nth(ran, 2)))
  local own, again = messages_of(nth(ran, 4)), messages_of(nth(ran, 5))
  assert(own == again, own .. "\n--\n" .. again)
end

local function test_a_refused_record_shape_is_published_at_its_call()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  local text = 'local Shape = require("cosmic.shape")\nlocal record R\n  n: integer\nend\n' ..
    'local name = "R"\nlocal R_SHAPE <const> = Shape.record_of(name)\nreturn R_SHAPE\n'
  local refused = only(nth(served(root, { initialize(root), open(root, "main.tl", text) }), 1))
  assert(refused.message:find("the name must be a string literal", 1, true) ~= nil, refused.message)
  assert(edge(refused, "start").line == 5, tostring(edge(refused, "start").line))
end

local function test_a_column_after_a_surrogate_pair_counts_two_units()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  -- "😀" is four bytes and two UTF-16 units; the error is at `nope`.
  local text = 'local _ = { "😀", nope }\n'
  local wide = only(nth(served(root, { initialize(root), open(root, "main.tl", text) }), 1))
  assert(edge(wide, "start").character == 18, tostring(edge(wide, "start").character))
  assert(edge(wide, "end").character == 22, tostring(edge(wide, "end").character))
  local narrow = only(nth(served(root, { initialize(root, '{"general":{"positionEncodings":["utf-8"]}}'),
    open(root, "main.tl", text) }), 1))
  assert(edge(narrow, "start").character == 20, tostring(edge(narrow, "start").character))
end

local function test_hover_counts_bytes_when_utf8_is_negotiated()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  local text = 'local F = require("cosmic.fs")\nlocal _ = { "😀", F.read }\n'
  local ran = served(root, { initialize(root, '{"general":{"positionEncodings":["utf-8"]}}'),
    open(root, "main.tl", text),
    -- Byte 25 is the `d` of `read`; as UTF-16 units it would be the `}`.
    at(2, "textDocument/hover", root, "main.tl", 1, 25),
    -- Byte 19 is the space before `F`.
    at(3, "textDocument/hover", root, "main.tl", 1, 19),
  }, { fs_docs(root) })
  local value = assert(hovered(ran, 2), ran.err)
  assert(value:find("cosmic.fs.read", 1, true) ~= nil, value)
  assert(hovered(ran, 3) == nil, "the space before F")
end

local function test_the_last_of_several_changes_is_the_text()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  local good, bad = "local n: integer = 1\nreturn n\n", "local n: integer = 'x'\nreturn n\n"
  local fixed = served(root, { initialize(root), open(root, "main.tl", bad), changes(root, "main.tl", { bad, good }) })
  assert(counts(fixed) == "1,0", counts(fixed))
  local broken = served(root, { initialize(root), open(root, "main.tl", good), changes(root, "main.tl", { good, bad }) })
  assert(counts(broken) == "0,1", counts(broken))
end

--- A `file:` URI of `path`, a space and a `%` escaped.
local function escaped(path: string): string
  return "file://" .. (path:gsub("%%", "%%25"):gsub(" ", "%%20"))
end

local function test_a_root_is_read_from_its_escaped_uri_or_its_path_or_folder()
  local base = assert(Fs.mkdtemp("cosmic-lsp-"))
  local root = base .. "/a b%c"
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/shapes.tl", 'return { sides = "three" }\n'))
  local main = 'local shapes = require("lib.shapes")\nlocal n: integer = shapes.sides\nreturn n\n'
  local opened = '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":' ..
    Json.quote(escaped(root .. "/main.tl")) .. ',"languageId":"teal","version":1,"text":' ..
    Json.quote(main) .. "}}}"
  local inits: {string} = {
    '{"rootUri":' .. Json.quote(escaped(root)) .. "}",
    '{"rootPath":' .. Json.quote(root) .. "}",
    '{"workspaceFolders":[{"uri":' .. Json.quote(escaped(root)) .. ',"name":"w"}]}',
  }
  for _, params in ipairs(inits) do
    local init = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":' .. params .. "}"
    -- The session starts at another directory: only the root it is
    -- given finds lib/shapes.tl.
    local found = only(nth(served(base, { init, opened }), 1))
    assert(found.message:find("expected integer", 1, true) ~= nil, params .. ": " .. found.message)
  end
end

local function test_a_template_is_a_module_and_testdata_is_none()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  assert(Fs.mkdirs(root .. "/testdata"))
  assert(Fs.write(root .. "/data.tl", "local record data\n  record Page\n    title: string\n  end\nend\nreturn data\n"))
  assert(Fs.write(root .. "/page.tmpl", "{{type Page from data}}{{mode text}}one {{.title}}"))
  assert(Fs.write(root .. "/testdata/m.tl", "return { n = 1 }\n"))
  local main = 'local page = require("page")\nlocal data = require("data")\n' ..
    'local p: data.Page = { title = "t" }\nlocal n: integer = page.render(p)\nreturn n\n'
  local rendered = only(nth(served(root, { initialize(root), open(root, "main.tl", main) }), 1))
  assert(rendered.message:find("expected integer", 1, true) ~= nil, "the template renders a string: " ..
      rendered.message)
  local fixture = 'local m = require("testdata.m")\nreturn m\n'
  local unfound = only(nth(served(root, { initialize(root), open(root, "main.tl", fixture) }), 1))
  assert(unfound.message:find("testdata.m", 1, true) ~= nil, unfound.message)
end

--- Messages a session sent that are requests of its own.
local function requests(ran: Ran): {string}
  local out: {string} = {}
  for _, body in ipairs(ran.sent) do
    local sent = assert(SENT:decode_into(body))
    local method = sent.method
    if method ~= nil and sent.id ~= nil then out[#out + 1] = method end
  end
  return out
end

local function test_a_file_changed_on_disk_checks_open_documents_again()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/lib/shapes.tl", "return { sides = 3 }\n"))
  local main = 'local shapes = require("lib.shapes")\nlocal n: integer = shapes.sides\nreturn n\n'
  local watching = '{"workspace":{"didChangeWatchedFiles":{"dynamicRegistration":true}}}'
  local initialized = '{"jsonrpc":"2.0","method":"initialized","params":{}}'
  local registered = '{"jsonrpc":"2.0","id":1,"result":null}'
  local first = served(root, { initialize(root, watching), initialized, registered,
    open(root, "main.tl", main) })
  local asked = table.concat(requests(first), " ")
  assert(asked == "client/registerCapability", asked)
  assert(table.concat(first.sent, "\n"):find('"globPattern":"**/*.tl"', 1, true) ~= nil)
  assert(#requests(served(root, { initialize(root), initialized })) == 0,
    "no registration where the editor takes none")
  -- One session, served twice: the file changes between.
  local wrote: {string} = {}
  local session = lsp.new(root, { err = function(_line: string) end, store = nil })
  local function send(messages: {string})
    local _ = lsp.serve(session, Stream.from_string(framed(messages)), function(text: string): boolean, string
      wrote[#wrote + 1] = text
      return true, ""
    end)
  end
  send({ initialize(root, watching), initialized, open(root, "main.tl", main) })
  assert(Fs.write(root .. "/lib/shapes.tl", 'return { sides = "three" }\n'))
  send({ '{"jsonrpc":"2.0","method":"workspace/didChangeWatchedFiles","params":{"changes":[{"uri":' ..
      uri(root, "lib/shapes.tl") .. ',"type":2}]}}' })
  local ran: Ran = { code = 0, sent = bodies(table.concat(wrote)), err = "" }
  assert(counts(ran) == "0,1", "the file as it was types, and as it is now does not: " .. counts(ran))
end

local function test_cosmics_own_tree_holds_a_standard_module_to_its_stub()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  local text = "local x = 1\nreturn { x = x }\n"
  local elsewhere = served(root, { initialize(root), open(root, "cosmic/thing.tl", text) })
  assert(counts(elsewhere) == "0", messages_of(nth(elsewhere, 1)))
  -- What tells cosmic's own tree ([`build.tree`]).
  assert(Fs.mkdirs(root .. "/core"))
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.write(root .. "/build/importer.tl", "return {}\n"))
  local own = only(nth(served(root, { initialize(root), open(root, "cosmic/thing.tl", text) }), 1))
  assert(own.message:find("its stub keeps every statement", 1, true) ~= nil, own.message)
end

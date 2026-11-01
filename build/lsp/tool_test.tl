--- `cosmic lsp` run as this program: the command lines it refuses, one
--- editor over standard input and output, a listener that a signal
--- stops while an editor holds a connection open, the socket paths it
--- refuses, and a request that arrives over standard input or a
--- connection while dependents are checked, answered before the rest of
--- them. These start this program, so they need `tool`; a session's
--- answers are in session_test.tl.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Net = require("cosmic.net")
local Shape = require("cosmic.shape")
local Stream = require("cosmic.stream")
local Test = require("cosmic.test")
local protocol = require("build.lsp.protocol")
local session_fixture = require("build.lsp.session_fixture")
local this_program = require("build.this_program")
local unix_socket = require("build.unix_socket")

--- The program itself, which its tests start, and a loopback its
--- listener listens on.
Test.policy{
  cpu_features = true,
  profiles = { "cosmic" },
  grants = { { path = "o/bin", letters = "rx" } },
  loopback = { "127.0.0.1" },
}

local record Ran
  code: integer
  out: string
  err: string
end

local function cosmic(dir: string, words: {string}, input?: string): Ran
  local started = this_program.program(words, {
    cwd = dir, stdout = "capture", stderr = "capture", input = input,
    timeout_ns = Clock.seconds(30),
  })
  local result = assert(Child.run(started.argv, started.options))
  -- A child a signal ended has no code: -1 is none a test expects.
  return { code = result.code or -1, out = result.stdout or "", err = result.stderr or "" }
end

local record Info
  name: string
end

local record Initialized
  serverInfo: Info
end

--- What the tests read of an answer to `initialize`.
local record InitializeSent
  id: integer
  result: Initialized
end

local INITIALIZE_SENT <const>: Shape.Typed<InitializeSent> = Shape.record_of("InitializeSent")

local function initialize(root: string): string
  return protocol.frame('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"rootUri":' ..
      Json.quote("file://" .. root) .. ',"capabilities":{}}}')
end

local SHUTDOWN <const> = protocol.frame('{"jsonrpc":"2.0","id":2,"method":"shutdown"}')
local EXIT <const> = protocol.frame('{"jsonrpc":"2.0","method":"exit"}')

--- Whether `body` answers `initialize` as this server does.
local function answers_initialize(body: string): boolean
  local sent = INITIALIZE_SENT:decode_into(body)
  return sent ~= nil and sent.id == 1 and sent.result.serverInfo.name == "cosmic"
end

local function test_a_command_line_it_refuses_exits_2(tmp: string)
  for _, words in ipairs({
      { "lsp", "word" },
      { "lsp", "--listen", "localhost:9000" },
      { "lsp", "--listen", "1.2.3:9000" },
      { "lsp", "--listen", "256.1.1.1:9000" },
      { "lsp", "--listen", "::1:9000" },
      { "lsp", "--listen", "[::1::2]:9000" },
      { "lsp", "--listen", "70000" },
      { "lsp", "--stdio", "--listen", "9000" },
      { "lsp", "--stdio", "--socket", tmp .. "/lsp.sock" },
  }) do
    local ran = cosmic(tmp, words)
    local line = table.concat(words, " ")
    assert(ran.code == 2 and ran.out == "", line .. ": " .. tostring(ran.code) .. " " .. ran.err)
    assert(ran.err:find("cosmic: lsp: ", 1, true), line .. ": " .. ran.err)
  end
end

--- A `COSMIC_GRAMMAR` that names no checker stops the verb, naming the ones there are: it is not read as the fork's.
local function test_a_grammar_that_is_none_stops_the_server_and_names_the_one_there_is(tmp: string)
  local env = this_program.environment()
  env["COSMIC_GRAMMAR"] = "bogus"
  local started = this_program.program({ "lsp" }, { cwd = tmp, env = env, stdout = "capture", stderr = "capture",
    input = initialize(tmp) .. SHUTDOWN .. EXIT, timeout_ns = Clock.seconds(30) })
  local result = assert(Child.run(started.argv, started.options))
  assert(result.code == 1 and (result.stdout or "") == "", tostring(result.code) .. " " .. (result.stderr or ""))
  local said = result.stderr or ""
  assert(said:find("COSMIC_GRAMMAR=bogus: the only grammar is `new` (the default)", 1, true) ~= nil, said)
end

local function test_one_editor_over_standard_input_and_output(tmp: string)
  local ran = cosmic(tmp, { "lsp" }, initialize(tmp) .. SHUTDOWN .. EXIT)
  assert(ran.code == 0, ran.err)
  local body = assert(protocol.frames(Stream.from_string(ran.out)):next())
  assert(answers_initialize(body), body)
  local ended = cosmic(tmp, { "lsp", "--stdio" }, initialize(tmp) .. SHUTDOWN)
  assert(ended.code == 0, "the stream ends after shutdown: " .. ended.err)
  local early = cosmic(tmp, { "lsp" }, initialize(tmp))
  assert(early.code == 1, "the stream ends before shutdown: " .. early.err)
end

--- A definition asked of the program itself, in a project: it answers the module that declares the function, with the
--- place of its name.
local function test_a_definition_is_answered_from_the_module_that_declares_it()
  local root = session_fixture.project()
  assert(Fs.write(root .. "/helper.tl",
    "local record helper\nend\n\nfunction helper.twice(n: integer): integer\n  return n * 2\nend\n\nreturn helper\n"))
  local main = 'local helper = require("helper")\nlocal _ = helper.twice(2)\n'
  local ran = cosmic(root, { "lsp" }, initialize(root) ..
      protocol.frame(session_fixture.open(root, "main.tl", main)) ..
      protocol.frame(session_fixture.at(7, "textDocument/definition", root, "main.tl", 1, 19)) .. SHUTDOWN .. EXIT)
  assert(ran.code == 0, ran.err)
  local answer = ""
  for _, body in ipairs(session_fixture.bodies(ran.out)) do
    if session_fixture.sent(body).id == 7 then answer = body end
  end
  local expected = '"result":{"range":{"end":{"character":21,"line":3},"start":{"character":16,"line":3}},"uri":' ..
    Json.quote("file://" .. root .. "/helper.tl") .. "}"
  assert(answer:find(expected, 1, true) ~= nil, answer)
end

--- A `cosmic lsp` started to listen, once it says where.
local record Listening
  handle: Child.Handle
  --- What it said it listens at.
  at: string
  --- The file its standard error goes to.
  err: string
end

local function listening(tmp: string, words: {string}): Listening
  local err = tmp .. "/lsp.err"
  local fd = assert(Fs.open_write(err))
  local start = this_program.program(words, { cwd = tmp, stdout = fd, stderr = fd })
  local handle = assert(Child.start(start.argv, start.options))
  assert(Fs.close(fd))
  local deadline = Clock.monotonic_ns() + Clock.seconds(30)
  while true do
    local said = Fs.read(err) or ""
    local at = said:match("cosmic: lsp: listening at ([^\n]+)\n")
    if at ~= nil then return { handle = handle, at = at, err = err } end
    assert(Clock.monotonic_ns() < deadline, said)
    assert(Child.wait_any({ handle }, Clock.ms(10)) == nil, said)
  end
end

--- Runs a whole session at `address`, then holds a second one open and
--- idle and stops the server with SIGTERM (`stop`'s signal), which it
--- ends at promptly, with exit 0, closing the connection held.
local function served_and_stopped(root: string, started: Listening, address: Net.Address)
  -- Reaped by the wait below.
  local handle = started.handle
  local first <close> = assert(Net.connect(address, { timeout_ns = Clock.seconds(10) }))
  assert(first:write(initialize(root) .. SHUTDOWN .. EXIT))
  local frames = protocol.frames(first)
  local body = assert(frames:next())
  assert(answers_initialize(body), body)
  assert(frames:next())
  local after, why = frames:next()
  assert(after == nil and why == "", "the server closes the connection at exit: " .. why)
  local held <close> = assert(Net.connect(address, { timeout_ns = Clock.seconds(10) }))
  assert(held:write(initialize(root)))
  local answered = assert(protocol.frames(held):next())
  assert(answers_initialize(answered), answered)
  local stopped = Clock.monotonic_ns()
  assert(handle:stop())
  local result = assert(handle:wait(Clock.seconds(20)))
  local took = Clock.monotonic_ns() - stopped
  local said = assert(Fs.read(started.err))
  assert(not result.timed_out and result.code == 0, tostring(result.code) .. ": " .. said)
  -- Well inside the server's grace: the stop closes the idle connection
  -- rather than waiting the grace out.
  assert(took < Clock.seconds(3), tostring(took // 1000000) .. " ms")
  local rest = said:gsub("cosmic: lsp: listening at [^\n]*\n", "")
  assert(rest == "", said)
  local ended, _ = protocol.frames(held):next()
  assert(ended == nil, "the held connection is closed")
end

--- The loopback port `started` listens at.
local function port_of(started: Listening): integer
  local port = math.tointeger(tonumber(started.at:match("^127%.0%.0%.1:(%d+)$")))
  if port == nil then
    local _, _ = started.handle:close()
    error("listening at " .. started.at)
  end
  return port
end

local function test_a_tcp_listener_stops_at_sigterm_with_a_connection_open(tmp: string)
  local started = listening(tmp, { "lsp", "--listen", "127.0.0.1:0" })
  served_and_stopped(tmp, started, Net.tcp("127.0.0.1", port_of(started)))
end

local function test_a_socket_listener_stops_at_sigterm_with_a_connection_open(tmp: string)
  if unix_socket.skipped(tmp) then return end
  local path = tmp .. "/lsp.sock"
  local started = listening(tmp, { "lsp", "--socket", path })
  assert(started.at == path, started.at)
  served_and_stopped(tmp, started, Net.unix(path))
  assert(Fs.exists(path) ~= true, "the stop removes the socket file")
end

--- The signal that ends a process with no chance to clean up, as a crash does.
local SIGKILL <const> = 9

local function test_a_socket_file_already_there_is_refused_and_left(tmp: string)
  if unix_socket.skipped(tmp) then return end
  local path = tmp .. "/lsp.sock"
  local crashed = listening(tmp, { "lsp", "--socket", path })
  assert(crashed.handle:stop(SIGKILL))
  local result = assert(crashed.handle:wait(Clock.seconds(20)))
  assert(result.signal == SIGKILL, tostring(result.signal))
  assert(Fs.exists(path) == true, "the crash leaves the socket file")
  -- Whether a listener is behind it no connect can tell: a live one's
  -- full backlog refuses as a dead one does.
  local ran = cosmic(tmp, { "lsp", "--socket", path })
  assert(ran.code == 1, tostring(ran.code) .. ": " .. ran.err)
  assert(ran.err:find(path .. " is a socket file already; remove it if no server is running there",
    1, true), ran.err)
  assert(Fs.exists(path) == true, "the socket file is left")
end

local function test_a_socket_path_holding_another_file_is_left_alone(tmp: string)
  local path = tmp .. "/lsp.sock"
  assert(Fs.write(path, "not a socket\n"))
  local ran = cosmic(tmp, { "lsp", "--socket", path })
  assert(ran.code == 1, tostring(ran.code) .. ": " .. ran.err)
  assert(Fs.read(path) == "not a socket\n", "the file is not removed")
end

local function test_a_listener_beyond_the_loopback_is_warned_of(tmp: string)
  local err = tmp .. "/lsp.err"
  local fd = assert(Fs.open_write(err))
  local start = this_program.program({ "lsp", "--listen", "0.0.0.0:0" }, { cwd = tmp, stdout = fd, stderr = fd })
  local handle = assert(Child.start(start.argv, start.options))
  assert(Fs.close(fd))
  local deadline = Clock.monotonic_ns() + Clock.seconds(30)
  local said = ""
  while said:find("warning: ", 1, true) == nil do
    said = Fs.read(err) or ""
    if Child.wait_any({ handle }, Clock.ms(10)) ~= nil then
      -- A sandboxed worker may be refused an address beyond its loopback.
      Test.skip("this host refuses a listener at 0.0.0.0: " .. said)
      return
    end
    assert(Clock.monotonic_ns() < deadline, said)
  end
  assert(handle:stop())
  local result = assert(handle:wait(Clock.seconds(20)))
  assert(result.code == 0, tostring(result.code) .. ": " .. said)
  local at = said:match("cosmic: lsp: listening at (0%.0%.0%.0:%d+)\n")
  assert(at ~= nil, said)
  assert(said:find("cosmic: lsp: warning: " .. at .. " is reached from beyond this host", 1, true),
    said)
end

--- How many open documents require the helper the editor changes, and
--- how many lines of them use it: one check each, of a tenth of a second
--- or so, all of which but the first must outlast the request's way to
--- the server, however slow the host.
local DEPENDENTS <const> = 8
local USES <const> = 300

--- A project of a helper and the [`DEPENDENTS`] modules requiring it,
--- and the messages that open them all, framed.
local function helped(): string, string
  local root = session_fixture.project()
  local integer = "local record helper\nend\n\nfunction helper.twice(n: integer): integer\n  return n * 2\nend\n\nreturn helper\n"
  local main = 'local helper = require("helper")\nlocal n: integer = 0\n' ..
    ("n = n + helper.twice(2)\n"):rep(USES) .. "return n\n"
  assert(Fs.write(root .. "/helper.tl", integer))
  local opening = protocol.frame(session_fixture.initialize(root)) ..
    protocol.frame(session_fixture.open(root, "helper.tl", integer))
  for i = 1, DEPENDENTS do
    local name = "d" .. tostring(i) .. ".tl"
    assert(Fs.write(root .. "/" .. name, main))
    opening = opening .. protocol.frame(session_fixture.open(root, name, main))
  end
  return root, opening
end

--- Whether `body` is a publication of the dependent `d<n>.tl`.
local function a_dependent(body: string): boolean
  return session_fixture.sent(body).method == "textDocument/publishDiagnostics" and
    body:match('"uri":"[^"]*/d%d+%.tl"') ~= nil
end

--- Opens the helper and its dependents through `write`, changes the
--- helper's type, and sends a hover once the helper's own publication is
--- read from `frames`: it arrives while the dependents are checked, read
--- by the program's poll of its stream, so it is answered before the last
--- of them is published. Then shuts the session down.
local function asked_while_checking(root: string, opening: string, write: function(text: string),
                                    frames: protocol.Frames)
  local text = "local record helper\nend\n\nfunction helper.twice(n: integer): string\n  return tostring(n * 2)\nend\n\n" ..
    "return helper\n"
  write(opening)
  -- The initialize's answer, the helper's publication and each dependent's.
  for _ = 1, DEPENDENTS + 2 do assert(frames:next()) end
  write(protocol.frame(session_fixture.change(root, "helper.tl", text)))
  local own = assert(frames:next())
  assert(own:match('"uri":"[^"]*/helper%.tl"') ~= nil, own)
  write(protocol.frame(session_fixture.at(7, "textDocument/hover", root, "d1.tl", 0, 0)))
  -- What was read after the helper's publication, in order.
  local seen = ""
  local published = 0
  while published < DEPENDENTS do
    local body = assert(frames:next())
    if a_dependent(body) then
      published = published + 1
      seen = seen .. " d"
    elseif session_fixture.sent(body).id == 7 then
      seen = seen .. " answer"
    end
  end
  assert(seen:find("answer", 1, true), "answered before the last dependent:" .. seen)
  write(protocol.frame(session_fixture.SHUTDOWN) .. EXIT)
end

local function test_a_request_over_standard_input_is_answered_while_dependents_are_checked()
  local root, opening = helped()
  local started = this_program.program({ "lsp" }, {
    cwd = root, stdin = "stream", stdout = "stream", stderr = "capture", timeout_ns = Clock.seconds(60),
  })
  local handle <close> = assert(Child.start(started.argv, started.options))
  local input = assert(handle.stdin_stream)
  asked_while_checking(root, opening, function(text: string) assert(input:write(text)) end,
    protocol.frames(assert(handle.stdout_stream)))
  assert(input:close())
  local result = assert(handle:wait(Clock.seconds(30)))
  assert(result.code == 0, tostring(result.code) .. ": " .. (result.stderr or ""))
end

local function test_a_request_over_a_connection_is_answered_while_dependents_are_checked()
  local root, opening = helped()
  local started = listening(root, { "lsp", "--listen", "127.0.0.1:0" })
  local conn <close> = assert(Net.connect(Net.tcp("127.0.0.1", port_of(started)),
    { timeout_ns = Clock.seconds(30) }))
  asked_while_checking(root, opening, function(text: string) assert(conn:write(text)) end,
    protocol.frames(conn))
  assert(started.handle:stop())
  local result = assert(started.handle:wait(Clock.seconds(20)))
  assert(result.code == 0, tostring(result.code) .. ": " .. (Fs.read(started.err) or ""))
end

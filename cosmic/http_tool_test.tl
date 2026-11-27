--- cosmic.http's tests that need the program itself, apart from
--- cosmic/http_test.tl's so those stand while the tree moves:
--- $SSL_CERT_FILE, which only a fresh process started from the program
--- reads, and a client in a process of its own beside a local
--- server that sees the request as sent. The CA roots the binary's own
--- database carries are read in cosmic/http_store_test.tl.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local _ = require("build.standalone")
local type Stream = require("cosmic.stream")
--- What the scripts its tests run standalone require, which a child
--- is typed and run against only where the closure holds it (`lua`).
local type _ = require("cosmic.http")
local Clock = require("cosmic.clock")

--- The next chunk of `reader`: raises where it ended or failed.
local function chunk_of(reader: Stream.Reader, max_bytes?: integer): string
  local chunk, why = reader:read(max_bytes)
  if chunk == nil then error(tostring(why), 2) end
  if chunk == false then error("the stream ended", 2) end
  return chunk
end

--- Requests to a local port, closed or one a test serves, which a
--- loopback alone reaches: the worker runs offline, and is keyed. And
--- the program itself, which its tests start only to run a script
--- standalone (`lua`, [`build.standalone`]).
Test.policy{ profiles = { "cosmic" }, loopback = { "127.0.0.1" } }

--- What a fresh process, $SSL_CERT_FILE naming `cert_file`, is told
--- when it opens a closed local port: the roots, that file's included,
--- are loaded once per process, at its first request.
local function refused_with_cert_file(tmp: string, cert_file: string): string
  local script = tmp .. "/open.tl"
  assert(Fs.write(script, [[
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Http = require("cosmic.http")
local _, trouble = Http.open("http://127.0.0.1:1/", { timeout_ns = Clock.seconds(60), connect_timeout_ns = Clock.seconds(2) })
local _, _ = Fs.put(Fs.stdout, tostring(trouble))
]]))
  local started = Test.cosmic({ "--standalone", script },
    { env = { SSL_CERT_FILE = cert_file, XDG_CACHE_HOME = tmp .. "/cache" },
      stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) })
  local result = assert(Child.run(started.argv, started.options))
  assert(result.code == 0, tostring(result.stderr))
  return result.stdout or ""
end

--- $SSL_CERT_FILE naming what holds no certificates -- a directory, a
--- named pipe, or a file of anything else -- adds none and refuses
--- nothing: a request fails as it would without it. Reading a directory
--- by the size that seeking to its end gives would ask for more memory
--- than there is, and opening a pipe without O_NONBLOCK would wait for a
--- writer forever.
local function test_a_cert_file_holding_no_certificates_is_passed_over(tmp: string)
  local junk = tmp .. "/junk.pem"
  assert(Fs.write(junk, "no certificate here\n"))
  local pipe = tmp .. "/pipe.pem"
  assert(sys.mkfifo(pipe))
  for _, cert_file in ipairs({ tmp, junk, pipe, tmp .. "/missing.pem" }) do
    local trouble = refused_with_cert_file(tmp, cert_file)
    assert(not trouble:find("SSL_CERT_FILE", 1, true), cert_file .. ": " .. trouble)
    assert(trouble:lower():find("connect", 1, true) ~= nil, cert_file .. ": " .. trouble)
  end
end

--- A caught signal ending a wait on a stalled connection is tested here,
--- not in cosmic/http_test.tl: the scripted transport closes after its
--- reply, and a server that stalls runs beside a blocking client only in
--- a process of its own.
---
--- A client of this program running `body`, a standalone script's
--- function of its arguments, against a local server that stalls: once
--- the client has written `marker`, which it does just before the call
--- that is to wait, it is sent SIGINT, and what it printed is returned.
--- `serve` is the server's side: it gets the accepted connection and
--- the request's head, and writes what it will, then stalls.
local function interrupted(tmp: string, body: string,
                           serve: function(Net.Conn, string)): string
  local script = tmp .. "/client.tl"
  assert(Fs.write(script, [[
local Fs = require("cosmic.fs")
local Clock = require("cosmic.clock")
local Http = require("cosmic.http")
local Signal = require("cosmic.signal")
return function(argv: {string}): integer
  local url, marker = (argv[1] or ""), (argv[2] or "")
  local guard = assert(Signal.guard())
]] .. body .. [[
  local caught = assert(guard:release())
  local _, _ = Fs.put(Fs.stdout, " " .. tostring(caught))
  return 0
end
]]))
  local server <close> = assert(Net.listen(Net.tcp("127.0.0.1", 0), { timeout_ns = Clock.seconds(20) }))
  local url = "http://127.0.0.1:" .. tostring(assert(server.address.port)) .. "/"
  local marker = tmp .. "/marker"
  local started = Test.cosmic({ "--standalone", script, url, marker },
    { timeout_ns = Child.FOREVER, stdout = "capture", stderr = "capture" })
  local child <close> = assert(Child.start(started.argv, started.options))
  local conn <close> = assert(server:accept())
  local head = ""
  while not head:find("\r\n\r\n", 1, true) do head = head .. chunk_of(conn) end
  serve(conn, head)
  for _ = 1, 2000 do
    if assert(Fs.status(marker)).exists then break end
    assert(sys.nanosleep(Clock.ms(10)))
  end
  assert(assert(Fs.status(marker)).exists, "the client never reached its wait")
  assert(child:stop(sys.SIGINT))
  local result = assert(child:wait(Clock.seconds(20)))
  assert(result.code == 0, tostring(result.code) .. " " .. tostring(result.stderr))
  return result.stdout or ""
end

--- A body `read` that waits on a server that sent part of the body and
--- stalls ends when a guard catches a signal.
local function test_a_caught_signal_ends_a_read_that_waits(tmp: string)
  local said = interrupted(tmp, [[
  local response = assert(Http.open(url, { timeout_ns = Clock.seconds(60) }))
  local first, _ = response:read()
  assert(first == "part")
  assert(Fs.write(marker, ""))
  local data, why = response:read()
  local _, _ = Fs.put(Fs.stdout, tostring(data) .. " " .. tostring(why))
]], function(conn: Net.Conn, _head: string)
  assert(conn:write("HTTP/1.1 200 OK\r\nContent-Length: 100000\r\n\r\npart"))
end)
  assert(said == "nil interrupted " .. tostring(sys.SIGINT), said)
end

--- A download that waits on a server that sent part of the body and
--- stalls fails "interrupted" when a guard catches a signal, though the
--- caller's `cancelled` returns true by then too, as the verbs' own do,
--- and leaves nothing at its path or beside it.
local function test_a_caught_signal_ends_a_download_that_waits(tmp: string)
  local said = interrupted(tmp, [[
  local target = marker .. ".target"
  local ok, why = Http.download(url, target, { timeout_ns = Clock.seconds(60),
    cancelled = function(): boolean
      if not assert(Fs.status(marker)).exists then assert(Fs.write(marker, "")) end
      return guard:cancelled() ~= 0
    end,
  })
  local _, _ = Fs.put(Fs.stdout, tostring(ok) .. " " .. tostring(why))
]], function(conn: Net.Conn, _head: string)
  assert(conn:write("HTTP/1.1 200 OK\r\nContent-Length: 100000\r\n\r\npart"))
end)
  assert(said == "nil interrupted " .. tostring(sys.SIGINT), said)
  for _, name in ipairs((assert(Fs.list(tmp)))) do
    assert(not name:find(".target", 1, true), "left behind: " .. name)
  end
end

--- A request [`Http.request`] sends to a local server, as the server
--- read it, and what the client then printed: the status and body of
--- the server's "done", or why it failed. The client runs in a process
--- of its own, since a server in this one could not respond while the
--- request blocks. Only a server sees what [`Http.request`] sends:
--- the scripted transport's `sent` is a Response's, and the whole body
--- it returns has none.
local function served(tmp: string, method: string, body?: string): string, string
  local script = tmp .. "/request.tl"
  assert(Fs.write(script, [[
local Fs = require("cosmic.fs")
local Http = require("cosmic.http")
return function(argv: {string}): integer
  local body = argv[3]
  local got, trouble = Http.request((argv[1] or ""), (argv[2] or ""), if body ~= nil then { timeout_ns = 60000000000, body = body } else { timeout_ns = 60000000000 } end)
  local _, _ = Fs.put(Fs.stdout, if got ~= nil then tostring(got.status) .. " " .. got.body else tostring(trouble) end)
  return 0
end
]]))
  local server <close> = assert(Net.listen(Net.tcp("127.0.0.1", 0), { timeout_ns = Clock.seconds(20) }))
  local url = "http://127.0.0.1:" .. tostring(assert(server.address.port)) .. "/items/1"
  local args = { "--standalone", script, method, url }
  if body ~= nil then args[#args + 1] = body end
  local started = Test.cosmic(args, { timeout_ns = Child.FOREVER, stdout = "capture", stderr = "capture" })
  local child <close> = assert(Child.start(started.argv, started.options))
  local accepted, refused = server:accept()
  if accepted == nil then
    local died, _ = child:wait(Clock.seconds(5))
    error(tostring(refused) .. ": " .. tostring(died ~= nil and died.stderr)) -- checked: or_mix
  end
  local conn <close> = accepted
  local request = ""
  local head_start = request:find("\r\n\r\n", 1, true)
  while head_start == nil do
    request = request .. chunk_of(conn)
    head_start = request:find("\r\n\r\n", 1, true)
  end
  local head_end = head_start + 3
  -- The pattern takes digits only, and "0" is the default.
  local length = assert(tonumber(request:sub(1, head_end):lower():match("\r\ncontent%-length: *(%d+)") or "0"),
    "a Content-Length of digits")
  while #request < head_end + length do request = request .. chunk_of(conn) end
  assert(conn:write("HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\ndone"))
  local _, _ = conn:close()
  local result = assert(child:wait(Clock.seconds(20)))
  assert(result.code == 0, tostring(result.code) .. " " .. tostring(result.stderr))
  return request, result.stdout or ""
end

--- A PUT reaches the server as a PUT carrying its body, and its response
--- comes back whole.
local function test_request_sends_a_put_with_its_body(tmp: string)
  local request, said = served(tmp, "PUT", "new item")
  assert(request:find("PUT /items/1 HTTP/1.1\r\n", 1, true) == 1, request)
  assert(request:sub(-#"\r\n\r\nnew item") == "\r\n\r\nnew item", request)
  assert(said == "200 done", said)
end

--- A DELETE reaches the server as a DELETE with no body.
local function test_request_sends_a_delete(tmp: string)
  local request, said = served(tmp, "DELETE")
  assert(request:find("DELETE /items/1 HTTP/1.1\r\n", 1, true) == 1, request)
  assert(request:sub(-4) == "\r\n\r\n", request)
  assert(not request:lower():find("content-length", 1, true), request)
  assert(said == "200 done", said)
end

--- The bytes of a TLS record from `conn`: its 5-byte header, then as
--- many bytes as the header says, with whatever `pending` already holds.
local function tls_record(conn: Net.Conn, pending: string): string
  local got = pending
  while #got < 5 do got = got .. chunk_of(conn) end
  local length = string.unpack(">I2", got, 4)
  while #got < 5 + length do got = got .. chunk_of(conn) end
  return got:sub(1, 5 + length)
end

--- A TLS 1.2 ServerHello for `hello`, a ClientHello record,
--- with `version` as its legacy_version: the ClientHello's session id,
--- the first ECDHE suite it offers, no compression and no extensions.
local function server_hello(hello: string, version: integer): string
  -- The record header is 5 bytes and the handshake header 4, then the
  -- client's version (2) and random (32): the session id's length is at 44.
  local at = 44
  local id_length = assert(hello:byte(at), "a ClientHello cut short")
  local session_id = hello:sub(at + 1, at + id_length)
  at = at + 1 + id_length
  local suites_length = string.unpack(">I2", hello, at)
  local offered: mut {integer: boolean} = {}
  for i = at + 2, at + 1 + suites_length, 2 do offered[string.unpack(">I2", hello, i)] = true end
  local suite = 0
  for _, ecdhe in ipairs({ 0xC02B, 0xC02F, 0xC02C, 0xC030, 0xCCA9, 0xCCA8 }) do
    if suite == 0 and offered[ecdhe] == true then suite = ecdhe end
  end
  assert(suite ~= 0, "the client offers no ECDHE suite")
  local body = string.pack(">I2", version) .. string.rep("\1", 32) .. string.char(id_length) .. session_id ..
    string.pack(">I2", suite) .. "\0"
  local handshake = "\2" .. string.pack(">I3", #body) .. body
  return "\x16\x03\x03" .. string.pack(">I2", #handshake) .. handshake
end

--- A TLS 1.2 ServerHello whose legacy_version is TLS 1.3's (0x0304) is
--- refused for its version, with a protocol_version alert (70). mbedtls
--- 4.1.1 took the version (CVE-2026-115490), so a server that replied to
--- fit could finish a handshake with no ephemeral secret in its keys;
--- this one it refused only later, with handshake_failure (40).
local function test_a_tls_1_2_server_hello_naming_tls_1_3_is_refused(tmp: string)
  local script = tmp .. "/hello.tl"
  assert(Fs.write(script, [[
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Http = require("cosmic.http")

return function(argv: {string}): integer
  local _, trouble = Http.open((argv[1] or ""), { timeout_ns = Clock.seconds(10) })
  local _, _ = Fs.put(Fs.stdout, tostring(trouble))
  return 0
end
]]))
  local server <close> = assert(Net.listen(Net.tcp("127.0.0.1", 0), { timeout_ns = Clock.seconds(20) }))
  local url = "https://127.0.0.1:" .. tostring(assert(server.address.port)) .. "/"
  local started = Test.cosmic({ "--standalone", script, url }, { timeout_ns = Child.FOREVER, stdout = "capture", stderr = "capture" })
  local child <close> = assert(Child.start(started.argv, started.options))
  local conn <close> = assert(server:accept())
  local hello = tls_record(conn, "")
  assert(hello:byte(1) == 0x16 and hello:byte(6) == 1, "not a ClientHello")
  assert(conn:write(server_hello(hello, 0x0304)))
  conn:set_timeout(Clock.seconds(5))
  local answer = ""
  while #answer < 7 do
    local more, _ = conn:read()
    if more == nil or more == false or more == "" then break end
    answer = answer .. more
  end
  local _, _ = conn:close()
  local result = assert(child:wait(Clock.seconds(20)))
  assert(result.code == 0, tostring(result.stderr))
  local shown = answer:gsub(".", function(c: string): string
    return ("%02x"):format(assert(c:byte()))
  end)
  -- An alert record: type 21, a 2-byte body, level fatal (2), protocol_version (70).
  assert(answer:byte(1) == 0x15 and answer:sub(4, 5) == "\0\2" and answer:byte(6) == 2 and answer:byte(7) == 70,
    "answered " .. shown .. "; the client said: " .. tostring(result.stdout))
end

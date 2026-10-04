--- cosmic.http's tests that need the program itself, apart from
--- cosmic/http_test.tl's so those stand while the tree moves:
--- $SSL_CERT_FILE, which only a fresh process started from the program
--- reads, and a client in a process of its own beside a local
--- server that sees the request as sent. The CA roots the binary's own
--- database carries are read in cosmic/http_store_test.tl.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local this_program = require("build.this_program")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")
--- What the scripts its tests run standalone require, which a child
--- is typed and run against only where the closure holds it (`lua`).
local type _ = require("cosmic.http")
local Clock = require("cosmic.clock")

--- Requests to a local port, closed or one a test serves, which a
--- loopback alone answers: the worker runs offline, and is keyed. And
--- the program itself, which its tests start only to run a script
--- standalone (`lua`, `standalone`).
Test.needs{ network = { "127.0.0.1" }, lua = true, standalone = true }

--- What a fresh process, $SSL_CERT_FILE naming `cert_file`, is told
--- when it opens a closed local port: the roots, that file's included,
--- are loaded once per process, at its first request.
local function refused_with_cert_file(tmp: string, cert_file: string): string
  local script = tmp .. "/open.tl"
  assert(Fs.write(script, [[
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Http = require("cosmic.http")
local _, trouble = Http.open("http://127.0.0.1:1/", { connect_timeout_ns = Clock.seconds(2) })
Fs.put(Fs.stdout, trouble or "")
]]))
  local started = this_program.program({ "--standalone", script },
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
--- that is to wait, it is sent SIGINT, and what it printed is answered.
--- `serve` is the server's side: it gets the accepted connection and
--- the request's head, and answers as it will, then stalls.
local function interrupted(tmp: string, body: string,
                           serve: function(Net.Conn, string)): string
  local script = tmp .. "/client.tl"
  assert(Fs.write(script, [[
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Http = require("cosmic.http")
return function(argv: {string}): integer
  local url, marker = argv[1], argv[2]
  local guard = assert(Child.guard())
]] .. body .. [[
  local caught = assert(guard:release())
  Fs.put(Fs.stdout, " " .. tostring(caught))
  return 0
end
]]))
  local server <close> = assert(Net.listen(Net.tcp("127.0.0.1", 0), { timeout_ns = Clock.seconds(20) }))
  local url = "http://127.0.0.1:" .. server.address.port .. "/"
  local marker = tmp .. "/marker"
  local started = this_program.program({ "--standalone", script, url, marker },
    { stdout = "capture", stderr = "capture" })
  local child <close> = assert(Child.start(started.argv, started.options))
  local conn <close> = assert(server:accept())
  local head = ""
  while not head:find("\r\n\r\n", 1, true) do head = head .. assert(conn:read()) end
  serve(conn, head)
  for _ = 1, 2000 do
    if Fs.stat(marker) ~= nil then break end
    assert(sys.nanosleep(Clock.ms(10)))
  end
  assert(Fs.stat(marker) ~= nil, "the client never reached its wait")
  assert(child:stop(sys.SIGINT))
  local result = assert(child:wait(Clock.seconds(20)))
  assert(result.code == 0, tostring(result.code) .. " " .. tostring(result.stderr))
  return result.stdout or ""
end

--- A body `read` that waits on a server that sent part of the body and
--- stalls ends when a guard catches a signal.
local function test_a_caught_signal_ends_a_read_that_waits(tmp: string)
  local said = interrupted(tmp, [[
  local response = assert(Http.open(url))
  assert(assert(response:read()) == "part")
  assert(Fs.write(marker, ""))
  local data, why = response:read()
  Fs.put(Fs.stdout, tostring(data) .. " " .. why)
]], function(conn: Net.Conn, _head: string)
  assert(conn:write("HTTP/1.1 200 OK\r\nContent-Length: 100000\r\n\r\npart"))
end)
  assert(said == "nil interrupted " .. sys.SIGINT, said)
end

--- A download that waits on a server that sent part of the body and
--- stalls fails "interrupted" when a guard catches a signal, though the
--- caller's `cancelled` answers true by then too, as the verbs' own do,
--- and leaves nothing at its path or beside it.
local function test_a_caught_signal_ends_a_download_that_waits(tmp: string)
  local said = interrupted(tmp, [[
  local target = marker .. ".target"
  local ok, why = Http.download(url, target, {
    cancelled = function(): boolean
      if not Fs.stat(marker) then assert(Fs.write(marker, "")) end
      return guard:cancelled() ~= 0
    end,
  })
  Fs.put(Fs.stdout, tostring(ok) .. " " .. why)
]], function(conn: Net.Conn, _head: string)
  assert(conn:write("HTTP/1.1 200 OK\r\nContent-Length: 100000\r\n\r\npart"))
end)
  assert(said == "false interrupted " .. sys.SIGINT, said)
  for _, name in ipairs((assert(Fs.list(tmp)))) do
    assert(not name:find(".target", 1, true), "left behind: " .. name)
  end
end

--- A request [`Http.request`] sends to a local server, as the server
--- read it, and what the client then printed: the status and body of
--- the server's "done", or why it failed. The client runs in a process
--- of its own, since a server in this one could not answer while the
--- request blocks. Only a server sees what [`Http.request`] sends:
--- the scripted transport's `sent` is a Response's, and the whole body
--- it answers has none.
local function served(tmp: string, method: string, body?: string): string, string
  local script = tmp .. "/request.tl"
  assert(Fs.write(script, [[
local Fs = require("cosmic.fs")
local Http = require("cosmic.http")
return function(argv: {string}): integer
  local got, trouble = Http.request(argv[1], argv[2], { body = argv[3] })
  Fs.put(Fs.stdout, got ~= nil and tostring(got.status) .. " " .. got.body or trouble)
  return 0
end
]]))
  local server <close> = assert(Net.listen(Net.tcp("127.0.0.1", 0), { timeout_ns = Clock.seconds(20) }))
  local url = "http://127.0.0.1:" .. server.address.port .. "/items/1"
  local args = { "--standalone", script, method, url }
  if body ~= nil then args[#args + 1] = body end
  local started = this_program.program(args, { stdout = "capture", stderr = "capture" })
  local child <close> = assert(Child.start(started.argv, started.options))
  local accepted, refused = server:accept()
  if accepted == nil then
    local died = child:wait(Clock.seconds(5))
    error(refused .. ": " .. tostring(died ~= nil and died.stderr))
  end
  local conn <close> = accepted
  local request = ""
  while not request:find("\r\n\r\n", 1, true) do request = request .. assert(conn:read()) end
  local head_end = request:find("\r\n\r\n", 1, true) + 3
  local length = tonumber(request:sub(1, head_end):lower():match("\r\ncontent%-length: *(%d+)") or "0")
  while #request < head_end + length do request = request .. assert(conn:read()) end
  assert(conn:write("HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\ndone"))
  conn:close()
  local result = assert(child:wait(Clock.seconds(20)))
  assert(result.code == 0, tostring(result.code) .. " " .. tostring(result.stderr))
  return request, result.stdout or ""
end

--- A PUT reaches the server as a PUT carrying its body, and its answer
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

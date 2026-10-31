--- [`Http.Options.via`] against [`Server.serve`] on a socket file: the
--- client holds its thread while it waits, so it runs in a child of this
--- program against a server here, as cosmic/http/server_tool_test.tl's do.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Http = require("cosmic.http")
local Net = require("cosmic.net")
local Server = require("cosmic.http.server")
local Test = require("cosmic.test")
local _ = require("build.standalone")
local this_program = require("build.this_program")

--- The program itself, started to run a script `--standalone`
--- ([`build.standalone`]), and a socket file in the test's directory.
Test.policy{ profiles = { "cosmic" }, loopback = { "127.0.0.1" }, requires = { "unix_socket" } }

--- What the client's run came to, once it has.
local record Ran
  mut value: Child.Result?
end

--- The requests a server saw, as "target @host" joined by "|".
local record Seen
  mut text: string
end

--- Serves on a socket file in `tmp` while the program runs `client` as a
--- script, given the socket's path as its argument, and returns what the
--- client printed and the requests the server saw, each target with its Host.
local function across(tmp: string, client: string): string, string
  local script = tmp .. "/client.tl"
  assert(Fs.write(script, client))
  local seen: Seen = { text = "" }
  local ran: Ran = { value = nil }
  assert(Server.serve{
    listeners = { Net.unix(tmp .. "/s.sock") },
    on_stop = function(_: Net.Server) end,
    handle = function(req: Server.Request): Server.Reply
      seen.text = seen.text .. (if seen.text == "" then "" else "|" end) .. req.target .. " @" .. (req.headers["host"] or "")
      if req.path == "/moved" then
        return { status = 302, headers = { Location = "/final" } }
      end
      return { status = 200, body = "body of " .. req.path }
    end,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      local started = this_program.program({ "--standalone", script, assert(addresses[1].path) },
        { stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(60) })
      ran.value = assert(Child.run(started.argv, started.options))
      server:stop()
    end,
  })
  local result_value = ran.value
  assert(result_value ~= nil, "the server never became ready")
  assert(result_value.code == 0, tostring(result_value.code) .. " " .. tostring(result_value.stderr))
  return assert(result_value.stdout), seen.text
end

--- The URL gives the request line and the Host; the socket file is where
--- the bytes go, so a host that names nothing is never looked up.
local function test_a_request_goes_over_the_socket_with_the_urls_host(tmp: string)
  local said, seen = across(tmp, [[
local Fs = require("cosmic.fs")
local Http = require("cosmic.http")
local Net = require("cosmic.net")
return function(argv: {string}): integer
  local got = assert(Http.get("http://files.test:8080/hello?x=1", { via = Net.unix((argv[1] or "")) }))
  local _, _ = Fs.put(Fs.stdout, tostring(got.status) .. " " .. got.body)
  return 0
end
]])
  assert(said == "200 body of /hello", said)
  assert(seen == "/hello?x=1 @files.test:8080", seen)
end

--- A redirect would lead anywhere the socket's server does not serve, so
--- `via` answers it instead of following it, until `follow = true` asks;
--- then it goes through the same socket.
local function test_a_redirect_is_not_followed_over_the_socket_unless_asked(tmp: string)
  local said, seen = across(tmp, [[
local Fs = require("cosmic.fs")
local Http = require("cosmic.http")
local Net = require("cosmic.net")
return function(argv: {string}): integer
  local via = Net.unix((argv[1] or ""))
  local moved = assert(Http.get("http://files.test/moved", { via = via }))
  local followed = assert(Http.get("http://files.test/moved", { via = via, follow = true }))
  local _, _ = Fs.put(Fs.stdout, table.concat({
    tostring(moved.status) .. " " .. (moved.headers["location"] or "") .. " " .. moved.body,
    tostring(followed.status) .. " " .. followed.body,
  }, "\n"))
  return 0
end
]])
  assert(said == "302 /final \n200 body of /final", said)
  assert(seen == "/moved @files.test|/moved @files.test|/final @files.test",
    seen)
end

--- A client script's lines: a download's destination is `out` beside the
--- socket, and what a download wrote there is read back and printed.
local download_prelude = [[
local Fs = require("cosmic.fs")
local Http = require("cosmic.http")
local Net = require("cosmic.net")
local function destination(sock: string): string
  return (sock:gsub("/s%.sock$", "/out"))
end
]]

--- `open` takes the same `via`: the URL gives the request line and the
--- Host, and the body streams from the socket's server.
local function test_open_streams_a_body_over_the_socket(tmp: string)
  local said, seen = across(tmp, [[
local Fs = require("cosmic.fs")
local Http = require("cosmic.http")
local Net = require("cosmic.net")
local Stream = require("cosmic.stream")
return function(argv: {string}): integer
  local response = assert(Http.open("http://files.test:8080/streamed?y=2", { via = Net.unix((argv[1] or "")) }))
  local body = assert(Stream.read_all(response))
  local _, _ = response:close()
  local _, _ = Fs.put(Fs.stdout, tostring(response.status) .. " " .. body)
  return 0
end
]])
  assert(said == "200 body of /streamed", said)
  assert(seen == "/streamed?y=2 @files.test:8080", seen)
end

--- `open`, like `get`, answers a redirect rather than following it.
local function test_open_does_not_follow_a_redirect_over_the_socket(tmp: string)
  local said, seen = across(tmp, [[
local Fs = require("cosmic.fs")
local Http = require("cosmic.http")
local Net = require("cosmic.net")
return function(argv: {string}): integer
  local response = assert(Http.open("http://files.test/moved", { via = Net.unix((argv[1] or "")) }))
  local _, _ = response:close()
  local _, _ = Fs.put(Fs.stdout, tostring(response.status) .. " " .. (response.headers["location"] or ""))
  return 0
end
]])
  assert(said == "302 /final", said)
  assert(seen == "/moved @files.test", seen)
end

--- `download` writes the served body to its file, asking the socket's
--- server for the URL's path with the URL's host.
local function test_download_writes_the_body_it_fetched_over_the_socket(tmp: string)
  local said, seen = across(tmp, download_prelude .. [[
return function(argv: {string}): integer
  local dest = destination((argv[1] or ""))
  local ok, why = Http.download("http://files.test:8080/pkg.tar?z=3", dest, { via = Net.unix((argv[1] or "")) })
  assert(ok, why)
  local _, _ = Fs.put(Fs.stdout, (assert(Fs.read(dest))))
  return 0
end
]])
  assert(said == "body of /pkg.tar", said)
  assert(seen == "/pkg.tar?z=3 @files.test:8080", seen)
end

--- `download_result` takes the same `via` and reports "downloaded".
local function test_download_result_writes_the_body_it_fetched_over_the_socket(tmp: string)
  local said, seen = across(tmp, download_prelude .. [[
return function(argv: {string}): integer
  local dest = destination((argv[1] or ""))
  local result = Http.download_result("http://files.test:8080/pkg.tar?z=3", dest, { via = Net.unix((argv[1] or "")) })
  assert(result.kind == "downloaded", result.kind .. ": " .. result.reason)
  local _, _ = Fs.put(Fs.stdout, result.kind .. " " .. result.reason .. "|" .. assert(Fs.read(dest)))
  return 0
end
]])
  assert(said == "downloaded |body of /pkg.tar", said)
  assert(seen == "/pkg.tar?z=3 @files.test:8080", seen)
end

--- A download is of the first response: over `via` a 3xx is not followed,
--- so it is not a 2xx and fails with its status, leaving no file; with
--- `follow = true` the redirect goes through the same socket and the
--- final body is written.
local function test_a_download_over_the_socket_fails_on_a_redirect_unless_asked_to_follow(tmp: string)
  local said, seen = across(tmp, download_prelude .. [[
return function(argv: {string}): integer
  local via = Net.unix((argv[1] or ""))
  local dest = destination((argv[1] or ""))
  local ok, why = Http.download("http://files.test/moved", dest, { via = via })
  local result = Http.download_result("http://files.test/moved", dest, { via = via })
  local lines = {
    tostring(ok) .. " " .. why,
    result.kind .. " " .. tostring(result.status),
    "exists " .. tostring((Fs.exists(dest))),
  }
  local followed, followed_why = Http.download("http://files.test/moved", dest, { via = via, follow = true })
  assert(followed, followed_why)
  lines[#lines + 1] = (assert(Fs.read(dest)))
  local _, _ = Fs.put(Fs.stdout, table.concat(lines, "\n"))
  return 0
end
]])
  assert(said == "false http://files.test/moved: HTTP 302\nhttp_status 302\nexists false\nbody of /final", said)
  assert(seen == "/moved @files.test|/moved @files.test|/moved @files.test|/final @files.test", seen)
end

--- A request over a socket that cannot be connected to names the socket
--- path and why, as [`Net.connect`] says it, and no `host:port` of the
--- URL, which a reader would take for a TCP port the request never uses.
local function test_a_connect_failure_names_the_socket_and_the_reason(tmp: string)
  local missing = tmp .. "/none.sock"
  local _, why = Http.get("http://authd.local/", { via = Net.unix(missing) })
  assert(why == "cannot connect to unix socket " .. missing .. ": No such file or directory", tostring(why))
  assert(not why:find(":80", 1, true), why)

  local plain = tmp .. "/plain"
  assert(Fs.write(plain, "not a socket"))
  local _, refused = Http.request("POST", "http://authd.local:8080/", { via = Net.unix(plain), body = "x" })
  assert(refused == "cannot connect to unix socket " .. plain .. ": Connection refused", tostring(refused))
  assert(Fs.remove(plain))
end

--- [`Http.Options.via`] against [`Server.serve`] on a socket file: the
--- client holds its thread while it waits, so it runs in a child of this
--- program against a server here, as cosmic/http/server_tool_test.tl's do.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local Server = require("cosmic.http.server")
local Test = require("cosmic.test")
local _ = require("build.standalone")
local this_program = require("build.this_program")
--- What the client script, run standalone, requires.
local type _ = require("cosmic.http")

--- The program itself, started to run a script `--standalone`
--- ([`build.standalone`]), and a socket file in the test's directory.
Test.policy{ profiles = { "cosmic" }, loopback = { "127.0.0.1" }, requires = { "unix_socket" } }

--- What the client's run came to, once it has.
local record Ran
  value: Child.Result | nil
end

--- The requests a server saw, as "target @host" joined by "|".
local record Seen
  text: string
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
      seen.text = seen.text .. (seen.text == "" and "" or "|") .. req.target .. " @" .. (req.headers["host"] or "")
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
  local got = assert(Http.get("http://files.test:8080/hello?x=1", { via = Net.unix(argv[1]) }))
  Fs.put(Fs.stdout, got.status .. " " .. got.body)
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
  local via = Net.unix(argv[1])
  local moved = assert(Http.get("http://files.test/moved", { via = via }))
  local followed = assert(Http.get("http://files.test/moved", { via = via, follow = true }))
  Fs.put(Fs.stdout, table.concat({
    moved.status .. " " .. moved.headers.location .. " " .. moved.body,
    followed.status .. " " .. followed.body,
  }, "\n"))
  return 0
end
]])
  assert(said == "302 /final \n200 body of /final", said)
  assert(seen == "/moved @files.test|/moved @files.test|/final @files.test",
    seen)
end

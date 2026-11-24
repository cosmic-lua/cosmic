--- A connection over https kept for the next request that trusts what
--- it was verified against, and only for it, over a TLS server of the
--- test's own run: the CA blob a request names is the request's to keep
--- alive, and the pooled connection holds a copy of its own.

local Array = require("cosmic.array")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Http = require("cosmic.http")
local Net = require("cosmic.net")
local Server = require("cosmic.http.server")
local Test = require("cosmic.test")
local Tls = require("cosmic.tls")

Test.policy{ loopback = { "127.0.0.1" }, grants = { { path = "testdata/tls", letters = "r" } } }

--- The fixture `name` of testdata/tls.
local function fixture(name: string): string
  return (assert(Fs.read("testdata/tls/" .. name)))
end

--- Serves b.pem (for 127.0.0.1) over TLS, each reply carrying the
--- port of the connection it came on, and runs `body` with the server's
--- https URL in a task of its run.
local function serving(body: function(base: string))
  assert(Server.serve{
    listeners = { Net.tcp("127.0.0.1", 0) },
    tls = Tls.certs(Tls.static({ { cert = fixture("b.pem"), key = fixture("b.key") } })),
    on_error = function(_: string) end,
    handle = function(req: Server.Request): Server.Reply
      local from = req.peer
      return { status = 200, body = tostring(from and from.port) }
    end,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      local port = assert(Array.at(addresses, 1).port)
      local ok, trouble: boolean, any = pcall(body, "https://127.0.0.1:" .. tostring(port) .. "/")
      server:stop()
      assert(ok, tostring(trouble))
    end,
  })
end

--- A second request with the same `ca` takes the first one's connection,
--- after a collection between them; one trusting other roots is
--- verified on a connection of its own and refused.
local function test_a_connection_is_reused_for_the_same_roots_alone()
  serving(function(base: string)
    local first = assert(Http.get(base, { timeout_ns = Clock.seconds(20), roots = "none", ca = fixture("ca.pem") }))
    collectgarbage("collect")
    collectgarbage("collect")
    local second = assert(Http.get(base, { timeout_ns = Clock.seconds(20), roots = "none", ca = fixture("ca.pem") }))
    assert(first.status == 200 and second.body == first.body,
      ("the second request came on port %s, the first on %s"):format(second.body, first.body))
    local got, why = Http.get(base, { timeout_ns = Clock.seconds(20) })
    assert(got == nil and tostring(why):find("not correctly signed", 1, true) ~= nil, why)
  end)
end

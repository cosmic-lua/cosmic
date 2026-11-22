--- A redirect from https to http, refused by default, over a TLS server
--- of the test's own run: the scripted transport cannot finish a TLS
--- handshake, so cosmic/http_test.tl cannot start over https.

local Array = require("cosmic.array")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Http = require("cosmic.http")
local Net = require("cosmic.net")
local Test = require("cosmic.test")
local Tls = require("cosmic.tls")

Test.policy{ loopback = { "127.0.0.1" }, grants = { { path = "testdata/tls", letters = "r" } } }

--- The fixture `name` of testdata/tls.
local function fixture(name: string): string
  return (assert(Fs.read("testdata/tls/" .. name)))
end

--- Serves b.pem (for 127.0.0.1) over TLS, each request answered with a
--- 302 to `location`, and runs `body` with the server's https URL in a
--- task of its run.
local function redirecting(location: string, body: function(base: string))
  assert(Net.serve{
    listeners = { Net.tcp("127.0.0.1", 0) },
    tls = Tls.certs(Tls.static({ { cert = fixture("b.pem"), key = fixture("b.key") } })),
    on_error = function(_: string) end,
    serve = function(conn: Net.Conn)
      if not conn:handshake() then return end
      local seen = ""
      while not seen:find("\r\n\r\n", 1, true) do
        local chunk = conn:read()
        if chunk == nil then return end
        seen = seen .. chunk
      end
      local _, _ = conn:write("HTTP/1.1 302 Found\r\nLocation: " .. location ..
          "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    end,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      local port = assert(Array.at(addresses, 1).port)
      local ok, trouble: boolean, any = pcall(body, "https://127.0.0.1:" .. tostring(port) .. "/")
      server:stop()
      assert(ok, tostring(trouble))
    end,
  })
end

local function test_an_https_request_refuses_a_redirect_to_http_by_default()
  redirecting("http://127.0.0.1:1/plain", function(base: string)
    local opts: Http.Options = { timeout_ns = Clock.seconds(20), roots = "none", ca = fixture("ca.pem") }
    local got, why = Http.get(base, opts)
    assert(got == nil and why:find("disabled (in redirect)", 1, true) ~= nil, why)
    -- Asked for, the hop is attempted: port 1 of loopback refuses it.
    got, why = Http.get(base, { ...opts, redirect_protocols = { "http", "https" } })
    assert(got == nil and why:find("disabled", 1, true) == nil, why)
  end)
end

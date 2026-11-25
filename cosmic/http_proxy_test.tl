--- A request to this machine skips a proxy that the environment names
--- elsewhere, so it and a token in its headers never leave the machine;
--- a proxy on this machine, such as a sandbox's relay, is kept.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local HttpServer = require("cosmic.http.server")
local Net = require("cosmic.net")
local Proc = require("cosmic.proc")
local Test = require("cosmic.test")

Test.policy{ loopback = { "127.0.0.1" }, profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

--- A program that gets `url` and prints its status and body.
local GET = [[
local Clock = require("cosmic.clock")
local Http = require("cosmic.http")
return function(argv: {string}): integer
  local got, why = Http.get(assert(argv[1]), { timeout_ns = Clock.seconds(20) })
  print(if got ~= nil then tostring(got.status) .. " " .. got.body else "failed: " .. tostring(why) end)
  return 0
end
]]

--- What the program prints for `url` with the proxy variable `variable`
--- (`http_proxy` where nil) set to `proxy`.
local function got_with(proxy: string, url: string, variable?: string): string
  local tmp = assert(Fs.mkdtemp("proxy-"))
  assert(Fs.write(tmp .. "/get.tl", GET))
  local relaunch = assert(Proc.relaunch())
  local env = Env.all()
  for name, value in pairs(relaunch.env) do env[name] = value end
  for _, name in ipairs({ "HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "ALL_PROXY", "all_proxy", "NO_PROXY", "no_proxy" }) do
    env[name] = nil
  end
  env["http_proxy"] = nil
  env[variable or "http_proxy"] = proxy
  env["COSMIC_TEST_SANDBOX"] = "0"
  local argv: mut {string} = { table.unpack(relaunch.argv) }
  argv[#argv + 1] = tmp .. "/get.tl"
  argv[#argv + 1] = url
  local ran = assert(Child.run(argv, { env = env, fds = relaunch.fds, cwd = tmp, stdout = "capture",
    stderr = "capture", timeout_ns = Clock.seconds(120) }))
  assert(ran.code == 0, tostring(ran.stderr))
  return ((ran.stdout or ""):gsub("\n$", ""))
end

local function test_a_loopback_request_skips_a_proxy_elsewhere_and_keeps_one_here()
  assert(HttpServer.serve{
    listeners = { Net.tcp("127.0.0.1", 0), Net.tcp("127.0.0.1", 0) },
    handle = function(req: HttpServer.Request): HttpServer.Reply
      local proxied = req.target:sub(1, 7) == "http://"
      return { status = 200, body = if proxied then "proxied" else "direct" end }
    end,
    on_ready = function(addresses: {Net.Address}, running: Net.Server)
      local port = tostring(assert(addresses[1]).port)
      local origin = "http://127.0.0.1:" .. port .. "/"
      local here = "http://127.0.0.1:" .. tostring(assert(addresses[2]).port)
      local said: mut {string: string} = {}
      said["away"] = got_with("http://192.0.2.1:9", origin)
      said["all"] = got_with("socks5h://192.0.2.1:9", origin, "all_proxy")
      said["named"] = got_with("192.0.2.1:9", "http://localhost:" .. port .. "/")
      said["under"] = got_with("http://192.0.2.1:9", "http://app.localhost.:" .. port .. "/")
      said["bare"] = got_with("http://192.0.2.1:9", "127.0.0.1:" .. port .. "/")
      said["kept"] = got_with(here, origin)
      running:stop()
      for _, case in ipairs({ "away", "all", "named", "under", "bare" }) do
        assert(said[case] == "200 direct", case .. ": " .. tostring(said[case]))
      end
      assert(said["kept"] == "200 proxied", said["kept"])
    end,
  })
end

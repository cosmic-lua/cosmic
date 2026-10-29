--- The children of the relay tests that run the relay's own modules as a program: cosmic/internal/relay_direct_test.tl
--- and cosmic/internal/relay_handed_test.tl start this program again with the words
--- [`build.test_child`]'s `words` makes, and it runs the child registered here. They are here rather than in the tests
--- because a chunk run by `-e` may not require a module of `cosmic.internal`, which a test of one is named for.

local Clock = require("cosmic.clock")
local Config = require("cosmic.internal.relay_config")
local Connector = require("cosmic.internal.connector")
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Relay = require("cosmic.internal.relay_server")
local SandboxRelay = require("cosmic.internal.relay_start")
local relay_main = require("cosmic.internal.relay_main")
local test_child = require("build.test_child")

local record relay_children
end

--- The relay's main, as the macOS start runs it.
test_child.register("relay", function(args: {string}): integer
  return relay_main(args)
end)

--- The child that prepares the upstream proxy.test, named by the caller's https_proxy, as
--- the starter does (resolving it through the name server at 127.0.0.1
--- port argv[1]), and serves a relay that resolves through the same server,
--- with a proxy of its own at the port https_proxy names: asks it for
--- api.test three times (through the proxy), for ungranted.test (refused
--- before any lookup) and for direct.test (granted, reached directly, and so
--- looked up). Prints each answer's status line, a line each.
test_child.register("serve", function(argv: {string}): integer
  local dns_port = assert(math.tointeger(tonumber((argv[1] or ""))))
  local servers: {Net.Endpoint} = { { host = "127.0.0.1", port = dns_port } }
  local lines: mut {string} = {}
  Poll.run(function()
    local proxy = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
    local serving = Poll.spawn(function()
      while true do
        local conn, _ = proxy:accept()
        if conn == nil then return end
        Poll.spawn(function()
          local head = ""
          while not head:find("\r\n\r\n", 1, true) do
            local data, _ = conn:read(4096)
            if data == nil then break end
            head = head .. data
          end
          local _, _ = conn:write("HTTP/1.1 200 Connection established\r\n\r\n")
          local _, _ = conn:close()
        end)
      end
    end)
    -- As the starter does: the upstream's host resolved once, through a
    -- connector of the name servers.
    local plan = assert(SandboxRelay.plan({}, { https_proxy = "http://proxy.test:" .. tostring(assert(proxy.address.port)),
      no_proxy = "direct.test" }))
    local up = assert(plan.upstream)
    local name_servers = assert(SandboxRelay.name_servers({ servers = { { host = "127.0.0.1", port = dns_port } } }))
    local dns = assert(Connector.start(name_servers.servers, name_servers.wait_ns // 1000000))
    local resolved = assert(SandboxRelay.upstream_addresses(up, { fd = dns.fd, name_servers = name_servers }, ""))
    local pinned: Config.Upstream = { host = up.host, port = up.port, authorization = up.authorization,
      no_proxy = up.no_proxy, addresses = resolved }
    assert(dns:close())
    table.insert(lines, "upstream " .. table.concat(resolved, ","))
    local resolve_connector = assert(Net.connector(servers, { timeout_ns = name_servers.wait_ns }))
    local resolve: Net.ResolveOptions = { servers = servers, connector = resolve_connector }
    local http = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
    local relay = Relay.start({
      http = http, grants = { "api.test:443", "direct.test:443" }, upstream = pinned, resolve = resolve,
      log = function(_: string) end,
      connector = function(address: string, port: integer, timeout_ns: integer): Net.Conn?, string
        return Net.connect(Net.tcp(address, port), { timeout_ns = timeout_ns })
      end,
    })
    for _, target in ipairs({ "api.test:443", "api.test:443", "api.test:443", "ungranted.test:443",
        "direct.test:443" }) do
      local conn = assert(Net.connect(http.address, { timeout_ns = Clock.seconds(5) }))
      conn:set_timeout(Clock.seconds(10))
      assert(conn:write("CONNECT " .. target .. " HTTP/1.1\r\nHost: " .. target .. "\r\n\r\n"))
      local reply = ""
      while not reply:find("\r\n") do
        local data, _ = conn:read(4096)
        if data == nil then break end
        reply = reply .. data
      end
      table.insert(lines, target .. " " .. (reply:match("^HTTP/1.1 (%d+)") or "none"))
      local _, _ = conn:close()
    end
    relay:stop()
    relay:wait()
    assert(resolve_connector:close())
    serving:cancel()
    assert(http:close())
    assert(proxy:close())
  end)
  local _, _ = Fs.put(Fs.stdout, table.concat(lines, "\n"))
  return 0

end)

return relay_children

--- What the relay's starter reads and decides (cosmic/sandbox/relay.tl):
--- what a policy's `connect` targets open, the cap on the addresses a
--- table holds, the name servers and the wait for each, and the upstream
--- proxy resolved once. What the relay does with the connectors it is
--- handed is cosmic/relay/handed_test.tl's.

local Clock = require("cosmic.clock")
local Net = require("cosmic.net")
local SandboxRelay = require("cosmic.sandbox.relay")

--- Literal targets are each address once, in the form a table takes, a
--- port of "*" as 0; a target that is no literal of the forms a grant
--- takes opens nothing; any name, or "*", opens names.
local function test_a_plan_reads_the_targets_as_the_relay_does()
  local plan = assert(SandboxRelay.plan({ "127.0.0.1:80", "[::1]:*", "127.0.0.1:80", "[::1:443",
    "2001:db8::1:443", "[10.0.0.1]:80" }, {}))
  local rows: {string} = {}
  for _, entry in ipairs(plan.literals) do rows[#rows + 1] = entry.host .. " " .. entry.port end
  assert(table.concat(rows, ",") == "127.0.0.1 80,0:0:0:0:0:0:0:1 0", table.concat(rows, ","))
  assert(not plan.names and plan.upstream == nil)
  for _, grant in ipairs({ "api.example.test:443", "*:443", "*:*" }) do
    assert(assert(SandboxRelay.plan({ grant }, {})).names, grant)
  end
  assert(not assert(SandboxRelay.plan({ "a*.test:443", "a.test:0443" }, {})).names, "a pattern opens nothing")
end

--- More addresses named literally than a connector holds are refused,
--- naming the count and the cap, before anything is started; so are those
--- the upstream proxy's address takes past it. An upstream that cannot be
--- used is refused naming why.
local function test_more_addresses_than_a_table_holds_are_refused()
  local grants: {string} = {}
  for port = 1, 129 do grants[port] = "127.0.0.1:" .. port end
  local none, why = SandboxRelay.plan(grants, {})
  assert(none == nil and why == "connect names 129 addresses literally: 129 endpoints, more than the 128 a " ..
      "connector holds; grant fewer addresses, or names", why)
  grants[129] = nil
  local plan = assert(SandboxRelay.plan(grants, { https_proxy = "http://10.0.0.1:3128" }))
  assert(plan.upstream.host == "10.0.0.1" and plan.upstream.port == 3128)
  local over, over_why = SandboxRelay.table(plan, { "10.0.0.1" })
  assert(over == nil and over_why:find("connect names 128 addresses literally, with the upstream " ..
      "proxy's: 129 endpoints", 1, true), over_why)
  local bad, bad_why = SandboxRelay.plan({ "a.test:1" }, { https_proxy = "https://proxy.test:3128" })
  assert(bad == nil and bad_why:find("https_proxy has the scheme \"https\"", 1, true), bad_why)
end

--- A fixed port of an address granted at any port is dropped, a repeat too,
--- and the endpoints and the port-table bytes are limited together: 32 IPv4
--- or 16 IPv6 addresses at any port fit, one more does not, and the message
--- names the limit it passed.
local function test_plan_normalizes_and_limits_endpoints_and_table_bytes_together()
  local plan = assert(SandboxRelay.plan({ "10.0.0.1:80", "10.0.0.1:*", "10.0.0.1:443", "10.0.0.2:80",
    "10.0.0.2:80", "[2001:db8::1]:*", "[2001:db8::1]:80" }, {}))
  local rows: {string} = {}
  for _, entry in ipairs(plan.literals) do rows[#rows + 1] = entry.host .. " " .. entry.port end
  assert(table.concat(rows, ",") == "10.0.0.1 0,10.0.0.2 80,2001:db8:0:0:0:0:0:1 0", table.concat(rows, ","))
  local v4: {string} = {}
  for i = 1, 32 do v4[i] = "10.0.0." .. i .. ":*" end
  assert(SandboxRelay.plan(v4, {}) ~= nil)
  v4[33] = "10.0.0.33:*"
  local none, why = SandboxRelay.plan(v4, {})
  assert(none == nil and why:find("connect names 33 addresses literally: 33 MiB of port tables, more than the " ..
      "32 MiB a connector holds", 1, true), tostring(why))
  local v6: {string} = {}
  for i = 1, 16 do v6[i] = "[2001:db8::" .. i .. "]:*" end
  assert(SandboxRelay.plan(v6, {}) ~= nil)
  v6[17] = "[2001:db8::17]:*"
  local none6, why6 = SandboxRelay.plan(v6, {})
  assert(none6 == nil and why6:find("34 MiB of port tables", 1, true), tostring(why6))
  -- The upstream's address at a port its any-port grant covers adds nothing; at another, a slot of its own.
  local fits = assert(SandboxRelay.plan({ "10.0.0.1:*", "10.0.0.2:*" }, { https_proxy = "http://10.0.0.1:3128" }))
  local covered = assert(SandboxRelay.table(fits, { "10.0.0.1" }))
  assert(#covered == 2)
  local full: {string} = {}
  for i = 1, 32 do full[i] = "10.0.0." .. i .. ":*" end
  local tight = assert(SandboxRelay.plan(full, { https_proxy = "http://10.9.9.9:3128" }))
  local added = assert(SandboxRelay.table(tight, { "10.9.9.9" }))
  assert(#added == 33 and added[33].port == 3128)
end

--- The table holds the literals and the upstream's addresses at its port,
--- each once; a numeric upstream is its own address, with no lookup.
local function test_the_table_holds_the_literals_and_the_upstream()
  local plan = assert(SandboxRelay.plan({ "127.0.0.1:3128", "[2001:db8::1]:443" },
    { HTTPS_PROXY = "http://127.0.0.1:3128" }))
  local addresses = assert(SandboxRelay.upstream_addresses(plan.upstream, nil, "no name servers"))
  assert(table.concat(addresses, ",") == "127.0.0.1", table.concat(addresses, ","))
  local rows: {string} = {}
  local table_rows = assert(SandboxRelay.table(plan, addresses))
  for _, entry in ipairs(table_rows) do rows[#rows + 1] = entry.host .. " " .. entry.port end
  assert(table.concat(rows, ",") == "127.0.0.1 3128,2001:db8:0:0:0:0:0:1 443", table.concat(rows, ","))
  local named = assert(SandboxRelay.plan({}, { https_proxy = "http://proxy.test:3128" }))
  local none, why = SandboxRelay.upstream_addresses(named.upstream, nil, "no name servers here")
  assert(none == nil and why == "https_proxy's host proxy.test cannot be resolved: no name servers here", why)
end

--- The name servers' connector waits for each server a share of the
--- lookup's time; more servers than a connector holds are refused; the
--- public connector refuses the relay's deny list and the host's own
--- addresses.
local function test_name_servers_and_the_public_lists()
  local one = assert(SandboxRelay.name_servers({ servers = { { host = "127.0.0.1", port = 53 } } }))
  assert(#one.servers == 1 and one.wait_ns == Clock.seconds(5) // 2, tostring(one.wait_ns))
  local many: {Net.Endpoint} = {}
  for port = 1, 129 do many[port] = { host = "127.0.0.1", port = port } end
  local none, why = SandboxRelay.name_servers({ servers = many })
  assert(none == nil and why:find("more than a connector holds (128)", 1, true), why)
  local public = SandboxRelay.public({ "10.1.0.2" })
  local own, deny = assert(public.own), public.deny
  assert(own[1] == "10.1.0.2" and deny[1] == "169.254.169.254/32", deny[1])
end

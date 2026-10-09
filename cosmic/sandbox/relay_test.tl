--- What the relay's starter reads and decides (cosmic/sandbox/relay.tl):
--- what a policy's `connect` targets open, the cap on the addresses a
--- table holds, the name servers and the wait for each, and the upstream
--- proxy resolved once. What the relay does with the connectors it is
--- handed is cosmic/relay/handed_test.tl's.

local Clock = require("cosmic.clock")
local Net = require("cosmic.net")
local SandboxRelay = require("cosmic.sandbox.relay")
local Test = require("cosmic.test")

Test.policy{ promises = { "fork" } }

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
  assert(none == nil and why == "connect names 129 endpoints, more than the 128 a connector holds; " ..
      "grant fewer addresses, or names", why)
  grants[129] = nil
  local plan = assert(SandboxRelay.plan(grants, { https_proxy = "http://10.0.0.1:3128" }))
  assert(plan.upstream.host == "10.0.0.1" and plan.upstream.port == 3128)
  local over, over_why = SandboxRelay.table(plan, { "10.0.0.1" })
  assert(over == nil and over_why:find("connect and the upstream proxy together name 129 endpoints", 1, true), over_why)
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
  assert(none == nil and why:find("connect names addresses whose port tables take 33 MiB, more than the " ..
      "32 MiB a connector holds", 1, true), tostring(why))
  local v6: {string} = {}
  for i = 1, 16 do v6[i] = "[2001:db8::" .. i .. "]:*" end
  assert(SandboxRelay.plan(v6, {}) ~= nil)
  v6[17] = "[2001:db8::17]:*"
  local none6, why6 = SandboxRelay.plan(v6, {})
  assert(none6 == nil and why6:find("take 34 MiB", 1, true), tostring(why6))
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

--- Spellings of one address are one row; an IPv4-mapped IPv6 address is a row
--- of its own; the upstream at a fixed grant's address and another port
--- keeps both rows; 128 endpoints and 16 IPv6 wildcards are accepted by plan.
local function test_plan_collapses_spellings_and_keeps_distinct_rows()
  local plan = assert(SandboxRelay.plan({ "[2001:0db8::1]:80", "[2001:db8::1]:80", "[::ffff:10.0.0.1]:80",
    "10.0.0.1:80", "10.0.0.2:3128" }, { https_proxy = "http://10.0.0.2:8080" }))
  local rows: {string} = {}
  for _, entry in ipairs(plan.literals) do rows[#rows + 1] = entry.host .. " " .. entry.port end
  assert(#rows == 4 and rows[1] == "2001:db8:0:0:0:0:0:1 80" and rows[2]:find("ffff", 1, true) ~= nil and
      rows[3] == "10.0.0.1 80", table.concat(rows, ","))
  local both = assert(SandboxRelay.table(plan, { "10.0.0.2" }))
  assert(#both == 5 and both[4].port == 3128 and both[5].host == "10.0.0.2" and both[5].port == 8080,
    #both .. " rows")
  local most: {string} = {}
  for i = 1, 128 do most[i] = "10.0.0.1:" .. i end
  assert(#assert(SandboxRelay.plan(most, {})).literals == 128)
  local six: {string} = {}
  for i = 1, 16 do six[i] = "[2001:db8::" .. i .. "]:*" end
  assert(#assert(SandboxRelay.plan(six, {})).literals == 16)
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
  local many: SandboxRelay.NameServerOptions = { servers = {} }
  for port = 1, 129 do many.servers[port] = { host = "127.0.0.1", port = port } end
  local none, why = SandboxRelay.name_servers(many)
  assert(none == nil and why:find("more than a connector holds (128)", 1, true), why)
  local public = SandboxRelay.public({ "10.1.0.2" })
  local own, deny = assert(public.own), public.deny
  assert(own[1] == "10.1.0.2" and deny[1] == "169.254.169.254/32", deny[1])
end
--- Whether the core starts a connector on `rows`, and its refusal if not.
local function core_takes(rows: {Net.Endpoint}): boolean, string
  local ok, made, why = pcall(Net.connector, rows)
  if ok and made ~= nil then
    local _, _ = (made as Net.Connector):close()
    return true, ""
  end
  return false, tostring(ok and why or made)
end

--- The plan-time count of the port tables (cosmic/sandbox/relay.tl) agrees
--- with the core's (core/connector.c) at the 32 MiB boundary: 32 IPv4 and
--- 16 IPv6 addresses at any port start, one more of either is refused by
--- both, and so is a table whose alignment padding is what reaches the limit.
local function test_the_plan_and_the_core_count_the_port_tables_alike()
  local probe, absent = Net.connector({ { host = "127.0.0.1", port = 9 } })
  if probe == nil then Test.skip("no native connector: " .. tostring(absent)) end
  local _, _ = (probe as Net.Connector):close()
  local function agree(grants: {string}, accepted: boolean)
    local plan = SandboxRelay.plan(grants, {})
    assert((plan ~= nil) == accepted, "the plan " .. (accepted and "refused" or "took") .. " " .. #grants .. " grants")
    local rows: {Net.Endpoint} = {}
    for _, grant in ipairs(grants) do
      local host, port = grant:match("^%[?([^%]]+)%]?:([%d*]+)$")
      rows[#rows + 1] = { host = host, port = port == "*" and 0 or math.tointeger(port) as integer }
    end
    local took, why = core_takes(rows)
    assert(took == accepted, "the core " .. (took and "took" or "refused: " .. why) .. " what the plan did not agree to")
    if not accepted then assert(why:find("exceed 32 MiB", 1, true) ~= nil, why) end
  end
  local v4: {string} = {}
  for i = 1, 32 do v4[i] = "10.0.0." .. i .. ":*" end
  agree(v4, true)
  v4[33] = "10.0.0.33:*"
  agree(v4, false)
  local v6: {string} = {}
  for i = 1, 16 do v6[i] = "[2001:db8::" .. i .. "]:*" end
  agree(v6, true)
  v6[17] = "[2001:db8::17]:*"
  agree(v6, false)
  -- An IPv4 slot before each IPv6 range pads it by 16 bytes: the 16 pairs are exactly 32 MiB, a 17th slot over.
  local padded: {string} = {}
  for i = 1, 16 do
    padded[#padded + 1] = "10.0.0." .. i .. ":80"
    padded[#padded + 1] = "[2001:db8::" .. i .. "]:*"
  end
  agree(padded, true)
  padded[#padded + 1] = "10.0.1.1:80"
  agree(padded, false)
  -- The same wildcards with the IPv4 slots last need no padding, and the limit is the same in both orders.
  local last: {string} = {}
  for i = 1, 16 do last[i] = "[2001:db8::" .. i .. "]:*" end
  for i = 1, 16 do last[#last + 1] = "10.0.0." .. i .. ":80" end
  agree(last, true)
end

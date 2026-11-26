--- The relay's policy on each platform, and the upstream a numeric host
--- names, which the start tells the relay without a lookup.

local RelayStart = require("cosmic.internal.relay_start")
local Sandbox = require("cosmic.sandbox")
local type Config = require("cosmic.internal.relay_config")

local DIGEST <const> = string.rep("0", 64)

local function test_the_relays_policy_differs_by_platform_only_in_what_holds_it()
  local linux = RelayStart.policy("/tmp/relay.db", DIGEST)
  local macos = RelayStart.policy("/tmp/relay.db", DIGEST, true)
  for _, policy in ipairs({ linux, macos }) do
    local database = assert(assert(policy.setup).database)
    assert(database.path == "/tmp/relay.db" and database.sha256 == DIGEST)
    for _, grant in ipairs(Sandbox.paths(policy)) do
      assert(grant.letters == "r", grant.path .. " is granted " .. grant.letters)
    end
    assert(#Sandbox.connects(policy) == 0 and #Sandbox.calls(policy) == 0)
  end
  assert(table.concat(assert(linux.isolate), ",") == "proc" and #Sandbox.profiles(linux) == 0)
  assert(table.concat(Sandbox.profiles(macos), ",") == "system" and macos.isolate == nil)
end

local function test_a_numeric_upstream_is_its_own_address_in_canonical_text()
  for host, want in pairs({ ["192.0.2.7"] = "192.0.2.7", ["2001:DB8:0:0:0:0:0:1"] = "2001:db8::1",
      ["::ffff:192.0.2.7"] = "::ffff:c000:207" }) do
    local up: Config.Upstream = { host = host, port = 3128, no_proxy = {} }
    local addresses = assert(RelayStart.resolved_upstream(up))
    assert(#addresses == 1 and addresses[1] == want, host .. ": " .. tostring(addresses[1]))
  end
end

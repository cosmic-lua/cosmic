local Grant = require("cosmic.grant")
local Sandbox = require("cosmic.sandbox")
local Relay = require("cosmic.relay")

local Wire = Relay.Wire
local Address = Relay.Address

--- The text of a target that parses, else a failed assert naming `text`.
local function canonical(text: string): string
  local target, why = Grant.parse(text)
  assert(target ~= nil, text .. ": " .. why)
  return target.text
end

local function refused(text: string): string
  local target, why = Grant.parse(text)
  assert(target == nil, text .. " should be refused")
  assert(why ~= "", text)
  return why
end

local function test_canonical_forms()
  assert(canonical("API.Example.com.:443") == "api.example.com:443")
  assert(canonical("example.com:*") == "example.com:*")
  assert(canonical("*:443") == "*:443")
  assert(canonical("1.2.3.4:80") == "1.2.3.4:80")
  assert(canonical("[0:0:0:0:0:0:0:1]:80") == "[::1]:80")
  assert(canonical("[2001:DB8:0:0:1:0:0:1]:80") == "[2001:db8::1:0:0:1]:80")
  assert(canonical("[::ffff:1.2.3.4]:80") == "[::ffff:102:304]:80")
end

local function test_kinds()
  local name = assert(Grant.parse("example.com:443"))
  assert(name.kind == "name" and name.bytes == nil and name.port == 443)
  local any = assert(Grant.parse("*:*"))
  assert(any.kind == "any" and any.port == 0)
  local v6 = assert(Grant.parse("[::1]:*"))
  assert(v6.kind == "ipv6" and #v6.bytes == 16 and v6.port == 0)
  local v4 = assert(Grant.parse("10.0.0.1:1"))
  assert(v4.kind == "ipv4" and #v4.bytes == 4)
end

local function test_refuses_what_the_relay_cannot_use()
  assert(refused("*.example.com:443"):find("pattern", 1, true))
  refused("bad_name:443")
  refused("-bad.example:443")
  refused(".:443")
  refused("a..b:443")
  refused("example.:443:443")
  refused("1.2.3:443")
  refused("1.2.3.04:443")
  refused("host name:443")
  refused("host\0:443")
  refused("host\n:443")
  refused(string.rep("a", 64) .. ".example:443")
  refused(string.rep("a.", 127) .. "a:443")
  refused("::1:80")
  refused("[1.2.3.4]:80")
  refused("[:]:80")
  refused("[example.com]:80")
  refused("example.com:0")
  refused("example.com:65536")
  refused("example.com:080")
  refused("example.com")
  refused(":443")
end

local function test_policy_refuses_at_the_connect_pointer()
  local ok, why = Sandbox.check({ connect = { "example.com:443", "*.example.com:443" } })
  assert(not ok)
  assert(why:find("/connect/1", 1, true), why)
  ok, why = Sandbox.check({ connect = { "example.com:443", "Example.COM.:*", "[::1]:80", "*:*" } })
  assert(ok, why)
end

local function test_every_accepted_name_is_a_request_host()
  for _, host in ipairs({ "example.com", "a-b.example", "EXAMPLE.com.", "x1.y2" }) do
    local target = assert(Grant.parse(host .. ":443"))
    local head = Wire.connect_reader():feed(("CONNECT %s:443 HTTP/1.1\r\n\r\n"):format(host))
    assert(head.status == "done" and head.host == target.host, host)
    local socks = Wire.socks_request_reader():feed((assert(Wire.socks_client_request(host, 443))))
    assert(socks.status == "done" and socks.host == target.host, host)
  end
end

local function test_consumers_read_one_canonical_meaning()
  local plan = assert(Sandbox.Relay.plan({ "[0:0:0:0:0:0:0:1]:80", "[::1]:80", "Example.COM.:443" }, {}))
  assert(#plan.literals == 1 and plan.names, "one literal, however it is spelt")
  assert(Address.granted("::1", 80, { "[0:0:0:0:0:0:0:1]:80" }))
  assert(not Address.granted("::1", 81, { "[::1]:80" }))
  assert(not Address.granted("1.2.3.4", 80, { "*:80", "example.com:80" }))
end

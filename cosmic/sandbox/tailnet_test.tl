--- Tailnet `connect` targets: their grammar ([`Grant.tailnet`]), the
--- check of a policy that holds them, and their resolution against a
--- node's status into the addresses the relay grants.

local Child = require("cosmic.child")
local Grant = require("cosmic.relay.grant")
local Sandbox = require("cosmic.sandbox")
local Tailscale = require("cosmic.tailscale")
local tailnet = require("cosmic.sandbox.tailnet")
local Test = require("cosmic.test")

Test.policy{ profiles = { "cosmic" }, loopback = { "127.0.0.1" }, requires = { "unix_socket" } }

local function peer(id: string, user: integer, addresses: {string}, tags: {string}): Tailscale.Peer
  return {
    id = id, host_name = id, dns_name = id .. ".tail1234.ts.net", os = "linux", user_id = user,
    addresses = addresses, tags = tags, online = true, active = false, exit_node = false,
    exit_node_option = false, relay = "", direct = "",
  }
end

local function status(peers?: {Tailscale.Peer}): Tailscale.Status
  local default: {Tailscale.Peer} = {
    peer("db1", 9, { "100.64.0.3", "fd7a:115c:a1e0:0:0:0:0:3" }, { "tag:db", "tag:prod" }),
    peer("db2", 9, { "100.64.0.4" }, { "tag:db" }),
    peer("laptop", 42, { "100.64.0.2" }, {}),
    peer("web", 42, { "100.64.0.5" }, { "tag:web" }),
    peer("guest", 7, { "100.64.0.6" }, {}),
  }
  return {
    version = "1.90.0", backend_state = "Running", addresses = { "100.64.0.1" }, health = {},
    tailnet = "example.com", magic_dns_suffix = "tail1234.ts.net", magic_dns = true, cert_domains = {},
    self = peer("box", 42, { "100.64.0.1" }, { "tag:db" }),
    peers = peers or default,
    users = {
      [42] = { id = 42, login_name = "Will@Example.com", display_name = "Will" },
      [9] = { id = 9, login_name = "tagged-devices", display_name = "Tagged Devices" },
      [7] = { id = 7, login_name = "guest@example.org", display_name = "Guest" },
    },
  }
end

--- A tag or a user target reads to its canonical text; a text of
--- neither kind is left to Grant.parse, and a malformed one says why.
local function test_a_tailnet_target_reads_its_kind_name_and_port()
  local tag = assert(Grant.tailnet("tag:db:5432"))
  assert(tag.kind == "tag" and tag.name == "tag:db" and tag.port == 5432 and tag.text == "tag:db:5432", tag.text)
  local user = assert(Grant.tailnet("user:Will@Example.com:*"))
  assert(user.kind == "user" and user.name == "will@example.com" and user.port == 0, user.text)
  assert(user.text == "user:will@example.com:*", user.text)
  local github = assert(Grant.tailnet("user:alice@github:22"))
  assert(github.name == "alice@github", github.name)
  local other, none = Grant.tailnet("example.com:443")
  assert(other == nil and none == "", none)
  for _, text in ipairs({ "tag:9db:1", "tag:d_b:1", "user:will:1", "user:@x:1", "tag:db:0", "tag::1" }) do
    local read, why = Grant.tailnet(text)
    assert(read == nil and why ~= "", text)
  end
end

--- A policy may hold tailnet targets, and a malformed one is refused
--- naming its place.
local function test_a_policy_holds_tailnet_targets()
  assert(Sandbox.check({ connect = { "tag:db:5432", "user:will@example.com:*", "example.com:443" } }))
  local ok, why = Sandbox.check({ connect = { "example.com:443", "tag:9db:5432" } })
  assert(not ok and why:find("$.connect[1]", 1, true) ~= nil and why:find("not a tailnet target", 1, true) ~= nil, why)
end

--- A tag grants each address of its peers, a user each of their
--- untagged peers', at the port, after the other targets; this node is
--- never granted, though it carries the tag.
local function test_targets_resolve_to_the_addresses_of_the_peers_they_name()
  local got = tailnet.resolved({ "example.com:443", "tag:db:5432", "user:will@example.com:*", "tag:none:1" }, status())
  assert(table.concat(got, " ") == "example.com:443 100.64.0.3:5432 [fd7a:115c:a1e0::3]:5432 100.64.0.4:5432 " ..
      "100.64.0.2:*", table.concat(got, " "))
  assert(not tailnet.named({ "example.com:443" }) and tailnet.named({ "a:1", "tag:db:1" }))
end

--- A policy with nothing of the tailnet is left as it was, unasked; one
--- whose daemon is not there fails the start, naming the target.
local function test_a_daemon_that_is_not_there_fails_the_start(tmp: string)
  local plain = assert(Sandbox.merge({ connect = { "example.com:443" } }))
  local same = assert(tailnet.policy(plain, { socket = tmp .. "/none.sock" }))
  assert(same == plain)
  local merged = assert(Sandbox.merge({ connect = { "tag:db:5432" } }))
  local none, why = tailnet.policy(merged, { socket = tmp .. "/none.sock" })
  assert(none == nil and why:find('^sandbox: connect "tag:db:5432" names nodes of the tailnet') ~= nil, why)
  local child, refused = Child.start({ "/bin/true" }, {
    timeout_ns = Child.FOREVER, policy = { connect = { "tag:db:5432" } }, tailscale = { socket = tmp .. "/none.sock" },
  })
  assert(child == nil and refused.message:find('connect "tag:db:5432"', 1, true) ~= nil, refused)
end

--- An address outside Tailscale's ranges is never granted, whatever the
--- status says: a name, `*`, the loopback, a private or metadata address.
local function test_an_address_outside_the_tailnet_is_never_granted()
  local odd = status({
    peer("odd", 9, { "*", "evil.example.com", "127.0.0.1", "::1", "::ffff:10.0.0.1", "[::1]", "10.0.0.1",
      "169.254.169.254", "100.128.0.1", "100.63.255.255", "fd7a:115c:a1e1::1", "100.127.255.254" }, { "tag:db" }),
  })
  local got = tailnet.resolved({ "tag:db:5432" }, odd)
  assert(table.concat(got, " ") == "100.127.255.254:5432", table.concat(got, " "))
end

--- A host named `tag` or `user` is a name, as it was before tailnet
--- targets.
local function test_a_host_named_tag_is_still_a_name()
  local read, why = Grant.tailnet("tag:443")
  assert(read == nil and why == "", why)
  assert(Sandbox.check({ connect = { "tag:443", "user:22" } }))
end

--- Stands in for tailscaled, sending `body` for `status`, while
--- `run` asks it, at the socket path it is given.
local function with_daemon(tmp: string, body: string, run: function(socket: string))
  local Array = require("cosmic.array")
  local Net = require("cosmic.net")
  local Server = require("cosmic.http.server")
  assert(Server.serve{
    listeners = { Net.unix(tmp .. "/ts.sock") },
    on_stop = function(_: Net.Server) end,
    handle = function(req: Server.Request): Server.Reply
      if req.target == "/localapi/v0/status" then return { status = 200, body = body } end
      return { status = 404, body = "404 page not found\n" }
    end,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      run(assert(Array.at(addresses, 1).path))
      server:stop()
    end,
  })
end

local STATUS_JSON <const> = [[{
  "Version": "1.90.0", "BackendState": "Running", "MagicDNSSuffix": "tail1234.ts.net",
  "Peer": {
    "nodekey:aa": {"ID": "nA", "HostName": "db1", "DNSName": "db1.tail1234.ts.net.", "OS": "linux",
      "UserID": 9, "TailscaleIPs": ["100.64.0.3"], "Tags": ["tag:db"], "Online": true, "Active": false,
      "ExitNode": false, "ExitNodeOption": false, "Relay": "", "CurAddr": ""}
  },
  "User": {"9": {"ID": 9, "LoginName": "tagged-devices", "DisplayName": "Tagged Devices"}}
}]]

--- A policy's tailnet targets are resolved through the daemon; one that
--- names no peer is refused, naming it, rather than granting nothing.
local function test_a_policy_resolves_through_the_daemon_and_refuses_a_target_of_no_peer(tmp: string)
  local said: mut {string} = {}
  with_daemon(tmp, STATUS_JSON, function(socket: string)
    local merged = assert(Sandbox.merge({ connect = { "example.com:443", "tag:db:5432" } }))
    local run = assert(tailnet.policy(merged, { socket = socket }))
    local text = table.concat(assert(run.connect), " ")
    said[#said + 1] = text
    local typo = assert(Sandbox.merge({ connect = { "tag:dbs:5432" } }))
    local _, why = tailnet.policy(typo, { socket = socket })
    said[#said + 1] = why
  end)
  assert(said[1] == "example.com:443 100.64.0.3:5432", said[1])
  assert(said[2] == 'sandbox: connect "tag:dbs:5432" names no peer of the tailnet that tailscaled lists', said[2])
end

--- A node that is not running knows no peers, which fails the start.
local function test_a_node_that_is_not_running_fails_the_start(tmp: string)
  local why = ""
  with_daemon(tmp, '{"Version": "1.90.0", "BackendState": "Stopped", "MagicDNSSuffix": ""}', function(socket: string)
    local merged = assert(Sandbox.merge({ connect = { "tag:db:5432" } }))
    local _, trouble = tailnet.policy(merged, { socket = socket })
    why = trouble
  end)
  assert(why:find("the node is Stopped, so it knows no peers", 1, true) ~= nil, why)
end

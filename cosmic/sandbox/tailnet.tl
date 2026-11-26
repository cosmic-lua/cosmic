--- A policy's `connect` targets that name nodes of the machine's tailnet
--- (`tag:db:5432`, `user:will@example.com:*`, read by [`Grant.tailnet`]),
--- turned into the addresses the relay grants. [`Child.start`] asks
--- tailscaled for the node's status ([`Tailscale.connect`]) once, as it
--- starts, and grants each address of every peer the target names: a
--- tag's peers, or the untagged peers a user owns. This node itself is
--- never among them, as the relay never connects to the host's own
--- addresses.
---
---     local status = assert(assert(Tailscale.connect()):status())
---     local connect = tailnet.resolved({ "tag:db:5432" }, status)
---     -- { "100.64.0.3:5432", "[fd7a:115c:a1e0::3]:5432" }
--- @public

local Failure = require("cosmic.failure")
local Grant = require("cosmic.relay.grant")
local rules = require("cosmic.sandbox.policy")
local type Tailscale = require("cosmic.tailscale")

local record tailnet
end

--- Whether any of `connect` is a tailnet target.
function tailnet.named(connect: {string}): boolean
  for _, target in ipairs(connect) do
    local read, _ = Grant.tailnet(target)
    if read ~= nil and read ~= false then return true end
  end
  return false
end

--- The canonical text of `address` where it is a tailnet address, with
--- `port` after it, else nil: an IPv4 address of 100.64.0.0/10 or an IPv6
--- one of fd7a:115c:a1e0::/48, the ranges Tailscale gives its nodes. The
--- daemon's word is checked, not trusted: an address of the host's
--- loopback, a metadata service, a name or `*` would be granted
--- literally, past every refusal the relay makes.
local function tailnet_target(address: string, port: string): string?
  local bytes = Grant.address(address)
  if bytes == nil then return nil end
  if #bytes == 4 then
    local a, b, c, d = bytes[1], bytes[2], bytes[3], bytes[4]
    if a ~= 100 or b < 64 or b > 127 then return nil end
    return table.concat({ tostring(a), tostring(b), tostring(c), tostring(d) }, ".") .. ":" .. port
  end
  local prefix <const>: {integer} = { 0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0 }
  for i, byte in ipairs(prefix) do
    if bytes[i] ~= byte then return nil end
  end
  return "[" .. Grant.ipv6_text(bytes) .. "]:" .. port
end

--- Whether `peer` is one of the nodes `target` names.
local function names(target: Grant.Tailnet, peer: Tailscale.Peer, status: Tailscale.Status): boolean
  if target.kind == "tag" then
    for _, tag in ipairs(peer.tags) do
      if tag == target.name then return true end
    end
    return false
  end
  if #peer.tags > 0 then return false end
  local user = status.users[peer.user_id]
  return user ~= nil and user.login_name:lower() == target.name
end

--- `connect` with each tailnet target replaced by a target of each
--- address of the peers it names, at its port, in the order of
--- [`Status.peers`]: the other targets first, as given, then those, each
--- once. Only addresses of Tailscale's ranges are granted
--- (100.64.0.0/10, fd7a:115c:a1e0::/48), whatever else the status holds.
--- A target that names no peer grants nothing here; [`tailnet.policy`]
--- refuses it.
--- @param connect {string} A policy's `connect` targets
--- @param status Tailscale.Status The node's status
--- @return {string} The targets the relay is given
function tailnet.resolved(connect: {string}, status: Tailscale.Status): {string}
  local out: mut {string} = {}
  local seen: mut {string: boolean} = {}
  local function add(text: string)
    if seen[text] == true then return end
    seen[text] = true
    out[#out + 1] = text
  end
  local wanted: mut {Grant.Tailnet} = {}
  for _, target in ipairs(connect) do
    local read, _ = Grant.tailnet(target)
    if read ~= nil and read ~= false then wanted[#wanted + 1] = read else add(target) end
  end
  for _, target in ipairs(wanted) do
    local port = if target.port == 0 then "*" else tostring(target.port) end
    for _, peer in ipairs(status.peers) do
      if names(target, peer, status) then
        for _, address in ipairs(peer.addresses) do
          local granted = tailnet_target(address, port)
          if granted ~= nil then add(granted) end
        end
      end
    end
  end
  return out
end

--- The node's status, asked of the daemon `daemon` names
--- ([`Tailscale.connect`]; the machine's own when nil). Nil and a Failure where
--- the daemon cannot be asked, or this node is not running.
local function status_of(daemon?: Tailscale.Daemon): (Tailscale.Status) | (nil, Failure)
  local Live = require("cosmic.tailscale")
  local ts, why = Live.connect(daemon)
  if ts == nil then return nil, Failure.new(tostring(why)) end
  local status, trouble = ts:status()
  if status == nil then return nil, Failure.new(tostring(trouble)) end
  if status.backend_state ~= "Running" then
    return nil, Failure.new("tailscale: the node is " .. status.backend_state .. ", so it knows no peers")
  end
  return status
end

--- The merged policy `merged` as the sandbox runs it: unchanged where
--- its `connect` names nothing of the tailnet, and else with those
--- targets resolved ([`tailnet.resolved`]) against the status `daemon`
--- reports ([`Tailscale.connect`]; the machine's own when nil). Nil and
--- why, naming the target, where they cannot be, where one names no peer
--- (a typo, or a tag no node carries yet, which would start the program
--- with less than it was meant to reach).
function tailnet.policy(merged: rules.Policy, daemon?: Tailscale.Daemon): (rules.Policy) | (nil, Failure)
  local connect = rules.connects(merged)
  if not tailnet.named(connect) then return merged end
  local status, why = status_of(daemon)
  for _, target in ipairs(connect) do
    local read, _ = Grant.tailnet(target)
    if read ~= nil and read ~= false then
      if status == nil then
        return nil, Failure.new("sandbox: connect \"" .. target .. "\" names nodes of the tailnet, which tailscaled was asked " ..
            "for: " .. (tostring(why):gsub("^tailscale: ", "")))
      end
      if #tailnet.resolved({ target }, status) == 0 then
        return nil, Failure.new("sandbox: connect \"" .. target .. "\" names no peer of the tailnet that tailscaled lists")
      end
    end
  end
  return rules.with_connect(merged, tailnet.resolved(connect, assert(status)))
end

--- `policy` with the `connect` of `merged`, the policy [`tailnet.policy`]
--- returned: what macOS's start compiles its profile from.
function tailnet.applied(policy: rules.Policy, merged: rules.Policy): rules.Policy
  local given, held = rules.connects(policy), rules.connects(merged)
  if table.concat(given, "\0") == table.concat(held, "\0") then return policy end
  return rules.with_connect(policy, held)
end

return tailnet

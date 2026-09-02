--- The pure fs-policy -> landlock mapping behind cosmic.sandbox.
--- Kept separate from the facade so the mapping stays inspectable and
--- unit-testable without being public API: cosmic.sandbox.plan is an
--- internal shard, and the facade's apply() is the one door.
local landlock = require("cosmic.sandbox.landlock")

local type Rule = landlock.Rule
local type NetRule = landlock.NetRule
local type RestrictOptions = landlock.RestrictOptions

--- The facade's filesystem policy: path allowlists. Everything not
--- listed is denied once the policy applies. `ro` paths are readable
--- and nothing else; `exec` paths are readable *and* executable; `rw`
--- paths are readable and writable (including creating and removing
--- entries) but never executable. A path listed in several groups gets
--- the union of their access. A present-but-empty group is a real
--- policy (`fs = { ro = {} }` denies everything); a policy with no
--- group at all is rejected — omit `fs` entirely to skip filesystem
--- policy. With `optional = true`, rules naming paths that do not
--- exist are dropped instead of failing the whole policy (landlock
--- rules are OPENED, so a missing path otherwise kills the restrict).
local record Fs
  ro: {string}
  rw: {string}
  exec: {string}
  optional: boolean
end

--- The facade's network policy: per-port TCP allowlists, ABI 4+ only.
--- `connect_tcp` grants outbound connect() to the listed ports;
--- `bind_tcp` grants bind() to them. A present-but-empty group denies
--- that operation entirely; an absent group leaves it unrestricted
--- (landlock never learns to handle it, so the kernel's normal rules
--- apply); a policy with neither group is rejected — omit `net`
--- entirely to skip network policy. There is no `optional`: a port
--- number cannot be "absent" the way a path can.
local record Net
  connect_tcp: {integer}
  bind_tcp: {integer}
end

--- The facade's signal / abstract-UNIX-socket scoping policy, Landlock
--- ABI 6+ only. `signal = true` confines signal delivery to the sandbox
--- domain (a domain member may signal only another member); `abstract_
--- unix = true` does the same for abstract UNIX sockets. Landlock
--- scoping is deny-outside-the-domain rather than a per-target grant,
--- so there is nothing path- or pid-like to list — a boolean is the
--- honest shape for each category. A policy setting neither key is
--- rejected (the same "say what you mean" rule fs/net apply to their
--- groupless case); a policy with no `scope` section at all skips
--- scoping entirely.
local record Scope
  signal: boolean
  abstract_unix: boolean
end

-- Add rules for every path in `paths` with the given access mask,
-- de-duplicating by path: a path listed in several groups gets the
-- union of their masks (landlock ORs per inode anyway; deduping keeps
-- the rules list small and predictable).
local function add_rules(
    out: {Rule},
    seen: {string: integer},
    paths: {string},
    mask: integer
  )
  if not paths then return end
  for _, p in ipairs(paths) do
    local idx = seen[p]
    if idx then
      out[idx].access = out[idx].access | mask
    else
      table.insert(out, {path = p, access = mask})
      seen[p] = #out
    end
  end
end

--- Translate an fs policy to `landlock.restrict` options. Pure: no
--- syscalls, no side effects (`optional` rides each rule; the skip
--- happens at open time, inside `landlock.restrict`). `no_new_privs`
--- defaults on so landlock applies without CAP_SYS_ADMIN; the facade's
--- Options can override it. `handled` always requests the full current
--- access set (`landlock.ALL`) — narrowing which categories a ruleset
--- controls is a mechanism-level knob (`landlock.RestrictOptions.
--- handled`), not a facade concern (R3). An empty or nil policy
--- produces an empty rules list, which denies everything when applied.
---
--- @param fs Fs nil treated as empty (deny-all)
--- @param no_new_privs boolean? default true
--- @return RestrictOptions options for landlock.restrict
local function for_landlock(fs: Fs, no_new_privs?: boolean): RestrictOptions
  local rules: {Rule} = {}
  local seen: {string: integer} = {}
  add_rules(rules, seen, fs and fs.ro or nil, landlock.READ)
  add_rules(rules, seen, fs and fs.rw or nil, landlock.RW)
  add_rules(rules, seen, fs and fs.exec or nil, landlock.READ | landlock.EXEC)
  if fs and fs.optional then
    for _, r in ipairs(rules) do
      r.optional = true
    end
  end
  return {
    handled = landlock.ALL,
    rules = rules,
    no_new_privs = no_new_privs ~= false,
  }
end

-- Add net rules for every port in `ports` with the given access mask,
-- de-duplicating by port: a port listed in both groups gets the union
-- of their masks, mirroring add_rules above.
local function add_net_rules(
    out: {NetRule},
    seen: {integer: integer},
    ports: {integer},
    mask: integer
  )
  if not ports then return end
  for _, p in ipairs(ports) do
    local idx = seen[p]
    if idx then
      out[idx].access = out[idx].access | mask
    else
      table.insert(out, {port = p, access = mask})
      seen[p] = #out
    end
  end
end

--- Translate a net policy to `landlock.restrict` options. Pure: no
--- syscalls. `handled_net` is built from which groups are PRESENT (a
--- key's mere presence, not its length, hands that category to
--- landlock — absent leaves it unrestricted, present-but-empty denies
--- every port). `handled` (fs) stays 0 and `rules` stays empty: a
--- net-only restrict call must not also deny every path, and landlock
--- defaults an omitted `handled` to ALL, so this must be explicit.
---
--- @param net Net nil treated as empty (no net policy)
--- @param no_new_privs boolean? default true
--- @return RestrictOptions options for landlock.restrict
local function for_landlock_net(net: Net, no_new_privs?: boolean): RestrictOptions
  local net_rules: {NetRule} = {}
  local seen: {integer: integer} = {}
  local handled_net = 0
  if net and net.connect_tcp ~= nil then
    handled_net = handled_net | landlock.NET_CONNECT_TCP
    add_net_rules(net_rules, seen, net.connect_tcp, landlock.NET_CONNECT_TCP)
  end
  if net and net.bind_tcp ~= nil then
    handled_net = handled_net | landlock.NET_BIND_TCP
    add_net_rules(net_rules, seen, net.bind_tcp, landlock.NET_BIND_TCP)
  end
  return {
    handled = 0,
    rules = {},
    handled_net = handled_net,
    net_rules = net_rules,
    no_new_privs = no_new_privs ~= false,
  }
end

-- Structural + range validation for one net port group, named by
-- index and value so a caller can find the bad entry directly.
local function check_ports(ports: {integer}, label: string): string | nil
  if ports == nil then return nil end
  if type(ports) ~= "table" then
    return "sandbox: " .. label .. " must be a list of ports"
  end
  for i, p in ipairs(ports) do
    if type(p) ~= "number" or p ~= math.floor(p) or p < 0 or p > 65535 then
      return string.format(
        "sandbox: %s[%d] must be an integer port 0-65535, got %s",
        label, i, tostring(p))
    end
  end
  return nil
end

--- Validate a net policy's structure, before any enforcement: group
--- types, the "at least one group" requirement, and port range.
---
--- @param net Net the section to check
--- @return string? Error message, nil when valid
local function validate_net(net: Net): string | nil
  if type(net) ~= "table" then
    return "sandbox: net must be a table"
  end
  for _, name in ipairs({"connect_tcp", "bind_tcp"}) do
    local v = (net as {string: any})[name] -- cast: record to map probe
    if v ~= nil and type(v) ~= "table" then
      return "sandbox: net." .. name .. " must be a list of ports"
    end
  end
  if net.connect_tcp == nil and net.bind_tcp == nil then
    return "sandbox: net policy has no groups — pass net = { connect_tcp = {} }"
    .. " to deny everything, or omit net to skip network policy"
  end
  local err = check_ports(net.connect_tcp, "net.connect_tcp")
  if err then return err end
  return check_ports(net.bind_tcp, "net.bind_tcp")
end

--- Translate a scope policy to `landlock.restrict` options. Pure: no
--- syscalls. `scoped` is built from which keys are TRUE — Landlock
--- scoping has no per-target grant to plan, only "confine this
--- category or don't" — so unlike the fs/net path, no `rules` are ever
--- produced. `handled` (fs) and `handled_net` stay 0: a scope-only
--- restrict call must not also deny every path or claim the net
--- domain, mirroring `for_landlock_net`'s reasoning.
---
--- @param scope Scope nil treated as empty (no scope policy)
--- @param no_new_privs boolean? default true
--- @return RestrictOptions options for landlock.restrict
local function for_landlock_scope(scope: Scope, no_new_privs?: boolean): RestrictOptions
  local scoped = 0
  if scope and scope.signal then
    scoped = scoped | landlock.SCOPE_SIGNAL
  end
  if scope and scope.abstract_unix then
    scoped = scoped | landlock.SCOPE_ABSTRACT_UNIX_SOCKET
  end
  return {
    handled = 0,
    rules = {},
    scoped = scoped,
    no_new_privs = no_new_privs ~= false,
  }
end

--- Validate a scope policy's structure, before any enforcement: key
--- types and the "at least one key" requirement.
---
--- @param scope Scope the section to check
--- @return string? Error message, nil when valid
local function validate_scope(scope: Scope): string | nil
  if type(scope) ~= "table" then
    return "sandbox: scope must be a table"
  end
  for _, name in ipairs({"signal", "abstract_unix"}) do
    local v = (scope as {string: any})[name] -- cast: record to map probe
    if v ~= nil and type(v) ~= "boolean" then
      return "sandbox: scope." .. name .. " must be a boolean"
    end
  end
  if scope.signal == nil and scope.abstract_unix == nil then
    return "sandbox: scope policy has no keys — pass scope = { signal = true }"
    .. " and/or scope = { abstract_unix = true }, or omit scope to skip scoping"
  end
  return nil
end

local record PlanModule
  type Fs = Fs
  type Net = Net
  type Scope = Scope
  for_landlock: function(fs: Fs, no_new_privs?: boolean): RestrictOptions
  for_landlock_net: function(net: Net, no_new_privs?: boolean): RestrictOptions
  validate_net: function(net: Net): string | nil
  for_landlock_scope: function(scope: Scope, no_new_privs?: boolean): RestrictOptions
  validate_scope: function(scope: Scope): string | nil
end

local M: PlanModule = {
  for_landlock = for_landlock,
  for_landlock_net = for_landlock_net,
  validate_net = validate_net,
  for_landlock_scope = for_landlock_scope,
  validate_scope = validate_scope,
}

return M

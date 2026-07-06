--- Allowlist rule parsing, validation, and matching for the
--- cosmic.quicksand.proxy egress proxy.
---
--- An allowlist maps host-spec strings to rule values:
---
---   host              any port on exact host
---   host:port         exact host + exact port
---   host:*            any port on exact host (explicit)
---   *.suffix          any host ending in ".suffix", any port
---   *.suffix:port     any host ending in ".suffix", exact port
---
--- Rule values: an empty table (or true) means "allow, no auth
--- injection". A table with a `type` field of "bearer", "basic", or
--- "header" injects the corresponding header on plain-HTTP requests
--- (CONNECT tunnels are opaque; the rule still gates the allowlist).
--- validate() rejects unknown types and missing fields loudly — a
--- typo'd rule silently degrading to pass-through would strip auth
--- from an otherwise-authenticated egress path.
local cosmo = require("cosmo")

--- One wildcard ("*.suffix") allowlist entry. `port` nil = any port.
local record SuffixEntry
  suffix: string
  port: integer
  rule: any
end

--- Fast lookup structure built from an allowlist by index().
--- exact[host][port] and exact[host]["*"] hold exact-host rules;
--- suffix is walked in insertion order for "*.suffix" patterns.
local record Index
  exact: {string: {any: any}}
  suffix: {SuffixEntry}
end

--- Split a host-spec into ("host", port or nil). A missing port,
--- ":*", or ":" all mean "any port". Hosts compare case-insensitively.
--- A malformed port is *not* handled here — callers must validate keys
--- with validate_key first, or a typo silently widens to "any port".
local function parse_rule(key: string): string, integer
  local h, p = key:match("^(.-):(.-)$")
  if not h then
    return key:lower(), nil
  end
  if p == "*" or p == "" then
    return h:lower(), nil
  end
  return h:lower(), tonumber(p) as integer
end

--- Validate an allowlist *key* (host-spec). Returns nil on success or a
--- human-readable error. The port component, when present, must be `*`,
--- empty, or a decimal integer in 1..65535 — otherwise `tonumber`
--- returns nil and parse_rule would silently widen the rule to "any
--- port" (fail-open in a security boundary). A stray extra colon
--- (`"host:5432:6"`) trips the digit check for the same reason. The
--- optional `*.` wildcard prefix is stripped before checking.
local function validate_key(key: string): string
  local spec = key:match("^%*%.(.+)$") or key
  local _, p = spec:match("^(.-):(.-)$")
  if p == nil or p == "" or p == "*" then
    return nil
  end
  if not p:match("^%d+$") then
    return string.format("allowed_hosts[%q]: invalid port %q "
      .. "(expected a decimal number, \"*\", or none)", key, p)
  end
  local n = tonumber(p)
  if n < 1 or n > 65535 then
    return string.format("allowed_hosts[%q]: port %q out of range "
      .. "(expected 1..65535)", key, p)
  end
  return nil
end

--- Validate a single allowlist rule. Returns nil on success, or a
--- human-readable error string. Bare pass-through values (nil, true,
--- {}) are accepted as "allow, no auth injection"; a table with a
--- `type` field must use a known type and carry the fields that
--- auth_header() would dereference. Unknown non-type fields are
--- ignored (forward compatibility).
local function validate_rule(key: string, rule: any): string
  if rule == nil or rule == true then return nil end
  if not (rule is table) then
    return string.format("allowed_hosts[%q]: rule must be a table, true, "
      .. "or nil (got %s)", key, type(rule))
  end
  local r = rule as {string: any}
  local t = r["type"]
  if t == nil then return nil end
  if t == "bearer" then
    if type(r["token"]) ~= "string" or r["token"] == "" then
      return string.format("allowed_hosts[%q]: bearer rule requires "
        .. "non-empty string `token`", key)
    end
  elseif t == "basic" then
    if type(r["username"]) ~= "string" or r["username"] == "" then
      return string.format("allowed_hosts[%q]: basic rule requires "
        .. "non-empty string `username`", key)
    end
    if type(r["password"]) ~= "string" then
      return string.format("allowed_hosts[%q]: basic rule requires "
        .. "string `password`", key)
    end
  elseif t == "header" then
    if type(r["header_name"]) ~= "string" or r["header_name"] == "" then
      return string.format("allowed_hosts[%q]: header rule requires "
        .. "non-empty string `header_name`", key)
    end
    if type(r["header_value"]) ~= "string" then
      return string.format("allowed_hosts[%q]: header rule requires "
        .. "string `header_value`", key)
    end
  else
    return string.format("allowed_hosts[%q]: unknown rule type %q "
      .. "(expected \"bearer\", \"basic\", or \"header\")",
      key, tostring(t))
  end
  return nil
end

--- Validate every rule in an allowlist. Returns true, or false plus
--- the first error found.
local function validate(allowed_hosts: {string: any}): boolean, string
  for key, rule in pairs(allowed_hosts or {}) do
    local kerr = validate_key(key)
    if kerr then return false, kerr end
    local verr = validate_rule(key, rule)
    if verr then return false, verr end
  end
  return true
end

--- Build a lookup Index from an allowlist table. Wildcard entries
--- are stored with a leading "." and matched at the tail of the
--- candidate host, in insertion order.
local function index(allowed_hosts: {string: any}): Index
  local idx: Index = {exact = {}, suffix = {}}
  for k, rule in pairs(allowed_hosts or {}) do
    local wild = k:match("^%*%.(.+)$")
    if wild then
      local h, p = parse_rule(wild)
      table.insert(idx.suffix, {suffix = "." .. h, port = p, rule = rule})
    else
      local h, p = parse_rule(k)
      if not idx.exact[h] then idx.exact[h] = {} end
      local by_port = idx.exact[h]
      if p then
        by_port[p] = rule
      else
        by_port["*"] = rule
      end
    end
  end
  return idx
end

--- Look up a (host, port) pair. Returns the rule value on a hit, or
--- nil. Exact-host matches win over suffix patterns; suffix patterns
--- return the first hit in insertion order.
local function match(idx: Index, host: string, port: integer): any
  host = host:lower()
  local entry = idx.exact[host]
  if entry then
    local hit = entry[port] or entry["*"]
    if hit ~= nil then return hit end
  end
  for _, s in ipairs(idx.suffix) do
    if host:sub(-#s.suffix) == s.suffix
    and (s.port == nil or s.port == port) then
      return s.rule
    end
  end
  return nil
end

--- Build the auth header a rule injects on plain-HTTP requests.
--- Returns (name, value), or nil for pass-through rules.
local function auth_header(rule: any): string | nil, string
  if not (rule is table) then return nil end
  local r = rule as {string: any}
  local t = r["type"]
  if t == "bearer" then
    return "Authorization", "Bearer " .. tostring(r["token"])
  elseif t == "basic" then
    local enc = cosmo.EncodeBase64(
      tostring(r["username"]) .. ":" .. tostring(r["password"]))
    return "Authorization", "Basic " .. enc
  elseif t == "header" then
    return r["header_name"] as string, r["header_value"] as string
  end
  return nil
end

local record RulesModule
  parse_rule: function(key: string): string, integer
  validate_key: function(key: string): string
  validate_rule: function(key: string, rule: any): string
  validate: function(allowed_hosts: {string: any}): boolean, string
  index: function(allowed_hosts: {string: any}): Index
  match: function(idx: Index, host: string, port: integer): any
  auth_header: function(rule: any): string | nil, string
end

local M: RulesModule = {
  parse_rule = parse_rule,
  validate_key = validate_key,
  validate_rule = validate_rule,
  validate = validate,
  index = index,
  match = match,
  auth_header = auth_header,
}

return M

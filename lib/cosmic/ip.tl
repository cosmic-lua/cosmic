--- IP address parsing, formatting, and classification utilities.
--- The typed Addr is the only address currency in public signatures
--- (api-review-2, #588): parse and lookup return Addr, sockets accept
--- and return Addr, and classification lives on Addr methods. The
--- implementation is IPv4-only — IPv6 strings are rejected with an
--- explicit error — but the shape is ready for IPv6 as a value
--- extension: a later "inet6" family is a new Addr value, not a new
--- API. Addr:int() exposes the raw v4 integer for the C boundary.
local cosmo = require("cosmo")

--- Category of an IPv4 address, as reported by categorize().
--- LOOPBACK/PRIVATE/TESTNET/MULTICAST are special-use ranges; the rest
--- name the registry or organization the block is delegated to.
local enum Category
  "MULTICAST"
  "LOOPBACK"
  "PRIVATE"
  "TESTNET"
  "AFRINIC"
  "LACNIC"
  "APNIC"
  "ARIN"
  "RIPE"
  "DOD"
  "AT&T"
  "APPLE"
  "FORD"
  "COGENT"
  "PRUDENTIAL"
  "USPS"
  "COMCAST"
  "FUTURE"
  "ANONYMOUS"
end

--- Address family. IPv4 only today; IPv6 (whilp/cosmopolitan#144) adds
--- "inet6" as a value, leaving every Addr-taking signature unchanged.
local enum Family
  "inet"
end

--- A typed IP address: the one address type in public signatures.
--- Compares by value (two Addrs are == when they hold the same
--- address) and formats with tostring().
local record Addr
  _n: number
  --- Address family; "inet" for IPv4.
  family: Family
  --- Get the raw integer representation (the IPv4 payload).
  --- Use this at the C boundary or for arithmetic on the raw value.
  --- @return integer The IP address as an integer
  int: function(Addr): number
  --- Format as a dotted-quad string (e.g., "192.168.1.1").
  --- @return string The formatted IP address
  format: function(Addr): string
  --- Categorize the address (e.g., "LOOPBACK", "PRIVATE", "ARIN").
  --- @return Category The category name
  categorize: function(Addr): Category
  --- Check if this is a loopback address (127.x.x.x).
  --- @return boolean True if loopback
  is_loopback: function(Addr): boolean
  --- Check if this is a private address (10.x, 172.16-31.x, 192.168.x).
  --- @return boolean True if private
  is_private: function(Addr): boolean
  --- Check if this is a public/routable address.
  --- @return boolean True if public
  is_public: function(Addr): boolean
end

local function addr_int(self: Addr): number
  return self._n
end

local function addr_format(self: Addr): string
  return cosmo.FormatIp(self._n)
end

local function addr_categorize(self: Addr): Category
  return cosmo.CategorizeIp(self._n) as Category
end

local function addr_is_loopback(self: Addr): boolean
  return cosmo.IsLoopbackIp(self._n)
end

local function addr_is_private(self: Addr): boolean
  return cosmo.IsPrivateIp(self._n)
end

local function addr_is_public(self: Addr): boolean
  return cosmo.IsPublicIp(self._n)
end

-- Methods and the family constant live on the shared metatable (#563
-- precedent), so make_addr allocates one two-field table and nothing else.
local Addr_mt: metatable < Addr > = {
  __index = {
    family = "inet",
    int = addr_int,
    format = addr_format,
    categorize = addr_categorize,
    is_loopback = addr_is_loopback,
    is_private = addr_is_private,
    is_public = addr_is_public,
  } as Addr,
  __tostring = function(self: Addr): string
    return cosmo.FormatIp(self._n)
  end,
  __eq = function(a: Addr, b: Addr): boolean
    return a._n == b._n
  end,
}

local function make_addr(n: number): Addr
  return setmetatable({_n = n} as Addr, Addr_mt)
end

--- Wrap a raw integer as a typed Addr.
--- This is the explicit int-to-Addr constructor for the C boundary
--- (e.g. values from cosmo bindings); everything else should already
--- hold an Addr.
--- @param n integer The IP address as an integer
--- @return Addr The typed IP address
local function addr(n: number): Addr
  return make_addr(n)
end

--- Parse an IPv4 address string into a typed Addr.
--- Strict dotted quad only: exactly four decimal octets 0-255, no
--- leading zeros ("127.1", "1.2.3.4.5", "01.2.3.4" are all errors).
--- IPv6 is rejected with an explicit error.
--- @param str string The IP address string (e.g., "192.168.1.1")
--- @return Addr | nil The typed IP address, or nil on error
--- @return string Error message if parsing failed
local function parse(str: string): Addr | nil, string
  if not str or str == "" then
    return nil, "empty IP address"
  end
  if str:find(":", 1, true) then
    return nil, "IPv6 not supported: " .. str
  end
  local a, b, c, d = str:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then
    return nil, "invalid IPv4 address (want dotted quad): " .. str
  end
  local n: integer = 0
  for _, octet in ipairs({a, b, c, d}) do
    -- no leading zeros: "0" is fine, "01" reads as octal in other parsers
    if #octet > 3 or (#octet > 1 and octet:sub(1, 1) == "0") then
      return nil, "invalid IPv4 octet '" .. octet .. "' in: " .. str
    end
    local v = math.tointeger(tonumber(octet))
    if v > 255 then
      return nil, "invalid IPv4 octet '" .. octet .. "' in: " .. str
    end
    n = n * 256 + v
  end
  return make_addr(n)
end

--- Look up a hostname and return a typed Addr.
--- Returns nil and an error message on failure.
--- @param hostname string The hostname to look up
--- @return Addr? The resolved IP address, or nil on error
--- @return string? Error message on failure
local function lookup(hostname: string): Addr | nil, string
  local raw, err = cosmo.ResolveIp(hostname)
  if not raw then
    return nil, "dns: lookup failed for " .. hostname .. ": " .. tostring(err)
  end
  return make_addr(raw)
end

local record IpModule
  Addr: Addr
  type Category = Category
  type Family = Family
  addr: function(n: number): Addr
  parse: function(str: string): Addr | nil, string
  lookup: function(hostname: string): Addr | nil, string
end

local M: IpModule = {
  addr = addr,
  parse = parse,
  lookup = lookup,
}

return M

--- IP address parsing, formatting, and classification utilities.
--- IPv4 only: IPv6 addresses are rejected with an explicit error.
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

--- A typed IP address.
--- Wraps the raw integer representation with convenience methods.
local record Addr
  _n: number
  --- Get the raw integer representation.
  --- Use this when passing to net.Socket:connect() or other APIs that take integer IPs.
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

local Addr_mt: metatable < Addr > = {
  __index = {
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
}

local function make_addr(n: number): Addr
  return setmetatable({_n = n} as Addr, Addr_mt)
end

--- Wrap a raw integer as a typed Addr.
--- @param n integer The IP address as an integer
--- @return Addr The typed IP address
local function addr(n: number): Addr
  return make_addr(n)
end

--- Parse an IPv4 address string to its integer representation.
--- Strict dotted quad only: exactly four decimal octets 0-255, no
--- leading zeros ("127.1", "1.2.3.4.5", "01.2.3.4" are all errors).
--- IPv6 is rejected with an explicit error.
--- @param str string The IP address string (e.g., "192.168.1.1")
--- @return integer | nil The IP address as an integer, or nil on error
--- @return string Error message if parsing failed
local function parse(str: string): integer | nil, string
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
  return n
end

--- Format an integer IP address as a string.
--- @param ip integer The IP address as an integer
--- @return string The formatted IP address string
local function format(ip: number): string
  return cosmo.FormatIp(ip)
end

--- Categorize an IP address.
--- Returns categories like "LOOPBACK", "PRIVATE", "ARIN", etc.
--- @param ip integer The IP address as an integer
--- @return Category The category name
local function categorize(ip: number): Category
  return cosmo.CategorizeIp(ip) as Category
end

--- Check if an IP address is a loopback address (127.x.x.x).
--- @param ip integer The IP address as an integer
--- @return boolean True if the address is a loopback address
local function is_loopback(ip: number): boolean
  return cosmo.IsLoopbackIp(ip)
end

--- Check if an IP address is a private address.
--- Private ranges: 10.x.x.x, 172.16-31.x.x, 192.168.x.x
--- @param ip integer The IP address as an integer
--- @return boolean True if the address is private
local function is_private(ip: number): boolean
  return cosmo.IsPrivateIp(ip)
end

--- Check if an IP address is a public/routable address.
--- @param ip integer The IP address as an integer
--- @return boolean True if the address is public
local function is_public(ip: number): boolean
  return cosmo.IsPublicIp(ip)
end

--- Look up a hostname and return a typed Addr.
--- Returns nil and an error message on failure.
--- @param hostname string The hostname to look up
--- @return Addr? The resolved IP address, or nil on error
--- @return string? Error message on failure
local function lookup(hostname: string): Addr | nil, string
  local ip, err = cosmo.ResolveIp(hostname)
  if not ip then
    return nil, "dns: lookup failed for " .. hostname .. ": " .. tostring(err)
  end
  return make_addr(ip)
end

local record IpModule
  Addr: Addr
  type Category = Category
  addr: function(n: number): Addr
  parse: function(str: string): integer | nil, string
  format: function(ip: number): string
  categorize: function(ip: number): Category
  is_loopback: function(ip: number): boolean
  is_private: function(ip: number): boolean
  is_public: function(ip: number): boolean
  lookup: function(hostname: string): Addr | nil, string
end

local M: IpModule = {
  addr = addr,
  parse = parse,
  format = format,
  categorize = categorize,
  is_loopback = is_loopback,
  is_private = is_private,
  is_public = is_public,
  lookup = lookup,
}

return M

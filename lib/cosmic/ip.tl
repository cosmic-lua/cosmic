--- IP address parsing, formatting, and classification utilities.
local cosmo = require("cosmo")

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
  --- @return string The category name
  categorize: function(Addr): string
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

local function addr_categorize(self: Addr): string
  return cosmo.CategorizeIp(self._n)
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

--- Parse an IP address string to its integer representation.
--- Invalid or unsupported addresses (including IPv6) are errors.
--- @param str string The IP address string (e.g., "192.168.1.1")
--- @return integer | nil The IP address as an integer, or nil on error
--- @return string Error message if parsing failed
local function parse(str: string): integer | nil, string
  local n, err = cosmo.ParseIp(str)
  if not n then
    return nil, err as string
  end
  return n as integer
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
--- @return string The category name
local function categorize(ip: number): string
  return cosmo.CategorizeIp(ip)
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

--- Resolve a hostname to an IP address.
--- @param hostname string The hostname to resolve
--- @return integer | nil The IP address as an integer, or nil on error
--- @return string Error message if resolution failed
local function resolve(hostname: string): integer | nil, string
  local ip, err = cosmo.ResolveIp(hostname)
  if not ip then
    return nil, err as string
  end
  return ip as integer
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
  addr: function(n: number): Addr
  parse: function(str: string): integer | nil, string
  format: function(ip: number): string
  categorize: function(ip: number): string
  is_loopback: function(ip: number): boolean
  is_private: function(ip: number): boolean
  is_public: function(ip: number): boolean
  resolve: function(hostname: string): integer | nil, string
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
  resolve = resolve,
  lookup = lookup,
}

return M

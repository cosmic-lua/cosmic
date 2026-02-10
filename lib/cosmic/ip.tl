--- IP address parsing, formatting, and classification utilities.
local cosmo = require("cosmo")

--- Parse an IP address string to its integer representation.
--- Returns -1 for invalid or unsupported addresses (including IPv6).
--- @param str string The IP address string (e.g., "192.168.1.1")
--- @return integer The IP address as an integer, or -1 on error
local function parse(str: string): integer
  return cosmo.ParseIp(str)
end

--- Format an integer IP address as a string.
--- @param ip integer The IP address as an integer
--- @return string The formatted IP address string
local function format(ip: integer): string
  return cosmo.FormatIp(ip)
end

--- Categorize an IP address.
--- Returns categories like "LOOPBACK", "PRIVATE", "ARIN", etc.
--- @param ip integer The IP address as an integer
--- @return string The category name
local function categorize(ip: integer): string
  return cosmo.CategorizeIp(ip)
end

--- Check if an IP address is a loopback address (127.x.x.x).
--- @param ip integer The IP address as an integer
--- @return boolean True if the address is a loopback address
local function is_loopback(ip: integer): boolean
  return cosmo.IsLoopbackIp(ip)
end

--- Check if an IP address is a private address.
--- Private ranges: 10.x.x.x, 172.16-31.x.x, 192.168.x.x
--- @param ip integer The IP address as an integer
--- @return boolean True if the address is private
local function is_private(ip: integer): boolean
  return cosmo.IsPrivateIp(ip)
end

--- Check if an IP address is a public/routable address.
--- @param ip integer The IP address as an integer
--- @return boolean True if the address is public
local function is_public(ip: integer): boolean
  return cosmo.IsPublicIp(ip)
end

--- Resolve a hostname to an IP address.
--- @param hostname string The hostname to resolve
--- @return integer The IP address as an integer, or -1 on error
local function resolve(hostname: string): integer
  return cosmo.ResolveIp(hostname)
end

--- Look up a hostname and return its IP address.
--- Returns nil and an error message on failure.
--- @param hostname string The hostname to look up
--- @return integer? The IP address as an integer, or nil on error
--- @return string? Error message on failure
local function lookup(hostname: string): integer, string
  local ip = cosmo.ResolveIp(hostname)
  if not ip or ip == -1 then
    return nil, "dns: lookup failed for " .. hostname
  end
  return ip
end

local record IpModule
  parse: function(str: string): integer
  format: function(ip: integer): string
  categorize: function(ip: integer): string
  is_loopback: function(ip: integer): boolean
  is_private: function(ip: integer): boolean
  is_public: function(ip: integer): boolean
  resolve: function(hostname: string): integer
  lookup: function(hostname: string): integer, string
end

local M: IpModule = {
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

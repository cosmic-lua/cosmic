--- HTML and URL component escaping utilities.
--- Provides functions for safely escaping strings for use in HTML and various URL components.
local cosmo = require("cosmo")

--- Escape HTML special characters.
--- Converts <, >, &, ", and ' to their HTML entity equivalents.
--- @param str string The string to escape
--- @return string The HTML-safe string
local function html(str: string): string
  return cosmo.EscapeHtml(str)
end

--- Escape a hostname for use in a URL.
--- @param str string The hostname to escape
--- @return string The escaped hostname
local function host(str: string): string
  return cosmo.EscapeHost(str)
end

--- Escape a URL path.
--- Escapes characters that are not allowed in URL paths.
--- @param str string The path to escape
--- @return string The escaped path
local function path(str: string): string
  return cosmo.EscapePath(str)
end

--- Escape a single URL path segment.
--- More aggressive than path() - also escapes forward slashes.
--- @param str string The path segment to escape
--- @return string The escaped segment
local function segment(str: string): string
  return cosmo.EscapeSegment(str)
end

--- Escape a URL fragment.
--- @param str string The fragment to escape
--- @return string The escaped fragment
local function fragment(str: string): string
  return cosmo.EscapeFragment(str)
end

--- Escape a string for literal URL matching.
--- @param str string The string to escape
--- @return string The escaped string
local function literal(str: string): string
  return cosmo.EscapeLiteral(str)
end

--- Escape a username for use in a URL.
--- @param str string The username to escape
--- @return string The escaped username
local function user(str: string): string
  return cosmo.EscapeUser(str)
end

--- Escape a password for use in a URL.
--- @param str string The password to escape
--- @return string The escaped password
local function pass(str: string): string
  return cosmo.EscapePass(str)
end

--- Escape an IP address for use in a URL.
--- @param str string The IP address to escape
--- @return string The escaped IP address
local function ip(str: string): string
  return cosmo.EscapeIp(str)
end

local record EscapeModule
  html: function(str: string): string
  host: function(str: string): string
  path: function(str: string): string
  segment: function(str: string): string
  fragment: function(str: string): string
  literal: function(str: string): string
  user: function(str: string): string
  pass: function(str: string): string
  ip: function(str: string): string
end

local M: EscapeModule = {
  html = html,
  host = host,
  path = path,
  segment = segment,
  fragment = fragment,
  literal = literal,
  user = user,
  pass = pass,
  ip = ip,
}

return M

--- URL encoding, decoding, parsing, and escaping utilities.
--- Provides functions for URL query encoding, parsing, and component escaping.
local cosmo = require("cosmo")

--- Percent-encode a string for use as a URL query parameter value.
--- Use this when building query strings manually: `"q=" .. url.encode(search_term)`.
--- Spaces become %20, special characters become %XX hex sequences.
---
--- For other URL components, use the specific escape functions:
--- - `escape_path()`: encode a URL path (preserves slashes)
--- - `escape_segment()`: encode a single path segment (escapes slashes)
--- - `escape_host()`: encode a hostname
--- - `escape_fragment()`: encode a URL fragment
---
--- @param str string The string to encode
--- @return string The percent-encoded string
local function encode(str: string): string
  return cosmo.EscapeParam(str)
end

--- Decode a percent-encoded string.
--- Handles %XX sequences and + as space.
--- @param str string The percent-encoded string
--- @return string | nil The decoded string, or nil on error
--- @return string? Error message if decoding failed
local function decode(str: string): string | nil, string
  -- Check for invalid percent-encoding sequences before decoding
  -- Valid sequences are %XX where X is a hex digit
  local check = str:gsub("%%(%x%x)", "") -- Remove valid sequences
  if check:match("%%") then
    -- Found a % that wasn't followed by two hex digits
    return nil, "invalid percent-encoding"
  end

  -- Use native C implementation for the actual decoding
  return cosmo.UnescapeParam(str)
end

--- Parse a query string into key-value pairs.
--- Handles URL-encoded keys and values.
--- Duplicate keys: last value wins.
--- @param query string The query string (without leading ?)
--- @return {string:string} Table of key-value pairs
local function parse(query: string): {string: string}
  local pairs_list = cosmo.ParseParams(query) as {{string, string}}
  local result: {string: string} = {}
  for _, pair in ipairs(pairs_list) do
    result[pair[1]] = pair[2]
  end
  return result
end

--- Parsed URL components.
local record Url
  scheme: string
  user: string
  pass: string
  host: string
  port: integer
  path: string
  query: string
  fragment: string
end

local record UrlModule
  Url: Url

  encode: function(str: string): string
  decode: function(str: string): string | nil, string
  parse: function(query: string): {string: string}
  parse_url: function(url: string): Url
  parse_host: function(hostport: string): string | nil, integer
  escape_host: function(str: string): string
  escape_path: function(str: string): string
  escape_segment: function(str: string): string
  escape_fragment: function(str: string): string
  escape_literal: function(str: string): string
  escape_user: function(str: string): string
  escape_pass: function(str: string): string
  escape_ip: function(str: string): string
end

--- Parse a URL into its components.
--- @param url string The URL to parse
--- @return Url The parsed URL components
local function parse_url(url: string): Url
  local parsed = cosmo.ParseUrl(url)

  -- Convert port from string to integer if present
  local port: integer = nil
  if parsed.port and parsed.port ~= "" then
    port = tonumber(parsed.port) as integer
  end

  -- Reconstruct query string from params, re-encoding each decoded key and
  -- value so that characters like & and = inside values are not confused with
  -- query-string delimiters (e.g. ?a=x%26y must not become a=x&y).
  local query: string = nil
  if parsed.params and #parsed.params > 0 then
    local parts: {string} = {}
    for _, pair in ipairs(parsed.params) do
      local k = cosmo.EscapeParam(pair[1])
      local v = pair[2] as string
      if v ~= nil then
        table.insert(parts, k .. "=" .. cosmo.EscapeParam(v))
      else
        -- Flag-style param with no value (e.g. ?flag) — emit key only.
        table.insert(parts, k)
      end
    end
    query = table.concat(parts, "&")
  end

  return {
    scheme = parsed.scheme,
    user = parsed.user,
    pass = parsed.pass,
    host = parsed.host,
    port = port,
    path = parsed.path,
    query = query,
    fragment = parsed.fragment,
  }
end

--- Parse a host:port string into its components.
--- @param hostport string The host:port string (e.g., "example.com:8080")
--- @return string | nil The host
--- @return integer? The port, or nil if not specified
local function parse_host(hostport: string): string | nil, integer
  if not hostport or hostport == "" then
    return nil, nil
  end

  -- Handle IPv6 addresses in brackets: [::1]:8080
  local ipv6_host, ipv6_port = hostport:match("^%[([^%]]+)%]:(%d+)$")
  if ipv6_host then
    return ipv6_host, tonumber(ipv6_port) as integer
  end

  -- Handle IPv6 without port: [::1]
  local ipv6_only = hostport:match("^%[([^%]]+)%]$")
  if ipv6_only then
    return ipv6_only, nil
  end

  -- Handle regular host:port
  local host, port_str = hostport:match("^(.+):(%d+)$")
  if host and port_str then
    return host, tonumber(port_str) as integer
  end

  -- No port specified
  return hostport, nil
end

--- Escape a hostname for use in a URL.
--- Handles internationalized domain names and special characters.
--- @param str string The hostname to escape
--- @return string The escaped hostname
local function escape_host(str: string): string
  return cosmo.EscapeHost(str)
end

--- Escape a URL path, preserving forward slashes.
--- Use for paths like `/users/john doe` -> `/users/john%20doe`.
--- To escape a single segment (including slashes), use `escape_segment()`.
--- @param str string The path to escape
--- @return string The escaped path
local function escape_path(str: string): string
  return cosmo.EscapePath(str)
end

--- Escape a single URL path segment, including forward slashes.
--- Use when the segment itself may contain slashes: `file/name.txt` -> `file%2Fname.txt`.
--- For full paths where slashes should be preserved, use `escape_path()`.
--- @param str string The path segment to escape
--- @return string The escaped segment
local function escape_segment(str: string): string
  return cosmo.EscapeSegment(str)
end

--- Escape a URL fragment (the part after #).
--- @param str string The fragment to escape
--- @return string The escaped fragment
local function escape_fragment(str: string): string
  return cosmo.EscapeFragment(str)
end

--- Escape a string for literal URL matching.
--- @param str string The string to escape
--- @return string The escaped string
local function escape_literal(str: string): string
  return cosmo.EscapeLiteral(str)
end

--- Escape a username for use in a URL.
--- @param str string The username to escape
--- @return string The escaped username
local function escape_user(str: string): string
  return cosmo.EscapeUser(str)
end

--- Escape a password for use in a URL.
--- @param str string The password to escape
--- @return string The escaped password
local function escape_pass(str: string): string
  return cosmo.EscapePass(str)
end

--- Escape an IP address for use in a URL.
--- @param str string The IP address to escape
--- @return string The escaped IP address
local function escape_ip(str: string): string
  return cosmo.EscapeIp(str)
end

local M: UrlModule = {
  encode = encode,
  decode = decode,
  parse = parse,
  parse_url = parse_url,
  parse_host = parse_host,
  escape_host = escape_host,
  escape_path = escape_path,
  escape_segment = escape_segment,
  escape_fragment = escape_fragment,
  escape_literal = escape_literal,
  escape_user = escape_user,
  escape_pass = escape_pass,
  escape_ip = escape_ip,
}

return M

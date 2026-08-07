--- URL encoding, decoding, parsing, formatting, and escaping utilities.
local cosmo = require("cosmo")

--- Percent-encode a string for use as a URL query parameter value
--- (api-review-8: was `encode` — escape/unescape is the syntax-safety
--- verb pair, D20). Spaces become %20, specials become %XX.
--- Use this when building query strings manually:
--- `"q=" .. url.escape_param(term)` — or format_query() for whole maps.
---
--- For other URL components, use the specific escape functions:
--- - `escape_path()`: encode a URL path (preserves slashes)
--- - `escape_segment()`: encode a single path segment (escapes slashes)
--- - `escape_host()`: encode a hostname
--- - `escape_fragment()`: encode a URL fragment
--- and `unescape()` as their shared inverse.
---
--- @param str string The string to encode
--- @return string The percent-encoded string
local function escape_param(str: string): string
  return cosmo.EscapeParam(str)
end

--- Decode a percent-encoded query parameter (api-review-8: was
--- `decode`). Handles %XX sequences and + as space — the param rules.
--- For other components (paths, hosts, fragments), where + is a
--- literal plus, use unescape().
--- @param str string The percent-encoded string
--- @return string | nil The decoded string, or nil on error
--- @return string? Error message if decoding failed
local function unescape_param(str: string): string | nil, string
  -- Check for invalid percent-encoding sequences before decoding.
  -- UnescapeParam is lenient (a % not followed by two hex digits passes
  -- through unchanged), so reject malformed input up front; the C
  -- predicate does it in one scan with no allocation.
  if not cosmo.IsValidPercentEncoding(str) then
    return nil, "invalid percent-encoding"
  end

  -- Use native C implementation for the actual decoding
  return cosmo.UnescapeParam(str)
end

--- Decode %XX sequences with NO plus-as-space conversion: the shared
--- inverse of escape_path/escape_segment/escape_host/escape_fragment,
--- where `+` is an ordinary character.
--- @param str string The percent-encoded string
--- @return string | nil The decoded string, or nil on error
--- @return string? Error message if decoding failed
local function unescape(str: string): string | nil, string
  if not cosmo.IsValidPercentEncoding(str) then
    return nil, "invalid percent-encoding"
  end
  return (str:gsub("%%(%x%x)", function(hex: string): string
        return string.char(tonumber(hex, 16) as integer) -- cast: %x%x is a hex pair
      end))
end

--- Parse a query string into its key-value pairs, keeping every value.
--- Keys and values are percent-decoded; a repeated key's values arrive
--- in order. A flag-style key with no `=` yields one empty-string value.
--- @param query string The query string (without leading ?)
--- @return {string:{string}} Decoded keys, each with all its values in order
local function parse_query(query: string): {string: {string}}
  local pairs_list = cosmo.ParseParams(query) as {{string}} -- cast: from any
  local result: {string: {string}} = {}
  for _, pair in ipairs(pairs_list) do
    local key = pair[1]
    local list = result[key]
    if not list then
      list = {}
      result[key] = list
    end
    table.insert(list, pair[2] or "")
  end
  return result
end

--- Format a query map back into a query string: the inverse of
--- parse_query. Keys are sorted (deterministic output) and each of a
--- key's values becomes its own k=v pair, in order; both halves are
--- percent-encoded with the param rules (spaces become %20). A value
--- may be a plain string as well as a list — so a parsed query feeds
--- back in unchanged, and the common one-value-per-key map (e.g.
--- fetch's query option) needs no wrapping.
--- @param params {string:{string} | string} Keys with one value or all values in order
--- @return string The query string (no leading ?)
local function format_query(params: {string: {string} | string}): string
  local keys: {string} = {}
  for k in pairs(params) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  local out: {string} = {}
  for _, k in ipairs(keys) do
    local v = params[k]
    if v is string then
      out[#out + 1] = escape_param(k) .. "=" .. escape_param(v)
    else
      for _, item in ipairs(v) do
        out[#out + 1] = escape_param(k) .. "=" .. escape_param(item)
      end
    end
  end
  return table.concat(out, "&")
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

--- Parse a URL into its components.
--- The query field is re-encoded so delimiters inside values survive
--- (e.g. `?a=x%26y` stays one parameter); decode it with `parse_query`.
--- @param url string The URL to parse
--- @return Url | nil The parsed URL components, or nil on error
--- @return string? Error message if parsing failed
local function parse(url: string): Url | nil, string
  if not url or url == "" then
    return nil, "empty URL"
  end
  local parsed = cosmo.ParseUrl(url)

  -- Convert port from string to integer if present, validating range
  local port: integer = nil
  if parsed.port and parsed.port ~= "" then
    port = math.tointeger(tonumber(parsed.port))
    if not port or port < 1 or port > 65535 then
      return nil, "invalid port: " .. parsed.port
    end
  end

  -- Reconstruct query string from params, re-encoding each decoded key and
  -- value so that characters like & and = inside values are not confused with
  -- query-string delimiters (e.g. ?a=x%26y must not become a=x&y).
  local query: string = nil
  if parsed.params and #parsed.params > 0 then
    local parts: {string} = {}
    for _, pair in ipairs(parsed.params) do
      local k = cosmo.EscapeParam(pair[1])
      local v = pair[2]
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

--- Format a Url back into a string — the inverse of `parse`.
--- Each component is escaped for its position, so a parse/format round
--- trip yields an equivalent URL.
--- @param u Url The URL components to format
--- @return string The formatted URL
local function format(u: Url): string
  local params: {{string}} = nil
  if u.query then
    params = cosmo.ParseParams(u.query) as {{string}} -- cast: from any
  end
  return cosmo.EncodeUrl({
      scheme = u.scheme,
      user = u.user,
      pass = u.pass,
      host = u.host,
      port = u.port ~= nil and tostring(u.port) or nil,
      path = u.path,
      params = params,
      fragment = u.fragment,
    })
end

--- A parsed host:port pair; port is nil when the input carried none.
--- A record rather than (host, port, err) returns: the error is in
--- slot 2, where check.must and `local h, err = ...` can see it.
local record HostPort
  host: string
  port: integer
end

--- Parse a host:port string into its components.
--- IPv6 hosts must be bracketed ("[::1]" or "[::1]:8080"); a port, when
--- present, must be an integer in 1..65535.
--- @param hostport string The host:port string (e.g., "example.com:8080")
--- @return HostPort | nil The parsed host (port nil when absent)
--- @return string? Error message if parsing failed
local function parse_host(hostport: string): HostPort | nil, string
  if not hostport or hostport == "" then
    return nil, "empty host"
  end

  local port_str: string = nil
  local host: string

  local bracket_host, rest = hostport:match("^%[([^%]]+)%](.*)$")
  if bracket_host then
    host = bracket_host
    local r = rest
    if r ~= "" then
      port_str = r:match("^:(%d+)$")
      if not port_str then
        return nil, "invalid host:port: " .. hostport
      end
    end
  else
    local colon = hostport:find(":", 1, true)
    if not colon then
      host = hostport
    else
      host = hostport:sub(1, colon - 1)
      port_str = hostport:sub(colon + 1)
      if port_str:find(":", 1, true) then
        return nil, "IPv6 host must be bracketed, e.g. [::1]:8080"
      end
      if host == "" then
        return nil, "empty host in: " .. hostport
      end
      if not port_str:match("^%d+$") then
        return nil, "invalid port: " .. port_str
      end
    end
  end

  if port_str then
    local port = math.tointeger(tonumber(port_str))
    if not port or port < 1 or port > 65535 then
      return nil, "invalid port: " .. port_str
    end
    return {host = host, port = port}
  end
  return {host = host}
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

--- Format a HostPort back into a host:port string: the inverse of
--- parse_host. An IPv6 host (any host carrying a colon) is bracketed,
--- which is exactly the rule parse_host knows and callers were left to
--- rediscover; a nil port yields the bare host.
--- @param hp HostPort The host (port optional)
--- @return string The host:port string
local function format_host(hp: HostPort): string
  local host = hp.host
  if host:find(":", 1, true) then
    host = "[" .. host .. "]"
  end
  if hp.port then
    return host .. ":" .. tostring(hp.port)
  end
  return host
end

local record UrlModule
  type Url = Url
  type HostPort = HostPort

  escape_param: function(str: string): string
  unescape_param: function(str: string): string | nil, string
  unescape: function(str: string): string | nil, string
  parse: function(url: string): Url | nil, string
  format: function(u: Url): string
  parse_query: function(query: string): {string: {string}}
  format_query: function(params: {string: {string} | string}): string
  parse_host: function(hostport: string): HostPort | nil, string
  escape_host: function(str: string): string
  escape_path: function(str: string): string
  escape_segment: function(str: string): string
  escape_fragment: function(str: string): string
  format_host: function(hp: HostPort): string
end

local M: UrlModule = {
  escape_param = escape_param,
  unescape_param = unescape_param,
  unescape = unescape,
  format_query = format_query,
  parse = parse,
  format = format,
  parse_query = parse_query,
  parse_host = parse_host,
  escape_host = escape_host,
  escape_path = escape_path,
  escape_segment = escape_segment,
  escape_fragment = escape_fragment,
  format_host = format_host,
}

return M

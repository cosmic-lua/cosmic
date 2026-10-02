--- URLs in pure Teal: percent-escaping one piece of a URL, unescaping
--- it, a request path split into the names it is safe to join under a
--- directory, and an absolute URL read into its parts.
---
--- - [`Url.escape`] and [`Url.unescape`]: percent-encoding (RFC 3986),
---   one way for a path segment, a query name and a query value.
--- - [`Url.segments`]: a path's segments, unescaped, refusing one that
---   would climb out of the directory they are joined under.
--- - [`Url.parse`]: `scheme://[userinfo@]host[:port][/path][?query][#fragment]`
---   read into a [`Parts`].
---
---     local url = "https://example.com/files/" .. Url.escape("a b.txt")
---     local parts = assert(Url.parse(url))
---     print(parts.host, parts.path) -- example.com  /files/a%20b.txt
---
--- Nothing here raises on its text: a failure answers `nil` and why,
--- under the module's name.

local record Url
  --- An absolute URL's parts, as [`Url.parse`] reads them. The scheme
  --- and host are lowercased; the user info, path, query and fragment
  --- are as written, still escaped.
  record Parts
    --- The scheme, lowercased: "https".
    scheme: string
    --- What comes before an `@` in the authority, as written, or nil
    --- when there is no `@`.
    userinfo: string
    --- The host, lowercased: a name, an IPv4 address, or an IPv6
    --- address without its brackets ("::1").
    host: string
    --- The port, or nil when the URL names none (or an empty one, as
    --- "http://h:/").
    port: integer
    --- The path, as written: "" when the URL has none, else starting
    --- with "/".
    path: string
    --- What follows the first `?`, up to a `#`, or nil when there is no
    --- `?`.
    query: string
    --- What follows the first `#`, or nil when there is no `#`.
    fragment: string
  end
end

--- What a failure of this module answers: nil and `why` under its name.
local function refuse(why: string): nil, string
  return nil, "url: " .. why
end

--- Every byte's escape, by the byte: itself for an unreserved one
--- (A-Z a-z 0-9 - . _ ~), `%` and two uppercase hex digits for any
--- other. `gsub` takes the table as its replacement, one lookup a byte.
local escape_of: {string:string} = {}
--- Every pair of hex digits, either case, to the byte it spells.
local byte_of_hex: {string:string} = {}
do
  for byte = 0, 255 do
    local ch = string.char(byte)
    if ch:find("^[A-Za-z0-9._~-]$") then
      escape_of[ch] = ch
    else
      escape_of[ch] = ("%%%02X"):format(byte)
    end
    local lower, upper = ("%02x"):format(byte), ("%02X"):format(byte)
    for _, h in ipairs({ lower:sub(1, 1), upper:sub(1, 1) }) do
      for _, l in ipairs({ lower:sub(2, 2), upper:sub(2, 2) }) do
        byte_of_hex[h .. l] = ch
      end
    end
  end
end

--- `text` with every byte but the unreserved ones (A-Z a-z 0-9 `-` `.`
--- `_` `~`) written as `%` and two uppercase hex digits. What it
--- answers is safe as a path segment, a query name or a query value:
--- a `/`, `?`, `&`, `=`, `#`, `+`, space or `%` in `text` is escaped
--- too, so it reads back as itself and never as part of the URL's
--- structure.
--- @param text string Any bytes
--- @return string The escaped text
function Url.escape(text: string): string
  return (text:gsub(".", escape_of))
end

--- `text` with each `%` and two hex digits, of either case, replaced by
--- the byte they spell; `offset` is added to a byte position named in a
--- refusal, for text taken from inside a longer string.
local function unescape(text: string, offset: integer): string | nil, string
  local at = text:find("%", 1, true)
  while at ~= nil do
    if not text:find("^%x%x", at + 1) then
      return refuse(("'%%' at byte %d is not followed by two hex digits"):format(at + offset))
    end
    at = text:find("%", at + 3, true)
  end
  return (text:gsub("%%(%x%x)", byte_of_hex)), ""
end

--- The bytes percent-escaped `text` spells: each `%` and two hex digits,
--- of either case, becomes the byte they name, which may be any byte
--- (a NUL, a `/`). A `+` is left as it is: reading it as a space is a
--- form's rule, not a URL's. A `%` not followed by two hex digits
--- answers `nil` and why, naming its byte.
--- @param text string The escaped text
--- @return string | nil The bytes it spells
--- @return string Why it was refused, or "" when it was not
function Url.unescape(text: string): string | nil, string
  return unescape(text, 0)
end

--- The segments of a URL's `path`, unescaped, for a server to find a
--- file or route by: the path is split on `/` before anything is
--- unescaped, so an escaped `/` (`%2F`) never splits one. An empty
--- segment (from `//` or a trailing `/`) and a `.` are dropped, so "/"
--- answers `{}`. A segment that is `..` (`%2e%2e` included), or that
--- holds a `/` or a NUL once unescaped, answers `nil` and why, as does
--- a path that does not start with `/` or a malformed escape.
---
--- So `root .. "/" .. table.concat(segments, "/")` names a path under
--- `root` that cannot climb out of it by its name -- though a symbolic
--- link inside `root` still can. Hand it the path alone, without the
--- query: a `?` here is part of a segment.
--- @param path string A path, still escaped, starting with "/"
--- @return {string} | nil Its segments, unescaped
--- @return string Why it was refused, or "" when it was not
function Url.segments(path: string): {string} | nil, string
  if path:sub(1, 1) ~= "/" then
    return refuse("the path does not start with '/'")
  end
  local out: {string} = {}
  local at = 2
  while at <= #path do
    local slash = path:find("/", at, true) or #path + 1
    if slash > at then
      local piece, why = unescape(path:sub(at, slash - 1), at - 1)
      if piece == nil then
        return nil, why
      end
      if piece == ".." then
        return refuse(("the segment at byte %d is '..', which climbs out of the path"):format(at))
      elseif piece:find("/", 1, true) then
        return refuse(("the segment at byte %d holds an escaped '/'"):format(at))
      elseif piece:find("\0", 1, true) then
        return refuse(("the segment at byte %d holds a NUL"):format(at))
      elseif piece ~= "." then
        out[#out + 1] = piece
      end
    end
    at = slash + 1
  end
  return out, ""
end

--- Why `text` is no URL when it holds a space or control byte, which a
--- URL holds only escaped, naming the first; "" when it holds none.
local function unescaped_byte(text: string): string
  local at = text:find("[\0-\32\127]")
  if at == nil then
    return ""
  end
  local byte = text:byte(at)
  local what = byte == 32 and "a space" or byte == 0 and "a NUL" or
    ("control byte 0x%02x"):format(byte)
  return ("url: the URL holds %s at byte %d; escape a path segment or query value with Url.escape"):
     format(what, at)
end

--- Whether `text` is an IPv6 address (RFC 4291's text form): eight
--- groups of one to four hex digits, a `::` standing in for one or more
--- of them at most once, and the last two may be a dotted IPv4 address.
--- A zone (`%25eth0`, RFC 6874) is not taken: no caller here dials a
--- link-local address by its interface.
local function is_ipv6(text: string): boolean
  local groups = 8
  local v4 = text:match(":(%d+%.%d+%.%d+%.%d+)$")
  if v4 ~= nil then
    for octet in v4:gmatch("%d+") do
      if #octet > 3 or (math.tointeger(tonumber(octet)) or 256) > 255 then
        return false
      end
    end
    text, groups = text:sub(1, #text - #v4 - 1) .. ":", 6
    if text:sub(-2) ~= "::" then
      text = text:sub(1, -2)
    end
  end
  local head, tail = text, ""
  local gap = text:find("::", 1, true)
  if gap ~= nil then
    head, tail = text:sub(1, gap - 1), text:sub(gap + 2)
    if tail:find("::", 1, true) then
      return false
    end
  end
  local count = 0
  for _, side in ipairs({ head, tail }) do
    if side ~= "" then
      for group in (side .. ":"):gmatch("([^:]*):") do
        if not group:find("^%x%x?%x?%x?$") then
          return false
        end
        count = count + 1
      end
    end
  end
  if gap ~= nil then
    return count < groups
  end
  return count == groups
end

--- Sets `parts`' host, lowercased, and port from an authority past its
--- user info; false and why when it is malformed.
local function read_host(parts: Url.Parts, text: string): boolean, string
  local function bad(why: string): boolean, string
    return false, "url: " .. why
  end
  local host, rest: string, string
  if text:sub(1, 1) == "[" then
    host, rest = text:match("^%[([^%]]*)%](.*)$")
    if host == nil then
      return bad("an IPv6 host is missing its closing ']'")
    end
    if not is_ipv6(host) then
      return bad("the host in brackets is not an IPv6 address")
    end
  else
    host, rest = text:match("^([^:]*)(.*)$")
    if rest:find(":", 2, true) then
      return bad("the host holds more than one ':'; an IPv6 address goes in brackets, as http://[::1]/")
    end
    if host == "" then
      return bad("the URL names no host")
    end
    if host:find("[%[%]]") then
      return bad("the host holds a bracket outside an IPv6 address")
    end
  end
  parts.host = host:lower()
  if rest == "" or rest == ":" then
    return true, ""
  end
  if rest:sub(1, 1) ~= ":" then
    return bad("an IPv6 host's ']' is followed by something other than ':' and a port")
  end
  local digits = rest:sub(2)
  if digits:find("%D") then
    return bad("the port holds a byte other than a digit")
  end
  local value = digits:match("^0*(%d*)$")
  local port = math.tointeger(tonumber(value)) or 0
  if #value > 5 or port > 65535 then
    return bad("the port is not a number from 0 to 65535")
  end
  parts.port = port
  return true, ""
end

--- An absolute URL, `scheme://[userinfo@]host[:port][/path][?query][#fragment]`,
--- read into its [`Parts`]: the scheme and host lowercased, an IPv6
--- host taken out of its brackets, the port a number from 0 to 65535,
--- and the user info, path, query and fragment as written, still
--- escaped ([`Url.segments`] reads a path, [`Url.unescape`] a piece).
--- Answers `nil` and why for anything else: a relative reference, a URL
--- without `//` (`mailto:`), one that names no host (`file:///`), more
--- than one `@`, a malformed port or IPv6 host (one with a zone, as
--- `[fe80::1%25eth0]`, included), or a space or control byte anywhere,
--- which a URL holds only escaped ([`Url.escape`]).
--- @param text string The URL
--- @return Parts | nil Its parts
--- @return string Why it was refused, or "" when it was not
function Url.parse(text: string): Url.Parts | nil, string
  local unescaped = unescaped_byte(text)
  if unescaped ~= "" then
    return nil, unescaped
  end
  local _, scheme_end, scheme = text:find("^(%a[%w+.-]*)://")
  if scheme == nil then
    return refuse("the URL does not start with a scheme and '://', as https://example.com/ does")
  end
  local _, authority_end, authority = text:find("^([^/?#]*)", scheme_end + 1)
  local _, path_end, path = text:find("^([^?#]*)", authority_end + 1)
  local parts: Url.Parts = { scheme = scheme:lower(), path = path }
  local hostport = authority
  local at = authority:find("@", 1, true)
  if at ~= nil then
    if authority:find("@", at + 1, true) then
      return refuse("the authority holds more than one '@'; escape the user info with Url.escape")
    end
    parts.userinfo, hostport = authority:sub(1, at - 1), authority:sub(at + 1)
  end
  local ok, why = read_host(parts, hostport)
  if not ok then
    return nil, why
  end
  local rest = text:sub(path_end + 1)
  local hash = rest:find("#", 1, true)
  if hash ~= nil then
    parts.fragment, rest = rest:sub(hash + 1), rest:sub(1, hash - 1)
  end
  if rest ~= "" then
    parts.query = rest:sub(2)
  end
  return parts, ""
end

return Url

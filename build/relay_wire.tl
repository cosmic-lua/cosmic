--- What the sandbox relay reads from the program it confines, and what it
--- answers: an HTTP CONNECT request head, a SOCKS5 greeting, sub-negotiation
--- and request, and the server name in a TLS ClientHello. The program is
--- untrusted, so each reader is a pure function of the bytes it is given: it
--- never raises, reads nothing past a length field it has checked, and refuses
--- by naming why.
---
--- Each reader is incremental by being repeatable. The caller keeps what it
--- has read so far and gives it all again after each read: the answer is
--- `more` until the bytes decide it, then `done` with the count of bytes
--- consumed (what follows is the tunnel's, not the request's), or a refusal.
--- A prefix is refused only when every longer input is refused for the same
--- reason, and an input is done at the same count wherever its reads split
--- (build/relay_wire_fuzz_test.tl). Every length is bounded, so a buffer that
--- grows past the largest cap below is already decided.
---
--- A host the readers answer is one of three kinds and is already in the
--- form a grant is matched in: a DNS name (labels of letters, digits and
--- hyphens, 63 bytes at most, 253 in all, lower-cased, a trailing dot
--- removed, and no final label that inet_aton would read as a number),
--- a dotted IPv4 address (decimal octets, no leading zeros), or an IPv6
--- address in RFC 5952's form without brackets. Nothing is resolved here.

local plural = require("build.plural")

local record relay_wire
  --- What a reader has decided so far.
  enum Status
    "more"
    "done"
    "refused"
  end

  --- What a host is.
  enum Kind
    "name"
    "ipv4"
    "ipv6"
  end

  --- A CONNECT request head: `CONNECT host:port HTTP/1.1` and its headers.
  record Connect
    status: Status
    --- Bytes of the head, through its empty line, when `done`.
    consumed: integer
    --- When `refused`, why, worded to be shown to the program.
    reason: string
    --- When `refused`, the status line's code to answer with.
    http_status: integer
    --- When `done`, the host, in the form the module's header describes.
    host: string
    kind: Kind
    port: integer
    --- When `done`, the value of the `Proxy-Authorization` header, or nil
    --- when there is none. No other header is kept.
    authorization: string
  end

  --- The SOCKS5 method selection, answered with [`socks_method_reply`].
  record SocksGreeting
    status: Status
    --- Bytes of the greeting, when `done`.
    consumed: integer
    reason: string
    --- When `done`, the method to select: 0 (no authentication) or 2
    --- (username and password). When `refused`, 255 (none acceptable) or,
    --- for a greeting of the wrong version, 0.
    method: integer
  end

  --- A SOCKS5 username and password (RFC 1929), answered with
  --- [`socks_auth_reply`].
  record SocksAuth
    status: Status
    consumed: integer
    reason: string
    username: string
    password: string
  end

  --- The replies a SOCKS5 server answers a request with.
  enum SocksReply
    "succeeded"
    "failure"
    "not_allowed"
    "network_unreachable"
    "host_unreachable"
    "refused"
    "ttl_expired"
    "command_not_supported"
    "address_type_not_supported"
  end

  --- A SOCKS5 CONNECT request.
  record SocksRequest
    status: Status
    consumed: integer
    --- When `refused`, why, and the reply to answer with.
    reason: string
    reply: SocksReply
    host: string
    kind: Kind
    port: integer
  end

  --- What a ClientHello says of its server name.
  enum SniStatus
    "more"
    "name"
    "no_sni"
    "not_tls"
    "malformed"
  end

  --- The server name of a TLS ClientHello.
  record Hello
    --- `name`: the hello names a server, in `name`. `no_sni`: a well-formed
    --- hello with no server_name extension. `not_tls`: the bytes are not a
    --- TLS handshake at all, so the relay's policy for other protocols
    --- applies. `malformed`: a TLS record or hello that breaks its own
    --- lengths, or a name that breaks the rules above.
    status: SniStatus
    --- Bytes of the records the hello ends in, when `name` or `no_sni`.
    consumed: integer
    name: string
    --- When `not_tls` or `malformed`, why.
    reason: string
  end
end

--- The most bytes of one line, and of a whole head, a CONNECT request may
--- hold, and the most headers.
local MAX_LINE <const> = 8192
local MAX_HEAD <const> = 16384
local MAX_HEADERS <const> = 100

--- The most bytes a ClientHello message may hold, and the most records it
--- may be split across.
local MAX_HELLO <const> = 16384
local MAX_RECORDS <const> = 64

--- A byte no line holds, or one that ends a line: NUL, the other C0
--- controls but tab, and DEL.
local SPECIAL <const> = "[\0-\8\10-\31\127]"

--- The most bytes of a reason phrase a refusal's status line carries.
local MAX_PHRASE <const> = 200

local function lower(text: string): string
  return (text:gsub("%u", string.lower))
end

--- The four decimal octets of `text`, or nil.
local function octets(text: string): {integer} | nil
  local a, b, c, d = text:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if a == nil or b == nil or c == nil or d == nil then
    return nil
  end
  local out: {integer} = {}
  for _, octet in ipairs({ a, b, c, d }) do
    if #octet > 3 or (#octet > 1 and octet:sub(1, 1) == "0") then
      return nil
    end
    local value = math.tointeger(tonumber(octet))
    if value == nil or value > 255 then
      return nil
    end
    out[#out + 1] = value
  end
  return out
end

local function ipv4(text: string): boolean
  return octets(text) ~= nil
end

--- The 16-bit groups of the colon-separated `text`, whose last piece may be
--- a dotted IPv4 address when `tail` says so.
local function groups(text: string, tail: boolean): {integer} | nil
  local out: {integer} = {}
  if text == "" then
    return out
  end
  local pos = 1
  while true do
    local colon = text:find(":", pos, true)
    local piece = text:sub(pos, (colon or #text + 1) - 1)
    if piece:find(".", 1, true) then
      local n = octets(piece)
      if colon ~= nil or not tail or n == nil then
        return nil
      end
      out[#out + 1] = n[1] * 256 + n[2]
      out[#out + 1] = n[3] * 256 + n[4]
    else
      local value = math.tointeger(tonumber(piece, 16))
      if #piece < 1 or #piece > 4 or piece:find("%X") or value == nil then
        return nil
      end
      out[#out + 1] = value
    end
    if colon == nil then
      return out
    end
    pos = colon + 1
  end
end

--- `text`, an IPv6 address without brackets or a zone, in RFC 5952's
--- form, or nil and why.
local function ipv6(text: string): string | nil, string
  if text:find("[^%x:%.]") or not text:find(":", 1, true) then
    return nil, "not an IPv6 address (a zone, or a character an address does not hold)"
  end
  local bad = "not an IPv6 address"
  if text:find(":::", 1, true) then
    return nil, bad
  end
  local all: {integer} = {}
  local gap = text:find("::", 1, true)
  if gap ~= nil then
    if text:find("::", gap + 2, true) then
      return nil, bad
    end
    local left = groups(text:sub(1, gap - 1), false)
    local right = groups(text:sub(gap + 2), true)
    if left == nil or right == nil or #left + #right > 7 then
      return nil, bad
    end
    for _, g in ipairs(left) do
      all[#all + 1] = g
    end
    for _ = 1, 8 - #left - #right do
      all[#all + 1] = 0
    end
    for _, g in ipairs(right) do
      all[#all + 1] = g
    end
  else
    local whole = groups(text, true)
    if whole == nil or #whole ~= 8 then
      return nil, bad
    end
    all = whole
  end
  local best_at, best_len, at = 0, 1, 1
  while at <= 8 do
    if all[at] == 0 then
      local stop = at
      while stop < 8 and all[stop + 1] == 0 do
        stop = stop + 1
      end
      if stop - at + 1 > best_len then
        best_at, best_len = at, stop - at + 1
      end
      at = stop + 1
    else
      at = at + 1
    end
  end
  local parts: {string} = {}
  local i = 1
  while i <= 8 do
    if i == best_at then
      if best_len == 8 then
        return "::"
      end
      parts[#parts + 1] = ""
      if i == 1 or i + best_len > 8 then
        parts[#parts + 1] = ""
      end
      i = i + best_len
    else
      parts[#parts + 1] = ("%x"):format(all[i])
      i = i + 1
    end
  end
  local out = table.concat(parts, ":")
  return out
end

--- Whether `label`, the last of a name's, is one a resolver may read as a
--- number: all digits, or `0x` and hex digits (`inet_aton`'s forms).
local function numeric(label: string): boolean
  return label:find("^%d+$") ~= nil or label:find("^0x%x*$") ~= nil
end

--- `text` as a DNS name in the form a grant is matched in, or nil and why.
local function dns_name(text: string): string | nil, string
  if text:sub(-1) == "." then
    text = text:sub(1, -2)
  end
  if text == "" then
    return nil, "empty host name"
  end
  if #text > 253 then
    return nil, "host name longer than 253 bytes"
  end
  text = lower(text)
  local last = ""
  for label in (text .. "."):gmatch("([^.]*)%.") do
    if label == "" then
      return nil, "host name with an empty label"
    end
    if #label > 63 then
      return nil, "host name label longer than 63 bytes"
    end
    if not label:find("^[a-z0-9][a-z0-9-]*$") or label:sub(-1) == "-" then
      return nil, "host name label that is not letters, digits and inner hyphens"
    end
    last = label
  end
  if numeric(last) then
    return nil, "host name whose last label is a number (write an IPv4 address in four parts)"
  end
  return text
end

--- A host in the form a grant is matched in and its kind, or nil, nil and why.
local function bare_host(text: string): string | nil, relay_wire.Kind | nil, string
  if ipv4(text) then
    return text, "ipv4", ""
  end
  local name, why = dns_name(text)
  if name == nil then
    return nil, nil, why
  end
  return name, "name", ""
end

--- The port in `text`: decimal, 1 to 65535, without leading zeros.
local function port_of(text: string): integer | nil, string
  local why = "port is not a decimal number from 1 to 65535 without leading zeros"
  if not text:find("^[1-9]%d*$") or #text > 5 then
    return nil, why
  end
  local port = math.tointeger(tonumber(text))
  if port > 65535 then
    return nil, why
  end
  return port
end

--- A `host:port` authority taken apart.
local record Authority
  host: string
  kind: relay_wire.Kind
  port: integer
end

--- `text` as a `host:port` authority, or nil and why.
local function authority(text: string): Authority | nil, string
  if text:find("@", 1, true) then
    return nil, "userinfo is not allowed in a CONNECT target"
  end
  local out: Authority = { host = "", kind = "name", port = 0 }
  local rest: string
  if text:sub(1, 1) == "[" then
    local close = text:find("]", 1, true)
    if close == nil then
      return nil, "unclosed [ in the CONNECT target"
    end
    local canonical, why = ipv6(text:sub(2, close - 1))
    if canonical == nil then
      return nil, why
    end
    out.host, out.kind, rest = canonical, "ipv6", text:sub(close + 1)
    if rest:sub(1, 1) ~= ":" then
      return nil, "CONNECT target has no port after the ]"
    end
    rest = rest:sub(2)
  else
    local colon = text:find(":", 1, true)
    if colon == nil then
      return nil, "CONNECT target has no port (host:port)"
    end
    if text:find(":", colon + 1, true) then
      return nil, "an IPv6 address needs brackets in a CONNECT target"
    end
    local name, kind, why = bare_host(text:sub(1, colon - 1))
    if name == nil or kind == nil then
      return nil, why
    end
    out.host, out.kind, rest = name, kind, text:sub(colon + 1)
  end
  local port, why = port_of(rest)
  if port == nil then
    return nil, why
  end
  out.port = port
  return out
end

--- A reader's refusal of a CONNECT head.
local function refused(why: string, http_status: integer): relay_wire.Connect
  return { status = "refused", consumed = 0, reason = why, http_status = http_status }
end

--- One line of a head from `start`: "more" when it is not complete and
--- nothing in it is refused yet; "refused", why and the status to answer
--- with; or "line", "" and where the next begins (its content ends two
--- bytes before). Violations are decided by the position of the first
--- byte that commits one, so that a prefix never refuses what the whole
--- does not, or for another reason.
local function scan_line(buf: string, start: integer, first: boolean): string, string, integer
  local size = #buf
  local special = buf:find(SPECIAL, start)
  local excess_at = start + MAX_LINE
  local head_at = MAX_HEAD + 1
  local line_hit = size >= excess_at and (special == nil or special > excess_at)
  local head_hit = size >= head_at and (special == nil or special >= head_at)
  if head_hit and (not line_hit or head_at <= excess_at) then
    return "refused", ("request head longer than %s"):format(plural.count(MAX_HEAD, "byte")), 431
  end
  if line_hit then
    return "refused", ("%s longer than %s"):format(first and "request line" or "header line", plural.count(MAX_LINE, "byte")),
      first and 414 or 431
  end
  if special == nil then
    return "more", "", 0
  end
  local byte = buf:byte(special)
  if byte == 13 then
    if special >= MAX_HEAD then
      return "refused", ("request head longer than %s"):format(plural.count(MAX_HEAD, "byte")), 431
    end
    if special == size then
      return "more", "", 0
    end
    if buf:byte(special + 1) == 10 then
      return "line", "", special + 2
    end
    return "refused", "a carriage return outside a CRLF line ending", 400
  end
  if byte == 10 then
    return "refused", "a bare LF line ending (lines end in CRLF)", 400
  end
  return "refused", ("control byte 0x%02x in the request head"):format(byte), 400
end

--- A header name's bytes (RFC 9110's token).
local TOKEN <const> = "^[%w!#$%%&'*+%-%.%^_`|~]+$"

--- Reads the CONNECT request head at the start of `buf`.
---
--- It is exactly `CONNECT host:port HTTP/1.1` (or `HTTP/1.0`) with CRLF
--- line endings, then header lines up to an empty line. A request line of
--- another method is refused as plain HTTP, which is not relayed. At most
--- 8192 bytes to a line, 16384 to the head and 100 headers; a bare LF or CR,
--- NUL or other control byte, and an obsolete line fold are refused.
--- `Proxy-Authorization` is kept, and no other header is read.
function relay_wire.connect_head(buf: string): relay_wire.Connect
  local pos = 1
  local first = true
  local count = 0
  local authorization: string
  local host: string
  local kind: relay_wire.Kind
  local port: integer
  while true do
    local outcome, why, next_start = scan_line(buf, pos, first)
    if outcome == "more" then
      return { status = "more", consumed = 0 }
    elseif outcome == "refused" then
      return refused(why, next_start)
    end
    local content = buf:sub(pos, next_start - 3)
    pos = next_start
    if first then
      first = false
      local method = content:match("^[^ \t]*")
      if method ~= "CONNECT" then
        return refused("plain HTTP is not relayed: only CONNECT host:port is accepted", 405)
      end
      local target, version = content:match("^CONNECT ([^ ]*) ([^ ]*)$")
      if target == nil then
        return refused("malformed request line (expected CONNECT host:port HTTP/1.1)", 400)
      end
      if version ~= "HTTP/1.1" and version ~= "HTTP/1.0" then
        return refused("unsupported HTTP version " .. version .. " (HTTP/1.1 or HTTP/1.0)", 505)
      end
      local found, trouble = authority(target)
      if found == nil then
        return refused(trouble, 400)
      end
      host, kind, port = found.host, found.kind, found.port
    elseif content == "" then
      return {
        status = "done",
        consumed = pos - 1,
        host = host,
        kind = kind,
        port = port,
        authorization = authorization,
      }
    else
      if content:find("^[ \t]") then
        return refused("an obsolete header line fold (a line starting with whitespace)", 400)
      end
      count = count + 1
      if count > MAX_HEADERS then
        return refused(("more than %s"):format(plural.count(MAX_HEADERS, "header")), 431)
      end
      local name, value = content:match("^([^:]*):(.*)$")
      if name == nil then
        return refused("a header line without a colon", 400)
      end
      if not name:find(TOKEN) then
        return refused("a header name that is not a token", 400)
      end
      if lower(name) == "proxy-authorization" then
        if authorization ~= nil then
          return refused("a repeated Proxy-Authorization header", 400)
        end
        authorization = value:match("^[ \t]*(.-)[ \t]*$")
      end
    end
  end
end

--- The reply to a CONNECT that was granted and connected.
function relay_wire.connect_ok(): string
  return "HTTP/1.1 200 Connection established\r\n\r\n"
end

--- The reply to a CONNECT that was refused or failed: a status from 400
--- through 599, and `why` as the reason phrase, which the program's error
--- shows (`403 not granted: --connect api.github.com:443`). The phrase is
--- cut to visible ASCII, `?` for any other byte, and to 200 bytes. Raises
--- on a status outside 400 through 599.
function relay_wire.connect_refusal(status: integer, why: string): string
  if math.type(status) ~= "integer" or status < 400 or status > 599 then
    error("connect_refusal: status must be an integer from 400 to 599", 2)
  end
  local phrase = why:gsub("[^\32-\126]", "?"):sub(1, MAX_PHRASE):match("^ *(.-) *$")
  if phrase == "" then
    phrase = "Refused"
  end
  return ("HTTP/1.1 %d %s\r\n%sConnection: close\r\nContent-Length: 0\r\n\r\n"):format(status, phrase,
    status == 405 and "Allow: CONNECT\r\n" or "")
end

--- Reads the SOCKS5 greeting at the start of `buf` and picks the method:
--- no authentication (0x00), or with `password` set, only username and
--- password (0x02), which carries the sandbox's token. A greeting that
--- offers neither is refused with method 255.
function relay_wire.socks_greeting(buf: string, password?: boolean): relay_wire.SocksGreeting
  if #buf < 1 then
    return { status = "more", consumed = 0 }
  end
  if buf:byte(1) ~= 5 then
    return { status = "refused", consumed = 0, method = 0,
      reason = ("SOCKS version %d is not supported (only 5)"):format(buf:byte(1)) }
  end
  if #buf < 2 then
    return { status = "more", consumed = 0 }
  end
  local count = buf:byte(2)
  local want = password and 2 or 0
  if count == 0 then
    return { status = "refused", consumed = 0, method = 255, reason = "no authentication method offered" }
  end
  if #buf < 2 + count then
    return { status = "more", consumed = 0 }
  end
  for i = 3, 2 + count do
    if buf:byte(i) == want then
      return { status = "done", consumed = 2 + count, method = want }
    end
  end
  return { status = "refused", consumed = 0, method = 255,
    reason = password and "the sandbox's token needs username/password authentication (method 0x02)" or
      "no-authentication (method 0x00) was not offered" }
end

--- The reply to a greeting: the method chosen, or 255.
function relay_wire.socks_method_reply(method: integer): string
  if math.type(method) ~= "integer" or method < 0 or method > 255 then
    error("socks_method_reply: method must be an integer from 0 to 255", 2)
  end
  return "\5" .. string.char(method)
end

--- Reads the RFC 1929 username and password at the start of `buf`: both
--- from 1 to 255 bytes.
function relay_wire.socks_auth(buf: string): relay_wire.SocksAuth
  if #buf < 1 then
    return { status = "more", consumed = 0 }
  end
  if buf:byte(1) ~= 1 then
    return { status = "refused", consumed = 0,
      reason = ("username/password version %d is not supported (only 1)"):format(buf:byte(1)) }
  end
  if #buf < 2 then
    return { status = "more", consumed = 0 }
  end
  local ulen = buf:byte(2)
  if ulen == 0 then
    return { status = "refused", consumed = 0, reason = "empty username" }
  end
  if #buf < 2 + ulen + 1 then
    return { status = "more", consumed = 0 }
  end
  local plen = buf:byte(3 + ulen)
  if plen == 0 then
    return { status = "refused", consumed = 0, reason = "empty password" }
  end
  if #buf < 3 + ulen + plen then
    return { status = "more", consumed = 0 }
  end
  return { status = "done", consumed = 3 + ulen + plen, username = buf:sub(3, 2 + ulen),
    password = buf:sub(4 + ulen, 3 + ulen + plen) }
end

--- The reply to a username and password: success, or failure, after which
--- the connection closes.
function relay_wire.socks_auth_reply(ok: boolean): string
  return ok and "\1\0" or "\1\1"
end

--- The code of each [`relay_wire.SocksReply`].
local SOCKS_CODES <const>: {relay_wire.SocksReply: integer} = {
  succeeded = 0,
  failure = 1,
  not_allowed = 2,
  network_unreachable = 3,
  host_unreachable = 4,
  refused = 5,
  ttl_expired = 6,
  command_not_supported = 7,
  address_type_not_supported = 8,
}

local function socks_refused(reply: relay_wire.SocksReply, why: string): relay_wire.SocksRequest
  return { status = "refused", consumed = 0, reply = reply, reason = why }
end

--- Reads the SOCKS5 request at the start of `buf`: CONNECT only (BIND and
--- UDP ASSOCIATE are refused with reply `command_not_supported`), to a
--- domain name (the rules of the module's header), an IPv4 or an IPv6
--- address, and a port from 1 to 65535.
function relay_wire.socks_request(buf: string): relay_wire.SocksRequest
  local size = #buf
  if size < 1 then
    return { status = "more", consumed = 0 }
  end
  if buf:byte(1) ~= 5 then
    return socks_refused("failure", ("SOCKS version %d is not supported (only 5)"):format(buf:byte(1)))
  end
  if size < 2 then
    return { status = "more", consumed = 0 }
  end
  local command = buf:byte(2)
  if command ~= 1 then
    return socks_refused("command_not_supported", ("SOCKS command %d is not relayed (only CONNECT, 1)"):format(command))
  end
  if size < 3 then
    return { status = "more", consumed = 0 }
  end
  if buf:byte(3) ~= 0 then
    return socks_refused("failure", "the reserved byte of the request is not 0")
  end
  if size < 4 then
    return { status = "more", consumed = 0 }
  end
  local atyp = buf:byte(4)
  local host: string
  local kind: relay_wire.Kind
  local at: integer
  if atyp == 1 then
    if size < 8 then
      return { status = "more", consumed = 0 }
    end
    host, kind, at = ("%d.%d.%d.%d"):format(buf:byte(5), buf:byte(6), buf:byte(7), buf:byte(8)), "ipv4", 9
  elseif atyp == 4 then
    if size < 20 then
      return { status = "more", consumed = 0 }
    end
    local g: {string} = {}
    for i = 0, 7 do
      g[#g + 1] = ("%x"):format(buf:byte(5 + 2 * i) * 256 + buf:byte(6 + 2 * i))
    end
    local text, why = ipv6(table.concat(g, ":"))
    if text == nil then
      return socks_refused("failure", why)
    end
    host, kind, at = text, "ipv6", 21
  elseif atyp == 3 then
    if size < 5 then
      return { status = "more", consumed = 0 }
    end
    local length = buf:byte(5)
    if length == 0 then
      return socks_refused("failure", "empty domain name")
    end
    if size < 5 + length then
      return { status = "more", consumed = 0 }
    end
    local name, why = dns_name(buf:sub(6, 5 + length))
    if name == nil then
      return socks_refused("failure", why)
    end
    host, kind, at = name, "name", 6 + length
  else
    return socks_refused("address_type_not_supported", ("SOCKS address type %d is not supported"):format(atyp))
  end
  if size < at + 1 then
    return { status = "more", consumed = 0 }
  end
  local port = buf:byte(at) * 256 + buf:byte(at + 1)
  if port == 0 then
    return socks_refused("failure", "port 0")
  end
  return { status = "done", consumed = at + 1, host = host, kind = kind, port = port }
end

--- The reply to a request: `which`, with the bound address 0.0.0.0:0, as
--- the relay never gives the program one. Raises on a reply it does not
--- know.
function relay_wire.socks_reply(which: relay_wire.SocksReply): string
  local code = SOCKS_CODES[which]
  if code == nil then
    error("socks_reply: unknown reply " .. tostring(which), 2)
  end
  return "\5" .. string.char(code) .. "\0\1\0\0\0\0\0\0"
end

local function u16(text: string, at: integer): integer
  return text:byte(at) * 256 + text:byte(at + 1)
end

--- The server name in the body of a ClientHello message (what follows its
--- four-byte header): a name, or "" for none, and why not.
local function hello_name(body: string): string | nil, string
  local size = #body
  if size < 35 then
    return nil, "ClientHello shorter than its fixed fields"
  end
  local at = 35
  local session = body:byte(at)
  if session > 32 or at + session > size then
    return nil, "ClientHello session id past its end"
  end
  at = at + 1 + session
  if at + 1 > size then
    return nil, "ClientHello cipher suites past its end"
  end
  local suites = u16(body, at)
  if suites < 2 or suites % 2 == 1 or at + 1 + suites > size then
    return nil, "ClientHello cipher suites past its end or odd"
  end
  at = at + 2 + suites
  if at > size then
    return nil, "ClientHello compression methods past its end"
  end
  local methods = body:byte(at)
  if methods < 1 or at + methods > size then
    return nil, "ClientHello compression methods past its end"
  end
  at = at + 1 + methods
  if at == size + 1 then
    return ""
  end
  if at + 1 > size then
    return nil, "ClientHello extensions length cut short"
  end
  if u16(body, at) ~= size - at - 1 then
    return nil, "ClientHello extensions length does not reach the end of the hello"
  end
  at = at + 2
  local seen: {integer: boolean} = {}
  local found = ""
  while at <= size do
    if at + 3 > size then
      return nil, "ClientHello extension header past its end"
    end
    local kind = u16(body, at)
    local length = u16(body, at + 2)
    if at + 3 + length > size then
      return nil, "ClientHello extension past its end"
    end
    if seen[kind] then
      return nil, "ClientHello repeats an extension"
    end
    seen[kind] = true
    if kind == 0 then
      local list = body:sub(at + 4, at + 3 + length)
      if #list < 2 or u16(list, 1) ~= #list - 2 or #list == 2 then
        return nil, "server_name extension whose list length does not match"
      end
      local entry = 3
      while entry <= #list do
        if entry + 2 > #list then
          return nil, "server_name entry past its end"
        end
        local entry_length = u16(list, entry + 1)
        if entry + 2 + entry_length > #list then
          return nil, "server_name entry past its end"
        end
        if list:byte(entry) ~= 0 then
          return nil, "server_name entry of a type that is not host_name"
        end
        if found ~= "" then
          return nil, "server_name names two hosts"
        end
        local name, why = dns_name(list:sub(entry + 3, entry + 2 + entry_length))
        if name == nil then
          return nil, "server_name is not a host name: " .. why
        end
        found = name
        entry = entry + 3 + entry_length
      end
    end
    at = at + 4 + length
  end
  return found
end

local function malformed(why: string): relay_wire.Hello
  return { status = "malformed", consumed = 0, reason = why }
end

--- Reads the TLS ClientHello at the start of `buf`, which may arrive in
--- pieces and span handshake records (up to 64 of them, 16384 bytes of
--- hello), and answers the server name it carries, lower-cased and by the
--- rules of the module's header. The hello is judged only whole; `consumed`
--- ends with the record its last byte is in.
function relay_wire.client_hello(buf: string): relay_wire.Hello
  local size = #buf
  local pos = 1
  local records = 0
  local parts: {string} = {}
  local gathered = 0
  while true do
    if size < pos then
      return { status = "more", consumed = 0 }
    end
    if buf:byte(pos) ~= 22 then
      if records == 0 then
        return { status = "not_tls", consumed = 0,
          reason = ("first byte 0x%02x is not a TLS handshake record"):format(buf:byte(pos)) }
      end
      return malformed("a ClientHello continued by a record that is not a handshake record")
    end
    if size < pos + 1 then
      return { status = "more", consumed = 0 }
    end
    if buf:byte(pos + 1) ~= 3 then
      if records == 0 then
        return { status = "not_tls", consumed = 0, reason = "handshake record of a version that is not SSL 3 or TLS" }
      end
      return malformed("a handshake record of another version")
    end
    if size < pos + 2 then
      return { status = "more", consumed = 0 }
    end
    if buf:byte(pos + 2) > 4 then
      if records == 0 then
        return { status = "not_tls", consumed = 0, reason = "handshake record of a version past TLS 1.3" }
      end
      return malformed("a handshake record of another version")
    end
    if size < pos + 4 then
      return { status = "more", consumed = 0 }
    end
    local length = u16(buf, pos + 3)
    if length == 0 or length > 16384 then
      return malformed("a handshake record of length " .. length)
    end
    if size < pos + 4 + length then
      return { status = "more", consumed = 0 }
    end
    records = records + 1
    if records > MAX_RECORDS then
      return malformed(("a ClientHello in more than %s"):format(plural.count(MAX_RECORDS, "record")))
    end
    parts[#parts + 1] = buf:sub(pos + 5, pos + 4 + length)
    gathered = gathered + length
    pos = pos + 5 + length
    if gathered >= 4 then
      local message = table.concat(parts)
      parts = { message }
      if message:byte(1) ~= 1 then
        return malformed(("handshake message type %d is not a ClientHello"):format(message:byte(1)))
      end
      local total = message:byte(2) * 65536 + message:byte(3) * 256 + message:byte(4)
      if total > MAX_HELLO then
        return malformed(("a ClientHello of %s (at most %d)"):format(plural.count(total, "byte"), MAX_HELLO))
      end
      if gathered >= 4 + total then
        local name, why = hello_name(message:sub(5, 4 + total))
        if name == nil then
          return malformed(why)
        end
        if name == "" then
          return { status = "no_sni", consumed = pos - 1 }
        end
        return { status = "name", consumed = pos - 1, name = name }
      end
    end
  end
end

return relay_wire

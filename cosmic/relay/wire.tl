--- What the sandbox relay reads from the program it confines, and what it
--- answers: an HTTP CONNECT request head, a SOCKS5 greeting, sub-negotiation
--- and request, and the server name in a TLS ClientHello. The program is
--- untrusted, so each reader is a pure function of the bytes it is given: it
--- never raises, reads nothing past a length field it has checked, and refuses
--- by naming why. It opens no socket and resolves nothing.
---
--- A reader is an object fed the bytes as they arrive (`reader:feed(chunk)`).
--- It answers `more` until the bytes decide it, then `done` with `consumed`,
--- the count of bytes of everything fed so far that the request took (what
--- follows is the tunnel's, not the request's), or a refusal. The answer is
--- final: a later feed answers it again. A prefix is refused only when every
--- longer input is refused for the same reason, and an input answers the same
--- wherever its feeds split (cosmic/relay/wire_fuzz_test.tl). Total work is
--- linear in the bytes fed: the HTTP and TLS readers keep an offset and
--- the unfinished line or record, never reading a byte twice; a SOCKS message
--- is at most 513 bytes, so its reader re-reads what it holds, which is
--- bounded by that and not by what the program sends.
---
--- A host the readers answer is one of three kinds: a DNS name (labels of
--- letters, digits and inner hyphens, 63 bytes at most, 253 in all,
--- lower-cased, a trailing dot removed, and no final label that inet_aton
--- would read as a number), a dotted IPv4 address (decimal octets, no leading
--- zeros), or an IPv6 address in RFC 5952's form without brackets. The
--- readers only parse and canonicalise: whether an address may be connected
--- to is the address classifier's (cosmic.relay.address), and the relay
--- passes it every address host, mapped (`::ffff:`), NAT64, `0.0.0.0` and
--- `::` forms included. Nothing is resolved here.
---
--- The name rules refuse what some programs write. An underscore in a label
--- (which some internal DNS names hold) is refused, as are a final label of
--- digits and an IP literal in a TLS server_name (RFC 6066 forbids one, and a
--- client that connects to an address sends none). A grant names such a host
--- by its address instead.
---
--- A TLS reader judges only the first ClientHello of a connection. A second
--- one, after a HelloRetryRequest or a renegotiation, is outside what it
--- sees; the relay's tunnel carries it unread. A hello that carries an
--- Encrypted Client Hello or an encrypted-SNI extension names only a public
--- name in its server_name, so it answers `encrypted_sni` and no name. Clients
--- that send ECH as GREASE (Chrome and other BoringSSL-based clients do, to a
--- server that offers none) are indistinguishable from real ones, so the
--- relay's policy for that status decides whether they connect.

local String = require("cosmic.string")
local Grant = require("cosmic.relay.grant")

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
    --- How far the bytes have decided it.
    status: Status
    --- Bytes of everything fed that the head took, through its empty line,
    --- when `done`.
    consumed: integer
    --- When `refused`, why, worded to be shown to the program.
    reason: string
    --- When `refused`, the status line's code to answer with.
    http_status: integer
    --- When `done`, the host, in the form the module's header describes.
    host: string
    --- When `done`, what the host is.
    kind: Kind
    --- When `done`, the port.
    port: integer
    --- When `done`, the value of the `Proxy-Authorization` header, or nil
    --- when there is none. No other header is kept.
    authorization: string
  end

  --- Reads a CONNECT head from the bytes fed to it.
  interface ConnectReader
    --- Feeds the next bytes and answers what all fed so far say.
    feed: function(ConnectReader, chunk: string): Connect
  end

  --- The SOCKS5 method selection, answered with [`socks_method_reply`].
  record SocksGreeting
    --- How far the bytes have decided it.
    status: Status
    --- Bytes of the greeting, when `done`.
    consumed: integer
    --- When `refused`, why.
    reason: string
    --- When `done`, the method to select: 0 (no authentication) or 2
    --- (username and password). When `refused` because none offered is
    --- acceptable, 255, which [`socks_method_reply`] sends; when refused for
    --- another version, nil, and the caller closes without replying.
    method: integer
  end

  --- Reads a SOCKS5 greeting from the bytes fed to it.
  interface SocksGreetingReader
    --- Feeds the next bytes and answers what all fed so far say.
    feed: function(SocksGreetingReader, chunk: string): SocksGreeting
  end

  --- A SOCKS5 username and password (RFC 1929), answered with
  --- [`socks_auth_reply`].
  record SocksAuth
    --- How far the bytes have decided it.
    status: Status
    --- Bytes of everything fed that the message took, when `done`.
    consumed: integer
    --- When `refused`, why.
    reason: string
    --- The username, when `done`.
    username: string
    --- The password, when `done`.
    password: string
  end

  --- Reads a username and password from the bytes fed to it.
  interface SocksAuthReader
    --- Feeds the next bytes and answers what all fed so far say.
    feed: function(SocksAuthReader, chunk: string): SocksAuth
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
    --- How far the bytes have decided it.
    status: Status
    --- Bytes of everything fed that the message took, when `done`.
    consumed: integer
    --- When `refused`, why, and the reply to answer with.
    reason: string
    --- The reply to answer with.
    reply: SocksReply
    --- When `done`, the host.
    host: string
    --- When `done`, what the host is.
    kind: Kind
    --- When `done`, the port.
    port: integer
  end

  --- Reads a SOCKS5 request from the bytes fed to it.
  interface SocksRequestReader
    --- Feeds the next bytes and answers what all fed so far say.
    feed: function(SocksRequestReader, chunk: string): SocksRequest
  end

  --- The SOCKS5 server's choice of a method, the answer to a client's
  --- greeting.
  record SocksMethodAnswer
    --- How far the bytes have decided it.
    status: Status
    --- Bytes of the answer, when `done`.
    consumed: integer
    --- When `refused`, why.
    reason: string
    --- When `done`, the method chosen: 0, or 2 when the reader was made for
    --- a password, the one [`socks_client_greeting`] offers. When `refused`
    --- because the server accepts none of those offered, 255; nil for a
    --- refusal of another kind.
    method: integer
  end

  --- Reads a SOCKS5 server's method choice from the bytes fed to it.
  interface SocksMethodReader
    --- Feeds the next bytes and answers what all fed so far say.
    feed: function(SocksMethodReader, chunk: string): SocksMethodAnswer
  end

  --- The SOCKS5 server's verdict on a username and password (RFC 1929),
  --- the answer to [`socks_client_auth`].
  record SocksAuthAnswer
    --- How far the bytes have decided it.
    status: Status
    --- Bytes of the answer, when `done`.
    consumed: integer
    --- When `refused`, why.
    reason: string
    --- When `done`, whether the server accepted the credentials; the
    --- connection is closed by the server where it did not.
    accepted: boolean
  end

  --- Reads a SOCKS5 server's verdict on a username and password from the
  --- bytes fed to it.
  interface SocksAuthStatusReader
    --- Feeds the next bytes and answers what all fed so far say.
    feed: function(SocksAuthStatusReader, chunk: string): SocksAuthAnswer
  end

  --- A SOCKS5 server's answer to a CONNECT request.
  record SocksAnswer
    --- How far the bytes have decided it.
    status: Status
    --- Bytes of the answer, when `done`: what follows is the tunnel's.
    consumed: integer
    --- When `refused`, why.
    reason: string
    --- When `done`, the reply code: 0 for success, any other a refusal,
    --- whether or not [`SocksReply`] names it.
    code: integer
    --- When `done`, the [`SocksReply`] that `code` is, or nil for a code
    --- the protocol does not define.
    reply: SocksReply
  end

  --- Reads a SOCKS5 server's answer to a request from the bytes fed to it.
  interface SocksAnswerReader
    --- Feeds the next bytes and answers what all fed so far say.
    feed: function(SocksAnswerReader, chunk: string): SocksAnswer
  end

  --- What a ClientHello says of its server name.
  enum SniStatus
    "more"
    "name"
    "no_sni"
    "encrypted_sni"
    "not_tls"
    "malformed"
  end

  --- The server name of a TLS ClientHello.
  record Hello
    --- `name`: the hello names a server, in `name`. `no_sni`: a well-formed
    --- hello with no server_name extension. `encrypted_sni`: it carries an
    --- Encrypted Client Hello (extension 0xfe0d) or an encrypted-SNI draft
    --- (0xffce, 0xff02, 0xff03), so any server_name it holds is only the
    --- public name and is not given. `not_tls`: the bytes are not a TLS
    --- handshake at all, so the relay's policy for other protocols applies.
    --- `malformed`: a TLS record or hello that breaks its own lengths, bytes
    --- after the hello in its last record, or a name that breaks the rules
    --- above.
    status: SniStatus
    --- Bytes of everything fed that the records the hello ends in took,
    --- when `name`, `no_sni` or `encrypted_sni`.
    consumed: integer
    --- When `name`, the server name.
    name: string
    --- When `encrypted_sni`, `not_tls` or `malformed`, why.
    reason: string
  end

  --- Reads a ClientHello from the bytes fed to it.
  interface HelloReader
    --- Feeds the next bytes and answers what all fed so far say.
    feed: function(HelloReader, chunk: string): Hello
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
  local bytes = Grant.address(text)
  return bytes ~= nil and #bytes == 4 and bytes or nil
end

local function ipv4(text: string): boolean
  return octets(text) ~= nil
end

--- The sixteen bytes of `text`, an IPv6 address without brackets or a zone,
--- or nil and why.
local function ipv6_bytes(text: string): {integer} | nil, string
  local bytes = text:find(":", 1, true) and Grant.address(text) or nil
  if bytes == nil or #bytes ~= 16 then
    if text:find("[^%x:%.]") or not text:find(":", 1, true) then
      return nil, "not an IPv6 address (a zone, or a character an address does not hold)"
    end
    return nil, "not an IPv6 address"
  end
  return bytes, ""
end

--- `text`, an IPv6 address without brackets or a zone, in RFC 5952's
--- form, or nil and why.
local function ipv6(text: string): string | nil, string
  local bytes, bad = ipv6_bytes(text)
  if bytes == nil then
    return nil, bad
  end
  return Grant.ipv6_text(bytes), ""
end

local dns_name = Grant.name

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

local port_of = Grant.port

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

--- A header name's bytes (RFC 9110's token).
local TOKEN <const> = "^[%w!#$%%&'*+%-%.%^_`|~]+$"

--- `value` without the blanks at its ends, in two passes that each cost its
--- length (a pattern that anchors both ends backtracks quadratically).
local function trimmed(value: string): string
  local first = value:find("[^ \t]")
  if first == nil then
    return ""
  end
  local back = value:reverse():find("[^ \t]")
  return value:sub(first, #value - back + 1)
end

--- Reads the CONNECT request head from the bytes fed to it.
---
--- It is exactly `CONNECT host:port HTTP/1.1` (or `HTTP/1.0`) with CRLF
--- line endings, then header lines up to an empty line. A request line of
--- another method is refused as plain HTTP, which is not relayed. At most
--- 8192 bytes to a line, 16384 to the head and 100 headers; a bare LF or CR,
--- NUL or other control byte, and an obsolete line fold are refused.
--- `Proxy-Authorization` is kept, and no other header is read.
function relay_wire.connect_reader(): relay_wire.ConnectReader
  local final: relay_wire.Connect | nil = nil
  -- Bytes fed before the chunk in hand, and the position of the first
  -- byte of the line being read.
  local seen = 0
  local line_start = 1
  local pieces: {string} = {}
  local after_cr = false
  local first = true
  local count = 0
  local authorization: string
  local host: string
  local kind: relay_wire.Kind
  local port: integer

  local function finish(answer: relay_wire.Connect): relay_wire.Connect
    final = answer
    pieces = {}
    return answer
  end

  local function head_refusal(): relay_wire.Connect
    return finish(refused(("request head longer than %s"):format(String.counted(MAX_HEAD, "byte")), 431))
  end

  local function line_refusal(): relay_wire.Connect
    return finish(refused(("%s longer than %s"):format(first and "request line" or "header line",
      String.counted(MAX_LINE, "byte")), first and 414 or 431))
  end

  --- What a whole line, ending at position `at`, decides: an answer, or
  --- nil to go on.
  local function line(content: string, at: integer): relay_wire.Connect | nil
    if first then
      first = false
      local method = content:match("^[^ \t]*")
      if method ~= "CONNECT" then
        return finish(refused("plain HTTP is not relayed: only CONNECT host:port is accepted", 405))
      end
      local target, version = content:match("^CONNECT ([^ ]*) ([^ ]*)$")
      if target == nil then
        return finish(refused("malformed request line (expected CONNECT host:port HTTP/1.1)", 400))
      end
      if version ~= "HTTP/1.1" and version ~= "HTTP/1.0" then
        return finish(refused("unsupported HTTP version " .. version .. " (HTTP/1.1 or HTTP/1.0)", 505))
      end
      local found, trouble = authority(target)
      if found == nil then
        return finish(refused(trouble, 400))
      end
      host, kind, port = found.host, found.kind, found.port
      return nil
    end
    if content == "" then
      return finish({ status = "done", consumed = at, host = host, kind = kind, port = port,
        authorization = authorization })
    end
    if content:find("^[ \t]") then
      return finish(refused("an obsolete header line fold (a line starting with whitespace)", 400))
    end
    count = count + 1
    if count > MAX_HEADERS then
      return finish(refused(("more than %s"):format(String.counted(MAX_HEADERS, "header")), 431))
    end
    local name, value = content:match("^([^:]*):(.*)$")
    if name == nil then
      return finish(refused("a header line without a colon", 400))
    end
    if not name:find(TOKEN) then
      return finish(refused("a header name that is not a token", 400))
    end
    if lower(name) == "proxy-authorization" then
      if authorization ~= nil then
        return finish(refused("a repeated Proxy-Authorization header", 400))
      end
      authorization = trimmed(value)
    end
    return nil
  end

  return {
    feed = function(_: relay_wire.ConnectReader, chunk: string): relay_wire.Connect
      if final ~= nil then
        return final
      end
      local size = #chunk
      local i = 1
      while i <= size do
        -- Each byte is judged by its position alone, so that where the
        -- feeds split decides nothing: past the head's cap, then a line's
        -- end after a CR, then the byte itself.
        if seen + i > MAX_HEAD then
          return head_refusal()
        end
        if after_cr then
          if chunk:byte(i) ~= 10 then
            return finish(refused("a carriage return outside a CRLF line ending", 400))
          end
          after_cr = false
          local content = table.concat(pieces)
          pieces = {}
          line_start = seen + i + 1
          local answer = line(content, seen + i)
          if answer ~= nil then
            return answer
          end
          i = i + 1
        else
          local special = chunk:find(SPECIAL, i)
          local last = (special or size + 1) - 1
          if last >= i then
            local excess_at = line_start + MAX_LINE
            local line_hit = seen + last >= excess_at
            local head_hit = seen + last > MAX_HEAD
            if head_hit and (not line_hit or MAX_HEAD + 1 <= excess_at) then
              return head_refusal()
            end
            if line_hit then
              return line_refusal()
            end
            pieces[#pieces + 1] = chunk:sub(i, last)
            i = last + 1
          end
          if special ~= nil then
            -- A control byte is a byte of the head too: past the cap it is the
            -- cap's refusal whatever feed it arrives in, as the top of the
            -- loop gives it when it starts a feed.
            if seen + special > MAX_HEAD then
              return head_refusal()
            end
            local byte = chunk:byte(special)
            if byte == 13 then
              after_cr = true
            elseif byte == 10 then
              return finish(refused("a bare LF line ending (lines end in CRLF)", 400))
            else
              return finish(refused(("control byte 0x%02x in the request head"):format(byte), 400))
            end
            i = special + 1
          end
        end
      end
      seen = seen + size
      return { status = "more", consumed = 0 }
    end,
  }
end

--- The reply to a CONNECT that was granted and connected.
function relay_wire.connect_ok(): string
  return "HTTP/1.1 200 Connection established\r\n\r\n"
end

--- The reply to a CONNECT that was refused or failed: a status from 400
--- through 599, and `why` as the reason phrase, which the program's error
--- shows (`403 not granted: --connect api.github.com:443`). The phrase is
--- cut to visible ASCII, `?` for any other byte, and to 200 bytes. A 405
--- names the method allowed, and a 407 asks for Basic credentials
--- (`Proxy-Authenticate: Basic realm="cosmic sandbox"`). Raises on a status
--- outside 400 through 599.
function relay_wire.connect_refusal(status: integer, why: string): string
  if math.type(status) ~= "integer" or status < 400 or status > 599 then
    error("connect_refusal: status must be an integer from 400 to 599", 2)
  end
  local phrase = why:gsub("[^\32-\126]", "?"):sub(1, MAX_PHRASE):match("^ *(.-) *$")
  if phrase == "" then
    phrase = "Refused"
  end
  local extra = ""
  if status == 405 then
    extra = "Allow: CONNECT\r\n"
  elseif status == 407 then
    extra = "Proxy-Authenticate: Basic realm=\"cosmic sandbox\"\r\n"
  end
  return ("HTTP/1.1 %d %s\r\n%sConnection: close\r\nContent-Length: 0\r\n\r\n"):format(status, phrase, extra)
end

--- The SOCKS5 greeting at the start of `buf`, whole.
local function read_greeting(buf: string, password: boolean): relay_wire.SocksGreeting
  if #buf < 1 then
    return { status = "more", consumed = 0 }
  end
  if buf:byte(1) ~= 5 then
    return { status = "refused", consumed = 0,
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

--- The RFC 1929 username and password at the start of `buf`, whole: both
--- from 1 to 255 bytes.
local function read_auth(buf: string): relay_wire.SocksAuth
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

--- The SOCKS5 request at the start of `buf`, whole.
local function read_request(buf: string): relay_wire.SocksRequest
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

--- A reader of a message of at most a few hundred bytes: it holds what it
--- is fed and reads it again, which costs at most that many bytes a feed
--- and nothing once it has answered.
local function small_reader<T>(read: function(string): T, decided: function(T): boolean): function(string): T
  local held = ""
  local final: T | nil = nil
  return function(chunk: string): T
    if final ~= nil then
      return final
    end
    held = held .. chunk
    local answer = read(held)
    if decided(answer) then
      final = answer
      held = ""
    end
    return answer
  end
end

--- Reads the SOCKS5 greeting from the bytes fed to it and picks the method:
--- no authentication (0x00), or with `password` set, only username and
--- password (0x02), which carries the sandbox's token. A greeting that
--- offers neither is refused with method 255, and one of another version
--- with no method, for the caller to close.
function relay_wire.socks_greeting_reader(password?: boolean): relay_wire.SocksGreetingReader
  local want = password == true
  local step = small_reader(function(held: string): relay_wire.SocksGreeting
    return read_greeting(held, want)
  end, function(answer: relay_wire.SocksGreeting): boolean
    return answer.status ~= "more"
  end)
  return { feed = function(_: relay_wire.SocksGreetingReader, chunk: string): relay_wire.SocksGreeting
    return step(chunk)
  end }
end

--- Reads the RFC 1929 username and password from the bytes fed to it: both
--- from 1 to 255 bytes.
function relay_wire.socks_auth_reader(): relay_wire.SocksAuthReader
  local step = small_reader(read_auth, function(answer: relay_wire.SocksAuth): boolean
    return answer.status ~= "more"
  end)
  return { feed = function(_: relay_wire.SocksAuthReader, chunk: string): relay_wire.SocksAuth
    return step(chunk)
  end }
end

--- Reads the SOCKS5 request from the bytes fed to it: CONNECT only (BIND and
--- UDP ASSOCIATE are refused with reply `command_not_supported`), to a
--- domain name (the rules of the module's header), an IPv4 or an IPv6
--- address, and a port from 1 to 65535.
function relay_wire.socks_request_reader(): relay_wire.SocksRequestReader
  local step = small_reader(read_request, function(answer: relay_wire.SocksRequest): boolean
    return answer.status ~= "more"
  end)
  return { feed = function(_: relay_wire.SocksRequestReader, chunk: string): relay_wire.SocksRequest
    return step(chunk)
  end }
end

--- The greeting a SOCKS5 client opens with: version 5, offering no
--- authentication (method 0) alone, or with `with_password` username and
--- password (method 2) alone, which is what a relay with a token takes.
function relay_wire.socks_client_greeting(with_password?: boolean): string
  return with_password == true and "\5\1\2" or "\5\1\0"
end

--- The username and password message (RFC 1929) a client sends once the
--- server has chosen method 2. Nil and why for a username or a password
--- that is empty or over 255 bytes.
--- @param user the username
--- @param password the password
--- @return the message, or nil
--- @return why, when there is none
function relay_wire.socks_client_auth(user: string, password: string): string | nil, string
  if user == "" then return nil, "the username is empty" end
  if password == "" then return nil, "the password is empty" end
  if #user > 255 then return nil, "the username is longer than 255 bytes" end
  if #password > 255 then return nil, "the password is longer than 255 bytes" end
  return "\1" .. string.char(#user) .. user .. string.char(#password) .. password
end

--- The CONNECT request a SOCKS5 client sends for `host` and `port`: an
--- address type 1 for a dotted IPv4 literal, 4 for an IPv6 one (without
--- brackets), and otherwise 3, with `host` as the domain name for the
--- relay to resolve and judge, which is sent as it is (the relay applies
--- the name rules). Nil and why for an empty host, a name over 255 bytes or
--- a port outside 1 to 65535.
--- @param host the host: a name or an address literal
--- @param port the port
--- @return the request, or nil
--- @return why, when there is none
function relay_wire.socks_client_request(host: string, port: integer): string | nil, string
  if math.type(port) ~= "integer" or port < 1 or port > 65535 then
    return nil, "the port is not a number from 1 to 65535"
  end
  local tail = string.pack(">I2", port)
  local four = octets(host)
  if four ~= nil then
    return "\5\1\0\1" .. string.char(four[1], four[2], four[3], four[4]) .. tail
  end
  local six, _ = ipv6_bytes(host)
  if six ~= nil then
    return "\5\1\0\4" .. string.char(table.unpack(six)) .. tail
  end
  if host == "" then
    return nil, "the host is empty"
  end
  if #host > 255 then
    return nil, "the host name is longer than 255 bytes"
  end
  return "\5\1\0\3" .. string.char(#host) .. host .. tail
end

--- The method choice at the start of `buf`, whole.
local function read_method_answer(buf: string, password: boolean): relay_wire.SocksMethodAnswer
  if #buf < 1 then
    return { status = "more", consumed = 0 }
  end
  if buf:byte(1) ~= 5 then
    return { status = "refused", consumed = 0,
      reason = ("SOCKS version %d in the answer, not 5"):format(buf:byte(1)) }
  end
  if #buf < 2 then
    return { status = "more", consumed = 0 }
  end
  local method = buf:byte(2)
  local offered = password and 2 or 0
  if method == offered then
    return { status = "done", consumed = 2, method = method }
  elseif method == 255 then
    return { status = "refused", consumed = 0, method = 255, reason = "no authentication method offered is accepted" }
  end
  return { status = "refused", consumed = 0,
    reason = ("the method %d chosen is not one offered (only %d)"):format(method, offered) }
end

--- The verdict on a username and password at the start of `buf`, whole.
local function read_auth_answer(buf: string): relay_wire.SocksAuthAnswer
  if #buf < 1 then
    return { status = "more", consumed = 0 }
  end
  if buf:byte(1) ~= 1 then
    return { status = "refused", consumed = 0,
      reason = ("username/password version %d in the answer, not 1"):format(buf:byte(1)) }
  end
  if #buf < 2 then
    return { status = "more", consumed = 0 }
  end
  return { status = "done", consumed = 2, accepted = buf:byte(2) == 0 }
end

--- The reply codes by number, from [`SOCKS_CODES`].
local SOCKS_REPLIES <const>: {integer: relay_wire.SocksReply} = {}
for name, code in pairs(SOCKS_CODES) do
  SOCKS_REPLIES[code] = name
end

--- The server's answer to a request at the start of `buf`, whole: the reply
--- code and the bound address it carries, which is read to find where the
--- tunnel begins and kept for nothing.
local function read_answer(buf: string): relay_wire.SocksAnswer
  local size = #buf
  if size < 1 then
    return { status = "more", consumed = 0 }
  end
  if buf:byte(1) ~= 5 then
    return { status = "refused", consumed = 0,
      reason = ("SOCKS version %d in the reply, not 5"):format(buf:byte(1)) }
  end
  if size < 3 then
    return { status = "more", consumed = 0 }
  end
  if buf:byte(3) ~= 0 then
    return { status = "refused", consumed = 0, reason = "the reserved byte of the reply is not 0" }
  end
  if size < 4 then
    return { status = "more", consumed = 0 }
  end
  local atyp = buf:byte(4)
  local width: integer
  if atyp == 1 then
    width = 4
  elseif atyp == 4 then
    width = 16
  elseif atyp == 3 then
    if size < 5 then
      return { status = "more", consumed = 0 }
    end
    width = 1 + buf:byte(5)
  else
    return { status = "refused", consumed = 0, reason = ("SOCKS address type %d in the reply is not supported"):format(atyp) }
  end
  local total = 4 + width + 2
  if size < total then
    return { status = "more", consumed = 0 }
  end
  local code = buf:byte(2)
  return { status = "done", consumed = total, code = code, reply = SOCKS_REPLIES[code] }
end

--- Reads the SOCKS5 server's choice of a method from the bytes fed to it:
--- done for the method [`relay_wire.socks_client_greeting`] offers (0, or 2
--- with `password`), and refused for 255 (none accepted), another method or
--- another version.
function relay_wire.socks_method_reader(password?: boolean): relay_wire.SocksMethodReader
  local with = password == true
  local step = small_reader(function(held: string): relay_wire.SocksMethodAnswer
    return read_method_answer(held, with)
  end, function(answer: relay_wire.SocksMethodAnswer): boolean
    return answer.status ~= "more"
  end)
  return { feed = function(_: relay_wire.SocksMethodReader, chunk: string): relay_wire.SocksMethodAnswer
    return step(chunk)
  end }
end

--- Reads the SOCKS5 server's verdict on [`relay_wire.socks_client_auth`]'s
--- message from the bytes fed to it: two bytes, version 1 and a status,
--- where 0 is acceptance and any other value a refusal. Refused for another
--- version.
function relay_wire.socks_auth_status_reader(): relay_wire.SocksAuthStatusReader
  local step = small_reader(read_auth_answer, function(answer: relay_wire.SocksAuthAnswer): boolean
    return answer.status ~= "more"
  end)
  return { feed = function(_: relay_wire.SocksAuthStatusReader, chunk: string): relay_wire.SocksAuthAnswer
    return step(chunk)
  end }
end

--- Reads the SOCKS5 server's answer to a request from the bytes fed to it,
--- through its bound address (an IPv4 or IPv6 address or a domain name,
--- then a port), so that what is left of what was fed is the tunnel's. A
--- reply code that is no success is a `done` answer with its `code`: the
--- reader judges the message's shape, not the server's verdict. Refused for
--- another version, a nonzero reserved byte or an address type the
--- protocol does not define. The message is at most 262 bytes, so the
--- reader re-reads what it holds as the others do.
function relay_wire.socks_answer_reader(): relay_wire.SocksAnswerReader
  local step = small_reader(read_answer, function(answer: relay_wire.SocksAnswer): boolean
    return answer.status ~= "more"
  end)
  return { feed = function(_: relay_wire.SocksAnswerReader, chunk: string): relay_wire.SocksAnswer
    return step(chunk)
  end }
end

--- What a SOCKS5 reply code means, worded for a person: "connection not
--- allowed by ruleset" for 2, "connection refused" for 5 and so on, and
--- "unknown reply code N" for one the protocol does not define.
--- @param code the reply code
--- @return what it means
function relay_wire.socks_reply_meaning(code: integer): string
  local meanings: {integer: string} = {
    [0] = "succeeded",
    [1] = "general SOCKS server failure",
    [2] = "connection not allowed by ruleset",
    [3] = "network unreachable",
    [4] = "host unreachable",
    [5] = "connection refused",
    [6] = "TTL expired",
    [7] = "command not supported",
    [8] = "address type not supported",
  }
  return meanings[code] or ("unknown reply code %d"):format(code)
end

local function u16(text: string, at: integer): integer
  return text:byte(at) * 256 + text:byte(at + 1)
end

--- What a ClientHello says of its server: the name, or "" for none, and
--- whether an extension encrypts it.
local record ServerName
  name: string
  encrypted: boolean
end

--- The extensions that carry the server name encrypted: Encrypted Client
--- Hello and the encrypted-SNI drafts.
local ENCRYPTED <const>: {integer: boolean} = { [0xfe0d] = true, [0xffce] = true, [0xff02] = true, [0xff03] = true }

--- The server name in the body of a ClientHello message (what follows its
--- four-byte header), or nil and why not.
local function hello_name(body: string): ServerName | nil, string
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
    return { name = "", encrypted = false }
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
  local encrypted = false
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
    if ENCRYPTED[kind] then
      encrypted = true
    end
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
  return { name = found, encrypted = encrypted }
end

local function malformed(why: string): relay_wire.Hello
  return { status = "malformed", consumed = 0, reason = why }
end

--- What a TLS record header says: a refusal, or the record's payload length
--- (0 while the five bytes are not all there).
local record Header
  refusal: relay_wire.Hello
  length: integer
end

--- The bytes of a TLS record header a reader has, judged as far as they
--- go: a refusal, and the record's length once all five are there (0 until
--- then). A first record that is not a TLS handshake is `not_tls`; a later
--- one that is not is `malformed`.
local function record_header(data: string, pos: integer, first: boolean): Header
  local have = #data - pos + 1
  local function wrong(why: string): relay_wire.Hello
    if first then
      return { status = "not_tls", consumed = 0, reason = why }
    end
    return malformed("a ClientHello continued by " .. why)
  end
  -- A record that begins as a handshake is TLS whatever its legacy version
  -- says (RFC 8446 tells a receiver to ignore it), so one of a version this
  -- reader does not know is refused, never passed on unread.
  local function versioned(why: string): relay_wire.Hello
    if first then
      return malformed(why)
    end
    return wrong(why)
  end
  if have < 1 then
    return { length = 0 }
  end
  if data:byte(pos) ~= 22 then
    return { refusal = wrong(("a record whose first byte 0x%02x is not a TLS handshake record"):format(data:byte(pos))), length = 0 }
  end
  if have < 2 then
    return { length = 0 }
  end
  if data:byte(pos + 1) ~= 3 then
    return { refusal = versioned("a handshake record of a version that is not SSL 3 or TLS"), length = 0 }
  end
  if have < 3 then
    return { length = 0 }
  end
  if data:byte(pos + 2) > 4 then
    return { refusal = versioned("a handshake record of a version past TLS 1.3"), length = 0 }
  end
  if have < 5 then
    return { length = 0 }
  end
  local length = u16(data, pos + 3)
  if length == 0 or length > 16384 then
    return { refusal = malformed("a handshake record of length " .. length), length = 0 }
  end
  return { length = length }
end

--- Reads the TLS ClientHello from the bytes fed to it, which may arrive in
--- pieces and span handshake records (up to 64 of them, 16384 bytes of hello),
--- and answers the server name it carries, lower-cased and by the rules of
--- the module's header. The hello is judged only whole, and only the first;
--- `consumed` ends with the record its last byte is in, which must end with
--- it.
function relay_wire.hello_reader(): relay_wire.HelloReader
  local final: relay_wire.Hello | nil = nil
  -- The bytes of the record in progress (and any after it), and the bytes
  -- fed before them.
  local pending: {string} = {}
  local pending_len = 0
  local need = 5
  local base = 0
  local records = 0
  -- The handshake bytes gathered from complete records, by piece, and the
  -- size of the message once its four-byte header is in.
  local parts: {string} = {}
  local gathered = 0
  local total: integer | nil = nil

  local function finish(answer: relay_wire.Hello): relay_wire.Hello
    final = answer
    pending, parts = {}, {}
    return answer
  end

  --- Takes the whole record at `data`'s `pos`, of `length` payload bytes:
  --- an answer once the hello is complete or refused, else nil.
  local function take(data: string, pos: integer, length: integer): relay_wire.Hello | nil
    records = records + 1
    if records > MAX_RECORDS then
      return finish(malformed(("a ClientHello in more than %s"):format(String.counted(MAX_RECORDS, "record"))))
    end
    parts[#parts + 1] = data:sub(pos + 5, pos + 4 + length)
    gathered = gathered + length
    if total == nil then
      if gathered < 4 then
        return nil
      end
      local message = table.concat(parts)
      parts = { message }
      if message:byte(1) ~= 1 then
        return finish(malformed(("handshake message type %d is not a ClientHello"):format(message:byte(1))))
      end
      total = message:byte(2) * 65536 + message:byte(3) * 256 + message:byte(4)
      if total > MAX_HELLO then
        return finish(malformed(("a ClientHello of %s (at most %d)"):format(String.counted(total, "byte"), MAX_HELLO)))
      end
    end
    if gathered < 4 + total then
      return nil
    end
    if gathered > 4 + total then
      return finish(malformed("bytes after the ClientHello in its last record"))
    end
    local server, why = hello_name(table.concat(parts):sub(5))
    if server == nil then
      return finish(malformed(why))
    end
    local name, encrypted = server.name, server.encrypted
    local consumed = base + pos + 4 + length
    if encrypted then
      return finish({ status = "encrypted_sni", consumed = consumed,
        reason = "the hello carries an encrypted server name (Encrypted Client Hello or encrypted SNI), so its server_name is only a public name" })
    end
    if name == "" then
      return finish({ status = "no_sni", consumed = consumed })
    end
    return finish({ status = "name", consumed = consumed, name = name })
  end

  return {
    feed = function(_: relay_wire.HelloReader, chunk: string): relay_wire.Hello
      if final ~= nil then
        return final
      end
      pending[#pending + 1] = chunk
      pending_len = pending_len + #chunk
      if pending_len < need then
        if pending_len < 5 then
          local early = record_header(table.concat(pending), 1, records == 0).refusal
          if early ~= nil then
            return finish(early)
          end
        end
        return { status = "more", consumed = 0 }
      end
      local data = table.concat(pending)
      local size = #data
      local pos = 1
      while true do
        local header = record_header(data, pos, records == 0)
        if header.refusal ~= nil then
          return finish(header.refusal)
        end
        local length = header.length
        if length == 0 then
          need = 5
          break
        end
        if size - pos + 1 < 5 + length then
          need = 5 + length
          break
        end
        local answer = take(data, pos, length)
        if answer ~= nil then
          return answer
        end
        pos = pos + 5 + length
      end
      base = base + pos - 1
      local rest = pos == 1 and data or data:sub(pos)
      pending, pending_len = { rest }, #rest
      return { status = "more", consumed = 0 }
    end,
  }
end

return relay_wire

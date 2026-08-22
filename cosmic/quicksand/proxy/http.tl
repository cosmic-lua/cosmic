--- HTTP/1.1 wire helpers for the cosmic.quicksand.proxy egress proxy:
--- request-line / header / target parsing, bounded socket reads,
--- short-write-safe sends, request rewriting for upstream forwarding,
--- and the bidirectional CONNECT byte pump.
---
--- Parsing functions are pure; the I/O helpers operate on raw socket
--- fds via cosmo.unix and return cosmic's value,string error shape.
local unix = require("cosmo.unix")
local errno = require("cosmic.errno")

--- One parsed header: {original_name, lower_name, value}.
local type Header = {string}

--- Canned minimal responses. Content-Length: 0 + Connection: close so
--- clients never wait on a body.
local DENY < const > = "HTTP/1.1 403 Forbidden\r\n"
.. "Content-Length: 0\r\n"
.. "Connection: close\r\n\r\n"

local BAD_REQUEST < const > = "HTTP/1.1 400 Bad Request\r\n"
.. "Content-Length: 0\r\n"
.. "Connection: close\r\n\r\n"

local LENGTH_REQUIRED < const > = "HTTP/1.1 411 Length Required\r\n"
.. "Content-Length: 0\r\n"
.. "Connection: close\r\n\r\n"

local PAYLOAD_TOO_LARGE < const > = "HTTP/1.1 413 Payload Too Large\r\n"
.. "Content-Length: 0\r\n"
.. "Connection: close\r\n\r\n"

local UPSTREAM_FAIL < const > = "HTTP/1.1 502 Bad Gateway\r\n"
.. "Content-Length: 0\r\n"
.. "Connection: close\r\n\r\n"

--- Read from `fd` until "\r\n\r\n" or EOF. Returns (header_block,
--- leftover_after_block). Bounds the read to `max` bytes (default
--- 65536) to avoid memory blowups from junk input.
local function read_headers(fd: integer, max: integer): string | nil, string
  max = max or 65536
  local buf = ""
  while #buf < max do
    local chunk, err = unix.recv(fd, math.min(4096, max - #buf))
    if not chunk then return nil, tostring(err) end
    if chunk == "" then return nil, "eof" end
    buf = buf .. chunk
    local _, j = buf:find("\r\n\r\n", 1, true)
    if j then
      return buf:sub(1, j), buf:sub(j + 1)
    end
  end
  return nil, "header block exceeds " .. tostring(max) .. " bytes"
end

--- Send all of `data` on `fd`, resuming short writes via the send()
--- offset parameter (no tail-substring reallocation).
local function send_all(fd: integer, data: string): boolean, string
  local total = #data
  local off = 0
  while off < total do
    local n, err = unix.send(fd, data, 0, off)
    if not n then return false, tostring(err) end
    if n == 0 then return false, "short write" end
    off = off + (n)
  end
  return true
end

--- Read exactly `n` bytes from `fd`, given an optional already-
--- buffered prefix. Returns (body, leftover_beyond_n).
local function read_body(fd: integer, n: integer, prefix: string):
  string | nil, string
  local buf = prefix or ""
  while #buf < n do
    local chunk, err = unix.recv(fd, math.min(16384, n - #buf))
    if not chunk then return nil, tostring(err) end
    if chunk == "" then return nil, "eof in body" end
    buf = buf .. chunk
  end
  return buf:sub(1, n), buf:sub(n + 1)
end

--- A parsed request line, returned as one record rather than three
--- scalars: a return whose first slot may be nil needs the second
--- slot free for an error, leaving no room for a third parsed field.
local record RequestLine
  method: string
  target: string
  version: string
end

--- Parse an HTTP request line "METHOD TARGET HTTP/x.y\r\n", or nil
--- when it is not one.
local function parse_request_line(line: string): RequestLine | nil
  local m, t, v = line:match("^(%u+) (%S+) (HTTP/%d%.%d)\r\n")
  if not m then
    return nil
  end
  return {method = m, target = t, version = v}
end

--- A decimal digit run that no integer can hold: `tonumber` yields a
--- float and `math.tointeger` yields nil. Ports out of 1..65535 are
--- refused the same way, so callers never see a port they cannot dial.
local function port_of(digits: string): integer | nil
  local n = math.tointeger(tonumber(digits))
  if not n or n < 1 or n > 65535 then return nil end
  return n
end

--- Parse a CONNECT target "host:port". Returns (host, port) or nil.
local function parse_connect_target(t: string): string | nil, integer
  local h, p = t:match("^([^:]+):(%d+)$")
  if not h then return nil end
  local port = port_of(p)
  if not port then return nil end
  return h, port
end

--- A parsed absolute-form request target, with the scheme's default
--- port and "/" already filled in.
local record AbsoluteUri
  scheme: string
  host: string
  port: integer
  path: string
end

--- Parse an absolute URI "http://host[:port]/path" (proxies receive
--- absolute-form per RFC 7230 5.3.2), or nil when it is not one.
local function parse_absolute_uri(t: string): AbsoluteUri | nil
  local s, hp, path = t:match("^(https?)://([^/]+)(/.*)$")
  if not s then
    s, hp = t:match("^(https?)://([^/]+)$")
    path = "/"
  end
  if not s then return nil end
  local h, p = hp:match("^([^:]+):(%d+)$")
  if h then
    local port = port_of(p)
    if not port then return nil end
    return {scheme = s, host = h, port = port, path = path}
  end
  return {scheme = s, host = hp, port = s == "https" and 443 or 80, path = path}
end

--- Parse a header block (everything after the request line, up to the
--- blank \r\n) into a list of {orig_name, lower_name, value} triples.
local function parse_headers(block: string): {Header}
  local out: {Header} = {}
  local skip = true
  for line in block:gmatch("([^\r\n]+)\r\n") do
    if skip then
      skip = false
    else
      local n, v = line:match("^([^:]+):%s*(.*)$")
      if n then
        table.insert(out, {n, n:lower(), v})
      end
    end
  end
  return out
end

--- First header value for `lower_name` (case-insensitive), or nil.
local function header_get(headers: {Header}, lower_name: string): string | nil
  for _, h in ipairs(headers) do
    if h[2] == lower_name then return h[3] end
  end
  return nil
end

--- Content-Length from a parsed header list: 0 when absent, nil when
--- present but not a plain digit string (RFC 7230: 1*DIGIT) or too
--- large for an integer — callers treat nil as a malformed request.
--- tonumber() leniency here would accept hex, exponents, and
--- negatives, letting a client name an absurd or nonsensical body
--- size that read_body would then try to buffer.
local function content_length(headers: {Header}): integer | nil
  local v = header_get(headers, "content-length")
  if not v then return 0 end
  local digits = string.match(v, "^(%d+)%s*$")
  if not digits then return nil end
  local n = math.tointeger(tonumber(digits))
  if not n then return nil end
  return n
end

--- Hop-by-hop headers per RFC 7230 6.1, plus content-length (always
--- reissued to avoid duplicates) and host (rewritten to the upstream
--- target). transfer-encoding triggers a 411 before forwarding.
local HOP_BY_HOP: {string: boolean} = {
  ["connection"] = true,
  ["proxy-connection"] = true,
  ["keep-alive"] = true,
  ["te"] = true,
  ["trailer"] = true,
  ["transfer-encoding"] = true,
  ["upgrade"] = true,
  ["content-length"] = true,
  ["host"] = true,
}

--- Everything needed to rewrite a client request for the upstream:
--- request line pieces, parsed headers, optional body, the Host
--- header value, and an optional auth header to inject.
local record ForwardSpec
  method: string
  path: string
  headers: {Header}
  body: string
  host_hdr: string
  inject_name: string
  inject_value: string
end

--- Construct the forwarded HTTP request: method + origin-form target
--- + HTTP/1.1, Host rewritten to spec.host_hdr, hop-by-hop headers
--- stripped, our injected auth header replacing any client-supplied
--- one of the same name, and Connection: close.
local function rebuild_request(spec: ForwardSpec): string
  local injected_lower = spec.inject_name and spec.inject_name:lower() or nil
  local out: {string} = {
    string.format("%s %s HTTP/1.1\r\n", spec.method, spec.path),
  }
  table.insert(out, "Host: " .. spec.host_hdr .. "\r\n")
  for _, h in ipairs(spec.headers) do
    local oname, lname, value = h[1], h[2], h[3]
    if HOP_BY_HOP[lname] then
      -- strip
    elseif injected_lower and lname == injected_lower then
      -- replaced below
    else
      table.insert(out, oname .. ": " .. value .. "\r\n")
    end
  end
  if spec.inject_name then
    table.insert(out, spec.inject_name .. ": " .. spec.inject_value .. "\r\n")
  end
  table.insert(out, "Connection: close\r\n")
  if spec.body and #spec.body > 0 then
    table.insert(out, "Content-Length: " .. tostring(#spec.body) .. "\r\n")
  else
    table.insert(out, "Content-Length: 0\r\n")
  end
  table.insert(out, "\r\n")
  if spec.body then table.insert(out, spec.body) end
  return table.concat(out)
end

--- Bidirectional byte pump between two TCP fds. Returns when both
--- sides hit EOF or one side errors. Single-process: multiplexes with
--- unix.poll, and issues shutdown(SHUT_WR) toward the peer on each
--- half-close so it sees clean EOF.
local function pump(a: integer, b: integer)
  local fds: {integer: integer} = {}
  fds[a] = unix.POLLIN
  fds[b] = unix.POLLIN
  local open: {integer: boolean} = {}
  open[a] = true
  open[b] = true
  local hup_mask = (unix.POLLHUP)
  | (unix.POLLERR)
  | (unix.POLLNVAL)
  local function close_side(fd: integer, peer: integer)
    pcall(unix.shutdown, peer, unix.SHUT_WR)
    fds[fd] = nil
    open[fd] = false
  end
  while open[a] or open[b] do
    local ready, _perr, peno = unix.poll(fds)
    if not ready then
      -- A forwarded signal arriving mid-poll is not a real failure;
      -- only a non-EINTR error tears down the tunnel.
      if not errno.is_code(peno, "EINTR") then return end
    else
      for fd, ev in pairs(ready) do
        local peer = (fd == a) and b or a
        local evi = ev
        local readable = (evi & (unix.POLLIN)) ~= 0
        local hup = (evi & hup_mask) ~= 0
        if readable then
          local chunk = unix.recv(fd, 16384)
          if not chunk or chunk == "" then
            close_side(fd, peer)
          elseif not send_all(peer, chunk) then
            return
          end
        elseif hup then
          close_side(fd, peer)
        end
      end
    end
  end
end

local record HttpModule
  DENY: string
  BAD_REQUEST: string
  LENGTH_REQUIRED: string
  PAYLOAD_TOO_LARGE: string
  UPSTREAM_FAIL: string
  read_headers: function(fd: integer, max: integer): string | nil, string
  send_all: function(fd: integer, data: string): boolean, string
  read_body: function(fd: integer, n: integer, prefix: string): string | nil, string
  type RequestLine = RequestLine
  type AbsoluteUri = AbsoluteUri
  parse_request_line: function(line: string): RequestLine | nil
  parse_connect_target: function(t: string): string | nil, integer
  parse_absolute_uri: function(t: string): AbsoluteUri | nil
  parse_headers: function(block: string): {Header}
  header_get: function(headers: {Header}, lower_name: string): string | nil
  content_length: function(headers: {Header}): integer | nil
  rebuild_request: function(spec: ForwardSpec): string
  pump: function(a: integer, b: integer)
end

local M: HttpModule = {
  DENY = DENY,
  BAD_REQUEST = BAD_REQUEST,
  LENGTH_REQUIRED = LENGTH_REQUIRED,
  PAYLOAD_TOO_LARGE = PAYLOAD_TOO_LARGE,
  UPSTREAM_FAIL = UPSTREAM_FAIL,
  read_headers = read_headers,
  send_all = send_all,
  read_body = read_body,
  parse_request_line = parse_request_line,
  parse_connect_target = parse_connect_target,
  parse_absolute_uri = parse_absolute_uri,
  parse_headers = parse_headers,
  header_get = header_get,
  content_length = content_length,
  rebuild_request = rebuild_request,
  pump = pump,
}

return M

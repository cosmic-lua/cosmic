--- cosmo.sandbox.proxy: an HTTP CONNECT + plain-HTTP allowlist proxy.
---
--- Designed for the netns-isolated sandbox use case: the proxy listens
--- inside a child network namespace (the only thing the sandboxed
--- process can reach) and dials upstream in a *different* namespace —
--- typically the parent's. Cross-namespace dialing is handled by setns()
--- in per-connection forks, so a slow upstream never blocks others and
--- there is no global namespace-state contention.
---
--- Features (v1):
---   - HTTP/1.1 CONNECT method (HTTPS tunnels — opaque, allowlist only)
---   - HTTP/1.1 GET/POST/HEAD/PUT/DELETE/PATCH forwarding with auth
---     header injection
---   - Allowlist with exact host:port, host (any port), and host:*
---     matching
---   - Per-host auth rules: bearer / basic / arbitrary header
---   - Configurable logging: level (quiet/info/debug), format
---     (text/json), destination (callable / file path / stderr)
---
--- Out of scope (v1): keep-alive reuse upstream, HTTP/2, MITM TLS
--- interception. Chunked-encoded request bodies are detected and
--- rejected with 411 Length Required.
---
--- Returns nil,unix.Errno on failure for non-fatal API; raises on
--- programmer errors (bad config schema).

local unix = require "unix"
local cosmo = require "cosmo"

local M = {_VERSION = "0.0.3"}

--------------------------------------------------------------------------------
-- Logging

local function ts()
  local s, ns = unix.clock_gettime(unix.CLOCK_REALTIME)
  return string.format("%d.%09d", s, ns)
end

local LEVELS = {quiet = 0, info = 1, debug = 2}

local function make_logger(opts)
  local level = LEVELS[opts.log_level or "info"]
  local format = opts.log_format or "text"
  local sink = opts.on_log
  local out
  -- Only set up an output stream when no callable sink was supplied.
  if not sink then
    if type(opts.log_file) == "string" then
      local f, err = io.open(opts.log_file, "a")
      if not f then
        return nil, "cannot open log file: " .. tostring(err)
      end
      f:setvbuf("line")
      out = f
    else
      out = io.stderr
    end
  end
  local function emit(ev, fields)
    if sink then
      -- emit() runs inside the per-connection worker. A raising
      -- user sink would abort the handler mid-request; swallow it.
      pcall(sink, fields)
      return
    end
    if format == "json" then
      local parts = {}
      parts[#parts + 1] = string.format('{"ts":"%s"', ts())
      parts[#parts + 1] = string.format(',"event":%q', ev)
      for k, v in pairs(fields) do
        if type(v) == "number" then
          parts[#parts + 1] = string.format(',%q:%d', k, v)
        else
          parts[#parts + 1] = string.format(',%q:%q', k, tostring(v))
        end
      end
      parts[#parts + 1] = "}\n"
      out:write(table.concat(parts))
    else
      local kv = {}
      for k, v in pairs(fields) do
        kv[#kv + 1] = string.format("%s=%s", k, tostring(v))
      end
      out:write(string.format("%s %s %s\n", ts(), ev, table.concat(kv, " ")))
    end
  end
  return {
    info  = function(ev, f) if level >= 1 then emit(ev, f or {}) end end,
    debug = function(ev, f) if level >= 2 then emit(ev, f or {}) end end,
    warn  = function(ev, f) if level >= 1 then emit(ev, f or {}) end end,
  }
end
M._make_logger = make_logger

--------------------------------------------------------------------------------
-- Allowlist matching

-- Normalize a rule key into ("host", port_or_nil) where port is nil if any.
local function parse_rule(key)
  local h, p = key:match("^(.-):(.-)$")
  if not h then
    return key:lower(), nil
  end
  if p == "*" or p == "" then
    return h:lower(), nil
  end
  return h:lower(), tonumber(p)
end
M._parse_rule = parse_rule

-- Build a fast lookup index from a {[key]=rule} table.
-- The result is a table with two shapes:
--   idx.exact[host][port|"*"]  = rule   (exact-host matches)
--   idx.suffix[i]              = {suffix = ".x", port = p|"*", rule = ...}
--                                       (wildcard *.suffix matches)
-- Suffixes are stored with a leading "." and matched via string.sub
-- at the tail of the candidate host. The list is kept in insertion
-- order; match() walks it and returns the first hit.
local function build_index(allowed_hosts)
  local idx = {exact = {}, suffix = {}}
  for k, rule in pairs(allowed_hosts or {}) do
    -- Detect "*.suffix" or "*.suffix:port" form.
    local wild = k:match("^%*%.(.+)$")
    if wild then
      local h, p = parse_rule(wild)
      idx.suffix[#idx.suffix + 1] = {
        suffix = "." .. h, port = p or "*", rule = rule,
      }
    else
      local h, p = parse_rule(k)
      idx.exact[h] = idx.exact[h] or {}
      idx.exact[h][p or "*"] = rule
    end
  end
  return idx
end
M._build_index = build_index

-- Look up a (host, port) pair. Returns the rule table on a hit, or nil.
-- Tries exact-host match first, then walks suffix patterns.
local function match(idx, host, port)
  host = host:lower()
  local entry = idx.exact[host]
  if entry then
    local hit = entry[port] or entry["*"]
    if hit then return hit end
  end
  for _, s in ipairs(idx.suffix) do
    if host:sub(-#s.suffix) == s.suffix
       and (s.port == "*" or s.port == port) then
      return s.rule
    end
  end
  return nil
end
M._match = match

--------------------------------------------------------------------------------
-- Auth header construction

local function auth_header(rule)
  -- Accept the shorthand forms `true` / non-table as pass-through
  -- (allowed, no injection). Only a real table with a known `type`
  -- produces an injected header.
  if type(rule) ~= "table" then return nil end
  if rule.type == "bearer" then
    return "Authorization", "Bearer " .. tostring(rule.token)
  elseif rule.type == "basic" then
    local enc = cosmo.EncodeBase64(rule.username .. ":" .. rule.password)
    return "Authorization", "Basic " .. enc
  elseif rule.type == "header" then
    return rule.header_name, rule.header_value
  end
  return nil
end
M._auth_header = auth_header

-- Validate a single allowlist rule. Returns nil on success, a
-- human-readable error string on failure. Invoked on every rule at
-- proxy.new time so operators can't silently typo their way out of
-- header injection — a sandbox proxy is security-sensitive and a
-- misspelled `type` must fail loudly, not degrade to pass-through.
--
-- Bare pass-through values (nil, true, {}) are accepted as "allow,
-- no auth injection". A table with a `type` field must use a known
-- type and carry the fields that auth_header() would dereference.
local function validate_rule(key, rule)
  if rule == nil or rule == true then return nil end
  if type(rule) ~= "table" then
    return string.format("allowed_hosts[%q]: rule must be a table, true, "
                         .. "or nil (got %s)", key, type(rule))
  end
  if rule.type == nil then return nil end   -- {} is explicit pass-through
  if rule.type == "bearer" then
    if type(rule.token) ~= "string" or rule.token == "" then
      return string.format("allowed_hosts[%q]: bearer rule requires "
                           .. "non-empty string `token`", key)
    end
  elseif rule.type == "basic" then
    if type(rule.username) ~= "string" or rule.username == "" then
      return string.format("allowed_hosts[%q]: basic rule requires "
                           .. "non-empty string `username`", key)
    end
    if type(rule.password) ~= "string" then
      return string.format("allowed_hosts[%q]: basic rule requires "
                           .. "string `password`", key)
    end
  elseif rule.type == "header" then
    if type(rule.header_name) ~= "string" or rule.header_name == "" then
      return string.format("allowed_hosts[%q]: header rule requires "
                           .. "non-empty string `header_name`", key)
    end
    if type(rule.header_value) ~= "string" then
      return string.format("allowed_hosts[%q]: header rule requires "
                           .. "string `header_value`", key)
    end
  else
    return string.format("allowed_hosts[%q]: unknown rule type %q "
                         .. "(expected \"bearer\", \"basic\", or \"header\")",
                         key, tostring(rule.type))
  end
  return nil
end
M._validate_rule = validate_rule

--------------------------------------------------------------------------------
-- Wire I/O helpers

-- Read until "\r\n\r\n" or EOF. Returns (header_block, leftover_after).
-- Bounds the read to `max` bytes to avoid memory blowups from junk input.
local function read_headers(fd, max)
  max = max or 65536
  local buf = ""
  while #buf < max do
    local chunk, err = unix.recv(fd, math.min(4096, max - #buf))
    if not chunk then return nil, tostring(err) end
    if chunk == "" then return nil, "eof" end
    buf = buf .. chunk
    local i, j = buf:find("\r\n\r\n", 1, true)
    if i then
      return buf:sub(1, j), buf:sub(j + 1)
    end
  end
  return nil, "header block exceeds " .. max .. " bytes"
end
M._read_headers = read_headers

-- Send all bytes (handles short writes). Uses the send() offset
-- parameter so we don't reallocate a tail substring every iteration.
local function send_all(fd, data)
  local total = #data
  local off = 0
  while off < total do
    local n, err = unix.send(fd, data, 0, off)
    if not n then return nil, tostring(err) end
    if n == 0 then return nil, "short write" end
    off = off + n
  end
  return true
end
M._send_all = send_all

-- Helper: shutdown one direction, mark side closed, drop from poll set.
local function close_side(fds, fd, peer, sides, which)
  pcall(unix.shutdown, peer, unix.SHUT_WR)
  fds[fd] = nil
  sides[which] = false
end

-- Bidirectional byte pump between two TCP fds. Returns when both
-- sides hit EOF or one side errors. Uses unix.poll so the work
-- happens in a single process. shutdown(SHUT_WR) is issued in the
-- appropriate direction so the peer sees a clean half-close.
local function pump(a, b)
  local fds = {[a] = unix.POLLIN, [b] = unix.POLLIN}
  local sides = {a = true, b = true}
  while sides.a or sides.b do
    local ready = unix.poll(fds)
    if not ready then return end
    for fd, ev in pairs(ready) do
      local which = (fd == a) and "a" or "b"
      local peer = (fd == a) and b or a
      local readable = (ev & unix.POLLIN) ~= 0
      local hup = (ev & (unix.POLLHUP | unix.POLLERR | unix.POLLNVAL)) ~= 0
      if readable then
        local chunk = unix.recv(fd, 16384)
        if not chunk or chunk == "" then
          close_side(fds, fd, peer, sides, which)
        else
          if not send_all(peer, chunk) then return end
        end
      elseif hup then
        close_side(fds, fd, peer, sides, which)
      end
    end
  end
end
M._pump = pump

--------------------------------------------------------------------------------
-- Upstream dialing across namespaces

-- Resolve `host` to an IPv4 integer suitable for unix.connect. Uses
-- cosmo.ResolveIp which goes through the system resolver in the
-- *current* netns (so call this AFTER setns() to the upstream netns).
--
-- cosmo.ParseIp returns -1 (not nil) when the string isn't a literal
-- IP, so we explicitly fall back to ResolveIp on -1.
--
-- When `timeout_ms` is non-nil, DNS resolution is bounded: the actual
-- lookup runs in a forked helper and the parent polls the result pipe
-- with ppoll(timeout_ms). If the deadline elapses the helper is
-- SIGKILL'd and (nil, "resolve timeout") is returned, so a hostile or
-- tarpitting upstream resolver can't wedge a per-connection worker
-- past the configured budget. Literal IPs skip the fork entirely.
--
-- `resolver` is an injection seam for tests: it defaults to
-- cosmo.ResolveIp and takes `(host)` → ip | nil, err. Passing a fake
-- slow/failing resolver lets the timeout path be exercised without a
-- working DNS stack.
local function resolve_v4(host, timeout_ms, resolver)
  local ip = cosmo.ParseIp(host)
  if ip and ip ~= -1 then return ip end
  resolver = resolver or cosmo.ResolveIp
  if not timeout_ms then
    return resolver(host)
  end
  local r, w, perr = unix.pipe()
  if not r then return nil, w or perr end
  local pid, ferr = unix.fork()
  if not pid then
    unix.close(r); unix.close(w)
    return nil, ferr
  end
  if pid == 0 then
    unix.close(r)
    local resolved, rerr = resolver(host)
    if resolved then
      unix.write(w, "O" .. string.pack("<i8", resolved))
    else
      unix.write(w, "E" .. tostring(rerr or "resolve failed"))
    end
    unix.close(w)
    unix.exit(0)
  end
  unix.close(w)
  local ready = unix.poll({[r] = unix.POLLIN}, timeout_ms)
  if not ready or not ready[r] then
    pcall(unix.kill, pid, unix.SIGKILL)
    pcall(unix.wait, pid)
    unix.close(r)
    return nil, "resolve timeout"
  end
  -- Drain the pipe. The helper writes at most 9 bytes (1 status byte +
  -- 8-byte packed int) on success, or "E" + a short error string.
  local data = unix.read(r, 4096) or ""
  unix.close(r)
  pcall(unix.wait, pid)
  local tag = data:sub(1, 1)
  if tag == "O" and #data >= 9 then
    return string.unpack("<i8", data, 2)
  elseif tag == "E" then
    return nil, data:sub(2)
  end
  return nil, "resolve failed"
end
M._resolve_v4 = resolve_v4

-- Open a TCP connection to (host, port) in the namespace identified by
-- `upstream_ns_fd`, falling back to the current namespace if the fd is
-- nil. `resolve_timeout_ms` (optional) bounds DNS resolution per dial.
-- Returns fd | nil,err.
local function dial(host, port, upstream_ns_fd, resolve_timeout_ms)
  if upstream_ns_fd then
    local ok, err = unix.setns(upstream_ns_fd, unix.CLONE_NEWNET)
    if not ok then return nil, err end
  end
  local ip, rerr = resolve_v4(host, resolve_timeout_ms)
  if not ip then return nil, rerr end
  -- Block non-public IPs to prevent SSRF. This covers loopback (127/8),
  -- link-local (169.254/16) including the cloud metadata endpoint
  -- 169.254.169.254, RFC1918, CGNAT (100.64/10), 0.0.0.0/8, and other
  -- reserved ranges. Applies to both CONNECT and plain-HTTP paths.
  if not cosmo.IsPublicIp(ip) then
    return nil, "request to private network blocked (SSRF protection)"
  end
  -- SOCK_CLOEXEC: prevent this upstream connection socket from leaking
  -- into any exec'd child via an accidental fork/exec ordering change.
  -- setns() in this process (before connect) is unaffected by CLOEXEC.
  local sk, serr = unix.socket(unix.AF_INET, unix.SOCK_STREAM | unix.SOCK_CLOEXEC, 0)
  if not sk then return nil, serr end
  local ok, cerr = unix.connect(sk, ip, port)
  if not ok then
    unix.close(sk)
    return nil, cerr
  end
  return sk
end
M._dial = dial

--------------------------------------------------------------------------------
-- HTTP request/response handling

local DENY = "HTTP/1.1 403 Forbidden\r\n" ..
             "Content-Length: 0\r\n" ..
             "Connection: close\r\n\r\n"

local BAD_REQUEST = "HTTP/1.1 400 Bad Request\r\n" ..
                    "Content-Length: 0\r\n" ..
                    "Connection: close\r\n\r\n"

local LENGTH_REQUIRED = "HTTP/1.1 411 Length Required\r\n" ..
                        "Content-Length: 0\r\n" ..
                        "Connection: close\r\n\r\n"

local UPSTREAM_FAIL = "HTTP/1.1 502 Bad Gateway\r\n" ..
                      "Content-Length: 0\r\n" ..
                      "Connection: close\r\n\r\n"

-- Parse an HTTP request line: "METHOD TARGET HTTP/x.y\r\n".
-- Returns method, target, version | nil.
local function parse_request_line(line)
  local m, t, v = line:match("^(%u+) (%S+) (HTTP/%d%.%d)\r\n")
  return m, t, v
end
M._parse_request_line = parse_request_line

-- Parse a CONNECT target "host:port".
local function parse_connect_target(t)
  local h, p = t:match("^([^:]+):(%d+)$")
  if not h then return nil end
  return h, tonumber(p)
end
M._parse_connect_target = parse_connect_target

-- Parse an absolute URI of the form "http://host[:port]/path".
-- HTTP proxies receive these (RFC 7230 §5.3.2) instead of origin-form.
-- Returns scheme, host, port (default 80), path.
local function parse_absolute_uri(t)
  local s, hp, path = t:match("^(https?)://([^/]+)(/.*)$")
  if not s then
    s, hp = t:match("^(https?)://([^/]+)$")
    path = "/"
  end
  if not s then return nil end
  local h, p = hp:match("^([^:]+):(%d+)$")
  if h then
    return s, h, tonumber(p), path
  end
  return s, hp, (s == "https") and 443 or 80, path
end
M._parse_absolute_uri = parse_absolute_uri

-- Parse a header block (everything after the request line, up to the
-- blank \r\n) into a list of {orig_name, lower_name, value} triples.
-- Cheaper than re-scanning the block multiple times.
local function parse_headers(block)
  local out = {}
  -- Skip the request line, then iterate header lines.
  local skip = true
  for line in block:gmatch("([^\r\n]+)\r\n") do
    if skip then
      skip = false
    else
      local n, v = line:match("^([^:]+):%s*(.*)$")
      if n then out[#out + 1] = {n, n:lower(), v} end
    end
  end
  return out
end
M._parse_headers = parse_headers

-- Find the first header value (case-insensitive). Returns nil if absent.
local function header_get(headers, lower_name)
  for _, h in ipairs(headers) do
    if h[2] == lower_name then return h[3] end
  end
  return nil
end
M._header_get = header_get

-- Parse Content-Length out of a parsed header list (or a raw block,
-- for backward compat / convenience). Returns 0 if absent.
local function content_length(headers)
  if type(headers) == "string" then headers = parse_headers(headers) end
  local v = header_get(headers, "content-length")
  return v and tonumber(v) or 0
end
M._content_length = content_length

-- Hop-by-hop headers per RFC 7230 §6.1, plus content-length (which we
-- always reissue ourselves to avoid duplicates) and host (which we
-- rewrite). transfer-encoding triggers a 411 path before we get here.
local HOP_BY_HOP = {
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

-- Construct the forwarded HTTP request: method + origin-form target +
-- HTTP/1.1, with our injected auth header (replacing any existing one
-- of the same name), Host rewritten to the upstream target, and
-- Connection: close. Strips proxy-only headers.
local function rebuild_request(method, path, headers, body,
                               inject_name, inject_value, host_hdr)
  -- `headers` may be either a parsed list (from parse_headers) or a
  -- raw block — accept both for backward compat.
  if type(headers) == "string" then headers = parse_headers(headers) end
  local injected_lower = inject_name and inject_name:lower() or nil
  local out = {string.format("%s %s HTTP/1.1\r\n", method, path)}
  out[#out + 1] = "Host: " .. host_hdr .. "\r\n"
  for _, h in ipairs(headers) do
    local oname, lname, value = h[1], h[2], h[3]
    if HOP_BY_HOP[lname] then
      -- skip
    elseif injected_lower and lname == injected_lower then
      -- replaced below
    else
      out[#out + 1] = oname .. ": " .. value .. "\r\n"
    end
  end
  if inject_name then
    out[#out + 1] = inject_name .. ": " .. inject_value .. "\r\n"
  end
  out[#out + 1] = "Connection: close\r\n"
  if body and #body > 0 then
    out[#out + 1] = "Content-Length: " .. #body .. "\r\n"
  else
    out[#out + 1] = "Content-Length: 0\r\n"
  end
  out[#out + 1] = "\r\n"
  if body then out[#out + 1] = body end
  return table.concat(out)
end
M._rebuild_request = rebuild_request

-- Read exactly `n` bytes from `fd`, given an optional already-buffered
-- prefix. Returns the body string, plus any leftover from `prefix`.
local function read_body(fd, n, prefix)
  local buf = prefix or ""
  while #buf < n do
    local chunk, err = unix.recv(fd, math.min(16384, n - #buf))
    if not chunk then return nil, tostring(err) end
    if chunk == "" then return nil, "eof in body" end
    buf = buf .. chunk
  end
  return buf:sub(1, n), buf:sub(n + 1)
end
M._read_body = read_body

--------------------------------------------------------------------------------
-- Per-connection handler

-- Handle one accepted client connection. Closes `client_fd` before
-- returning. Designed to be called in a forked worker process so it
-- can call setns() without affecting the parent.
local function handle(self, client_fd)
  local logger = self._logger
  local hdr, leftover = read_headers(client_fd)
  if not hdr then
    logger.warn("malformed", {reason = leftover or "truncated"})
    send_all(client_fd, BAD_REQUEST)
    unix.close(client_fd)
    return
  end
  local first = hdr:match("^([^\r\n]+)\r\n")
  if not first then
    send_all(client_fd, BAD_REQUEST)
    unix.close(client_fd)
    return
  end
  local method, target = parse_request_line(first .. "\r\n")
  if not method then
    send_all(client_fd, BAD_REQUEST)
    unix.close(client_fd)
    return
  end

  if method == "CONNECT" then
    local host, port = parse_connect_target(target)
    if not host then
      send_all(client_fd, BAD_REQUEST)
      unix.close(client_fd)
      return
    end
    local rule = match(self._index, host, port)
    if not rule then
      logger.warn("deny", {method = "CONNECT", host = host, port = port})
      send_all(client_fd, DENY)
      unix.close(client_fd)
      return
    end
    logger.debug("dial", {method = "CONNECT", host = host, port = port})
    local up, derr = dial(host, port, self._upstream_ns_fd,
                          self._resolve_timeout_ms)
    if not up then
      logger.warn("upstream_fail",
                  {method = "CONNECT", host = host, port = port, err = derr})
      send_all(client_fd, UPSTREAM_FAIL)
      unix.close(client_fd)
      return
    end
    logger.info("allow", {method = "CONNECT", host = host, port = port})
    if not send_all(client_fd, "HTTP/1.1 200 Connection Established\r\n\r\n") then
      unix.close(up); unix.close(client_fd); return
    end
    -- If the client already sent payload after the CONNECT line (rare
    -- but possible for racy clients), forward it to upstream first.
    if leftover and #leftover > 0 then
      if not send_all(up, leftover) then
        unix.close(up); unix.close(client_fd); return
      end
    end
    pump(client_fd, up)
    unix.close(up)
    unix.close(client_fd)
    return
  end

  -- Plain HTTP. Target is absolute-form for proxy requests.
  local scheme, host, port, path = parse_absolute_uri(target)
  if not host then
    send_all(client_fd, BAD_REQUEST)
    unix.close(client_fd)
    return
  end
  local parsed = parse_headers(hdr)
  -- Reject chunked-encoded request bodies — we don't dechunk in v1.
  local te = header_get(parsed, "transfer-encoding")
  if te and te:lower():find("chunked", 1, true) then
    logger.warn("chunked_unsupported",
                {method = method, host = host, path = path})
    send_all(client_fd, LENGTH_REQUIRED)
    unix.close(client_fd)
    return
  end
  local rule = match(self._index, host, port)
  if not rule then
    logger.warn("deny",
                {method = method, host = host, port = port, path = path})
    send_all(client_fd, DENY)
    unix.close(client_fd)
    return
  end
  -- Read the request body (Content-Length only).
  local clen = content_length(parsed)
  local body
  if clen > 0 then
    local b, err = read_body(client_fd, clen, leftover)
    if not b then
      send_all(client_fd, BAD_REQUEST)
      unix.close(client_fd)
      return
    end
    body = b
  end
  local up, derr = dial(host, port, self._upstream_ns_fd, self._resolve_timeout_ms)
  if not up then
    logger.warn("upstream_fail",
                {method = method, host = host, port = port, err = derr})
    send_all(client_fd, UPSTREAM_FAIL)
    unix.close(client_fd)
    return
  end
  local injn, injv = auth_header(rule)
  local host_hdr = host
  if (scheme == "http"  and port ~= 80) or
     (scheme == "https" and port ~= 443) then
    host_hdr = host .. ":" .. port
  end
  local req = rebuild_request(method, path, parsed, body, injn, injv, host_hdr)
  if not send_all(up, req) then
    unix.close(up); unix.close(client_fd); return
  end
  logger.info("allow", {method = method, host = host, port = port,
                        path = path,
                        injected = injn ~= nil and injn or false})
  -- Stream the response back. We pump bidirectionally for symmetry;
  -- after the client's body is forwarded the cli→up direction quickly
  -- EOFs.
  pump(client_fd, up)
  unix.close(up)
  unix.close(client_fd)
end

--------------------------------------------------------------------------------
-- Public Proxy object

--- Allowlist rule schema
--- ----------------------
---
--- `opts.allowed_hosts` is a map from host-spec string to a rule value:
---
---     opts.allowed_hosts = {
---       -- Pass-through: host is allowed, no auth header injection.
---       ["api.anthropic.com:443"]         = {},
---       ["*.githubusercontent.com"]       = true,
---
---       -- Bearer token injection (plain-HTTP only; HTTPS is opaque).
---       ["api.internal.example.com:80"]   = {
---         type  = "bearer",
---         token = os.getenv("TOKEN") or "",
---       },
---
---       -- Basic auth.
---       ["legacy.example.com:80"]         = {
---         type = "basic", username = "u", password = "p",
---       },
---
---       -- Arbitrary header injection.
---       ["api.internal.example.com:80"]   = {
---         type         = "header",
---         header_name  = "x-api-key",
---         header_value = os.getenv("INTERNAL_API_KEY") or "",
---       },
---     }
---
--- Host-spec forms:
---   host              any port on exact host
---   host:port         exact host + exact port
---   host:*            any port on exact host (explicit)
---   *.suffix          any host ending in ".suffix", any port
---   *.suffix:port     any host ending in ".suffix", exact port
---
--- Rule values:
---   Any non-table (e.g. `true`, or an empty table `{}`) means "allow,
---   do not inject auth". A table with a recognized `type` field
---   injects the corresponding header on plain-HTTP requests only —
---   HTTPS (CONNECT) tunnels are end-to-end encrypted, so no injection
---   is possible. The rule is still consulted as the allowlist gate
---   for CONNECT, and serves as documentation of which credentials the
---   child process is expected to use.
---
---   type="bearer", token=STRING
---     → "Authorization: Bearer <token>"
---
---   type="basic", username=STRING, password=STRING
---     → "Authorization: Basic base64(user:pass)"
---
---   type="header", header_name=STRING, header_value=STRING
---     → "<header_name>: <header_value>"
---
--- Every rule is validated at proxy.new time: unknown `type` values
--- and missing required fields raise immediately. This is
--- deliberate — a typo'd rule silently degrading to pass-through
--- would strip auth from an otherwise-authenticated egress path.
--- Unknown *non-type* fields are ignored (forward compatibility).

local Proxy = {__name = "cosmo.sandbox.proxy.Proxy"}
Proxy.__index = Proxy

--- Create a new proxy. `opts` fields:
---
---   bind_ip          uint32 IPv4 (default cosmo.ParseIp("127.0.0.1"))
---   bind_port        uint16 (default 3128; 0 = ephemeral)
---   allowed_hosts    table {host_spec = rule} — see schema above
---   upstream_ns_fd   int (open fd to the netns to dial in; default
---                    nil means dial in the current namespace)
---   on_log           function(fields) — overrides default sink
---   log_level        "quiet"|"info"|"debug"  (default "info")
---   log_format       "text"|"json"           (default "text")
---   log_file         path                    (default stderr)
---   accept_backlog   int                     (default 32)
---   resolve_timeout_ms int | false            (default 5000)
---                    Per-dial DNS resolution deadline in milliseconds.
---                    A hostile or slow upstream resolver is capped at
---                    this budget; on timeout the dial fails with
---                    "resolve timeout" and the connection gets 502.
---                    Pass `false` to opt out of the timeout entirely
---                    (restores pre-v0.0.3 unbounded behaviour).
---
--- Raises if any allowed_hosts rule has an unknown `type` or is
--- missing a required field — see "Allowlist rule schema" above.
---
--- Returns the Proxy object.
function M.new(opts)
  opts = opts or {}
  for key, rule in pairs(opts.allowed_hosts or {}) do
    local verr = validate_rule(key, rule)
    if verr then error(verr) end
  end
  local logger, lerr = make_logger(opts)
  if not logger then error(lerr) end
  -- `resolve_timeout_ms = false` opts out of the timeout; a nil key
  -- falls back to the 5000ms default.
  local resolve_timeout_ms
  if opts.resolve_timeout_ms == nil then
    resolve_timeout_ms = 5000
  elseif opts.resolve_timeout_ms then
    resolve_timeout_ms = opts.resolve_timeout_ms
  end
  return setmetatable({
    _bind_ip = opts.bind_ip or cosmo.ParseIp("127.0.0.1"),
    _bind_port = opts.bind_port or 3128,
    _index = build_index(opts.allowed_hosts or {}),
    _upstream_ns_fd = opts.upstream_ns_fd,
    _logger = logger,
    _backlog = opts.accept_backlog or 32,
    _resolve_timeout_ms = resolve_timeout_ms,
    _listen_fd = nil,
  }, Proxy)
end

--- Bind + listen. Returns the listening fd, or nil, unix.Errno.
function Proxy:listen()
  -- SOCK_CLOEXEC: the listening socket must not be inherited by the
  -- sandboxed exec'd child (it would allow rebinding or probing the
  -- proxy from inside the jail). Per-connection forks already explicitly
  -- close it; CLOEXEC adds defense-in-depth against ordering accidents.
  local fd, err = unix.socket(unix.AF_INET, unix.SOCK_STREAM | unix.SOCK_CLOEXEC, 0)
  if not fd then return nil, err end
  unix.setsockopt(fd, unix.SOL_SOCKET, unix.SO_REUSEADDR, 1)
  local ok, berr = unix.bind(fd, self._bind_ip, self._bind_port)
  if not ok then unix.close(fd); return nil, berr end
  ok, err = unix.listen(fd, self._backlog)
  if not ok then unix.close(fd); return nil, err end
  -- Refresh bind_port if the caller asked for 0.
  local _, port = unix.getsockname(fd)
  if port then self._bind_port = port end
  self._listen_fd = fd
  self._logger.info("listen",
                    {ip = cosmo.FormatIp(self._bind_ip),
                     port = self._bind_port})
  return fd
end

--- Accept one connection. Returns the client fd | nil, unix.Errno.
function Proxy:accept()
  return unix.accept(self._listen_fd)
end

--- Handle one accepted fd in this process. Does NOT fork.
function Proxy:handle(client_fd)
  return handle(self, client_fd)
end

--- Run the accept loop forever, forking per connection. Reaps zombies
--- non-blockingly between accepts. Breaks out of the loop on EBADF
--- (listening fd was closed externally) or other persistent errors;
--- the caller is responsible for SIGTERM/SIGINT handling.
function Proxy:serve_forever()
  if not self._listen_fd then assert(self:listen()) end
  local function reap()
    while true do
      local pid = unix.wait(-1, unix.WNOHANG)
      if not pid or pid == 0 then return end
    end
  end
  while true do
    local cli, aerr = self:accept()
    if not cli then
      local errno = aerr and aerr:errno()
      if errno == unix.EINTR then
        reap()
      elseif errno == unix.EBADF or errno == unix.EINVAL then
        -- Listener went away. Stop the loop; the supervisor will
        -- decide what to do next.
        self._logger.warn("accept_fatal", {err = tostring(aerr)})
        return
      else
        self._logger.warn("accept_fail", {err = tostring(aerr)})
      end
    else
      local pid = unix.fork()
      if pid == 0 then
        unix.close(self._listen_fd)
        self:handle(cli)
        unix.exit(0)
      else
        unix.close(cli)
        reap()
      end
    end
  end
end

--------------------------------------------------------------------------------
-- Convenience: fork + listen + serve in one call.

local Handle = {__name = "cosmo.sandbox.proxy.Handle"}
Handle.__index = Handle

local function now_ms()
  local s, ns = unix.clock_gettime(unix.CLOCK_MONOTONIC)
  return s * 1000 + ns // 1000000
end

--- handle:stop([timeout_ms]) → true
---
--- Send SIGTERM and reap. Idempotent: once the child has been reaped
--- (self.pid == 0), subsequent calls short-circuit without re-
--- signalling — critical because `kill(0, ...)` targets the caller's
--- whole process group, and a reused pid would receive a spurious
--- signal. Escalates to SIGKILL if the child hasn't exited within
--- `timeout_ms` (default 5000), so a hung or SIGTERM-ignoring worker
--- can't wedge the supervisor forever.
---
--- Always returns true; signal/wait failures are swallowed via pcall
--- since the post-condition (pid cleared, child no longer our
--- responsibility) is reached regardless.
function Handle:stop(timeout_ms)
  if self.pid == 0 then return true end
  timeout_ms = timeout_ms or 5000
  local pid = self.pid
  pcall(unix.kill, pid, unix.SIGTERM)
  local deadline = now_ms() + timeout_ms
  while true do
    local gone = unix.wait(pid, unix.WNOHANG)
    if gone == pid then
      self.pid = 0
      return true
    end
    if now_ms() >= deadline then break end
    unix.nanosleep(0, 10 * 1000 * 1000)
  end
  pcall(unix.kill, pid, unix.SIGKILL)
  pcall(unix.wait, pid)
  self.pid = 0
  return true
end

--- handle:alive() → boolean
---
--- Non-blocking health check: true while the proxy child is still
--- running, false once it has exited. Uses waitpid(WNOHANG) so it
--- returns immediately whether or not the child is ready.
---
--- Once alive() has observed an exit, it reaps the child (consuming
--- the zombie) and clears self.pid to 0. Subsequent calls short-
--- circuit to false without a waitpid syscall — avoiding races
--- against pid reuse.
function Handle:alive()
  if self.pid == 0 then return false end
  local gone = unix.wait(self.pid, unix.WNOHANG)
  if gone == self.pid then
    self.pid = 0
    return false
  end
  return true
end

M._Handle = Handle

--- proxy.start(opts) → {pid, port, stop()} | nil, unix.Errno
---
--- Fork a child process, bring the proxy up in it, and return a
--- handle the caller can use to address the listening proxy:
---
---   p.pid      child pid (for waitpid / signal forwarding)
---   p.port     the port the proxy is listening on (resolved even if
---              opts.bind_port was 0)
---   p:stop()   send SIGTERM and waitpid(p.pid)
---   p:alive()  non-blocking health check (true while running)
---
--- The parent blocks until the child has bound-and-listened, so
--- p.port is valid immediately. The port is communicated back via a
--- pipe so the parent doesn't have to poll.
---
--- This is the common case: spawn a proxy alongside a jailed
--- workload. Callers that need finer control (custom dispatch,
--- non-forking mode, shared listener) should use proxy.new() +
--- listen() + serve_forever() directly.
function M.start(opts)
  local r, w, perr = unix.pipe()
  if not r then return nil, w or perr end
  local pid, ferr = unix.fork()
  if not pid then
    unix.close(r); unix.close(w)
    return nil, ferr
  end
  if pid == 0 then
    -- Child: listen, report the bound port to the parent, then serve.
    unix.close(r)
    local p = M.new(opts)
    local fd, lerr = p:listen()
    if not fd then
      unix.write(w, string.pack("<i4", -1))
      unix.close(w)
      io.stderr:write("proxy.start: listen: " .. tostring(lerr) .. "\n")
      unix.exit(1)
    end
    unix.write(w, string.pack("<i4", p._bind_port))
    unix.close(w)
    p:serve_forever()
    unix.exit(0)
  end
  -- Parent: read the bound port, then return the handle.
  unix.close(w)
  local packed = unix.read(r, 4)
  unix.close(r)
  if not packed or #packed < 4 then
    pcall(unix.kill, pid, unix.SIGTERM)
    pcall(unix.wait, pid)
    return nil, unix.EIO
  end
  local port = string.unpack("<i4", packed)
  if port < 0 then
    pcall(unix.wait, pid)
    return nil, unix.EIO
  end
  return setmetatable({pid = pid, port = port}, Handle)
end

return M

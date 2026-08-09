--- Listener, per-connection handler, and logging for the
--- cosmic.quicksand.proxy egress proxy.
---
--- new() builds a Server from ProxyOptions; listen() binds it;
--- serve_forever() runs the accept loop, forking one worker per
--- connection so each worker can setns() into the upstream namespace
--- without affecting the others. Most callers should use
--- cosmic.quicksand.proxy.start() instead, which forks the whole
--- server into a sidecar child and returns a handle.
local unix = require("cosmo.unix")
local cosmo = require("cosmo")
local rules = require("cosmic.quicksand.proxy.rules")
local qtypes = require("cosmic.quicksand.types")

local type ProxyRule = qtypes.NetRule
local http = require("cosmic.quicksand.proxy.http")
local updial = require("cosmic.quicksand.proxy.dial")
local errno = require("cosmic.errno")

--- Leveled event logger. Each method takes an event name and a flat
--- field table.
local record Logger
  info: function(ev: string, fields: {string: any})
  debug: function(ev: string, fields: {string: any})
  warn: function(ev: string, fields: {string: any})
end

--- A bound (or bindable) proxy server. Methods are closures over the
--- server's internal state.
local record Server
  port: function(): integer
  listen: function(): integer | nil, string
  accept: function(): integer | nil, string
  handle: function(client_fd: integer)
  serve_forever: function()
end

local record ServeModule
  --- The Server record new() returns, exported so callers (tests
  --- included) can name it instead of casting to structural twins.
  type Server = Server

  --- A single allowlist rule. `type` nil means pass-through
  --- (allowed, no header injection). Fields not relevant to the
  --- chosen type are ignored. This is cosmic.quicksand.types.NetRule:
  --- one nominal record for the whole quicksand family.
  type ProxyRule = ProxyRule

  --- Options for start() / new().
  record ProxyOptions
    bind_ip: integer -- default cosmo.ParseIp("127.0.0.1")
    bind_port: integer -- default 3128; 0 = ephemeral
    allowed_hosts: {string: ProxyRule}
    upstream_ns_fd: integer -- netns fd to dial in; nil = current ns
    log_level: qtypes.LogLevel -- default "info"
    log_format: qtypes.LogFormat -- default "text"
    log_file: string -- path; default stderr
    accept_backlog: integer -- default 32
    resolve_timeout_ms: integer -- per-dial DNS deadline in ms;
    -- nil = 5000, <= 0 disables the deadline entirely
    max_body_bytes: integer -- request-body cap in bytes; a larger
    -- Content-Length is refused with 413 before any body byte is
    -- buffered. nil = 64 MiB, <= 0 disables the cap
    on_log: function({string: any}) -- overrides the default sink
  end

  new: function(opts: ProxyOptions): Server | nil, string
end

-- <total>: adding a LogLevel member without deciding its threshold is a
-- compile error, not a silent fallthrough to the `or 1` default.
local LEVELS < total >: {qtypes.LogLevel: integer} = {quiet = 0, info = 1, debug = 2}

local function ts(): string
  local s, ns = unix.clock_gettime(unix.CLOCK_REALTIME)
  return string.format("%d.%09d", s, ns)
end

--- Build a Logger from options: level (quiet/info/debug), format
--- (text/json), destination (on_log callable / log_file path /
--- stderr). A raising on_log sink is swallowed with pcall — it runs
--- inside per-connection workers and must not abort a handler
--- mid-request.
local function make_logger(opts: ServeModule.ProxyOptions): Logger, string
  local level = LEVELS[opts.log_level or "info"] or 1
  local format = opts.log_format or "text"
  local sink = opts.on_log
  local out: FILE
  if not sink then
    if opts.log_file then
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
  local function emit(ev: string, fields: {string: any})
    if sink then
      pcall(sink, fields)
      return
    end
    if format == "json" then
      local parts: {string} = {}
      table.insert(parts, string.format('{"ts":"%s"', ts()))
      table.insert(parts, string.format(',"event":%q', ev))
      for k, v in pairs(fields) do
        if v is number then
          -- cast: number to integer for %d format
          table.insert(parts, string.format(',%q:%d', k, v as integer))
        else
          table.insert(parts, string.format(',%q:%q', k, tostring(v)))
        end
      end
      table.insert(parts, "}\n")
      out:write(table.concat(parts))
    else
      local kv: {string} = {}
      for k, v in pairs(fields) do
        table.insert(kv, string.format("%s=%s", k, tostring(v)))
      end
      out:write(string.format("%s %s %s\n", ts(), ev, table.concat(kv, " ")))
    end
  end
  return {
    info = function(ev: string, f: {string: any})
      if level >= 1 then emit(ev, f or {}) end
    end,
    debug = function(ev: string, f: {string: any})
      if level >= 2 then emit(ev, f or {}) end
    end,
    warn = function(ev: string, f: {string: any})
      if level >= 1 then emit(ev, f or {}) end
    end,
  }
end

--- Build a Server from ProxyOptions. Does not bind; call listen()
--- (or hand the Server to serve_forever(), which listens lazily).
--- Returns nil + error when the log sink can't be opened. Rule
--- validation is the caller's job (proxy.start validates before
--- forking); unvalidated rule tables here behave as pass-through.
local function new(opts: ServeModule.ProxyOptions): Server | nil, string
  opts = opts or {}
  local logger, lerr = make_logger(opts)
  if not logger then return nil, lerr end
  local idx = rules.index(opts.allowed_hosts or {})
  local bind_ip: integer = opts.bind_ip or cosmo.ParseIp("127.0.0.1")
  local bind_port: integer = opts.bind_port or 3128
  local backlog: integer = opts.accept_backlog or 32
  local upstream_ns_fd = opts.upstream_ns_fd
  local resolve_timeout_ms: integer
  if opts.resolve_timeout_ms == nil then
    resolve_timeout_ms = 5000
  elseif opts.resolve_timeout_ms > 0 then
    resolve_timeout_ms = opts.resolve_timeout_ms
  end
  local max_body_bytes: integer
  if opts.max_body_bytes == nil then
    max_body_bytes = 64 * 1024 * 1024
  elseif opts.max_body_bytes > 0 then
    max_body_bytes = opts.max_body_bytes
  end
  local listen_fd: integer

  -- Reply with a canned response and close the client socket.
  local function refuse(client_fd: integer, response: string)
    local _ok, _err = http.send_all(client_fd, response)
    unix.close(client_fd)
  end

  local function handle_connect(client_fd: integer, target: string,
      leftover: string)
    local host, port = http.parse_connect_target(target)
    if not host then
      refuse(client_fd, http.BAD_REQUEST)
      return
    end
    local rule = rules.match(idx, host, port)
    if not rule then
      logger.warn("deny", {method = "CONNECT", host = host, port = port})
      refuse(client_fd, http.DENY)
      return
    end
    logger.debug("dial", {method = "CONNECT", host = host, port = port})
    local up, derr = updial.dial(host, port, upstream_ns_fd,
      resolve_timeout_ms)
    if not up then
      logger.warn("upstream_fail",
        {method = "CONNECT", host = host, port = port, err = derr})
      refuse(client_fd, http.UPSTREAM_FAIL)
      return
    end
    logger.info("allow", {method = "CONNECT", host = host, port = port})
    local established = "HTTP/1.1 200 Connection Established\r\n\r\n"
    if not http.send_all(client_fd, established) then
      unix.close(up)
      unix.close(client_fd)
      return
    end
    -- Forward any payload the client already sent after the CONNECT
    -- line (rare but possible for racy clients).
    if leftover and #leftover > 0 then
      if not http.send_all(up, leftover) then
        unix.close(up)
        unix.close(client_fd)
        return
      end
    end
    http.pump(client_fd, up)
    unix.close(up)
    unix.close(client_fd)
  end

  local function handle_http(client_fd: integer, method: string,
      target: string, hdr: string, leftover: string)
    local uri = http.parse_absolute_uri(target)
    if not uri then
      refuse(client_fd, http.BAD_REQUEST)
      return
    end
    local scheme, host, port, path = uri.scheme, uri.host, uri.port, uri.path
    local parsed = http.parse_headers(hdr)
    -- Reject chunked-encoded request bodies — we don't dechunk.
    local te = http.header_get(parsed, "transfer-encoding")
    if te and string.lower(te):find("chunked", 1, true) then
      logger.warn("chunked_unsupported",
        {method = method, host = host, path = path})
      refuse(client_fd, http.LENGTH_REQUIRED)
      return
    end
    local rule = rules.match(idx, host, port)
    if not rule then
      logger.warn("deny",
        {method = method, host = host, port = port, path = path})
      refuse(client_fd, http.DENY)
      return
    end
    -- Read the request body (Content-Length only). A malformed
    -- Content-Length is a 400; an over-cap one is refused with 413
    -- before a single body byte is read, so a client inside the box
    -- cannot make this worker buffer an attacker-chosen amount of
    -- memory.
    local clen = http.content_length(parsed)
    if not clen then
      logger.warn("bad_content_length",
        {method = method, host = host, path = path})
      refuse(client_fd, http.BAD_REQUEST)
      return
    end
    if max_body_bytes and clen > max_body_bytes then
      logger.warn("body_too_large", {method = method, host = host,
          path = path, content_length = clen, max = max_body_bytes})
      refuse(client_fd, http.PAYLOAD_TOO_LARGE)
      return
    end
    local body: string
    if clen > 0 then
      local b = http.read_body(client_fd, clen, leftover)
      if not b then
        refuse(client_fd, http.BAD_REQUEST)
        return
      end
      body = b
    end
    local up, derr = updial.dial(host, port, upstream_ns_fd,
      resolve_timeout_ms)
    if not up then
      logger.warn("upstream_fail",
        {method = method, host = host, port = port, err = derr})
      refuse(client_fd, http.UPSTREAM_FAIL)
      return
    end
    local injn, injv = rules.auth_header(rule)
    local host_hdr = host
    if (scheme == "http" and port ~= 80)
    or (scheme == "https" and port ~= 443) then
      host_hdr = host .. ":" .. tostring(port)
    end
    local req = http.rebuild_request({
        method = method,
        path = path,
        headers = parsed,
        body = body,
        host_hdr = host_hdr,
        inject_name = injn,
        inject_value = injv,
      })
    if not http.send_all(up, req) then
      unix.close(up)
      unix.close(client_fd)
      return
    end
    logger.info("allow", {method = method, host = host, port = port,
        path = path, injected = injn ~= nil and injn or false})
    -- Stream the response back. Pump bidirectionally for symmetry;
    -- after the client's body is forwarded the client-to-upstream
    -- direction quickly EOFs.
    http.pump(client_fd, up)
    unix.close(up)
    unix.close(client_fd)
  end

  -- Handle one accepted client connection. Closes client_fd before
  -- returning. Designed to run in a forked worker so dial's setns()
  -- can't affect the listener.
  local function handle(client_fd: integer)
    local hdr, leftover = http.read_headers(client_fd, nil)
    if not hdr then
      logger.warn("malformed", {reason = leftover or "truncated"})
      refuse(client_fd, http.BAD_REQUEST)
      return
    end
    local first = string.match(hdr, "^([^\r\n]+)\r\n")
    if not first then
      refuse(client_fd, http.BAD_REQUEST)
      return
    end
    local line = http.parse_request_line(first .. "\r\n")
    if not line then
      refuse(client_fd, http.BAD_REQUEST)
      return
    end
    local method, target = line.method, line.target
    if method == "CONNECT" then
      handle_connect(client_fd, target, leftover)
      return
    end
    handle_http(client_fd, method, target, hdr, leftover)
  end

  local function listen(): integer | nil, string
    -- SOCK_CLOEXEC: the listening socket must not be inherited by any
    -- exec'd child (it would allow rebinding or probing the proxy
    -- from inside the box). Per-connection forks also explicitly
    -- close it.
    local fd, serr = unix.socket(unix.AF_INET,
      (unix.SOCK_STREAM) | (unix.SOCK_CLOEXEC), 0)
    if not fd then return nil, errno.format(serr, "socket") end
    local lfd = fd
    unix.setsockopt(lfd, unix.SOL_SOCKET, unix.SO_REUSEADDR, 1)
    local bok, berr = unix.bind(lfd, bind_ip, bind_port)
    if not bok then
      unix.close(lfd)
      return nil, errno.format(berr, "bind")
    end
    local lok, lerr2 = unix.listen(lfd, backlog)
    if not lok then
      unix.close(lfd)
      return nil, errno.format(lerr2, "listen")
    end
    -- Refresh bind_port if the caller asked for an ephemeral port.
    local _, got_port = unix.getsockname(lfd)
    if got_port then bind_port = got_port end
    listen_fd = lfd
    logger.info("listen",
      {ip = cosmo.FormatIp(bind_ip), port = bind_port})
    return lfd
  end

  local function accept(): integer | nil, string
    local cli, aerr = unix.accept(listen_fd)
    if not cli then return nil, errno.format(aerr, "accept") end
    return cli
  end

  -- Run the accept loop forever, forking per connection and reaping
  -- zombies non-blockingly between accepts. Returns on EBADF/EINVAL
  -- (listener closed externally); the supervisor decides what next.
  local function serve_forever()
    if not listen_fd then assert(listen()) end
    local function reap()
      while true do
        local pid = unix.wait(-1, unix.WNOHANG)
        if not pid or pid == 0 then return end
      end
    end
    while true do
      -- On failure accept returns nil, err (string), errno; the error
      -- string and numeric errno land in the ip/port success slots.
      local cli, aerr, aeno = unix.accept(listen_fd)
      if not cli then
        if errno.is_code(aeno, "EINTR") then
          reap()
        elseif errno.is_code(aeno, "EBADF") or errno.is_code(aeno, "EINVAL") then
          logger.warn("accept_fatal", {err = tostring(aerr)})
          return
        else
          logger.warn("accept_fail", {err = tostring(aerr)})
        end
      else
        local pid = unix.fork()
        if pid == 0 then
          unix.close(listen_fd)
          handle(cli)
          unix.exit(0)
        else
          unix.close(cli)
          reap()
        end
      end
    end
  end

  local srv: Server = {}
  srv.port = function(): integer
    return bind_port
  end
  srv.listen = listen
  srv.accept = accept
  srv.handle = handle
  srv.serve_forever = serve_forever
  return srv
end

local M: ServeModule = {
  new = new,
}

return M

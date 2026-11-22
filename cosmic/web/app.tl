--- An app: the routes compiled, the middleware folded around the router, the
--- handler that answers a server's request, and [`App.serve`], which runs
--- it over [`cosmic.http.server`] with its lifespan and graceful stop.
--- @public

local Builtin = require("cosmic.web.builtin")
local Clock = require("cosmic.clock")
local Errors = require("cosmic.web.errors")
local Middleware = require("cosmic.web.middleware")
local Net = require("cosmic.net")
local Request = require("cosmic.web.request")
local Router = require("cosmic.web.router")
local Server = require("cosmic.http.server")
-- Only the type: an app that serves no tailnet loads no client of
-- tailscaled.
local type Tailscale = require("cosmic.tailscale")
local Types = require("cosmic.web.types")

--- The value of a `<close>` variable: only its `__close` matters.
local record Closing
  __close: function(Closing)
end

--- What a request's handler answered, where the closer of its bodies can
--- read it: the closer is a function, and a function may write a field of
--- what it holds but not assign a local of the code around it.
local record Answered
  mut reply?: Types.Response
end

local record App
end

--- How long requests in flight have to finish once the server stops.
local GRACE_NS <const> = Clock.seconds(10)

--- The streams an app allows when it is not served: half the server's
--- default of 256 connections.
local DEFAULT_STREAM_LIMIT <const> = 128

--- What `fn` raised, or nil when it returned.
local function raised_by(fn: function()): string?
  local ok, err = pcall(function(): any
    fn()
    return nil -- checked: any_use
  end)
  if ok then return nil end
  return tostring(err)
end

local function url_for(self: Types.App, name: string, params?: {string: string | integer},
                       query?: {string:string}): string?, string
  return self.router:reverse(name, params, query)
end

local function stopping(self: Types.App): boolean
  return self.stopped
end

local function on_stop(self: Types.App, fn: function())
  self.stoppers[#self.stoppers + 1] = fn
end

local app_methods = { url_for = url_for, stopping = stopping, on_stop = on_stop }
local app_mt: metatable<Types.App> = { __index = app_methods } -- checked: literal_missing

--- Compiles `spec` into an app. Raises, naming it, for a route that cannot
--- be registered ([`Web.router`]).
--- @param spec Types.AppSpec What the app is made of
--- @return Types.App The app
function App.new(spec: Types.AppSpec): Types.App
  local sink: Types.Sink = spec.sink or Middleware.stderr_sink()
  local hubs: {Types.Closable} = spec.hubs or {}
  local routes: {Types.Route} = spec.routes or {}
  local middleware: {Types.Middleware} = spec.middleware or {}
  local proxies, refused = Request.proxies(spec.trusted_proxy)
  if refused ~= "" then error(refused, 2) end
  local proxy_entries: {string}? = nil
  if proxies ~= nil then
    local entries: mut {string} = {}
    for i, entry in ipairs(assert(spec.trusted_proxy)) do entries[i] = entry end
    proxy_entries = entries
  end
  local kept: Types.AppSpec = {
    routes = routes, middleware = middleware, lifespan = spec.lifespan,
    debug = spec.debug == true, trailing_slash = spec.trailing_slash,
    trusted_proxy = proxy_entries, error_pages = spec.error_pages,
    error_view = spec.error_view, sink = sink,
    builtin = spec.builtin ~= false,
    hubs = hubs, max_streams = spec.max_streams, dev = spec.dev == true,
  }
  local kept_max_streams = kept.max_streams
  if kept_max_streams ~= nil and (math.type(kept_max_streams) ~= "integer" or kept_max_streams < 0) then
    error("web: max_streams must be a non-negative integer", 2)
  end
  for _, hub in ipairs(hubs) do
    if type(hub) ~= "table" or type(hub.close) ~= "function" then -- checked: interface_method_value
      error("web: hubs holds only what has a close method", 2)
    end
  end
  local trusted: mut {string:boolean}? = nil
  local trusted_hosts = spec.trusted_hosts
  if trusted_hosts ~= nil then
    local seen: mut {string:boolean} = {}
    trusted = seen
    local hosts: mut {string} = {}
    kept.trusted_hosts = hosts
    for _, host in ipairs(trusted_hosts) do
      local parsed = if type(host) == "string" then Request.parse_host(host) else nil end
      if parsed == nil or parsed.port ~= nil then
        error(("web: trusted_hosts: %q is not a host name without a port"):format(tostring(host)), 2)
      end
      seen[parsed.host] = true
      hosts[#hosts + 1] = parsed.host
    end
  end
  local router = Router.build(routes, Errors.terminal, kept.trailing_slash, kept.builtin)
  local app: Types.App = { spec = kept, state = {}, router = router, stopped = false, stoppers = {}, -- checked: literal_missing
    streams = {}, stream_count = 0, stream_limit = kept.max_streams or DEFAULT_STREAM_LIMIT, serve_socket = nil,
    serve_caps = nil, proxies = proxies }
  local function dispatch(req: Types.Request): Types.Response
    local given = req.outcome
    if given == nil and kept.builtin == true then
      -- Ahead of the routes, so that a catch-all cannot shadow the files.
      local served = Builtin.handle(req)
      if served ~= nil then return served end
    end
    local outcome = given or Router.lookup(router, req.method, req.segments, req.trailing)
    req.outcome = outcome
    if outcome.kind == "match" then
      req.params = assert(outcome.params)
      req.route = outcome.route
    end
    req.mount_path = outcome.mount_path
    return outcome.handler(req)
  end
  local stack = Middleware.compose(middleware, Errors.wrap(dispatch))
  app.handle = function(raw: Server.Request): Types.Response
    local parts: Request.Parts = { path = "/", segments = {}, trailing = false }
    local outcome: Types.Outcome? = nil
    if raw.path == "*" then
      outcome = Router.star(router, raw.method)
    else
      local canon, why = Router.canonical(raw.path)
      if canon == nil then
        outcome = { kind = "bad_path", detail = why, handler = router.miss, mount_path = "" }
      else
        parts = { path = canon.path, segments = canon.segments, trailing = canon.trailing }
        if canon.changed then
          outcome = { kind = "redirect", location = canon.path, handler = router.miss, mount_path = "" }
        end
      end
    end
    local req = Request.new(app, raw, parts)
    if trusted ~= nil then
      local host = req.host
      local named = if host ~= nil then Request.parse_host(host) else nil end
      if named == nil or trusted[named.host] ~= true then
        outcome = { kind = "bad_host", detail = "the host is not one this app answers to",
          handler = router.miss, mount_path = "" }
      end
    end
    req.outcome = outcome
    local answered: Answered = {}
    -- A `<close>` variable, not code after the call: a task killed where
    -- its handler waits (a client that went away mid-upload) runs the
    -- pending closes of its coroutine and nothing after them. The bodies
    -- a reply streams are the server's to close.
    local closing_mt: metatable<Closing> = { __close = function() -- checked: literal_missing
      for _, body in ipairs(req.bodies) do
        local reply = answered.reply
        if reply == nil or reply.body ~= body then
          local _, _ = body:close()
        end
      end
    end }
    local _closing <close>: Closing = setmetatable({}, closing_mt) -- checked: close_not_closable, setmetatable_call -- untyped: call
    local ok, reply = pcall(stack, req)
    if not ok then error(reply, 0) end
    answered.reply = reply
    return reply
  end
  return setmetatable(app, app_mt) -- checked: setmetatable_call -- untyped: call
end

--- Runs `app` over [`Server.serve`]: its lifespan first, then the server
--- until it stops, then the lifespan's cleanup. See [`Web.serve`].
--- @param app Types.App The app
--- @param opts Types.ServeOptions Where and how
--- @return boolean Whether the server stopped cleanly
--- @return string Why not
function App.serve(app: Types.App, opts: Types.ServeOptions): boolean, string
  local sink = assert(app.spec.sink)
  local listeners: mut {Net.Address} = {}
  for _, address in ipairs(opts.listeners or {}) do listeners[#listeners + 1] = address end
  local tls = opts.tls
  local clear = opts.clear
  local handle = app.handle
  local acme = opts.acme
  if acme ~= nil then
    if tls ~= nil or (opts.tailnet ~= nil and opts.tailnet ~= false) then
      error("web: serve takes one of acme, tls and tailnet", 2)
    end
    tls = acme.certs
    handle = acme:handler(app.handle)
    if #listeners == 0 then listeners[1] = Net.tcp("0.0.0.0", 443) end
    if clear == nil then clear = { Net.tcp("0.0.0.0", 80) } end
  end
  local tailnet = opts.tailnet
  -- Through the daemon's Serve: what files its configuration once the
  -- listener is open, and what removes the socket after (`unplace`).
  local put_up: (function(): Tailscale.Serving?, string)? = nil
  local unplace: function()? = nil
  local socket: string? = nil
  local forwarded: {string}? = nil
  -- Refuses to serve, removing what Serve's socket left first.
  local function declined(why: string): boolean, string
    local undo = unplace
    if undo ~= nil then undo() end
    return false, why
  end
  if tailnet ~= nil and tailnet ~= false then
    if tls ~= nil then error("web: serve takes tls or tailnet, not both", 2) end
    -- Required here, so an app that serves no tailnet loads no client of
    -- tailscaled.
    local Tailnet = require("cosmic.web.tailnet")
    local reached, why = Tailnet.serving(if tailnet is boolean then {} else tailnet end)
    if reached == nil then return false, why end
    for _, address in ipairs(reached.listeners) do listeners[#listeners + 1] = address end
    tls = reached.certs
    put_up, unplace, socket, forwarded = reached.put_up, reached.cleanup, reached.socket, reached.caps
  end
  -- Every address served, `clear`'s too, for the loopback checks below.
  local everywhere: mut {Net.Address} = { table.unpack(listeners) }
  for _, address in ipairs(clear or {}) do everywhere[#everywhere + 1] = address end
  if app.spec.dev == true then
    if app.proxies ~= nil then
      return declined("web: an app in development mode (Dev.app) cannot also have a trusted_proxy")
    end
    sink:line("development mode: stacks are shown and pages reload; serving on the loopback only")
    for _, address in ipairs(everywhere) do
      if not Net.is_loopback(address) then
        return declined("web: an app in development mode (Dev.app) serves only on the loopback")
      end
    end
  end
  if app.spec.debug == true then
    for _, address in ipairs(everywhere) do
      if not Net.is_loopback(address) then
        sink:line("debug is on and the app listens beyond the loopback: " ..
            "a fault shows its stack to whoever asks")
        break
      end
    end
  end
  app.stopped = false
  app.stream_limit = app.spec.max_streams or ((opts.limits or {}).connections or 256) // 2
  local shutdown: Types.Shutdown? = nil
  local lifespan = app.spec.lifespan
  if lifespan ~= nil then
    local cleanup, why = lifespan(app)
    if cleanup == nil and why ~= nil and why ~= "" then return declined(why) end -- checked: compare_disjoint
    shutdown = cleanup
  end
  local served = { ok = false, err = "" }
  local filed: Tailscale.Serving? = nil
  local refusal = ""
  local on_ready = opts.on_ready
  local function ready(addresses: {Net.Address}, server: Net.Server)
    if put_up ~= nil then
      local made, refused = put_up()
      if made == nil then
        refusal = refused
        server:stop()
        return
      end
      filed = made
      app.serve_socket = socket
      app.serve_caps = forwarded
    end
    if on_ready ~= nil then on_ready(addresses, server) end
  end
  -- TODO: once Server.ServeSpec has an `on_start` run in a task before the
  -- listeners open, run the lifespan there, so it may wait on Poll.
  local ran, raised = pcall(function()
    served.ok, served.err = Server.serve({
      listeners = listeners, clear = clear, limits = opts.limits, tls = tls, timeout_ns = opts.timeout_ns,
      idle_ns = opts.idle_ns, head_ns = opts.head_ns, body_ns = opts.body_ns,
      grace_ns = opts.grace_ns or GRACE_NS, on_ready = ready, handle = handle,
      on_stop = function(server: Net.Server)
        app.stopped = true
        -- The daemon stops sending requests before those in flight drain.
        local made = filed
        if made ~= nil then
          local closed, why = made:close()
          if not closed then sink:line("tailnet: taking down the Serve configuration: " .. why) end
        end
        for _, fn in ipairs(app.stoppers) do
          local trouble = raised_by(fn)
          if trouble ~= nil then sink:line("on_stop: " .. trouble) end
        end
        for _, hub in ipairs(assert(app.spec.hubs)) do
          local trouble = raised_by(function() hub:close() end)
          if trouble ~= nil then sink:line("on_stop: " .. trouble) end
        end
        local open: mut {function()} = {}
        for _, close in pairs(app.streams) do open[#open + 1] = close end
        for _, close in ipairs(open) do
          local trouble = raised_by(close)
          if trouble ~= nil then sink:line("on_stop: " .. trouble) end
        end
        if opts.on_stop ~= nil then opts.on_stop(server) end
      end,
      on_error = function(trouble: string) sink:line(trouble) end,
    })
  end)
  local made = filed
  if made ~= nil then local _, _ = made:close() end
  app.serve_socket = nil
  app.serve_caps = nil
  local undo = unplace
  if undo ~= nil then undo() end
  if shutdown ~= nil then
    local trouble = raised_by(shutdown)
    if trouble ~= nil then sink:line("lifespan cleanup: " .. trouble) end
  end
  if not ran then error(raised, 0) end
  if not served.ok then return false, served.err end
  -- A configuration the daemon refused stops the server, which then
  -- answers as stopped.
  if refusal ~= "" then return false, refusal end
  return true, ""
end

return App

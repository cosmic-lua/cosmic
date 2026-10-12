--- An app: the routes compiled, the middleware folded around the router, the
--- handler that answers a server's request, and [`App.serve`], which runs
--- it over [`cosmic.http.server`] with its lifespan and graceful stop.

local Builtin = require("cosmic.web.builtin")
local Clock = require("cosmic.clock")
local Errors = require("cosmic.web.errors")
local Middleware = require("cosmic.web.middleware")
local Net = require("cosmic.net")
local Request = require("cosmic.web.request")
local Router = require("cosmic.web.router")
local Server = require("cosmic.http.server")
local Types = require("cosmic.web.types")

--- The value of a `<close>` variable: only its `__close` matters.
local record Closing
  metamethod __close: function(Closing)
end

--- What a request's handler answered, where the closer of its bodies can
--- read it: a closure assigns a variable the checker narrows to nil.
local record Answered
  reply?: Types.Response
end

local record App
end

local SPEC_FIELDS <const>: {string:boolean} = {
  routes = true, middleware = true, lifespan = true, debug = true, trailing_slash = true,
  trusted_hosts = true, trusted_proxy = true, error_pages = true, error_view = true, sink = true,
  builtin = true,
  hubs = true, max_streams = true, dev = true,
}

local SERVE_FIELDS <const>: {string:boolean} = {
  listeners = true, limits = true, timeout_ns = true, idle_ns = true, head_ns = true,
  body_ns = true, grace_ns = true, on_ready = true, on_stop = true,
}

--- How long requests in flight have to finish once the server stops.
local GRACE_NS <const> = Clock.seconds(10)

--- The streams an app allows when it is not served: half the server's
--- default of 256 connections.
local DEFAULT_STREAM_LIMIT <const> = 128

--- Raises where `spec` is no table or holds a field `known` lacks.
local function checked(spec: any, known: {string:boolean}, what: string)
  if not spec is {any:any} then error("web: " .. what .. " takes a table", 3) end
  for key in pairs(spec) do
    if not (key is string and known[key]) then
      error(("web: %s has no field %s"):format(what, tostring(key)), 3)
    end
  end
end

--- Whether `address` is on the loopback: a unix socket, `::1` or a dotted
--- 127/8 address (not a name that merely starts with "127.").
local function loopback(address: Net.Address): boolean
  return address.kind == "unix" or address.host == "::1" or
    assert(address.host):find("^127%.%d+%.%d+%.%d+$") ~= nil
end

--- What `fn` raised, or nil when it returned.
local function raised_by(fn: function()): string | nil
  local ok, err = pcall(function(): any
    fn()
    return nil
  end)
  if ok then return nil end
  return tostring(err)
end

local function url_for(self: Types.App, name: string, params?: {string: string | integer},
                       query?: {string:string}): string | nil, string
  return self.router:reverse(name, params, query)
end

local function stopping(self: Types.App): boolean
  return self.stopped
end

local function on_stop(self: Types.App, fn: function())
  if type(fn) ~= "function" then error("web: on_stop takes a function", 2) end
  self.stoppers[#self.stoppers + 1] = fn
end

local app_methods = { url_for = url_for, stopping = stopping, on_stop = on_stop }
local app_mt: metatable<Types.App> = { __index = app_methods }

--- Compiles `spec` into an app. Raises, naming it, for a field of the
--- wrong shape or one `spec` should not have, and for a route that cannot
--- be registered ([`Web.router`]).
--- @param spec Types.AppSpec What the app is made of
--- @return Types.App The app
function App.new(spec: Types.AppSpec): Types.App
  checked(spec, SPEC_FIELDS, "app")
  local sink: Types.Sink = spec.sink or Middleware.stderr_sink()
  local hubs: {Types.Closable} = spec.hubs or {}
  local routes: {Types.Route} = spec.routes or {}
  local middleware: {Types.Middleware} = spec.middleware or {}
  local kept: Types.AppSpec = {
    routes = routes, middleware = middleware, lifespan = spec.lifespan,
    debug = spec.debug == true, trailing_slash = spec.trailing_slash,
    trusted_proxy = spec.trusted_proxy == true, error_pages = spec.error_pages,
    error_view = spec.error_view, sink = sink,
    builtin = spec.builtin ~= false,
    hubs = hubs, max_streams = spec.max_streams, dev = spec.dev == true,
  }
  if kept.max_streams ~= nil and (math.type(kept.max_streams) ~= "integer" or kept.max_streams < 0) then
    error("web: max_streams must be a non-negative integer", 2)
  end
  for _, hub in ipairs(hubs) do
    if type(hub) ~= "table" or type(hub.close) ~= "function" then
      error("web: hubs holds only what has a close method", 2)
    end
  end
  local trusted: {string:boolean} | nil = nil
  if spec.trusted_hosts ~= nil then
    trusted = {}
    local hosts: {string} = {}
    kept.trusted_hosts = hosts
    for i, host in ipairs(spec.trusted_hosts) do
      local parsed = type(host) == "string" and Request.parse_host(host) or nil
      if parsed == nil or parsed.port ~= nil then
        error(("web: trusted_hosts: %q is not a host name without a port"):format(tostring(host)), 2)
      end
      trusted[parsed.host] = true
      hosts[i] = parsed.host
    end
  end
  local router = Router.build(routes, Errors.terminal, kept.trailing_slash, kept.builtin)
  local app: Types.App = { spec = kept, state = {}, router = router, stopped = false, stoppers = {},
    streams = {}, stream_count = 0, stream_limit = kept.max_streams or DEFAULT_STREAM_LIMIT }
  local function dispatch(req: Types.Request): Types.Response
    local given = req.outcome
    if given == nil and kept.builtin then
      -- Ahead of the routes, so that a catch-all cannot shadow the files.
      local served = Builtin.handle(req)
      if served ~= nil then return served end
    end
    local outcome = given or Router.lookup(router, req.method, req.segments, req.trailing)
    req.outcome = outcome
    if outcome.kind == "match" then
      req.params = outcome.params
      req.route = outcome.route
    end
    req.mount_path = outcome.mount_path
    return outcome.handler(req)
  end
  local stack = Middleware.compose(middleware, Errors.wrap(dispatch))
  app.handle = function(raw: Server.Request): Types.Response
    local parts: Request.Parts = { path = "/", segments = {}, trailing = false }
    local outcome: Types.Outcome | nil = nil
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
      local named = req.host ~= nil and Request.parse_host(req.host) or nil
      if named == nil or not trusted[named.host] then
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
    local closing_mt: metatable<Closing> = { __close = function()
      for _, body in ipairs(req.bodies) do
        local reply = answered.reply
        if reply == nil or reply.body ~= body then
          local _, _ = body:close()
        end
      end
    end }
    local _closing <close>: Closing = setmetatable({}, closing_mt)
    local ok, raised = pcall(function() answered.reply = stack(req) end)
    if not ok then error(raised, 0) end
    local reply = answered.reply
    -- Out of contract (a middleware that returns nothing): the server
    -- answers 500 for the raise, as it did for the nil it was given.
    if reply == nil then error("web: the handler stack answered no Response", 0) end
    return reply
  end
  return setmetatable(app, app_mt)
end

--- Runs `app` over [`Server.serve`]: its lifespan first, then the server
--- until it stops, then the lifespan's cleanup. See [`Web.serve`].
--- @param app Types.App The app
--- @param opts Types.ServeOptions Where and how
--- @return boolean Whether the server stopped cleanly
--- @return string Why not
function App.serve(app: Types.App, opts: Types.ServeOptions): boolean, string
  checked(opts, SERVE_FIELDS, "serve")
  local sink = assert(app.spec.sink)
  if app.spec.dev then
    if app.spec.trusted_proxy then
      return false, "web: an app in development mode (Dev.app) cannot also have a trusted_proxy"
    end
    sink:line("development mode: stacks are shown and pages reload; serving on the loopback only")
    for _, address in ipairs(opts.listeners or {}) do
      if not loopback(address) then
        return false, "web: an app in development mode (Dev.app) serves only on the loopback"
      end
    end
  end
  if app.spec.debug then
    for _, address in ipairs(opts.listeners or {}) do
      if not loopback(address) then
        sink:line("debug is on and the app listens beyond the loopback: " ..
            "a fault shows its stack to whoever asks")
        break
      end
    end
  end
  app.stopped = false
  app.stream_limit = app.spec.max_streams or ((opts.limits or {}).connections or 256) // 2
  local shutdown: Types.Shutdown | nil = nil
  if app.spec.lifespan ~= nil then
    local cleanup, why = app.spec.lifespan(app)
    if cleanup == nil and why ~= nil and why ~= "" then return false, why end
    shutdown = cleanup
  end
  local ok, err = false, ""
  -- TODO: once Server.ServeSpec has an `on_start` run in a task before the
  -- listeners open, run the lifespan there, so it may wait on Poll.
  local ran, raised = pcall(function()
    ok, err = Server.serve({
      listeners = opts.listeners, limits = opts.limits, timeout_ns = opts.timeout_ns,
      idle_ns = opts.idle_ns, head_ns = opts.head_ns, body_ns = opts.body_ns,
      grace_ns = opts.grace_ns or GRACE_NS, on_ready = opts.on_ready, handle = app.handle,
      on_stop = function(server: Net.Server)
        app.stopped = true
        for _, fn in ipairs(app.stoppers) do
          local trouble = raised_by(fn)
          if trouble ~= nil then sink:line("on_stop: " .. trouble) end
        end
        for _, hub in ipairs(assert(app.spec.hubs)) do
          local trouble = raised_by(function() hub:close() end)
          if trouble ~= nil then sink:line("on_stop: " .. trouble) end
        end
        local open: {function()} = {}
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
  if shutdown ~= nil then
    local trouble = raised_by(shutdown)
    if trouble ~= nil then sink:line("lifespan cleanup: " .. trouble) end
  end
  if not ran then error(raised, 0) end
  if not ok then return false, err end
  return true, ""
end

return App

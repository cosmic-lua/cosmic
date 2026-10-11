--- An app: the routes compiled, the middleware folded around the router, the
--- handler that answers a server's request, and [`App.serve`], which runs
--- it over [`cosmic.http.server`] with its lifespan and graceful stop.

local Clock = require("cosmic.clock")
local Errors = require("cosmic.web.errors")
local Middleware = require("cosmic.web.middleware")
local Net = require("cosmic.net")
local Request = require("cosmic.web.request")
local Router = require("cosmic.web.router")
local Server = require("cosmic.http.server")
local Types = require("cosmic.web.types")

local record App
end

local SPEC_FIELDS <const>: {string:boolean} = {
  routes = true, middleware = true, lifespan = true, debug = true, trailing_slash = true,
  trusted_hosts = true, trusted_proxy = true, error_pages = true, error_view = true, sink = true,
}

local SERVE_FIELDS <const>: {string:boolean} = {
  listeners = true, limits = true, timeout_ns = true, idle_ns = true, head_ns = true,
  body_ns = true, grace_ns = true, on_ready = true, on_stop = true,
}

--- How long requests in flight have to finish once the server stops.
local GRACE_NS <const> = Clock.seconds(10)

--- Raises where `spec` is no table or holds a field `known` lacks.
local function checked(spec: any, known: {string:boolean}, what: string)
  if not spec is {any:any} then error("web: " .. what .. " takes a table", 3) end
  for key in pairs(spec) do
    if not (key is string and known[key]) then
      error(("web: %s has no field %s"):format(what, tostring(key)), 3)
    end
  end
end

--- Whether `address` is on the loopback.
local function loopback(address: Net.Address): boolean
  return address.kind == "unix" or address.host:find("^127%.") ~= nil or address.host == "::1"
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

local app_mt: metatable<Types.App> = {
  __index = { url_for = url_for, stopping = stopping, on_stop = on_stop },
}

--- Compiles `spec` into an app. Raises, naming it, for a field of the
--- wrong shape or one `spec` should not have, and for a route that cannot
--- be registered ([`Web.router`]).
--- @param spec Types.AppSpec What the app is made of
--- @return Types.App The app
function App.new(spec: Types.AppSpec): Types.App
  checked(spec, SPEC_FIELDS, "app")
  local kept: Types.AppSpec = {
    routes = spec.routes or {}, middleware = spec.middleware or {}, lifespan = spec.lifespan,
    debug = spec.debug == true, trailing_slash = spec.trailing_slash,
    trusted_proxy = spec.trusted_proxy == true, error_pages = spec.error_pages,
    error_view = spec.error_view, sink = spec.sink or Middleware.stderr_sink(),
  }
  local trusted: {string:boolean} = nil
  if spec.trusted_hosts ~= nil then
    trusted = {}
    kept.trusted_hosts = {}
    for i, host in ipairs(spec.trusted_hosts) do
      local parsed = type(host) == "string" and Request.parse_host(host) or nil
      if parsed == nil or parsed.port ~= nil then
        error(("web: trusted_hosts: %q is not a host name without a port"):format(tostring(host)), 2)
      end
      trusted[parsed.host] = true
      kept.trusted_hosts[i] = parsed.host
    end
  end
  local app: Types.App = { spec = kept, state = {}, stopped = false, stoppers = {} }
  local router = Router.build(kept.routes, Errors.terminal, kept.trailing_slash)
  app.router = router
  local function dispatch(req: Types.Request): Types.Response
    local outcome = req.outcome
    if outcome == nil then
      outcome = Router.lookup(router, req.method, req.segments, req.trailing)
      req.outcome = outcome
    end
    if outcome.kind == "match" then
      req.params = outcome.params
      req.route = outcome.route
    end
    req.mount_path = outcome.mount_path
    return outcome.handler(req)
  end
  local stack = Middleware.compose(kept.middleware, Errors.wrap(dispatch))
  app.handle = function(raw: Server.Request): Types.Response
    local parts: Request.Parts = { path = "/", segments = {}, trailing = false }
    local outcome: Types.Outcome = nil
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
    return stack(req)
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
  local sink = app.spec.sink
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
  local shutdown: Types.Shutdown = nil
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

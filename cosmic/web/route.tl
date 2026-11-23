--- The constructors of routes and mounts: plain data that a router is
--- built from, so a table of them can be returned from a module, joined and
--- generated.
--- @public

local Types = require("cosmic.web.types")

local record Route
end

--- [`Route.route`]'s work: a typed handler that does not suit the route raises at `level`, the caller of the
--- function that called this one.
local function made(level: integer, methods: string | {string}, pattern: string, handler: Types.Handles,
                    opts?: Types.RouteOptions): Types.Route
  local list: mut {string} = {}
  if methods is string then
    list[1] = methods
  else
    for i, method in ipairs(methods) do list[i] = method end
  end
  local plain: Types.Handler
  local input: Types.RouteInput? = nil
  if handler is Types.TypedHandler then
    local ok, bound = pcall(handler.bind, list, pattern, opts)
    if not ok then
      -- The message, without the position of the line that raised it inside the binding.
      local message = tostring(bound):gsub("^[^:\n]+:%d+: ", "")
      error(message, level)
    end
    plain, input = bound.handler, bound.input
  else
    plain = handler
  end
  return { methods = list, pattern = pattern, handler = plain, input = input,
    name = opts and opts.name or "", middleware = opts and opts.middleware or {} }
end

--- A route answering `methods` at `pattern`. Patterns are written without
--- a trailing slash (but for "/"): `/items/:id` matches one segment, named
--- `id`; `/static/*path` matches the rest, possibly nothing. A segment is
--- all literal or all parameter. Registration errors are raised when the
--- routes are compiled, naming the pattern.
--- @param methods string | {string} A method, or several, in capitals
--- @param pattern string The pattern
--- @param handler Types.Handles Answers a request: a plain handler, or a typed one ([`Web.typed`]), whose input
---   the route reads before it runs
--- @param opts RouteOptions | nil Its name and middleware
--- @return Types.Route The route
function Route.route(methods: string | {string}, pattern: string, handler: Types.Handles,
                     opts?: Types.RouteOptions): Types.Route
  local route = made(3, methods, pattern, handler, opts)
  return route
end

--- A route answering GET, and HEAD with the same handler: for a page or a
--- read. See [`Web.route`] for the patterns.
function Route.get(pattern: string, handler: Types.Handles, opts?: Types.RouteOptions): Types.Route
  local route = made(3, "GET", pattern, handler, opts)
  return route
end

--- A route answering POST: for what a form submits and for an action that
--- creates.
function Route.post(pattern: string, handler: Types.Handles, opts?: Types.RouteOptions): Types.Route
  local route = made(3, "POST", pattern, handler, opts)
  return route
end

--- A route answering PUT: it replaces the thing at the URL whole.
function Route.put(pattern: string, handler: Types.Handles, opts?: Types.RouteOptions): Types.Route
  local route = made(3, "PUT", pattern, handler, opts)
  return route
end

--- A route answering PATCH: it changes part of the thing at the URL.
function Route.patch(pattern: string, handler: Types.Handles, opts?: Types.RouteOptions): Types.Route
  local route = made(3, "PATCH", pattern, handler, opts)
  return route
end

--- A route answering DELETE: it removes the thing at the URL.
function Route.delete(pattern: string, handler: Types.Handles, opts?: Types.RouteOptions): Types.Route
  local route = made(3, "DELETE", pattern, handler, opts)
  return route
end

--- Everything under `prefix` goes to the router made of `routes`, which sees
--- the rest of the path. The prefix is literal segments. Once it matches,
--- the mount's router answers, 404 included: nothing falls through to a
--- route beside the mount, and registering one there raises. The mount's
--- middleware wraps its whole router. A named mount prefixes its routes'
--- names with "name:"; an unnamed one leaves them as they are.
--- @param prefix string The prefix, "/api"
--- @param routes {Types.Route} The routes below it
--- @param opts MountOptions | nil Its name and middleware
--- @return Types.Route The mount
function Route.mount(prefix: string, routes: {Types.Route}, opts?: Types.MountOptions): Types.Route
  return { methods = {}, pattern = prefix, routes = routes, name = opts and opts.name or "",
    middleware = opts and opts.middleware or {}, reverse = opts and opts.reverse }
end

-- TODO: a Web.mount_app(prefix, app) once App exposes a handler that takes a
-- Request and respects `mount_path` (App.handle takes the server's request and
-- reads the whole path), so another app can be mounted under a prefix.
--- Everything under `prefix` goes to `handler`, which reads the rest of the
--- path from `req.segments`, after those of `req.mount_path`. `opts.reverse`
--- answers `url_for` of the mount's name.
--- @param prefix string The prefix, "/legacy"
--- @param handler Types.Handler Answers every request below the prefix
--- @param opts MountOptions | nil Its name, middleware and resolver
--- @return Types.Route The mount
function Route.mount_handler(prefix: string, handler: Types.Handler, opts?: Types.MountOptions): Types.Route
  return { methods = {}, pattern = prefix, fallback = handler, name = opts and opts.name or "",
    middleware = opts and opts.middleware or {}, reverse = opts and opts.reverse }
end

return Route

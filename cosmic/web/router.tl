--- The router: patterns compiled to a trie of segments, a lookup that
--- prefers the most specific route whatever the order they were declared
--- in, canonical paths, and reverse routing.

local Html = require("cosmic.html")
local Middleware = require("cosmic.web.middleware")
local Types = require("cosmic.web.types")
local Url = require("cosmic.url")

local record Router
  --- A path made canonical: see [`Router.canonical`].
  record Canon
    --- The canonical path, still escaped: it starts with one "/", holds no
    --- empty and no "." segment, and ends in "/" only after a segment.
    path: string
    --- Its decoded segments.
    segments: {string}
    --- Whether it ends in "/" after a segment.
    trailing: boolean
    --- Whether the path sent differs from `path` in more than its
    --- escapes: it held an empty or "." segment.
    changed: boolean
  end

  --- What a constructor of a router is given beyond its routes.
  record Context
    --- The trailing-slash policy.
    policy: Types.TrailingSlash
    --- Answers a request no route takes: the innermost handler of every
    --- miss.
    terminal: Types.Handler
    --- The handler for a request this level cannot route: the terminal
    --- inside the middleware of the mounts around this level.
    miss: Types.Handler
    --- The middleware of the mounts around this level, outermost first.
    chain: {Types.Middleware}
    --- The segments of the mounts' prefixes.
    prefix: {string}
    --- The prefix of the mount that holds this level, as text.
    mount_path: string
    --- What a route's name is prefixed with: "api:".
    name_prefix: string
    --- The names of the whole tree.
    names: {string: Types.ReverseEntry}
    --- The methods of the whole tree.
    verbs: {string:boolean}
  end
end

--- The prefix under which cosmic.web serves its own assets: no route of
--- an app may be at or under it, by its full path (a mount's prefix and the
--- pattern): `/x/_web/a` inside a mount at `/x` is the app's. A catch-all
--- at the root (`/*p`, `/:x`, a mount of "/") is allowed.
-- TODO: once cosmic.web serves its own assets under /_web/, the router tries
-- that prefix before the app's routes, so a root catch-all cannot shadow them.
local RESERVED <const> = "_web"

--- A parameter's name.
local NAME <const> = "^[A-Za-z_][A-Za-z0-9_]*$"

--- A method as a route names it.
local METHOD <const> = "^[A-Z][A-Z0-9_-]*$"

--- The text of the canonical path of `segments`, with a trailing slash
--- where `slash` says and a segment precedes it.
local function path_of(segments: {string}, slash: boolean): string
  if #segments == 0 then return "/" end
  local escaped: {string} = {}
  for i, segment in ipairs(segments) do escaped[i] = Url.escape(segment) end
  return "/" .. table.concat(escaped, "/") .. (slash and "/" or "")
end

--- `path` in its canonical form, or nil and why when it is refused: not an
--- absolute path, a malformed escape, a segment of `..`, and an escaped
--- "/" or NUL ([`Url.segments`]). Empty and "." segments are dropped, which
--- `changed` says; the escapes of a segment are written again as
--- [`Url.escape`] writes them, which `changed` does not count.
--- @param path string The request's path as sent
--- @return Router.Canon | nil The canonical path
--- @return string Why it is refused
function Router.canonical(path: string): Router.Canon | nil, string
  local segments, why = Url.segments(path)
  if segments == nil then return nil, why end
  local rest = path:sub(2)
  local _, slashes = rest:gsub("/", "/")
  local last_empty = rest == "" or rest:sub(-1) == "/"
  local kept = last_empty and slashes or slashes + 1
  local trailing = last_empty and #segments > 0
  return { path = path_of(segments, trailing), segments = segments, trailing = trailing,
    changed = kept ~= #segments }, ""
end

--- A pattern read: its segments, whether it ends in "/", and the names of
--- its parameters in order; or nil and why.
local record Parsed
  segments: {Types.Segment}
  slash: boolean
  names: {string}
  wild: boolean
end

--- Reads `pattern`. Literal segments are decoded text; `:name` is one
--- segment, `*name` the rest and last; a segment mixes none of these.
local function parse(pattern: string, mount: boolean): Parsed | nil, string
  if pattern:sub(1, 1) ~= "/" then return nil, "the pattern must start with '/'" end
  if pattern:find("[%z\1-\31\127]") then return nil, "the pattern holds a control byte" end
  local parsed: Parsed = { segments = {}, slash = false, names = {}, wild = false }
  if pattern == "/" then return parsed, "" end
  local rest = pattern:sub(2)
  if rest:sub(-1) == "/" then
    parsed.slash = true
    rest = rest:sub(1, -2)
  end
  local seen: {string:boolean} = {}
  local at = 1
  while at <= #rest + 1 do
    local slash = rest:find("/", at, true) or #rest + 1
    local piece = rest:sub(at, slash - 1)
    if piece == "" then return nil, "the pattern holds an empty segment" end
    if parsed.wild then return nil, "'*name' must be the last segment" end
    local first = piece:sub(1, 1)
    if first == ":" or first == "*" then
      local name = piece:sub(2)
      if not name:find(NAME) then
        return nil, ("'%s' is not a parameter name (letters, digits and '_', not starting with a digit)"):
          format(piece)
      end
      if mount then return nil, "a mount's prefix holds no parameter" end
      if seen[name] then return nil, ("the parameter '%s' is named twice"):format(name) end
      seen[name] = true
      parsed.names[#parsed.names + 1] = name
      if first == "*" then
        parsed.wild = true
        parsed.segments[#parsed.segments + 1] = { kind = "rest", text = name }
      else
        parsed.segments[#parsed.segments + 1] = { kind = "param", text = name }
      end
    else
      if piece:find(":", 1, true) or piece:find("*", 1, true) then
        return nil, ("the segment '%s' mixes text with a parameter"):format(piece)
      end
      if piece == "." or piece == ".." then
        return nil, ("the segment '%s' can never match a canonical path"):format(piece)
      end
      parsed.segments[#parsed.segments + 1] = { kind = "literal", text = piece }
    end
    at = slash + 1
  end
  if parsed.wild then parsed.slash = false end
  return parsed, ""
end

--- A new node.
local function new_node(): Types.Node
  return { literal = {} }
end

--- Whether `node` holds nothing.
local function empty(node: Types.Node): boolean
  return next(node.literal) == nil and node.param == nil and node.exact == nil and
    node.wild == nil and node.mount == nil
end

--- The text of a pattern's segments: "/items/:id".
local function pattern_text(segments: {Types.Segment}, slash: boolean): string
  local out: {string} = {}
  for i, segment in ipairs(segments) do
    out[i] = segment.kind == "literal" and segment.text or
      (segment.kind == "param" and ":" or "*") .. segment.text
  end
  return "/" .. table.concat(out, "/") .. (slash and #out > 0 and "/" or "")
end

--- Raises for a route that cannot be registered, naming `what`.
local function refuse(what: string, why: string)
  error(("web: route %s: %s"):format(what, why), 4)
end

--- The node `segments` lead to from `root`, made on the way. Raises where
--- a mount stands on the way: its routes would never be reached.
local function descend(root: Types.Node, segments: {Types.Segment}, what: string): Types.Node
  local node = root
  for _, segment in ipairs(segments) do
    if node.mount ~= nil then
      refuse(what, ("it is under the mount at %s, which answers every path below it"):format(node.mount.prefix))
    end
    if segment.kind == "literal" then
      local child = node.literal[segment.text]
      if child == nil then
        child = new_node()
        node.literal[segment.text] = child
      end
      node = child
    elseif segment.kind == "param" then
      if node.param == nil then node.param = new_node() end
      node = node.param
    else
      return node
    end
  end
  if node.mount ~= nil then
    refuse(what, ("it is under the mount at %s, which answers every path below it"):format(node.mount.prefix))
  end
  return node
end

--- Adds `entry` under `full` to `names`, raising where the name is taken.
local function name_it(names: {string: Types.ReverseEntry}, full: string, entry: Types.ReverseEntry,
                       what: string)
  if names[full] ~= nil then
    refuse(what, ("the name '%s' is already used"):format(full))
  end
  names[full] = entry
end

--- The segments of the prefix of the router built so far plus `segments`.
local function joined(prefix: {string}, segments: {Types.Segment}): {Types.Segment}
  local out: {Types.Segment} = {}
  for i, text in ipairs(prefix) do out[i] = { kind = "literal", text = text } end
  for _, segment in ipairs(segments) do out[#out + 1] = segment end
  return out
end

--- Whether the path of `segments` below the mounts' `prefix` starts with
--- the reserved segment.
local function reserved(prefix: {string}, segments: {Types.Segment}): boolean
  if prefix[1] ~= nil then return prefix[1] == RESERVED end
  return segments[1] ~= nil and segments[1].kind == "literal" and segments[1].text == RESERVED
end

local compile: function(routes: {Types.Route}, ctx: Router.Context, root: Types.Node)

--- Adds a leaf route to the trie.
local function add_leaf(route: Types.Route, ctx: Router.Context, root: Types.Node)
  local pattern = route.pattern
  local parsed, why = parse(pattern, false)
  if parsed == nil then
    refuse(("%q"):format(tostring(pattern)), why)
    return
  end
  local segments, names, slash, wild = parsed.segments, parsed.names, parsed.slash, parsed.wild
  local what = ("%q"):format(pattern)
  if type(route.handler) ~= "function" then refuse(what, "it has no handler") end
  if #route.methods == 0 then refuse(what, "it names no method") end
  if reserved(ctx.prefix, segments) then
    -- TODO: once cosmic.web serves its own assets under /_web/, Web.app
    -- registers them through an option that lifts this for its own routes.
    refuse(what, "/_web/ is reserved for cosmic.web's own assets")
  end
  local node = descend(root, segments, what)
  local slot: Types.Methods
  if wild then
    if node.wild == nil then node.wild = { by_method = {} } end
    slot = node.wild
  else
    if node.exact == nil then node.exact = { by_method = {} } end
    slot = node.exact
  end
  local full_segments = joined(ctx.prefix, segments)
  local full_pattern = pattern_text(full_segments, slash)
  local stack: {Types.Middleware} = {}
  for _, mw in ipairs(ctx.chain) do stack[#stack + 1] = mw end
  for _, mw in ipairs(route.middleware or {}) do stack[#stack + 1] = mw end
  local handler = Middleware.compose(stack, route.handler)
  local full_name = route.name ~= "" and ctx.name_prefix .. route.name or ""
  local info: Types.RouteInfo = { name = full_name, pattern = full_pattern, methods = route.methods }
  for _, method in ipairs(route.methods) do
    if not method:find(METHOD) then
      refuse(what, ("%q is not a method in capitals"):format(method))
    end
    if slot.by_method[method] ~= nil then
      refuse(what, ("%s is already answered for the same paths by %s"):format(method,
        slot.by_method[method].info.pattern))
    end
    slot.by_method[method] = { info = info, names = names, slash = slash, handler = handler }
    ctx.verbs[method] = true
  end
  if full_name ~= "" then
    name_it(ctx.names, full_name, { segments = full_segments, slash = slash }, what)
  end
end

--- Adds a mount to the trie, compiling its routes into a router of their
--- own or taking its handler.
local function add_mount(route: Types.Route, ctx: Router.Context, root: Types.Node)
  local parsed, why = parse(route.pattern, true)
  if parsed == nil then
    refuse(("mount %q"):format(tostring(route.pattern)), why)
    return
  end
  local segments = parsed.segments
  local what = ("mount %q"):format(route.pattern)
  if reserved(ctx.prefix, segments) then
    refuse(what, "/_web/ is reserved for cosmic.web's own assets")
  end
  local node = descend(root, segments, what)
  if not empty(node) then
    refuse(what, "routes already stand at or under its prefix, which the mount answers")
  end
  local full_segments = joined(ctx.prefix, segments)
  local full_prefix = pattern_text(full_segments, false)
  local own: {Types.Middleware} = {}
  for _, mw in ipairs(ctx.chain) do own[#own + 1] = mw end
  for _, mw in ipairs(route.middleware or {}) do own[#own + 1] = mw end
  if route.name ~= "" and route.name:find(":", 1, true) then
    refuse(what, "a mount's name holds no ':'")
  end
  local mount: Types.Mount = { prefix = full_prefix }
  if route.fallback ~= nil then
    mount.handler = Middleware.compose(own, route.fallback)
    mount.info = { name = route.name ~= "" and ctx.name_prefix .. route.name or "",
      pattern = full_prefix == "/" and "/*" or full_prefix .. "/*", methods = {} }
  else
    local inner_prefix: {string} = {}
    for i, text in ipairs(ctx.prefix) do inner_prefix[i] = text end
    for _, part in ipairs(segments) do inner_prefix[#inner_prefix + 1] = part.text end
    local inner: Router.Context = {
      policy = ctx.policy, terminal = ctx.terminal, miss = Middleware.compose(own, ctx.terminal),
      chain = own,
      prefix = inner_prefix, mount_path = full_prefix,
      name_prefix = route.name ~= "" and ctx.name_prefix .. route.name .. ":" or ctx.name_prefix,
      names = ctx.names, verbs = ctx.verbs,
    }
    local sub: Types.Router = { root = new_node(), policy = ctx.policy, names = ctx.names,
      verbs = ctx.verbs, miss = inner.miss, mount_path = full_prefix }
    compile(route.routes, inner, sub.root)
    mount.router = sub
  end
  node.mount = mount
  if route.name ~= "" then
    name_it(ctx.names, ctx.name_prefix .. route.name,
      { mount = true, prefix = full_prefix, resolve = route.reverse }, what)
  end
end

compile = function(routes: {Types.Route}, ctx: Router.Context, root: Types.Node)
  for _, route in ipairs(routes) do
    if type(route) ~= "table" then
      error("web: routes must be built by Web.route, Web.mount and the like", 3)
    end
    if route.routes ~= nil or route.fallback ~= nil then
      add_mount(route, ctx, root)
    else
      add_leaf(route, ctx, root)
    end
  end
end

--- The nodes `segments` descend through to a route, most specific first:
--- a literal child, then the parameter child, then `*name`.
local record Hit
  methods?: Types.Methods
  values: {string}
  rest_from: integer
  mount?: Types.Mount
  at?: integer
end

--- What a walk carries: the method looked up, and the most specific node
--- the path reached that answers some other method.
local record Walk
  method: string
  other?: Hit
end

--- Whether `methods` answers `method` (HEAD by a GET).
local function answers(methods: Types.Methods, method: string): boolean
  return methods.by_method[method] ~= nil or (method == "HEAD" and methods.by_method["GET"] ~= nil)
end

--- The hit at `methods` for `walk`, or nil where it lacks the method; the
--- first such node is kept as the walk's `other`, for a 405 to name.
local function settle(walk_: Walk, methods: Types.Methods, values: {string}, rest_from: integer): Hit | nil
  if answers(methods, walk_.method) then
    return { methods = methods, values = values, rest_from = rest_from }
  end
  if walk_.other == nil then
    walk_.other = { methods = methods, values = {}, rest_from = rest_from }
  end
  return nil
end

local function walk(node: Types.Node, segments: {string}, i: integer, values: {string},
                    state: Walk): Hit | nil
  if node.mount ~= nil then
    return { mount = node.mount, at = i, values = values, rest_from = 0 }
  end
  if i > #segments then
    if node.exact ~= nil then
      local hit = settle(state, node.exact, values, 0)
      if hit ~= nil then return hit end
    end
    if node.wild ~= nil then return settle(state, node.wild, values, i) end
    return nil
  end
  local segment = segments[i]
  local child = node.literal[segment]
  if child ~= nil then
    local hit = walk(child, segments, i + 1, values, state)
    if hit ~= nil then return hit end
  end
  if node.param ~= nil then
    values[#values + 1] = segment
    local hit = walk(node.param, segments, i + 1, values, state)
    if hit ~= nil then return hit end
    values[#values] = nil
  end
  if node.wild ~= nil then
    return settle(state, node.wild, values, i)
  end
  return nil
end

--- The `Allow` header for the routes of `methods`: HEAD where there is a
--- GET, OPTIONS always.
local function allow_of(verbs: {string:boolean}): string
  local list: {string} = {}
  for method in pairs(verbs) do list[#list + 1] = method end
  if verbs["GET"] and not verbs["HEAD"] then list[#list + 1] = "HEAD" end
  if not verbs["OPTIONS"] then list[#list + 1] = "OPTIONS" end
  table.sort(list)
  return table.concat(list, ", ")
end

--- The methods answered at `methods`.
local function verbs_of(methods: Types.Methods): {string:boolean}
  local verbs: {string:boolean} = {}
  for method in pairs(methods.by_method) do verbs[method] = true end
  return verbs
end

--- Looks `segments`, from the `from`th, up in `router` for `method`. The
--- most specific route that answers the method wins: where the most
--- specific node answers others alone (`POST /files` beside `GET
--- /files/*r`) the lookup goes on to the next node that has the method, and
--- answers 405 (or the automatic OPTIONS) only where none does, with the
--- `Allow` of the most specific node the path reached.
--- @param router Types.Router The router, or a mount's
--- @param method string The request's method
--- @param segments {string} The canonical path's segments
--- @param trailing boolean Whether the path ends in "/" after a segment
--- @return Types.Outcome What to do
function Router.lookup(router: Types.Router, method: string, segments: {string}, trailing: boolean,
                       from?: integer): Types.Outcome
  local state: Walk = { method = method }
  local hit = walk(router.root, segments, from or 1, {}, state) or state.other
  if hit == nil then
    return { kind = "not_found", handler = router.miss, mount_path = router.mount_path }
  end
  local mount = hit.mount
  if mount ~= nil then
    if mount.router ~= nil then
      return Router.lookup(mount.router, method, segments, trailing, hit.at)
    end
    return { kind = "match", route = mount.info, params = {}, handler = mount.handler,
      mount_path = mount.prefix }
  end
  local methods = assert(hit.methods)
  local terminal = methods.by_method[method]
  if terminal == nil and method == "HEAD" then terminal = methods.by_method["GET"] end
  if terminal == nil then
    local allow = allow_of(verbs_of(methods))
    if method == "OPTIONS" then
      return { kind = "options", allow = allow, handler = router.miss, mount_path = router.mount_path }
    end
    return { kind = "not_allowed", allow = allow, handler = router.miss, mount_path = router.mount_path }
  end
  if hit.rest_from == 0 and terminal.slash ~= trailing then
    if router.policy == "strict" then
      return { kind = "not_found", handler = router.miss, mount_path = router.mount_path }
    end
    return { kind = "redirect", location = path_of(segments, terminal.slash), handler = router.miss,
      mount_path = router.mount_path }
  end
  local params: {string:string} = {}
  for i, name in ipairs(terminal.names) do
    if i <= #hit.values then
      params[name] = hit.values[i]
    else
      params[name] = table.concat(segments, "/", hit.rest_from, #segments)
    end
  end
  return { kind = "match", route = terminal.info, params = params, handler = terminal.handler,
    mount_path = router.mount_path }
end

--- The answer to `OPTIONS *`, which names no resource: 204 with every
--- method the app answers. Any other method is a bad request.
--- @param router Types.Router The router
--- @param method string The request's method
--- @return Types.Outcome What to do
function Router.star(router: Types.Router, method: string): Types.Outcome
  if method == "OPTIONS" then
    return { kind = "options", allow = allow_of(router.verbs), handler = router.miss, mount_path = "" }
  end
  return { kind = "bad_path", detail = "the target '*' is for OPTIONS alone", handler = router.miss,
    mount_path = "" }
end

--- The escaped form of one piece of a URL: [`Html.url_part`]'s.
local function raw_part(text: string): string
  return Html.raw_url_part(Html.url_part(text))
end

local function match(self: Types.Router, method: string, path: string): Types.Outcome
  if path == "*" then return Router.star(self, method) end
  local canon, why = Router.canonical(path)
  if canon == nil then
    return { kind = "bad_path", detail = why, handler = self.miss, mount_path = "" }
  end
  if canon.changed then
    return { kind = "redirect", location = canon.path, handler = self.miss, mount_path = "" }
  end
  return Router.lookup(self, method, canon.segments, canon.trailing)
end

local function reverse(self: Types.Router, name: string, params?: {string: string | integer},
                       query?: {string:string}): string | nil, string
  local entry = self.names[name]
  if entry == nil then return nil, ('url_for: no route named "%s"'):format(name) end
  local strings: {string:string} = {}
  for key, value in pairs(params or {}) do
    strings[key] = value is string and value or ("%d"):format(value)
  end
  local path: string
  if entry.mount then
    if entry.resolve == nil then return nil, ('url_for: mount "%s" has no reverse'):format(name) end
    local url, why = entry.resolve(entry.prefix, strings)
    if url == nil then return nil, why end
    path = url
  else
    local used: {string:boolean} = {}
    local parts: {string} = {}
    local open_rest = false
    for _, segment in ipairs(assert(entry.segments)) do
      if segment.kind == "literal" then
        parts[#parts + 1] = raw_part(segment.text)
      else
        local value = strings[segment.text]
        if value == nil then return nil, ('url_for "%s": missing %s'):format(name, segment.text) end
        used[segment.text] = true
        if segment.kind == "param" then
          if value == "" then
            return nil, ('url_for "%s": %s is empty'):format(name, segment.text)
          end
          parts[#parts + 1] = raw_part(value)
        elseif value == "" then
          open_rest = true
        else
          for piece in (value .. "/"):gmatch("([^/]*)/") do
            if piece == "" then
              return nil, ('url_for "%s": %s holds an empty segment'):format(name, segment.text)
            end
            parts[#parts + 1] = raw_part(piece)
          end
        end
      end
    end
    for key in pairs(strings) do
      if not used[key] then return nil, ('url_for "%s": unknown param %s'):format(name, key) end
    end
    path = "/" .. table.concat(parts, "/")
    if (entry.slash or open_rest) and #parts > 0 then path = path .. "/" end
  end
  if query ~= nil and next(query) ~= nil then
    local names: {string} = {}
    for key in pairs(query) do names[#names + 1] = key end
    table.sort(names)
    local entries: {{string}} = {}
    for i, key in ipairs(names) do entries[i] = { key, query[key] } end
    local part, why = Html.url_query(entries)
    if part == nil then return nil, "url_for: " .. why end
    path = path .. (path:find("?", 1, true) and "&" or "?") .. Html.raw_url_part(part)
  end
  return path, ""
end

local router_methods = { match = match, reverse = reverse }
local router_mt: metatable<Types.Router> = { __index = router_methods }

--- Compiles `routes` into a router. Raises, naming the pattern, for a route
--- or mount that cannot be registered: a pattern that is not valid, two
--- routes answering the same paths for one method, a name used twice, a
--- route under a mount's prefix, or one whose full path (a mount's prefix
--- and its pattern) starts with the reserved `/_web/`.
--- @param routes {Types.Route} The routes
--- @param terminal Types.Handler Answers a request no route takes
--- @param policy TrailingSlash | nil "redirect" (default) or "strict"
--- @return Types.Router The router
function Router.build(routes: {Types.Route}, terminal: Types.Handler, policy?: Types.TrailingSlash): Types.Router
  if policy ~= nil and policy ~= "redirect" and policy ~= "strict" then
    error("web: trailing_slash must be \"redirect\" or \"strict\"", 2)
  end
  local ctx: Router.Context = {
    policy = policy or "redirect", terminal = terminal, miss = terminal, chain = {}, prefix = {},
    mount_path = "", name_prefix = "", names = {}, verbs = {},
  }
  local router: Types.Router = { root = new_node(), policy = ctx.policy, names = ctx.names,
    verbs = ctx.verbs, miss = terminal, mount_path = "" }
  compile(routes, ctx, router.root)
  return setmetatable(router, router_mt)
end

return Router

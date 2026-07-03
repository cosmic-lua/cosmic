--- URL routing with path parameter capture.
--- Matches request method and path against registered routes.
--- Supports {param} placeholders in path patterns.
local types = require("cosmic.httpapi.types")

local type Handler = types.Handler

--- A compiled path segment: either a literal string or a parameter name.
local record Segment
  --- Literal text to match (nil for param segments).
  literal: string
  --- Parameter name to capture (nil for literal segments).
  param: string
end

--- A registered route.
local record Route
  method: string
  pattern: string
  segments: {Segment}
  handler: Handler
end

--- Compile a path pattern into segments.
--- Splits on "/" and identifies {param} placeholders.
--- @param pattern string URL pattern like "/users/{id}/posts"
--- @return {Segment} Compiled segments
local function compile(pattern: string): {Segment}
  local segments: {Segment} = {}
  for part in pattern:gmatch("[^/]+") do
    local param = part:match("^{(.+)}$")
    if param then
      table.insert(segments, {param = param})
    else
      table.insert(segments, {literal = part})
    end
  end
  return segments
end

--- Match a path against compiled segments.
--- @param segments {Segment} Compiled route segments
--- @param path string Request path to match
--- @return {string:string} Captured parameters, or nil if no match
local function match_path(segments: {Segment}, path: string): {string: string}
  -- Trailing slash means different path (except root)
  if #path > 1 and path:sub(#path) == "/" then
    return nil
  end
  local parts: {string} = {}
  for part in path:gmatch("[^/]+") do
    table.insert(parts, part)
  end
  if #parts ~= #segments then
    return nil
  end
  local params: {string: string} = {}
  for i = 1, #segments do
    local seg = segments[i]
    if seg.literal then
      if parts[i] ~= seg.literal then
        return nil
      end
    else
      params[seg.param] = parts[i]
    end
  end
  return params
end

--- Router that matches requests to handlers.
local record Router
  routes: {Route}
  --- Register a route.
  add: function(Router, string, string, Handler)
  --- Find a matching handler for a method and path.
  match: function(Router, string, string): Handler, {string: string}
end

--- Create a new router.
--- @return Router
local function new(): Router
  local r: Router = {routes = {}}

  r.add = function(self: Router, method: string, pattern: string, handler: Handler)
    local segments = compile(pattern)
    table.insert(self.routes, {
        method = method,
        pattern = pattern,
        segments = segments,
        handler = handler,
      })
  end

  function r:match(method: string, path: string): Handler, {string: string}
    -- Special case: root path "/" has zero segments
    local is_root = path == "/"
    for _, route in ipairs(self.routes) do
      if route.method == method then
        if is_root and route.pattern == "/" then
          return route.handler, {}
        end
        local params = match_path(route.segments, path)
        if params then
          return route.handler, params
        end
      end
    end
    return nil, nil
  end

  return r
end

return {
  Handler = Handler,
  Route = Route,
  Segment = Segment,
  Router = Router,
  compile = compile,
  match_path = match_path,
  new = new,
}

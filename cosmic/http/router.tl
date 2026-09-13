--- Method + path-pattern dispatch for cosmic.http, as a Handler.
--- `Router:handler()` returns an ordinary `cosmic.http.Handler`, so it
--- plugs into `Server:serve`/`serve_one` unchanged; a router is just
--- another way to write a handler, not a second thing a server knows
--- about.
---
--- Pattern grammar: a pattern is `/`-separated segments.
--- - a literal segment matches itself exactly ("todos")
--- - a `:name` segment matches exactly one non-empty segment (never a
---   `/`) and stores it in `req.params[name]`
--- - a trailing `*name` segment matches the rest of the path, joined
---   back with `/`; it may be empty, and it must be the LAST segment
---
--- A pattern is validated once, at registration: an empty segment (a
--- doubled or trailing `/`), a bare `:` with no name, a bare `*` with
--- no name, or a `*` anywhere but last are all refused there rather
--- than silently never matching. Registration therefore returns
--- `boolean, string` instead of throwing (library code never throws).
---
--- Matching is first-registered-wins, in source order: the first route
--- whose pattern matches the path AND whose method matches (or was
--- registered with `:any`) is the one that runs. A path that matches
--- some route's pattern under a different method answers 405 with an
--- `Allow` header listing every method registered for that pattern,
--- in registration order. Nothing matched answers 404, whose body
--- `Router:not_found` overrides. A `HEAD` request with no `HEAD` route
--- of its own falls back to the first matching `GET` route; the body
--- being empty on the wire is `cosmic.http.response`'s job (a `HEAD`
--- exchange's `Response` already suppresses body bytes), not this
--- module's.

local http = require("cosmic.http")
local request = require("cosmic.http.request")
local response = require("cosmic.http.response")

local type Request = request.Request
local type Response = response.Response

-- Aliased from cosmic.http rather than redeclared: two independently
-- written `function(req: Request, res: Response)` shapes are distinct
-- nominal types even when identical field-for-field (cosmic --docs
-- guide.gotchas, "records-are-nominal"), so a router built from a
-- locally-declared Handler could never be handed to Server:serve.
local type Handler = http.Handler

--- One compiled pattern segment.
local record Segment
  --- "literal", "param" or "wildcard".
  kind: string
  --- The parameter name, for "param" and "wildcard" segments.
  name: string
  --- The literal text to match, for "literal" segments.
  value: string
end

--- One registered route: a method, its compiled pattern, and its handler.
local record Route
  --- The uppercase method this route answers, or "*" for `:any`.
  method: string
  segments: {Segment}
  handler: Handler
end

--- A method + path-pattern router.
local record Router
  get: function(self: Router, pattern: string, h: Handler): boolean, string
  post: function(self: Router, pattern: string, h: Handler): boolean, string
  put: function(self: Router, pattern: string, h: Handler): boolean, string
  patch: function(self: Router, pattern: string, h: Handler): boolean, string
  delete: function(self: Router, pattern: string, h: Handler): boolean, string
  head: function(self: Router, pattern: string, h: Handler): boolean, string
  options: function(self: Router, pattern: string, h: Handler): boolean, string
  --- Register h for pattern under every method: the first route whose
  --- pattern matches wins regardless of the request's method.
  --- @param pattern string The path pattern (see the module doc)
  --- @param h Handler The handler to run on a match
  --- @return boolean True when the pattern was valid and the route was added
  --- @return string The pattern error, when the pattern was invalid
  any: function(self: Router, pattern: string, h: Handler): boolean, string
  --- Override the 404 body a fully unmatched request gets.
  --- @param h Handler The handler to run when nothing matched
  not_found: function(self: Router, h: Handler)
  --- The Handler to hand to `Server:serve`/`serve_one`.
  --- @return Handler The function that dispatches on method and path
  handler: function(self: Router): Handler
end

--- The default 404: a plain body, so a caller who never calls
--- `not_found` still gets a real answer rather than nothing.
--- @param _req Request Unused; every path reaches the same body
--- @param res Response The response to write 404 to
local function default_not_found(_req: Request, res: Response)
  res.status = 404
  local _ok, _err = res:text("Not Found\n")
end

--- Split a `/`-rooted string into its segments, preserving empties.
--- "/" and "" both yield no segments; "/a//b" yields {"a", "", "b"} so
--- a doubled slash is visible to the caller rather than silently
--- collapsed. A string with no leading "/" is split as it stands,
--- which is the same split a leading "/" would have produced after it.
--- @param s string The pattern or path to split
--- @return {string} Its segments, in order
local function segments_of(s: string): {string}
  local body = s:sub(1, 1) == "/" and s:sub(2) or s
  if body == "" then
    return {}
  end
  local parts: {string} = {}
  for part in (body .. "/"):gmatch("(.-)/") do
    parts[#parts + 1] = part
  end
  return parts
end

--- Compile one pattern into segments, or refuse it.
--- @param pattern string The path pattern (see the module doc)
--- @return {Segment} | nil The compiled segments, or nil when pattern is invalid
--- @return string The reason pattern was refused, on failure
local function compile_pattern(pattern: string): {Segment} | nil, string
  local parts = segments_of(pattern)
  local segs: {Segment} = {}
  for i, part in ipairs(parts) do
    if part == "" then
      return nil, "http.router: empty segment in pattern '" .. pattern .. "'"
    elseif part:sub(1, 1) == ":" then
      local name = part:sub(2)
      if name == "" then
        return nil,
        "http.router: ':' segment has no name in pattern '" .. pattern .. "'"
      end
      segs[i] = {kind = "param", name = name, value = ""}
    elseif part:sub(1, 1) == "*" then
      local name = part:sub(2)
      if name == "" then
        return nil,
        "http.router: '*' segment has no name in pattern '" .. pattern .. "'"
      end
      if i ~= #parts then
        return nil,
        "http.router: '*' segment must be last in pattern '" .. pattern .. "'"
      end
      segs[i] = {kind = "wildcard", name = name, value = ""}
    else
      segs[i] = {kind = "literal", name = "", value = part}
    end
  end
  return segs
end

--- Whether path_segs matches segs, and the params a match captured.
--- A "param" or "literal" segment never admits an empty actual segment
--- (the pattern grammar has no way to register a literal "" to match
--- one against, and `:name` is defined as one NON-EMPTY segment), so
--- one check ahead of the kind switch covers both.
--- @param segs {Segment} A route's compiled pattern
--- @param path_segs {string} The request path's segments
--- @return boolean True when every segment matched
--- @return {string: string} Captured params; meaningful only when true
local function match_segments(segs: {Segment}, path_segs: {string}): boolean, {string: string}
  local params: {string: string} = {}
  for i, seg in ipairs(segs) do
    if seg.kind == "wildcard" then
      params[seg.name] = table.concat(path_segs, "/", i)
      return true, params
    end
    local actual = path_segs[i]
    if actual == nil or actual == "" then
      return false, params
    end
    if seg.kind == "literal" then
      if actual ~= seg.value then
        return false, params
      end
    else
      params[seg.name] = actual
    end
  end
  if #path_segs ~= #segs then
    return false, params
  end
  return true, params
end

--- Create an empty router.
--- @return Router The router, ready for :get/:post/... and :handler()
local function new(): Router
  local routes: {Route} = {}
  local not_found_handler: Handler = default_not_found

  --- Compile pattern and, on success, append h under method in source
  --- order — the order `:handler()` walks, which is what makes
  --- registration order the match order.
  local function register(method: string, pattern: string, h: Handler): boolean, string
    local segs, err = compile_pattern(pattern)
    if segs == nil then
      return false, err
    end
    routes[#routes + 1] = {method = method, segments = segs, handler = h}
    return true, ""
  end

  local rt: Router = {}

  function rt:get(pattern: string, h: Handler): boolean, string
    return register("GET", pattern, h)
  end

  function rt:post(pattern: string, h: Handler): boolean, string
    return register("POST", pattern, h)
  end

  function rt:put(pattern: string, h: Handler): boolean, string
    return register("PUT", pattern, h)
  end

  function rt:patch(pattern: string, h: Handler): boolean, string
    return register("PATCH", pattern, h)
  end

  function rt:delete(pattern: string, h: Handler): boolean, string
    return register("DELETE", pattern, h)
  end

  function rt:head(pattern: string, h: Handler): boolean, string
    return register("HEAD", pattern, h)
  end

  function rt:options(pattern: string, h: Handler): boolean, string
    return register("OPTIONS", pattern, h)
  end

  function rt:any(pattern: string, h: Handler): boolean, string
    return register("*", pattern, h)
  end

  function rt:not_found(h: Handler)
    not_found_handler = h
  end

  function rt:handler(): Handler
    return function(req: Request, res: Response)
      local path_segs = segments_of(req.path)
      local matched: Route = nil
      local matched_params: {string: string} = nil
      local allowed: {string} = {}
      local allowed_seen: {string: boolean} = {}
      local path_matched = false

      for _, route in ipairs(routes) do
        local ok, params = match_segments(route.segments, path_segs)
        if ok then
          path_matched = true
          if route.method ~= "*" and not allowed_seen[route.method] then
            allowed_seen[route.method] = true
            allowed[#allowed + 1] = route.method
          end
          if route.method == req.method or route.method == "*" then
            matched = route
            matched_params = params
            break
          end
        end
      end

      if matched == nil and req.method == "HEAD" then
        for _, route in ipairs(routes) do
          if route.method == "GET" then
            local ok, params = match_segments(route.segments, path_segs)
            if ok then
              matched = route
              matched_params = params
              break
            end
          end
        end
      end

      if matched ~= nil then
        req.params = matched_params
        matched.handler(req, res)
        return
      end

      if path_matched then
        res.status = 405
        res:set_header("Allow", table.concat(allowed, ", "))
        local _ok, _err = res:send("")
        return
      end

      not_found_handler(req, res)
    end
  end

  return rt
end

local record HttpRouterModule
  type Router = Router
  new: function(): Router
end

local M: HttpRouterModule = {
  new = new,
}

return M

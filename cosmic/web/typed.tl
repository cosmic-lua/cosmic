--- Typed routes: a route whose path parameters, query and body are named by
--- [`cosmic.shape`] specs, so its handler is given checked records and
--- input that fails them is answered before it runs. The route is erased to
--- the plain [`Web.Route`]: its handler closes over the binding.

local Input = require("cosmic.web.input")
local Json = require("cosmic.json")
local Response = require("cosmic.web.response")
local Route = require("cosmic.web.route")
local Shape = require("cosmic.shape")
local Types = require("cosmic.web.types")

local record Typed
  --- The spec of an absent slot: see [`Web.NONE`].
  NONE: Shape.Typed<Types.None>
  --- The body slot of a route that reads none: see [`Web.no_body`].
  no_body: Types.Body<Types.None>
end

--- The spec of an absent slot: a record with no fields.
local NONE <const>: Shape.Typed<Types.None> = Shape.record_of("cosmic.web.types.None")

--- The body slot of a route that reads none.
local NO_BODY <const>: Types.Body<Types.None> = { kind = "none", typed = NONE }

Typed.NONE = NONE
Typed.no_body = NO_BODY

--- What a handler is given for a slot the route does not read: the empty
--- [`Web.None`] its spec builds from no fields.
local function absent<T>(spec: Shape.Typed<T>): T
  return (assert(spec:into({})))
end

--- The methods whose request may carry a body.
local BODY_METHODS <const>: {string:boolean} = { POST = true, PUT = true, PATCH = true, DELETE = true }

--- Raises unless `t` is what [`Shape.record_of`] answers.
local function need_typed(t: any, what: string)
  local spec: any = nil
  if t is {string:any} then spec = t["spec"] end
  if not (spec is {string:any}) then
    error(("web: %s takes the result of Shape.record_of"):format(what), 3)
  end
end

--- A body slot for a JSON body: the Content-Type must be `application/json`
--- (or `application/*+json`), and a failure answers a problem body by
--- default.
--- @param t Shape.Typed<B> The body's record and spec
--- @return Types.Body<B> The slot
function Typed.json_body<B>(t: Shape.Typed<B>): Types.Body<B>
  need_typed(t, "json_body")
  return { kind = "json", typed = t }
end

--- A body slot for an urlencoded form: bound by the rules of
--- cosmic.web.input.
--- @param t Shape.Typed<B> The body's record and spec
--- @return Types.Body<B> The slot
function Typed.form_body<B>(t: Shape.Typed<B>): Types.Body<B>
  need_typed(t, "form_body")
  return { kind = "form", typed = t }
end

--- A body slot for a `multipart/form-data` body: the text parts are bound
--- to the record as a form's fields are, and the Content-Type must be
--- multipart (a urlencoded body is a 415). The files are the handler's to
--- take from [`Input.multipart`]; they are removed when it returns. Raise
--- `input_options.max_bytes` (16 MiB by default here) and the file caps for
--- a route that takes large uploads, and give [`Web.serve`] a higher
--- `limits.body_bytes` (1 MiB): the server refuses a larger body with 413
--- before the route runs, whatever `max_bytes` is.
--- @param t Shape.Typed<B> The body's record and spec, of the text fields
--- @return Types.Body<B> The slot
-- TODO: let a route raise the server's body limit for its own uploads, once
-- `ServeSpec.body_limit` exists (the TODO at `Server.Limits.body_bytes` in
-- cosmic/http/server.tl).
-- TODO: bind a file part into the record, as `Input.upload` in input.md
-- section 4 has it, once cosmic.shape can carry a marker kind a
-- `record_of` field may name; until then a handler reads the files from
-- `Input.multipart(req)`.
function Typed.multipart_body<B>(t: Shape.Typed<B>): Types.Body<B>
  need_typed(t, "multipart_body")
  return { kind = "multipart", typed = t }
end

--- The three slots of a typed route, in the order the handler receives
--- them; [`Web.NONE`] and [`Web.no_body`] fill one the route does not read.
--- @param path Shape.Typed<P> The path parameters
--- @param query Shape.Typed<Q> The query
--- @param body Types.Body<B> The body
--- @return Types.Input<P,Q,B> The bundle
function Typed.input<P,Q,B>(path: Shape.Typed<P>, query: Shape.Typed<Q>, body: Types.Body<B>): Types.Input<P,Q,B>
  need_typed(path, "input's path")
  need_typed(query, "input's query")
  local slot: any = body
  if not (slot is {string:any}) or slot["typed"] == nil then
    error("web: input's body takes Web.json_body, Web.form_body, Web.multipart_body or Web.no_body", 2)
  end
  return { path = path, query = query, body = body }
end

--- The names of the parameters in `pattern`, in order.
local function param_names(pattern: string): {string}
  local names: mut {string} = {}
  for segment in pattern:gmatch("[^/]+") do
    local name = segment:match("^[:*](.+)$")
    if name ~= nil then names[#names + 1] = name end
  end
  return names
end

--- Raises, naming the pattern, unless the path spec and the pattern
--- agree.
local function check_path(pattern: string, spec: Shape.Spec?)
  local names = param_names(pattern)
  local fields: mut {string:boolean} = {}
  if spec ~= nil then
    for _, name in ipairs(assert(spec.names)) do fields[name] = true end
  end
  local seen: mut {string:boolean} = {}
  for _, name in ipairs(names) do
    seen[name] = true
    if not fields[name] then
      error(("web: route_typed %s: the parameter %q is not a field of the path spec"):format(pattern, name), 3)
    end
  end
  for name in pairs(fields) do
    if not seen[name] then
      error(("web: route_typed %s: the path spec field %q is not a parameter of the pattern"):format(pattern, name), 3)
    end
  end
end

--- The errors of `inv` as the `errors` member of a problem body.
local function problem_errors(inv: Types.Invalid): any
  local list: mut {any} = {}
  for i, e in ipairs(inv.errors) do
    list[i] = { source = e.source, field = e.field, pointer = e.pointer, message = e.message, code = e.code }
  end
  return Json.array(list)
end

--- The default answer for `inv`: a problem body for a client that prefers
--- JSON (a route with a JSON body offers it first, so a client that asks
--- for nothing in particular is given JSON), else the app's error page.
local function answer(req: Types.Request, inv: Types.Invalid, json_first: boolean): Types.Response
  local offers: {string} = if json_first then { "application/json", "text/html" } else { "text/html", "application/json" } end
  if req:accepts(offers) == "application/json" then
    return Response.problem(inv.status, inv.message, { errors = problem_errors(inv) })
  end
  return Response.abort(inv.status, inv.message)
end

--- A route answering `methods` at `pattern` whose input is bound to the
--- specs of `input` before `fn` runs, in order: the path, the query, the
--- body. `fn` is given the request and the three records, each an empty
--- [`Web.None`], which has no field to read, where the slot is absent:
---
---     Web.post_typed("/items", Web.input(Web.NONE, Web.NONE, Web.json_body(NEW)),
---       function(req: Web.Request, _: Web.None, _: Web.None, b: NewItem): Web.Response
---         return Web.json({ id = db:insert(b.title, b.qty) }, { status = 201 })
---       end)
---
--- Teal does not infer the handler's parameters from `input`: a parameter
--- left unannotated is `any`, and one annotated is checked against the
--- slot (`p: NewItem` for an `ItemPath` slot is a type error). The first
--- slot that fails ends the request, with every error of that source
--- collected in an [`Input.Invalid`], which `opts.on_invalid` answers if
--- given; without it the answer is a problem body for a client that
--- prefers JSON and the app's error page otherwise.
---
--- Raises, naming the pattern, when a path parameter and a field of the
--- path spec do not match one to one, when a spec is one its source cannot
--- carry ([`Input.check_spec`]), and when a body is declared for GET.
--- @param methods string | {string} A method, or several, in capitals
--- @param pattern string The pattern, as [`Web.route`] reads it
--- @param input Types.Input<P,Q,B> The slots, from [`Web.input`]
--- @param fn function(Types.Request, P, Q, B): Types.Response The handler
--- @param opts Types.RouteOptions | nil The name, middleware, `on_invalid` and `input_options`
--- @return Types.Route The route
function Typed.route_typed<P,Q,B>(methods: string | {string}, pattern: string, input: Types.Input<P,Q,B>,
                                  fn: function(Types.Request, P, Q, B): Types.Response, opts?: Types.RouteOptions): Types.Route
  need_typed(input.path, "route_typed's path")
  local has_path = not rawequal(input.path, NONE)
  local has_query = not rawequal(input.query, NONE)
  local kind = input.body.kind
  if kind ~= "json" and kind ~= "form" and kind ~= "multipart" and kind ~= "none" then
    error(("web: route_typed %s: the body is a %s, not json, form, multipart or none"):format(pattern, tostring(kind)), 2)
  end
  local verbs: {string} = if methods is string then { methods } else methods end
  if kind ~= "none" then
    for _, verb in ipairs(verbs) do
      if not BODY_METHODS[verb] then
        error(("web: route_typed %s: %s takes no body, so it cannot have a %s body spec"):format(pattern, verb, kind), 2)
      end
    end
  end
  check_path(pattern, has_path and input.path.spec or nil)
  if has_path then Input.check_spec(input.path.spec, "path") end
  if has_query then Input.check_spec(input.query.spec, "query") end
  if kind == "form" or kind == "multipart" then Input.check_spec(input.body.typed.spec, "form") end
  local options = opts and opts.input_options
  local on_invalid = opts and opts.on_invalid
  local json_first = kind == "json"
  local function refuse(req: Types.Request, inv: Types.Invalid): Types.Response
    if on_invalid ~= nil then return on_invalid(req, inv) end
    return answer(req, inv, json_first)
  end
  local handler: Types.Handler = function(req: Types.Request): Types.Response
    -- An absent slot is an empty [`Web.None`]: its record has no field to read.
    local p: P
    local q: Q
    local b: B
    if has_path then
      local read: Types.Parsed<P> = Input.path_into(req, input.path, options)
      local invalid = read.invalid
      if invalid ~= nil then return refuse(req, invalid) end
      p = read.value
    else
      p = absent(input.path)
    end
    if has_query then
      local read: Types.Parsed<Q> = Input.query_into(req, input.query, options)
      local invalid = read.invalid
      if invalid ~= nil then return refuse(req, invalid) end
      q = read.value
    else
      q = absent(input.query)
    end
    if kind == "form" then
      local read: Types.Parsed<B> = Input.form_into(req, input.body.typed, options)
      local invalid = read.invalid
      if invalid ~= nil then return refuse(req, invalid) end
      b = read.value
    elseif kind == "multipart" then
      local read: Types.Parsed<B> = Input.multipart_into(req, input.body.typed, options)
      local invalid = read.invalid
      if invalid ~= nil then return refuse(req, invalid) end
      b = read.value
    elseif kind == "json" then
      local read: Types.Parsed<B> = Input.json_into(req, input.body.typed, options)
      local invalid = read.invalid
      if invalid ~= nil then return refuse(req, invalid) end
      b = read.value
    else
      b = absent(input.body.typed)
    end
    return fn(req, p, q, b)
  end
  local route = Route.route(methods, pattern, handler, opts)
  route.input = {
    path = has_path and input.path.spec or nil, query = has_query and input.query.spec or nil,
    body_kind = kind, body = kind ~= "none" and input.body.typed.spec or nil,
    max_bytes = options and options.max_bytes or
      (kind == "multipart" and Input.DEFAULT_MULTIPART_MAX or Input.DEFAULT_MAX),
  }
  return route
end

--- A typed route for a page or a read: GET, and HEAD with the same
--- handler. Its input is the path and the query, and it takes no body, so
--- a body slot other than [`Web.no_body`] raises. See [`Web.route_typed`].
function Typed.get_typed<P,Q,B>(pattern: string, input: Types.Input<P,Q,B>,
                                fn: function(Types.Request, P, Q, B): Types.Response, opts?: Types.RouteOptions): Types.Route
  return Typed.route_typed("GET", pattern, input, fn, opts)
end

--- A typed route for what a form submits or an action that creates: POST,
--- whose body is urlencoded ([`Web.form_body`]), multipart
--- ([`Web.multipart_body`]) or JSON ([`Web.json_body`]).
--- See [`Web.route_typed`].
function Typed.post_typed<P,Q,B>(pattern: string, input: Types.Input<P,Q,B>,
                                 fn: function(Types.Request, P, Q, B): Types.Response, opts?: Types.RouteOptions): Types.Route
  return Typed.route_typed("POST", pattern, input, fn, opts)
end

--- A typed route that replaces the thing at the URL whole: PUT, with the
--- full record in the body. See [`Web.route_typed`].
function Typed.put_typed<P,Q,B>(pattern: string, input: Types.Input<P,Q,B>,
                                fn: function(Types.Request, P, Q, B): Types.Response, opts?: Types.RouteOptions): Types.Route
  return Typed.route_typed("PUT", pattern, input, fn, opts)
end

--- A typed route that changes part of the thing at the URL: PATCH, with a
--- body spec whose fields are mostly optional. See [`Web.route_typed`].
function Typed.patch_typed<P,Q,B>(pattern: string, input: Types.Input<P,Q,B>,
                                  fn: function(Types.Request, P, Q, B): Types.Response, opts?: Types.RouteOptions): Types.Route
  return Typed.route_typed("PATCH", pattern, input, fn, opts)
end

--- A typed route that removes the thing at the URL: DELETE, which may carry
--- a body but usually reads the path alone. See [`Web.route_typed`].
function Typed.delete_typed<P,Q,B>(pattern: string, input: Types.Input<P,Q,B>,
                                   fn: function(Types.Request, P, Q, B): Types.Response, opts?: Types.RouteOptions): Types.Route
  return Typed.route_typed("DELETE", pattern, input, fn, opts)
end

return Typed

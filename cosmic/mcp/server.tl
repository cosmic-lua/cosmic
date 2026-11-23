--- A Model Context Protocol server ([`cosmic.mcp`], revision 2026-07-28):
--- the tools, resources and prompts a program offers, answered over
--- stdio ([`McpServer.Instance.serve_stdio`]) or Streamable HTTP ([`McpServer.Instance.handler`],
--- under [`cosmic.http.server`]).
---
---     local Mcp = require("cosmic.mcp")
---     local McpServer = require("cosmic.mcp.server")
---
---     local server = McpServer.new{
---       info = { name = "adder", version = "1.0.0" },
---       tools = {
---         {
---           tool = {
---             name = "add",
---             description = "Adds two integers.",
---             inputSchema = Mcp.object_schema({ a = { type = "integer" }, b = { type = "integer" } }, { "a", "b" }),
---           },
---           call = function(args: {string: Json.Value}, _: McpServer.Call): (Mcp.ToolResult) | (nil, Failure)
---             local a, b = math.tointeger(args["a"]), math.tointeger(args["b"])
---             if a == nil or b == nil then return nil, Failure.new("a and b must be integers") end
---             return Mcp.result({ tostring(a + b) })
---           end,
---         },
---       },
---     }
---     assert(server:serve_stdio())
---
--- Each request is answered on its own, as the protocol is stateless: a
--- request names its protocol version and the client's capabilities in
--- its `_meta`, and one that does not, or names a version other than
--- [`Mcp.VERSION`], is refused. `server/discover` answers what the
--- server is; a client's `initialize`, from an earlier revision, is
--- refused naming the version spoken.
---
--- A tool's handler is given its arguments as the client sent them: the
--- server does not check them against the tool's `inputSchema`, so the
--- handler checks each one it reads (with `is`, or [`cosmic.shape`]). A
--- tool that runs and fails answers its failure, which the client is
--- sent as a result with `isError`, for the model to read; a handler that
--- raises is answered as an internal error, its words withheld from the
--- client and given to [`McpServer.Spec.on_error`].
---
--- Security: over HTTP every request passes `authorize`, which the
--- handler's spec must state ([`McpServer.bearer`] checks a token,
--- [`McpServer.anyone`] lets every caller in), and a request whose `Origin`
--- is not one of `origins` is refused 403 before anything else, so a web
--- page cannot reach a server on this machine by rebinding its DNS. Bind
--- a local server to 127.0.0.1, not every address. Over stdio the client
--- that started the process is the only caller; start a server you did
--- not write under a [`cosmic.sandbox`] policy (`cosmic docs
--- cosmic.mcp.client`). A tool's handler runs in the server, with all it
--- may reach; a tool made by [`McpServer.command`] runs a program under a
--- policy of its own instead, so a call reaches only what that tool's
--- policy grants, whatever the client asks.
--- @public

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Errors = require("cosmic.errors")
local Failure = require("cosmic.failure")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Json = require("cosmic.json")
local Mcp = require("cosmic.mcp")
local Net = require("cosmic.net")
local Sandbox = require("cosmic.sandbox")
local Shape = require("cosmic.shape")
local Stream = require("cosmic.stream")
local String = require("cosmic.string")
local wire = require("cosmic.mcp.wire")
local type HttpServer = require("cosmic.http.server")

local record McpServer
  --- What a handler knows of the request it answers.
  record Call
    --- How the client names itself, nil where it does not. Nothing
    --- verifies it: show it, log it, never decide by it.
    client?: Mcp.Implementation
    --- The capabilities the client declares for this request.
    capabilities: {string: Json.Value}
    --- The HTTP request this came in, nil over stdio: its headers say
    --- what `authorize` let in.
    http?: HttpServer.Request
  end

  --- A tool, and what calls it.
  record ToolSpec
    --- The tool, as `tools/list` lists it.
    tool: Mcp.Tool
    --- Runs the tool on `arguments`, as the client sent them. A failure
    --- answered is sent as a result with `isError`, its words for the
    --- model to read.
    call: function(arguments: {string: Json.Value}, call: Call): (Mcp.ToolResult) | (nil, Failure)
  end

  --- A tool that is a program run under a sandbox: what [`McpServer.command`] makes a [`ToolSpec`] of.
  record CommandSpec
    --- The tool, as `tools/list` lists it.
    tool: Mcp.Tool
    --- The program and its arguments. It reads the call's arguments, a JSON object, on stdin.
    argv: {string}
    --- What the program is held to ([`Child.Options.policy`]): what it does not grant, the program cannot reach,
    --- the server's own files, sockets and environment among them. Required: a tool that needs nothing still names
    --- the program it runs (`profiles = { "cosmic" }` for this program, or `"system"`).
    policy: Sandbox.Policy
    --- How long one call may run (60 seconds); one that runs past it is ended and answered as an error.
    timeout_ns?: integer
    --- The most bytes of output a call keeps (1 MiB); more is answered as an error.
    output_limit?: integer
    --- The directory it starts in, absolute, granted or not by `policy`; this process's when nil.
    cwd?: string
    --- How many calls may run at once (4); a call past them is answered as an error.
    concurrency?: integer
  end

  --- A resource, and what reads it.
  record ResourceSpec
    --- The resource, as `resources/list` lists it.
    resource: Mcp.Resource
    --- Reads it, for the caller of `call`.
    read: function(call: Call): ({Mcp.ResourceContents}) | (nil, Failure)
  end

  --- A prompt, and what fills it in.
  record PromptSpec
    --- The prompt, as `prompts/list` lists it.
    prompt: Mcp.Prompt
    --- Fills the prompt in from `arguments`, each one the prompt
    --- requires among them.
    get: function(arguments: {string: string}, call: Call): (Mcp.PromptResult) | (nil, Failure)
  end

  --- Who may share a list the server answers: "private" for the caller
  --- alone, "public" for a cache between too.
  enum CacheScope
    "public"
    "private"
  end

  --- What [`McpServer.new`] serves.
  record Spec
    --- How the server names itself, in `server/discover` and in each
    --- result's `_meta`.
    info: Mcp.Implementation
    --- Words for the model on how to use the server.
    instructions?: string
    --- The tools it offers, listed in this order.
    tools?: {ToolSpec}
    --- The resources it lists, in this order.
    resources?: {ResourceSpec}
    --- Families of resources, listed for the client; `read` reads them.
    templates?: {Mcp.ResourceTemplate}
    --- Reads a resource `resources` does not hold, by its URI: false
    --- where it is none of the server's.
    read?: function(uri: string, call: Call): ({Mcp.ResourceContents} | false) | (nil, Failure)
    --- The prompts it offers, in this order.
    prompts?: {PromptSpec}
    --- The most items of a list in one page (100).
    page_size?: integer
    --- How long a client may keep a list or a read before asking
    --- again, in milliseconds (0: ask each time).
    ttl_ms?: integer
    --- Who may keep a list or `server/discover` ("private"); a read is
    --- always "private", as what a resource holds may be one caller's.
    cache_scope?: CacheScope
    --- Given what a handler raised, with its stack; nil to write it to
    --- stderr.
    on_error?: function(trouble: string)
  end

  --- What [`McpServer.Instance.handler`] serves over HTTP.
  record HttpSpec
    --- Whether the request may be answered: false is answered 401.
    --- [`McpServer.bearer`] checks a token; [`McpServer.anyone`] lets each in.
    authorize: function(HttpServer.Request): boolean
    --- The origins a browser's request may come from, each as
    --- `scheme://host[:port]`; a request whose `Origin` is not one is
    --- refused 403. Nil or empty for none: a request with no `Origin`,
    --- which a browser always sends where it matters, is let through
    --- to `authorize`.
    origins?: {string}
    --- The path the endpoint answers ("/mcp"); any other is 404.
    path?: string
  end

  --- What [`McpServer.Instance.answer`] makes of one message: the text to
  --- send back, nil for a notification, and the HTTP status it goes with.
  record Answer
    --- The response's text, nil for a notification.
    body?: string
    --- The HTTP status it goes with: 200, 202, or what the refusal is.
    status: integer
  end

  --- A server [`McpServer.new`] made.
  interface Instance
    --- The answer to `text`, one JSON-RPC message, as either transport
    --- sends it: the response's text, nil for a notification, and the
    --- HTTP status it goes with. `http` is the request it came in over
    --- HTTP.
    answer: function(Instance, text: string, http?: HttpServer.Request): Answer
    --- Serves the protocol over stdio: a message a line from `input`
    --- (stdin), and each answer a line to `output` (stdout), until
    --- `input` ends, when it answers true. A line longer than
    --- [`Mcp.MAX_MESSAGE_BYTES`], or a failure to read or write, ends it
    --- with false and why. Write nothing else to stdout meanwhile: it is
    --- the protocol's alone, and a log goes to stderr.
    serve_stdio: function(Instance, input?: Stream.Reader, output?: Stream.Writer): (true) | (false, Failure)
    --- A handler for [`cosmic.http.server`] that answers Streamable HTTP at `spec.path`: one POST a message, each answered as
    --- `application/json`. In order, a request is refused 403 for an
    --- `Origin` not in `spec.origins`, 404 for another path, 405 for a
    --- method other than POST, 401 where `spec.authorize` says no, 415 for a
    --- body that is not `application/json`, 406 for an `Accept` that takes
    --- no JSON, and 400 for headers that disagree with the body
    --- (`MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name`, and each
    --- `Mcp-Param-` a tool's schema names). A notification is answered 202.
    ---
    ---     local Net = require("cosmic.net")
    ---     local Http = require("cosmic.http.server")
    ---     local token = assert(os.getenv("MCP_TOKEN"))
    ---     assert(Http.serve{
    ---       listeners = { Net.tcp("127.0.0.1", 8080) },
    ---       handle = server:handler{ authorize = McpServer.bearer(token) },
    ---     })
    handler: function(Instance, spec: HttpSpec): function(HttpServer.Request): HttpServer.Reply
    --- Serves as a program's main, by its command line `argv` from slot `from` (1 when nil), and answers the exit
    --- status: 0 when stdin ended or the server stopped, 1 when serving failed, and 2 for a command line it refuses,
    --- with why on stderr. With no options it serves stdio ([`McpServer.Instance.serve_stdio`]). `--http host:port`
    --- serves Streamable HTTP there instead ([`McpServer.Instance.handler`]; the host numeric, port 0 for any),
    --- and says the endpoint's URL on stderr once it listens. Each request must then carry the bearer token held in
    --- the environment variable `--token-env NAME` names, at least 16 bytes; `--anyone` lets every request in
    --- instead, and only on a loopback host. `--origin O`, which may be repeated, names an origin a browser's
    --- request may come from, and `--path P` the endpoint's path ("/mcp").
    ---
    ---     return function(argv: {string}): integer
    ---       return server:main(argv)
    ---     end
    ---
    --- run as `cosmic server.tl` for stdio, or `MCP_TOKEN=... cosmic server.tl --http 127.0.0.1:8080 --token-env
    --- MCP_TOKEN` for HTTP.
    main: function(Instance, argv: {string}, from?: integer): integer
  end
end

--- The options [`McpServer.Instance.main`] reads.
local MAIN_OPTIONS <const>: {string: boolean} = {
  ["--http"] = true, ["--token-env"] = true, ["--anyone"] = false, ["--origin"] = true, ["--path"] = true,
}

--- One server: its spec, read once, and its lists in order.
local record State
  spec: McpServer.Spec
  tools: {McpServer.ToolSpec}
  by_tool: {string: McpServer.ToolSpec}
  --- The header mirrors of each tool, by its name.
  mirrors: {string: {Mcp.Mirror}}
  resources: {McpServer.ResourceSpec}
  by_uri: {string: McpServer.ResourceSpec}
  templates: {Mcp.ResourceTemplate}
  prompts: {McpServer.PromptSpec}
  by_prompt: {string: McpServer.PromptSpec}
  page_size: integer
  ttl_ms: integer
  cache_scope: McpServer.CacheScope
end

local TOOL_NAME <const> = "^[%w_%-.]+$"

local META_VERSION <const> = "io.modelcontextprotocol/protocolVersion"
local META_CAPABILITIES <const> = "io.modelcontextprotocol/clientCapabilities"
local META_CLIENT <const> = "io.modelcontextprotocol/clientInfo"
local META_SERVER <const> = "io.modelcontextprotocol/serverInfo"

--- Raises for a spec that does not hold, at the caller of [`McpServer.new`].
local function refuse(why: string): never
  error("mcp: " .. why, 4)
end

--- The state of a server of `spec`. A tool named twice or outside `A-Z a-z 0-9
--- _ - .`, one whose schema names an `x-mcp-header` the transport
--- refuses, a resource's URI or a prompt's name given twice, raises.
local function state_of(spec: McpServer.Spec): State
  local by_tool: mut {string: McpServer.ToolSpec} = {}
  local mirrors: mut {string: {Mcp.Mirror}} = {}
  for _, t in ipairs(spec.tools or {}) do
    local name = t.tool.name
    if #name < 1 or #name > 128 or name:find(TOOL_NAME) == nil then
      refuse("tool name " .. Json.quote(name) .. " is not 1 to 128 of A-Z a-z 0-9 _ - .")
    end
    if by_tool[name] ~= nil then refuse("tool " .. name .. " is named twice") end
    if t.tool.inputSchema["type"] ~= "object" then
      refuse("tool " .. name .. ": inputSchema must have \"type\": \"object\"")
    end
    local found, why = Mcp.mirrors(t.tool.inputSchema)
    if found == nil then refuse("tool " .. name .. ": " .. tostring(why)) end
    by_tool[name] = t
    mirrors[name] = found
  end
  local by_uri: mut {string: McpServer.ResourceSpec} = {}
  for _, r in ipairs(spec.resources or {}) do
    if by_uri[r.resource.uri] ~= nil then
      refuse("resource " .. r.resource.uri .. " is named twice")
    end
    by_uri[r.resource.uri] = r
  end
  local by_prompt: mut {string: McpServer.PromptSpec} = {}
  for _, p in ipairs(spec.prompts or {}) do
    if by_prompt[p.prompt.name] ~= nil then
      refuse("prompt " .. p.prompt.name .. " is named twice")
    end
    by_prompt[p.prompt.name] = p
  end
  local page_size = spec.page_size or 100
  if page_size < 1 then refuse("page_size must be at least 1") end
  local ttl_ms = spec.ttl_ms or 0
  if ttl_ms < 0 then refuse("ttl_ms must not be negative") end
  return {
    spec = spec, tools = spec.tools or {}, by_tool = by_tool, mirrors = mirrors,
    resources = spec.resources or {}, by_uri = by_uri, templates = spec.templates or {},
    prompts = spec.prompts or {}, by_prompt = by_prompt, page_size = page_size, ttl_ms = ttl_ms,
    cache_scope = spec.cache_scope or "private",
  }
end

-- What a request's params hold, as the protocol names them.

--- The params every request has: its `_meta`.
local record Params
  _meta: any
end

--- The protocol's own keys of a request's `_meta`, read apart: their
--- names are not identifiers.
local record CallParams
  name: string
  arguments: any
end

local record ReadParams
  uri: string
end

local record PromptParams
  name: string
  arguments?: {string: string}
end

local record PageParams
  cursor?: string
end

local PARAMS <const>: Shape.Typed<Params> = Shape.record_of("Params")
local CALL_PARAMS <const>: Shape.Typed<CallParams> = Shape.record_of("CallParams")
local READ_PARAMS <const>: Shape.Typed<ReadParams> = Shape.record_of("ReadParams")
local PROMPT_PARAMS <const>: Shape.Typed<PromptParams> = Shape.record_of("PromptParams")
local PAGE_PARAMS <const>: Shape.Typed<PageParams> = Shape.record_of("PageParams")

--- A refusal of a request: JSON-RPC's code, its words, and data where
--- the protocol gives some.
local record Refusal
  code: integer
  message: string
  data?: Json.Value
end

local function refusal(code: integer, message: string, data?: Json.Value): Refusal
  return { code = code, message = message, data = data }
end

--- The HTTP status an answer of `code` goes with.
local function status_of(code: integer): integer
  if code == Mcp.METHOD_NOT_FOUND then return 404 end
  if code == Mcp.INTERNAL_ERROR then return 500 end
  return 400
end

--- What a request's `_meta` says: the version it speaks and the
--- capabilities it declares, read apart from the params.
local record Meta
  version: string
  capabilities: {string: Json.Value}
  client?: Mcp.Implementation
end

--- The `_meta` of `params`, or why the request is refused: a required
--- key missing (-32602), or a version not spoken (-32022).
local function meta_of(params: any): (Meta) | (nil, Refusal)
  local p, _ = PARAMS:into(params)
  local meta: {string: Json.Value}? = nil
  if p ~= nil and p._meta ~= nil then
    local m, _ = Json.to_object(p._meta)
    meta = m
  end
  if meta == nil then
    return nil, refusal(Mcp.INVALID_PARAMS, "the request has no _meta: every request names " .. META_VERSION .. " and " .. META_CAPABILITIES)
  end
  local version = meta[META_VERSION]
  if not version is string then
    return nil, refusal(Mcp.INVALID_PARAMS, "_meta has no " .. META_VERSION)
  end
  if version ~= Mcp.VERSION then
    return nil, refusal(Mcp.UNSUPPORTED_VERSION, "Unsupported protocol version " .. Json.quote(version) .. "; this server speaks " .. Mcp.VERSION,
      { supported = wire.strings({ Mcp.VERSION }), requested = version })
  end
  local raw_capabilities = meta[META_CAPABILITIES]
  local capabilities: {string: Json.Value}? = nil
  if raw_capabilities ~= nil and not Json.is_array(raw_capabilities) then
    local c, _ = Json.to_object(raw_capabilities)
    capabilities = c
  end
  if capabilities == nil then
    return nil, refusal(Mcp.INVALID_PARAMS, "_meta has no " .. META_CAPABILITIES .. " object")
  end
  local client: Mcp.Implementation? = nil
  local raw_client = meta[META_CLIENT]
  if raw_client ~= nil then
    client = wire.implementation_of(raw_client)
  end
  return { version = version, capabilities = capabilities, client = client }
end

--- `fields` made a result: its `resultType`, and the server's name in
--- its `_meta`.
local function result(self: State, fields: {string: Json.Value}): Json.Value
  local out: mut {string: Json.Value} = {}
  for k, v in pairs(fields) do out[k] = v end
  out["resultType"] = "complete"
  out["_meta"] = { [META_SERVER] = wire.implementation(self.spec.info) }
  return out
end

--- `fields` made a result a client may keep, for `ttl_ms`.
local function cacheable(self: State, fields: {string: Json.Value}, scope?: McpServer.CacheScope): Json.Value
  local out: mut {string: Json.Value} = {}
  for k, v in pairs(fields) do out[k] = v end
  out["ttlMs"] = self.ttl_ms
  out["cacheScope"] = scope or self.cache_scope
  return result(self, out)
end

--- The page of `count` items the cursor in `params` starts, as the
--- index of its first and last item, and the cursor of the next page,
--- nil at the last; or why the cursor is none of this server's.
local record Window
  first: integer
  last: integer
  next?: string
end

local function window(self: State, params: any, count: integer): (Window) | (nil, Refusal)
  local p, _ = PAGE_PARAMS:into(params)
  local first = 1
  local cursor = if p ~= nil then p.cursor else nil end
  if cursor ~= nil then
    local n = if cursor:find("^%d+$") ~= nil and #cursor <= 12 then math.tointeger(tonumber(cursor)) else nil end
    if n == nil or n < 1 or n > count + 1 then
      return nil, refusal(Mcp.INVALID_PARAMS, "no such cursor: " .. Json.quote(cursor))
    end
    first = n
  end
  local last = math.min(count, first + self.page_size - 1)
  return { first = first, last = last, next = if last < count then tostring(last + 1) else nil end }
end

--- The capabilities `server/discover` answers.
local function capabilities(self: State): Json.Value
  local c: mut {string: Json.Value} = {}
  local none: {string: Json.Value} = {}
  if #self.tools > 0 then c["tools"] = none end
  if #self.resources > 0 or #self.templates > 0 or self.spec.read ~= nil then
    c["resources"] = none
  end
  if #self.prompts > 0 then c["prompts"] = none end
  return c
end

--- Calls `f`, catching what it raises: false and its words, with the
--- stack where it raised.
local function traced(f: function()): (true) | (false, string)
  local ok, trouble = xpcall(f, function(err: any): string
    return Errors.trace(tostring(err), 2)
  end)
  if ok then return true end
  return false, if trouble is string then trouble else "error" end
end

--- Reports what a handler raised.
local function report(self: State, what: string, trouble: string)
  local on_error = self.spec.on_error
  if on_error ~= nil then
    on_error(what .. ": " .. trouble)
  else
    local _, _ = Fs.put(Fs.stderr, "mcp: " .. what .. ": " .. trouble .. "\n")
  end
end

local raised <const> = refusal(Mcp.INTERNAL_ERROR, "the server failed to answer")

local function list_tools(self: State, params: any): (Json.Value) | (nil, Refusal)
  local w, wrong = window(self, params, #self.tools)
  if w == nil then return nil, wrong end
  local out: mut {Json.Value} = {}
  for i = w.first, w.last do out[#out + 1] = wire.tool(assert(self.tools[i]).tool) end
  local fields: mut {string: Json.Value} = { tools = Json.array(out) }
  if w.next ~= nil then fields["nextCursor"] = w.next end
  return cacheable(self, fields)
end

local function call_tool(self: State, params: any, call: McpServer.Call): (Json.Value) | (nil, Refusal)
  local p, why = CALL_PARAMS:into(params)
  if p == nil then return nil, refusal(Mcp.INVALID_PARAMS, "tools/call: " .. why) end
  local t = self.by_tool[p.name]
  if t == nil then
    return nil, refusal(Mcp.INVALID_PARAMS, "no such tool: " .. Json.quote(p.name))
  end
  local arguments: {string: Json.Value} = {}
  if p.arguments ~= nil then
    local a, awhy = Json.to_object(p.arguments)
    if a == nil or Json.is_array(p.arguments) then
      return nil, refusal(Mcp.INVALID_PARAMS, "tools/call: arguments must be an object" .. (if a == nil then ": " .. tostring(awhy) else "" end))
    end
    arguments = a
  end
  local answered: Mcp.ToolResult? = nil
  local failure: Failure? = nil
  local ok, trouble = traced(function()
    local value, failed = t.call(arguments, call)
    answered, failure = value, failed
  end)
  if not ok then
    report(self, "tool " .. p.name, trouble)
    return nil, raised
  end
  local done = answered
  if done == nil then
    done = Mcp.result({ if failure ~= nil then tostring(failure) else "the tool failed" end }, true)
  end
  return result(self, wire.tool_result(done))
end

local function list_resources(self: State, params: any): (Json.Value) | (nil, Refusal)
  local w, wrong = window(self, params, #self.resources)
  if w == nil then return nil, wrong end
  local out: mut {Json.Value} = {}
  for i = w.first, w.last do out[#out + 1] = wire.resource(assert(self.resources[i]).resource) end
  local fields: mut {string: Json.Value} = { resources = Json.array(out) }
  if w.next ~= nil then fields["nextCursor"] = w.next end
  return cacheable(self, fields)
end

local function list_templates(self: State, params: any): (Json.Value) | (nil, Refusal)
  local w, wrong = window(self, params, #self.templates)
  if w == nil then return nil, wrong end
  local out: mut {Json.Value} = {}
  for i = w.first, w.last do out[#out + 1] = wire.template(assert(self.templates[i])) end
  local fields: mut {string: Json.Value} = { resourceTemplates = Json.array(out) }
  if w.next ~= nil then fields["nextCursor"] = w.next end
  return cacheable(self, fields)
end

local function read_resource(self: State, params: any, call: McpServer.Call): (Json.Value) | (nil, Refusal)
  local p, why = READ_PARAMS:into(params)
  if p == nil then return nil, refusal(Mcp.INVALID_PARAMS, "resources/read: " .. why) end
  local uri = p.uri
  local r = self.by_uri[uri]
  local read = self.spec.read
  local contents: ({Mcp.ResourceContents} | false)? = false
  local failure: Failure? = nil
  local ok, trouble = traced(function()
    if r ~= nil then
      local value, failed = r.read(call)
      contents, failure = value, failed
    elseif read ~= nil then
      local value, failed = read(uri, call)
      contents, failure = value, failed
    end
  end)
  if not ok then
    report(self, "resource " .. uri, trouble)
    return nil, raised
  end
  local got = contents
  if got == nil then
    report(self, "resource " .. uri, if failure ~= nil then tostring(failure) else "failed" end)
    return nil, raised
  end
  if got is boolean then
    return nil, refusal(Mcp.INVALID_PARAMS, "Resource not found", { uri = uri })
  end
  -- What a resource holds may be the caller's alone: a read is never
  -- for a shared cache, whatever the lists are.
  return cacheable(self, { contents = wire.list(got, wire.contents) }, "private")
end

local function list_prompts(self: State, params: any): (Json.Value) | (nil, Refusal)
  local w, wrong = window(self, params, #self.prompts)
  if w == nil then return nil, wrong end
  local out: mut {Json.Value} = {}
  for i = w.first, w.last do out[#out + 1] = wire.prompt(assert(self.prompts[i]).prompt) end
  local fields: mut {string: Json.Value} = { prompts = Json.array(out) }
  if w.next ~= nil then fields["nextCursor"] = w.next end
  return cacheable(self, fields)
end

local function get_prompt(self: State, params: any, call: McpServer.Call): (Json.Value) | (nil, Refusal)
  local p, why = PROMPT_PARAMS:into(params)
  if p == nil then return nil, refusal(Mcp.INVALID_PARAMS, "prompts/get: " .. why) end
  local spec = self.by_prompt[p.name]
  if spec == nil then
    return nil, refusal(Mcp.INVALID_PARAMS, "no such prompt: " .. Json.quote(p.name))
  end
  local arguments = p.arguments or {}
  for _, a in ipairs(spec.prompt.arguments or {}) do
    if a.required == true and arguments[a.name] == nil then
      return nil, refusal(Mcp.INVALID_PARAMS, "prompt " .. p.name .. " requires the argument " .. a.name)
    end
  end
  local answered: Mcp.PromptResult? = nil
  local failure: Failure? = nil
  local ok, trouble = traced(function()
    local value, failed = spec.get(arguments, call)
    answered, failure = value, failed
  end)
  if not ok then
    report(self, "prompt " .. p.name, trouble)
    return nil, raised
  end
  local done = answered
  if done == nil then
    report(self, "prompt " .. p.name, if failure ~= nil then tostring(failure) else "failed" end)
    return nil, raised
  end
  return result(self, wire.prompt_result(done))
end

local function discover(self: State): Json.Value
  local fields: mut {string: Json.Value} = {
    supportedVersions = wire.strings({ Mcp.VERSION }),
    capabilities = capabilities(self),
  }
  if self.spec.instructions ~= nil then fields["instructions"] = self.spec.instructions end
  return cacheable(self, fields)
end

--- What an earlier revision's `initialize` names.
local record Legacy
  protocolVersion?: string
end

local LEGACY <const>: Shape.Typed<Legacy> = Shape.record_of("Legacy")

--- Whether the server answers `method`: discovery always, and the
--- methods of each feature it has.
local function offers(self: State, method: string): boolean
  if method == "server/discover" then return true end
  if method == "tools/list" or method == "tools/call" then return #self.tools > 0 end
  if method == "resources/list" or method == "resources/templates/list" or method == "resources/read" then
    return #self.resources > 0 or #self.templates > 0 or self.spec.read ~= nil
  end
  if method == "prompts/list" or method == "prompts/get" then return #self.prompts > 0 end
  -- TODO: answer subscriptions/listen, and declare listChanged, once a
  -- spec's tools, resources or prompts can change while it serves: they
  -- are fixed at McpServer.new, so no list ever changes to tell of.
  return false
end

--- The answer to the request of `method` with `params`.
local function dispatch(self: State, method: string, params: any, http?: HttpServer.Request): (Json.Value) | (nil, Refusal)
  if method == "initialize" then
    local legacy, _ = LEGACY:into(params)
    local requested = if legacy ~= nil then legacy.protocolVersion or "" else "" end
    return nil, refusal(Mcp.UNSUPPORTED_VERSION,
      "this server speaks MCP " .. Mcp.VERSION .. " only, which has no initialize: send each request with its _meta",
      { supported = wire.strings({ Mcp.VERSION }), requested = requested })
  end
  if not offers(self, method) then
    return nil, refusal(Mcp.METHOD_NOT_FOUND, "Method not found: " .. method)
  end
  local meta, wrong = meta_of(params)
  if meta == nil then return nil, wrong end
  local call: McpServer.Call = { client = meta.client, capabilities = meta.capabilities, http = http }
  if method == "server/discover" then return discover(self) end
  if method == "tools/list" and #self.tools > 0 then return list_tools(self, params) end
  if method == "tools/call" and #self.tools > 0 then return call_tool(self, params, call) end
  local has_resources = #self.resources > 0 or #self.templates > 0 or self.spec.read ~= nil
  if method == "resources/list" and has_resources then return list_resources(self, params) end
  if method == "resources/templates/list" and has_resources then
    return list_templates(self, params)
  end
  if method == "resources/read" and has_resources then return read_resource(self, params, call) end
  if method == "prompts/list" and #self.prompts > 0 then return list_prompts(self, params) end
  if method == "prompts/get" and #self.prompts > 0 then return get_prompt(self, params, call) end
  return nil, refusal(Mcp.METHOD_NOT_FOUND, "Method not found: " .. method)
end

--- The answer to the message `message`, from HTTP's `http` where given.
local function answer_message(self: State, message: wire.Message, http?: HttpServer.Request): McpServer.Answer
  local method = message.method
  if method == nil then
    return { body = wire.error(message.id, Mcp.INVALID_REQUEST, "a client sends requests and notifications, not responses"),
      status = 400 }
  end
  local id = message.id
  if id == nil then
    -- A notification: this revision has the client send none but
    -- notifications/cancelled, and a request here is answered before the
    -- next is read, so there is nothing to cancel.
    return { body = nil, status = 202 }
  end
  local answered, refused_with = dispatch(self, method, message.params, http)
  if answered == nil then
    return { body = wire.error(id, refused_with.code, refused_with.message, refused_with.data), status = status_of(refused_with.code) }
  end
  local body = wire.response(id, answered)
  if body == nil then
    -- A string a handler answered is not UTF-8, which JSON cannot hold.
    report(self, method, "the answer could not be encoded as JSON")
    return { body = wire.error(id, Mcp.INTERNAL_ERROR, raised.message), status = 500 }
  end
  return { body = body, status = 200 }
end

--- The answer to `text`, one JSON-RPC message.
local function answer(self: State, text: string, http?: HttpServer.Request): McpServer.Answer
  local message, why = wire.message(text)
  if message == nil then
    local code = why.code or Mcp.INVALID_REQUEST
    return { body = wire.error(nil, code, why.message), status = 400 }
  end
  return answer_message(self, message, http)
end

--- Serves the protocol over stdio.
local function serve_stdio(self: State, input?: Stream.Reader, output?: Stream.Writer): (true) | (false, Failure)
  local reader = input or Stream.from_fd(0)
  local writer = output or Stream.to_fd(1)
  local lines = Stream.lines(reader, Mcp.MAX_MESSAGE_BYTES)
  while true do
    local line, trouble = lines:read()
    if line == nil then
      if trouble ~= "" then return false, Failure.new("mcp: " .. trouble) end
      return true
    end
    if line:find("%S") ~= nil then
      local said = answer(self, line)
      if said.body ~= nil then
        local ok, wtrouble = writer:write(said.body .. "\n")
        if not ok then return false, Failure.new("mcp: " .. wtrouble) end
      end
    end
  end
end

-- Streamable HTTP.

--- The reply refusing an HTTP request with `status`, its body a JSON-RPC
--- error with no id where `code` is given.
local function refused(status: integer, code?: integer, message?: string): HttpServer.Reply
  if code == nil then return { status = status } end
  return { status = status, headers = { ["Content-Type"] = "application/json" },
    body = wire.error(nil, code, message or "") }
end

--- Whether the media type `header` names is `want`, its parameters
--- aside.
local function media_is(header: string?, want: string): boolean
  if header == nil then return false end
  local kind = header:match("^%s*([^;%s]+)")
  return kind ~= nil and kind:lower() == want
end

--- Whether `accept` takes `want`, as itself or a wildcard.
local function accepts(accept: string?, want: string): boolean
  if accept == nil then return true end
  local major = want:match("^[^/]+") or want
  for item in accept:gmatch("[^,]+") do
    local kind = item:match("^%s*([^;%s]+)")
    if kind ~= nil then
      kind = kind:lower()
      if kind == want or kind == "*/*" or kind == major .. "/*" then return true end
    end
  end
  return false
end

--- What the body of a request names that a header must agree with.
local record Named
  name?: string
  uri?: string
  _meta: any
  arguments: any
end

local NAMED <const>: Shape.Typed<Named> = Shape.record_of("Named")

--- Why the headers of `req` disagree with `message`, its body, or "".
local function mismatch(self: State, req: HttpServer.Request, message: wire.Message): string
  local method = message.method or ""
  local header_method = req.headers["mcp-method"]
  if header_method == nil then return "the request has no Mcp-Method header" end
  if header_method ~= method then
    return "Header mismatch: Mcp-Method header value " .. Json.quote(header_method) .. " does not match body value " .. Json.quote(method)
  end
  local named, _ = NAMED:into(message.params)
  local version = req.headers["mcp-protocol-version"]
  local said: string? = nil
  if named ~= nil and named._meta ~= nil then
    local meta, _ = Json.to_object(named._meta)
    if meta ~= nil then
      local v = meta[META_VERSION]
      if v is string then said = v end
    end
  end
  if said ~= nil and version ~= said then
    return "Header mismatch: MCP-Protocol-Version header value " .. Json.quote(version or "") .. " does not match body value " .. Json.quote(said)
  end
  local body_name: string? = nil
  if method == "tools/call" or method == "prompts/get" then
    body_name = if named ~= nil then named.name else nil end
  elseif method == "resources/read" then
    body_name = if named ~= nil then named.uri else nil end
  end
  if body_name ~= nil then
    local header_name = req.headers["mcp-name"]
    if header_name == nil then return "the request has no Mcp-Name header" end
    local decoded = Mcp.header_read(header_name)
    if decoded ~= body_name then
      return "Header mismatch: Mcp-Name header value does not match body value " .. Json.quote(body_name)
    end
  end
  if method == "tools/call" and body_name ~= nil and named ~= nil then
    local tool_mirrors = self.mirrors[body_name]
    local arguments: {string: Json.Value} = {}
    if named.arguments ~= nil then
      local a, _ = Json.to_object(named.arguments)
      if a ~= nil then arguments = a end
    end
    for _, m in ipairs(tool_mirrors or {}) do
      local field = "mcp-param-" .. m.header:lower()
      local value, bad = Mcp.mirror_value(arguments, m.path)
      if value == nil then
        return "argument " .. table.concat(m.path, ".") .. ": " .. tostring(bad)
      end
      local header = req.headers[field]
      if value == false and header ~= nil then
        -- Stricter than the protocol asks: a header the server acts on no
        -- value of is one an intermediary may route by all the same.
        return "Header mismatch: Mcp-Param-" .. m.header .. " is sent for an argument the body does not hold"
      end
      if value is string then
        if header == nil then return "the request has no Mcp-Param-" .. m.header .. " header" end
        local decoded = Mcp.header_read(header)
        local same = decoded == value
        if not same and decoded ~= nil and value:find("^%-?%d+$") ~= nil then
          -- An integer written with a zero fraction ("42.0") is the same
          -- integer; nothing else (hex, exponents) is.
          local whole = decoded:match("^(%-?%d+)%.0+$")
          same = whole ~= nil and math.tointeger(tonumber(whole)) == math.tointeger(tonumber(value))
        end
        if not same then
          return "Header mismatch: Mcp-Param-" .. m.header .. " header value does not match body value"
        end
      end
    end
  end
  return ""
end

--- Whether `origin`, an `Origin` header, is one of `allowed`.
local function allowed_origin(origin: string, allowed: {string}): boolean
  local lower = origin:lower()
  for _, o in ipairs(allowed) do
    if o:lower() == lower then return true end
  end
  return false
end

--- The handler [`McpServer.Instance.handler`] answers.
local function handler(self: State, spec: McpServer.HttpSpec): function(HttpServer.Request): HttpServer.Reply
  local path = spec.path or "/mcp"
  local origins = spec.origins or {}
  local authorize = spec.authorize
  return function(req: HttpServer.Request): HttpServer.Reply
    local origin = req.headers["origin"]
    if origin ~= nil and not allowed_origin(origin, origins) then
      return refused(403, Mcp.INVALID_REQUEST, "Forbidden: origin " .. Json.quote(origin) .. " is not allowed")
    end
    if req.path ~= path then return refused(404) end
    if req.method ~= "POST" then
      local reply = refused(405)
      reply.headers = { Allow = "POST" }
      return reply
    end
    if not authorize(req) then return refused(401, Mcp.INVALID_REQUEST, "Unauthorized") end
    if not media_is(req.headers["content-type"], "application/json") then
      return refused(415, Mcp.INVALID_REQUEST, "the body must be application/json")
    end
    if not accepts(req.headers["accept"], "application/json") then
      return refused(406, Mcp.INVALID_REQUEST, "this server answers application/json")
    end
    local text, why = Stream.read_up_to(req.body, Mcp.MAX_MESSAGE_BYTES + 1)
    if text == nil then return refused(400, Mcp.PARSE_ERROR, tostring(why)) end
    if #text > Mcp.MAX_MESSAGE_BYTES then
      return refused(413, Mcp.INVALID_REQUEST, "the message is too large")
    end
    local message, bad = wire.message(text)
    if message == nil then return refused(400, bad.code or Mcp.INVALID_REQUEST, bad.message) end
    if message.method ~= nil and message.id ~= nil and message.method ~= "initialize" then
      if req.headers["mcp-protocol-version"] == nil then
        return { status = 400, headers = { ["Content-Type"] = "application/json" },
          body = wire.error(message.id, Mcp.HEADER_MISMATCH, "the request has no MCP-Protocol-Version header") }
      end
      local meta, _ = meta_of(message.params)
      if meta ~= nil then
        local wrong = mismatch(self, req, message)
        if wrong ~= "" then
          return { status = 400, headers = { ["Content-Type"] = "application/json" },
            body = wire.error(message.id, Mcp.HEADER_MISMATCH, wrong) }
        end
      end
    end
    local said = answer_message(self, message, req)
    if said.body == nil then return { status = said.status } end
    return { status = said.status, headers = { ["Content-Type"] = "application/json" }, body = said.body }
  end
end

--- Says `line` on stderr.
local function say(line: string)
  local _, _ = Fs.put(Fs.stderr, line .. "\n")
end

--- `text` (`host:port`, `[v6]:port`) as a TCP address, or nil and why.
local function listen_address(text: string): (Net.Address) | (nil, Failure)
  local host, port = text:match("^%[([^%]]+)%]:(%d+)$")
  if host == nil then host, port = text:match("^([^:]+):(%d+)$") end
  local number = if port ~= nil and #port <= 5 then math.tointeger(tonumber(port)) else nil end
  if host == nil or number == nil or number > 65535 then
    return nil, Failure.new("--http takes host:port, as 127.0.0.1:8080, not " .. text)
  end
  return Net.tcp(host, number)
end

--- What `main`'s HTTP options ask for: the spec, and where to listen.
local record Listening
  address: Net.Address
  spec: McpServer.HttpSpec
end

--- The HTTP serving `parsed` asks for, or nil and why it is refused.
local function listening(parsed: Flags.Parsed, at: string): (Listening) | (nil, Failure)
  local address, bad = listen_address(at)
  if address == nil then return nil, bad end
  local token_env = parsed.values["--token-env"]
  local anyone = parsed.set["--anyone"] == true
  local authorize: function(HttpServer.Request): boolean
  if token_env ~= nil and anyone then
    return nil, Failure.new("--token-env and --anyone are each other's opposite: give one")
  elseif token_env ~= nil then
    local token = Env.get(token_env)
    if token == nil or #token < 16 then
      return nil, Failure.new("--token-env " .. token_env .. ": $" .. token_env ..
          " must hold a token of at least 16 bytes")
    end
    authorize = McpServer.bearer(token)
  elseif anyone then
    if not Net.is_loopback(address) then
      return nil, Failure.new("--anyone serves every caller, so only on a loopback host, not " .. at)
    end
    authorize = McpServer.anyone
  else
    return nil, Failure.new("--http needs --token-env NAME, the variable that holds the bearer token, or --anyone " ..
        "on a loopback host")
  end
  return { address = address, spec = { authorize = authorize, origins = parsed.all["--origin"], path = parsed.values["--path"] } }
end

--- [`McpServer.Instance.main`].
local function main(self: McpServer.Instance, argv: {string}, from?: integer): integer
  local parsed, trouble = Flags.parse(argv, from or 1, MAIN_OPTIONS)
  if parsed == nil then
    say("mcp: " .. trouble)
    return 2
  end
  if #parsed.words > 0 then
    say("mcp: " .. parsed.words[1] .. ": the server takes options only")
    return 2
  end
  for _, name in ipairs({ "--http", "--token-env", "--path" }) do
    local all = parsed.all[name]
    if all ~= nil and #all > 1 then
      say("mcp: " .. name .. " is given more than once")
      return 2
    end
  end
  local path_given = parsed.values["--path"]
  if path_given ~= nil and path_given:sub(1, 1) ~= "/" then
    say("mcp: --path takes a path that starts with /, not " .. path_given)
    return 2
  end
  local at = parsed.values["--http"]
  if at == nil then
    for _, name in ipairs(parsed.given) do
      say("mcp: " .. name .. " is for --http")
      return 2
    end
    local ok, why = self:serve_stdio()
    if not ok then
      say("mcp: " .. tostring(why))
      return 1
    end
    return 0
  end
  local wanted, refused_why = listening(parsed, at)
  if wanted == nil then
    say("mcp: " .. tostring(refused_why))
    return 2
  end
  local path = wanted.spec.path or "/mcp"
  local Http = require("cosmic.http.server")
  local served, why = Http.serve{
    listeners = { wanted.address },
    handle = self:handler(wanted.spec),
    on_ready = function(addresses: {Net.Address}, _: Net.Server)
      for _, bound in ipairs(addresses) do
        local host = bound.host or ""
        if host:find(":", 1, true) then host = "[" .. host .. "]" end
        say("mcp: serving http://" .. host .. ":" .. tostring(bound.port) .. path)
      end
    end,
  }
  if not served then
    say("mcp: " .. tostring(why))
    return 1
  end
  return 0
end

--- A server, over its state.
local class Running is McpServer.Instance
  state: State

  function answer(self, text: string, http?: HttpServer.Request): McpServer.Answer
    return answer(self.state, text, http)
  end

  function serve_stdio(self, input?: Stream.Reader, output?: Stream.Writer): (true) | (false, Failure)
    return serve_stdio(self.state, input, output)
  end

  function handler(self, spec: McpServer.HttpSpec): function(HttpServer.Request): HttpServer.Reply
    return handler(self.state, spec)
  end

  function main(self, argv: {string}, from?: integer): integer
    return main(self, argv, from)
  end
end

--- A new server of `spec`. A tool named twice or outside `A-Z a-z 0-9
--- _ - .`, one whose schema is not `"type": "object"` or names an
--- `x-mcp-header` the transport refuses, a resource's URI or a prompt's
--- name given twice, raises.
function McpServer.new(spec: McpServer.Spec): McpServer.Instance
  local running: Running = { state = state_of(spec) }
  return running
end

--- An `authorize` that lets a request in when its `Authorization` is
--- `Bearer <token>` (the scheme in any case), the token compared in
--- constant time. A `token` shorter than
--- 16 bytes raises: one a person could guess is no token.
function McpServer.bearer(token: string): function(HttpServer.Request): boolean
  if #token < 16 then error("mcp: bearer: a token must be at least 16 bytes", 2) end
  return function(req: HttpServer.Request): boolean
    local said = req.headers["authorization"]
    if said == nil then return false end
    local scheme, credentials = said:match("^(%S+) +(%S+)%s*$")
    return scheme ~= nil and credentials ~= nil and scheme:lower() == "bearer" and Hash.equal(credentials, token)
  end
end

--- The calls of one command tool now running.
local record CallCount
  mut count: integer
end

--- One call's place among them, given back however the call ends: a return, a raise, or its task ended mid-wait.
local class Slot
  running: CallCount

  function __close(self)
    self.running.count = self.running.count - 1
  end
end

--- The most bytes of a failed call's stderr the client is sent; the rest is cut.
local SAID_LIMIT <const> = 16 * 1024

--- `text` cut to [`SAID_LIMIT`] bytes on a character's boundary, saying so where it is cut.
local function capped(text: string): string
  if #text <= SAID_LIMIT then return text end
  local cut = SAID_LIMIT
  while cut > 0 and utf8.len(text:sub(1, cut)) == nil do cut = cut - 1 end
  return text:sub(1, cut) .. "\n(cut at " .. String.counted(SAID_LIMIT, "byte") .. ")"
end

--- A tool whose every call runs `spec.argv` under `spec.policy` ([`Child.run`]), so the tool reaches what the
--- policy grants and nothing of the server's: the arguments go to the program's stdin as a JSON object, what it
--- prints on stdout is the result's text, and an exit other than 0 is a result with `isError`, its stderr (or
--- stdout, where stderr is empty) the text, its first 16 KiB: the client reads what the program prints there, so a
--- program prints nothing it would not show the client. A call that runs past `timeout_ns`, or prints more than
--- `output_limit` (on stdout or stderr, each held to it, so a call holds up to twice it), or sends what is not UTF-8,
--- is an error result too, and so is one past `concurrency` calls at once. A program that does not start, or that
--- the server is told to stop while it runs, is a raise: the client is told the server failed, and
--- [`McpServer.Spec.on_error`] how. The program learns nothing of the request beyond its arguments: not the client,
--- and not an HTTP request's headers, where a token is; and of the server's environment only what `policy.env`
--- passes on. The policy is merged ([`Sandbox.merge`]) once, here. A policy it refuses, a grant or `cwd` that is
--- not absolute, a `cwd` with a `..` step, a NUL byte in `argv` or `cwd`, an empty `argv`, or a limit below 1
--- raises.
---
---     local tool = McpServer.command{
---       tool = { name = "word_count", inputSchema = Mcp.object_schema({ path = { type = "string" } }) },
---       argv = { "/usr/bin/wc", "-w" },
---       policy = { profiles = { "system" } },
---     }
function McpServer.command(spec: McpServer.CommandSpec): McpServer.ToolSpec
  local name = spec.tool.name
  local argv: mut {string} = {}
  for _, word in ipairs(spec.argv) do argv[#argv + 1] = word end
  if argv[1] == nil or argv[1] == "" then
    refuse("command: " .. name .. ": argv names no program")
  end
  for _, word in ipairs(argv) do
    if word:find("\0", 1, true) ~= nil then
      refuse("command: " .. name .. ": a word of argv holds a NUL byte")
    end
  end
  -- Merged now, and so copied: what runs is the policy as it was given, and its profiles' paths as they are now.
  local merged, why = Sandbox.merge(spec.policy)
  if merged == nil then refuse("command: " .. name .. ": " .. why) end
  local checked, check_why = Sandbox.check(merged)
  if not checked then refuse("command: " .. name .. ": " .. check_why) end
  for _, grant in ipairs(merged.grants or {}) do
    if grant.path:sub(1, 1) ~= "/" then
      refuse("command: " .. name .. ": grant " .. grant.path .. " is relative: a call would read it from the " ..
          "server's directory as it is then")
    end
  end
  local cwd = spec.cwd
  if cwd ~= nil and cwd:sub(1, 1) ~= "/" then
    refuse("command: " .. name .. ": cwd " .. cwd .. " is relative")
  end
  if cwd ~= nil and (cwd:find("\0", 1, true) ~= nil or ("/" .. cwd .. "/"):find("/../", 1, true) ~= nil) then
    refuse("command: " .. name .. ": cwd must name its directory with no NUL byte and no .. step")
  end
  local timeout_ns = spec.timeout_ns or Clock.seconds(60)
  local limit = spec.output_limit or 1024 * 1024
  local most = spec.concurrency or 4
  if timeout_ns < 1 or limit < 1 or most < 1 then
    refuse("command: " .. name .. ": a limit must be at least 1")
  end
  local running: CallCount = { count = 0 }
  return {
    tool = spec.tool,
    call = function(arguments: {string: Json.Value}, _: McpServer.Call): (Mcp.ToolResult) | (nil, Failure)
      local input, bad = Json.encode(arguments)
      if input == nil then return nil, bad end
      if running.count >= most then
        return Mcp.result({ "the tool is running " .. String.counted(most, "call") .. " already: try again" }, true)
      end
      running.count = running.count + 1
      local _slot <close>: Slot = { running = running }
      local ran, trouble = Child.run(argv, { policy = merged, cwd = cwd, input = input, stdout = "capture",
        stderr = "capture", capture_limit = limit, timeout_ns = timeout_ns })
      -- How the run failed (a start refused, or the server told to stop while it waited) names the host's paths and
      -- the policy's shape: the server's to read, not the client's.
      if ran == nil then
        error("command: " .. name .. ": the program did not start, or did not run to its end: " .. trouble, 0)
      end
      if ran.timed_out then return Mcp.result({ "the tool ran past its time" }, true) end
      if ran.truncated then
        return Mcp.result({ "the tool printed more than " .. String.counted(limit, "byte") }, true)
      end
      local out, err = ran.stdout or "", ran.stderr or ""
      -- Only the stream the client is sent must be text.
      if ran.ok then
        if utf8.len(out) == nil then
          return Mcp.result({ "the tool printed bytes that are not UTF-8 text" }, true)
        end
        return Mcp.result({ out })
      end
      local said = if err ~= "" then err elseif out ~= "" then out else
        (if ran.code ~= nil then "the tool exited " .. tostring(ran.code) else
          "the tool was ended by signal " .. tostring(ran.signal) end) end
      if utf8.len(said) == nil then
        return Mcp.result({ "the tool failed and printed bytes that are not UTF-8 text" }, true)
      end
      return Mcp.result({ capped(said) }, true)
    end,
  }
end

--- An `authorize` that lets every request in: for a server bound to
--- loopback whose every caller may use every tool, or one behind a proxy
--- that authorizes.
function McpServer.anyone(_: HttpServer.Request): boolean
  return true
end

return McpServer

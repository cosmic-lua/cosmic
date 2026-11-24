--- A Model Context Protocol client ([`cosmic.mcp`], revision 2026-07-28):
--- it lists and calls a server's tools, reads its resources and gets
--- its prompts, over stdio ([`McpClient.spawn`], [`McpClient.stdio`]) or
--- Streamable HTTP ([`McpClient.http`]).
---
---     local Child = require("cosmic.child")
---     local McpClient = require("cosmic.mcp.client")
---
---     local session = assert(McpClient.spawn({ "./adder" }, { timeout_ns = Child.FOREVER }))
---     for _, tool in ipairs(assert(session:tools())) do print(tool.name) end
---     local said = assert(session:call("add", { a = 1, b = 2 }))
---     print(assert(said.content[1]).text)
---     assert(session:close())
---
--- The protocol is stateless, so there is no handshake: each request
--- carries the protocol version and the client's capabilities, and a
--- session is only where requests go. A server that speaks another
--- revision responds to the first request with the versions it speaks,
--- which the failure names.
---
--- Every fallible call returns its value, or nil and a [`Failure`]:
--- `code` holds the JSON-RPC code where the server refused the request
--- ([`Mcp.METHOD_NOT_FOUND`], [`Mcp.UNSUPPORTED_VERSION`]), and nil where
--- the request never got a response (a pipe closed, a connection
--- refused, a timeout).
---
--- A tool's result, a resource's text and a prompt are what the server
--- says, and a model reads them: treat them as untrusted input, as the
--- tools' descriptions and annotations are. A server started with
--- [`McpClient.spawn`] runs with this program's rights unless
--- `opts.sandbox` holds it to less ([`cosmic.sandbox`]): start one you
--- did not write under a policy that grants what it needs and no more.
--- @public

local Child = require("cosmic.child")
local Failure = require("cosmic.failure")
local Http = require("cosmic.http")
local Json = require("cosmic.json")
local Poll = require("cosmic.poll")
local JsonSchema = require("cosmic.jsonschema")
local Mcp = require("cosmic.mcp")
local McpOAuth = require("cosmic.mcp.oauth")
local Net = require("cosmic.net")
local Stream = require("cosmic.stream")
local String = require("cosmic.string")
local Url = require("cosmic.url")
local wire = require("cosmic.mcp.wire")

local record McpClient
  --- What [`McpClient.http`] takes.
  record HttpOptions
    --- How long one request may take, as [`Http.Options.timeout_ns`].
    timeout_ns: integer
    --- Headers sent with each request: `Authorization`, say. The
    --- protocol's own are set here and cannot be given. Over plain
    --- `http://`, headers go only to a loopback host.
    headers?: {string: string}
    --- How this client names itself (`cosmic`).
    info?: Mcp.Implementation
    --- Asks the person, as [`Options.elicit`] says.
    elicit?: Elicit
    --- Where given, a request the server refuses with 401 or 403 signs
    --- in, refreshes or steps up as [`cosmic.mcp.oauth`] says, and is
    --- sent again: once after a 401 and once after a 403. `headers` may
    --- not then name `Authorization`, and the URL must be https, or http
    --- on a loopback address.
    oauth?: McpOAuth.Options
  end

  --- Asks the person what a server's `elicitation/create` asks, and
  --- returns what they did: show `message` and a form of
  --- `requestedSchema`'s fields, or `message` and the `url` (a link the
  --- person chooses to open, never opened for them). What the server asks
  --- is untrusted: show which server asks, and let the person decline.
  type Elicit = function(elicitation: Mcp.Elicitation): (Mcp.Elicited) | (nil, Failure)

  --- What [`McpClient.stdio`] and [`McpClient.spawn`] take.
  record Options
    --- How this client names itself (`cosmic`).
    info?: Mcp.Implementation
    --- Where given, the client declares that a server may ask for input
    --- in a form or at a URL, and a tool call, a prompt's get or a
    --- resource's read that the server responds to with a need for input
    --- is asked again with each reply this returns. A failure it returns
    --- fails the call. Where nil, a server that needs input fails the
    --- call.
    elicit?: Elicit
  end

  --- How one call of a tool goes.
  record CallOptions
    --- Given each notice of the call's progress as it comes, in order:
    --- the call asks the server for them (a `progressToken`). A server
    --- may send none. Over HTTP the response then comes as an event
    --- stream, read as it arrives.
    on_progress?: function(progress: Mcp.Progress)
  end

  --- What a subscription asks to be told of, which [`Session.listen`]
  --- takes; its `on_ack` is given what the server agreed to, in the same
  --- shape.
  record Subscription
    --- That the server's list of tools changed.
    tools?: boolean
    --- That its list of prompts changed.
    prompts?: boolean
    --- That its list of resources, or of their families, changed.
    resources?: boolean
    --- The URIs of the resources whose updates to be told of.
    uris?: {string}
  end

  --- What a notice of a subscription tells of: that the list of
  --- `tools`, `prompts` or `resources` changed, or that a resource was
  --- `updated`.
  enum NoticeKind
    "tools"
    "prompts"
    "resources"
    "updated"
  end

  --- One notice of a subscription.
  record Notice
    --- What changed.
    kind: NoticeKind
    --- The resource that changed, for `updated`.
    uri?: string
  end

  --- Where a client's requests go. Each call is one request (a list,
  --- one per page), its response read before it returns. Tasks of one run
  --- may call a session at once: over stdio each request waits for its
  --- own response, and over HTTP each is a POST of its own.
  -- TODO: once Failure has a kind (the API audit's finding 2), give a
  -- request that timed out or whose pipe closed its kind, so a caller
  -- tells it from a refusal without reading the words.
  interface Session
    --- What the server is: the versions it speaks, what it can do,
    --- how it names itself.
    discover: function(Session): (Mcp.Discovery) | (nil, Failure)
    --- Every tool the server offers, page after page. Over HTTP, a tool
    --- whose schema names an `x-mcp-header` the transport refuses is
    --- left out, as the protocol has a client do.
    tools: function(Session): ({Mcp.Tool}) | (nil, Failure)
    --- Calls the tool `name` with `arguments`, as `opts` says. A tool that ran and
    --- failed is a result with `isError`; a call the server refused is
    --- a failure. Where [`cosmic.mcp.client.Session.tools`] listed the tool with an
    --- `outputSchema` this client can check, a result that is not an
    --- error and whose `structuredContent` does not hold to it is a
    --- failure too.
    --- A task that calls it and is cancelled cancels the call: over
    --- stdio the session sends `notifications/cancelled`, and over HTTP
    --- the request's connection closes, which the server reads as one.
    call: function(Session, name: string, arguments?: {string: Json.Value}, opts?: CallOptions): (Mcp.ToolResult) | (nil, Failure)
    --- Every resource the server lists.
    resources: function(Session): ({Mcp.Resource}) | (nil, Failure)
    --- Every family of resources the server lists.
    templates: function(Session): ({Mcp.ResourceTemplate}) | (nil, Failure)
    --- What the resource `uri` holds.
    read: function(Session, uri: string): ({Mcp.ResourceContents}) | (nil, Failure)
    --- Every prompt the server offers.
    prompts: function(Session): ({Mcp.Prompt}) | (nil, Failure)
    --- The prompt `name`, filled in from `arguments`.
    prompt: function(Session, name: string, arguments?: {string: string}): (Mcp.PromptResult) | (nil, Failure)
    --- Values for one argument of a prompt, or one variable of a
    --- resource template, that fit what `asked` says is typed so far:
    --- `{ prompt = "review", argument = "language", value = "py" }`.
    complete: function(Session, asked: Mcp.Completing): (Mcp.Completion) | (nil, Failure)
    --- Subscribes to the changes `wanted` names, giving `on_notice` each
    --- notice as it comes, and `on_ack` what the server agreed to, once,
    --- first: a server leaves out what it cannot tell of. It runs until
    --- the server ends the subscription, when it returns true, or until
    --- its task is cancelled, when it returns false and a Failure of
    --- kind "cancelled"; the request has no time limit. Over stdio,
    --- other tasks may call the session meanwhile. A notice says only
    --- what changed: list or read again to see how.
    listen: function(Session, wanted: Subscription, on_notice: function(Notice),
                     on_ack?: function(agreed: Subscription)): (true) | (false, Failure)
    --- Ends the session: closes the server's stdin and waits for a
    --- spawned server to exit. Safe to call more than once.
    close: function(Session): (true) | (false, Failure)
  end
end

--- The most pages of one list a client reads, so a server that responds with
--- a cursor for ever ends the list with a failure.
local MAX_PAGES <const> = 1000

--- The most items of one list a client holds, so a server cannot have
--- it hold what its pages add up to without end.
local MAX_ITEMS <const> = 10000

local META_VERSION <const> = "io.modelcontextprotocol/protocolVersion"
local META_CAPABILITIES <const> = "io.modelcontextprotocol/clientCapabilities"
local META_CLIENT <const> = "io.modelcontextprotocol/clientInfo"

local DEFAULT_INFO <const>: Mcp.Implementation = { name = "cosmic", version = "1" }

--- One request as a transport sends it.
local record Request
  id: string
  method: string
  params: {string: Json.Value}
  --- What `Mcp-Name` carries, for a method that names one.
  name?: string
  --- The `Mcp-Param-` headers, name to value, before encoding.
  mirrored?: {string: string}
  --- Given each notice of progress whose token is the request's id.
  on_progress?: function(Mcp.Progress)
  --- The last progress given: one that does not grow it is not given.
  mut last_progress?: number
  --- Given each notice of the subscription whose id is the request's: a `subscriptions/listen`.
  on_notice?: function(wire.Message)
  --- Whether the request runs until it is ended, with no time limit: a `subscriptions/listen` over HTTP.
  forever: boolean
end

--- What a request takes beside its method and fields.
local record Asking
  name?: string
  mirrored?: {string: string}
  on_progress?: function(Mcp.Progress)
  on_notice?: function(wire.Message)
  forever?: boolean
  --- Whether the server may respond that it needs input: a tool call, a prompt's get, a resource's read.
  may_ask?: boolean
end

--- Sends one request and returns its response, which holds a result,
--- or nil and why.
local type Send = function(Request): (wire.Message) | (nil, Failure)

--- The state of a session.
local record State
  send: Send
  info: Mcp.Implementation
  --- Whether the transport is HTTP, which mirrors arguments into headers.
  http: boolean
  mut next_id: integer
  --- What each tool listed mirrors into headers, by its name.
  mut mirrors: {string: {Mcp.Mirror}}
  --- The `outputSchema` of each tool listed with one this client can check, compiled, by its name.
  mut outputs: {string: JsonSchema.Schema}
  --- Ends the transport.
  finish: function(): (true) | (false, Failure)
  mut closed: boolean
  elicit?: McpClient.Elicit
end

--- The most rounds a request that needs input is asked again, so a server that asks for ever ends it.
local MAX_ROUNDS <const> = 10

--- The failure a server's error response says.
local function refused(err: wire.Error): Failure
  local message = "mcp: " .. err.message
  if err.code == Mcp.UNSUPPORTED_VERSION then
    message = message .. " (this client speaks " .. Mcp.VERSION .. ")"
  end
  return Failure.coded(message, err.code)
end

--- The params of a request of `fields` and the `_meta` every request
--- carries.
local function params_of(self: State, fields: {string: Json.Value}, token?: integer): {string: Json.Value}
  local out: mut {string: Json.Value} = {}
  for k, v in pairs(fields) do out[k] = v end
  local capabilities: mut {string: Json.Value} = {}
  if self.elicit ~= nil then
    local form: {string: Json.Value} = {}
    local url: {string: Json.Value} = {}
    capabilities["elicitation"] = { form = form, url = url }
  end
  local meta: mut {string: Json.Value} = {
    [META_VERSION] = Mcp.VERSION,
    [META_CLIENT] = wire.implementation(self.info),
    [META_CAPABILITIES] = capabilities,
  }
  if token ~= nil then meta["progressToken"] = token end
  out["_meta"] = meta
  return out
end

--- Sends `method` with `fields`, and returns the result once it is a
--- final one.
--- What the session's `elicit` returns for each request of `needs`, by key; or why there are none.
local function answers(self: State, method: string, needs: wire.Needs): ({string: Json.Value}) | (nil, Failure)
  local out: mut {string: Json.Value} = {}
  for key, request in pairs(needs.requests) do
    local elicit = self.elicit
    if request.method ~= "elicitation/create" or elicit == nil then
      return nil, Failure.new("mcp: " .. method .. ": the server asks for " .. request.method ..
          ", which this client does not give")
    end
    local elicitation, bad = wire.elicitation_of(request.params)
    if elicitation == nil then return nil, bad end
    local answer, why = elicit(elicitation)
    if answer == nil then return nil, why end
    out[key] = wire.elicited(answer)
  end
  return out
end

--- Sends `method` with `fields`, and returns the result once it is a
--- final one: where the server needs input first, the session's `elicit`
--- gives it, and the request is sent again with the replies and the
--- server's state, as a new request.
local function ask(self: State, method: string, fields: {string: Json.Value}, opts?: Asking): (wire.Message) | (nil, Failure)
  if self.closed then return nil, Failure.new("mcp: the session is closed") end
  local o: Asking = opts or {}
  local sent: {string: Json.Value} = fields
  for _ = 1, MAX_ROUNDS do
    self.next_id = self.next_id + 1
    -- The request's id is its progress token: unique among the requests in flight, as the token must be.
    local token = if o.on_progress ~= nil then self.next_id else nil end
    local req: Request = { id = tostring(self.next_id), method = method, params = params_of(self, sent, token),
      name = o.name, mirrored = o.mirrored, on_progress = o.on_progress, on_notice = o.on_notice,
      forever = o.forever == true }
    local response, why = self.send(req)
    if response == nil then return nil, why end
    if not (o.may_ask == true and self.elicit ~= nil and wire.needs_input(response.result)) then
      local complete, kind = wire.complete(response.result)
      if not complete then return nil, kind end
      return response
    end
    local needs, bad = wire.needs_of(response.result)
    if needs == nil then return nil, bad end
    local given, failed = answers(self, method, needs)
    if given == nil then return nil, failed end
    -- The retry is the first request and the replies: the state exactly as sent, and none where none was.
    local again: mut {string: Json.Value} = {}
    for k, v in pairs(fields) do again[k] = v end
    if next(given) ~= nil then again["inputResponses"] = given end
    local state = needs.state
    if state ~= nil then again["requestState"] = state end
    sent = again
  end
  return nil, Failure.new("mcp: " .. method .. ": the server asked for input more than " ..
      String.counted(MAX_ROUNDS, "time"))
end

--- What `each` returns for a page of the list the server sends for
--- `method`: the next page's cursor, nil at the last, or why it failed.
local record Step
  --- The next page's cursor, nil at the last.
  next?: string
  --- Why the page was refused.
  failure?: Failure
end

local function follow(self: State, method: string, each: function(result: any): Step): (true) | (false, Failure)
  local cursor: string? = nil
  local seen: mut {string: boolean} = {}
  for _ = 1, MAX_PAGES do
    local fields: mut {string: Json.Value} = {}
    if cursor ~= nil then fields["cursor"] = cursor end
    local response, why = ask(self, method, fields)
    if response == nil then return false, why end
    local step = each(response.result)
    local failure, following = step.failure, step.next
    if failure ~= nil then return false, failure end
    if following == nil then return true end
    if seen[following] == true then
      return false, Failure.new("mcp: " .. method .. " answered the cursor " .. Json.quote(following) .. " twice")
    end
    seen[following] = true
    cursor = following
  end
  return false, Failure.new("mcp: " .. method .. " answered more than " .. String.counted(MAX_PAGES, "page"))
end

--- A page read whole, and the next one's cursor, nil at the last.
local function next_of(cursor?: string): Step
  return { next = cursor }
end

--- The failure of a list the server sends for `method` with more than [`MAX_ITEMS`] items.
local function too_many(method: string): Failure
  return Failure.new("mcp: " .. method .. " answered more than " .. String.counted(MAX_ITEMS, "item"))
end

--- A page refused for `why`.
local function stopped(why: Failure): Step
  return { failure = why }
end

local function tools(self: State): ({Mcp.Tool}) | (nil, Failure)
  local out: mut {Mcp.Tool} = {}
  local fresh: mut {string: {Mcp.Mirror}} = {}
  local outputs: mut {string: JsonSchema.Schema} = {}
  local ok, why = follow(self, "tools/list", function(result: any): Step
    local page, bad = wire.tools(result)
    if page == nil then return stopped(bad) end
    for _, raw in ipairs(page.tools) do
      local tool, wrong = wire.tool_of(raw)
      if tool == nil then return stopped(wrong) end
      local mirrors, _ = Mcp.mirrors(tool.inputSchema)
      -- Over HTTP a tool whose headers cannot be sent is left out, as
      -- the protocol says; over stdio there are no headers to send.
      if mirrors ~= nil then fresh[tool.name] = mirrors end
      -- A schema that uses what cosmic.jsonschema does not check is
      -- left unchecked, not refused: the tool is the server's to say.
      local promised = tool.outputSchema
      if promised ~= nil then
        local schema, _ = JsonSchema.compile(promised)
        if schema ~= nil then outputs[tool.name] = schema end
      end
      if mirrors ~= nil or not self.http then out[#out + 1] = tool end
    end
    if #out > MAX_ITEMS then return stopped(too_many("tools/list")) end
    return next_of(page.nextCursor)
  end)
  if not ok then return nil, why end
  -- The headers of the tools as they are now: one listed before and
  -- gone or changed since sends what it sends now, or nothing.
  self.mirrors = fresh
  self.outputs = outputs
  return out
end

--- `answer` as a result of the tool `name`: a failure where it is not one, or is not an error and its
--- `structuredContent` does not hold to the tool's `outputSchema` as listed.
local function checked(self: State, name: string, answer: any): (Mcp.ToolResult) | (nil, Failure)
  local r, why = wire.tool_result_of(answer)
  if r == nil then return nil, why end
  local schema = self.outputs[name]
  if schema == nil or r.isError == true then return r end
  local structured = r.structuredContent
  if structured == nil then
    return nil, Failure.new("mcp: tool " .. Json.quote(name) .. " answered no structuredContent, though it lists an outputSchema")
  end
  local fits, unfit = schema:check(structured)
  if not fits then
    return nil, Failure.new("mcp: tool " .. Json.quote(name) .. " answered structuredContent that does not hold to its outputSchema: " .. tostring(unfit))
  end
  return r
end

local function call(self: State, name: string, arguments?: {string: Json.Value},
                    opts?: McpClient.CallOptions): (Mcp.ToolResult) | (nil, Failure)
  local on_progress = if opts ~= nil then opts.on_progress else nil end
  local args: {string: Json.Value} = arguments or {}
  local fields: {string: Json.Value} = { name = name, arguments = args }
  local function mirrored(): ({string: string}) | (nil, Failure)
    local headers: mut {string: string} = {}
    for _, m in ipairs(self.mirrors[name] or {}) do
      local value, why = Mcp.mirror_value(args, m.path)
      if value == nil then return nil, why end
      if value is string then headers[m.header] = value end
    end
    return headers
  end
  local headers, why = mirrored()
  if headers == nil then return nil, why end
  local response, failed = ask(self, "tools/call", fields, { name = name, mirrored = headers, on_progress = on_progress, may_ask = true })
  if response ~= nil then return checked(self, name, response.result) end
  if not (self.http and failed.code == Mcp.HEADER_MISMATCH) then return nil, failed end
  -- The tool's schema may have changed since it was listed: list again,
  -- and send the headers it names now.
  local listed, lwhy = tools(self)
  if listed == nil then return nil, lwhy end
  local again, awhy = mirrored()
  if again == nil then return nil, awhy end
  local retried, rwhy = ask(self, "tools/call", fields, { name = name, mirrored = again, on_progress = on_progress, may_ask = true })
  if retried == nil then return nil, rwhy end
  return checked(self, name, retried.result)
end

local function resources(self: State): ({Mcp.Resource}) | (nil, Failure)
  local out: mut {Mcp.Resource} = {}
  local ok, why = follow(self, "resources/list", function(result: any): Step
    local page, bad = wire.resources(result)
    if page == nil then return stopped(bad) end
    for _, r in ipairs(page.resources) do out[#out + 1] = r end
    if #out > MAX_ITEMS then return stopped(too_many("resources/list")) end
    return next_of(page.nextCursor)
  end)
  if not ok then return nil, why end
  return out
end

local function templates(self: State): ({Mcp.ResourceTemplate}) | (nil, Failure)
  local out: mut {Mcp.ResourceTemplate} = {}
  local ok, why = follow(self, "resources/templates/list", function(result: any): Step
    local page, bad = wire.templates(result)
    if page == nil then return stopped(bad) end
    for _, t in ipairs(page.resourceTemplates) do out[#out + 1] = t end
    if #out > MAX_ITEMS then return stopped(too_many("resources/templates/list")) end
    return next_of(page.nextCursor)
  end)
  if not ok then return nil, why end
  return out
end

local function prompts(self: State): ({Mcp.Prompt}) | (nil, Failure)
  local out: mut {Mcp.Prompt} = {}
  local ok, why = follow(self, "prompts/list", function(result: any): Step
    local page, bad = wire.prompts(result)
    if page == nil then return stopped(bad) end
    for _, p in ipairs(page.prompts) do out[#out + 1] = p end
    if #out > MAX_ITEMS then return stopped(too_many("prompts/list")) end
    return next_of(page.nextCursor)
  end)
  if not ok then return nil, why end
  return out
end

local function read(self: State, uri: string): ({Mcp.ResourceContents}) | (nil, Failure)
  local response, why = ask(self, "resources/read", { uri = uri }, { name = uri, may_ask = true })
  if response == nil then return nil, why end
  return wire.read(response.result)
end

local function prompt(self: State, name: string, arguments?: {string: string}): (Mcp.PromptResult) | (nil, Failure)
  local args: mut {string: Json.Value} = {}
  for k, v in pairs(arguments or {}) do args[k] = v end
  local response, why = ask(self, "prompts/get", { name = name, arguments = args }, { name = name, may_ask = true })
  if response == nil then return nil, why end
  return wire.prompt_result_of(response.result)
end

local function complete(self: State, asked: Mcp.Completing): (Mcp.Completion) | (nil, Failure)
  local params, wrong = wire.completing(asked)
  if params == nil then return nil, wrong end
  local response, why = ask(self, "completion/complete", params)
  if response == nil then return nil, why end
  return wire.completion_of(response.result)
end

--- What the acknowledgment of a subscription, `params`, says the server agreed to.
local function agreed_of(params: any): McpClient.Subscription
  local p, _ = Json.to_object(params)
  local n = if p ~= nil then Json.object_of(p["notifications"]) else nil end
  if n == nil then return {} end
  local uris: mut {string} = {}
  for _, uri in ipairs(Json.array_of(n["resourceSubscriptions"]) or {}) do
    if uri is string then uris[#uris + 1] = uri end
  end
  return { tools = n["toolsListChanged"] == true, prompts = n["promptsListChanged"] == true,
    resources = n["resourcesListChanged"] == true, uris = uris }
end

--- The kind of notice a subscription's `method` is, nil for one it does not know.
local NOTICE_KINDS <const>: {string: McpClient.NoticeKind} = {
  ["notifications/tools/list_changed"] = "tools",
  ["notifications/prompts/list_changed"] = "prompts",
  ["notifications/resources/list_changed"] = "resources",
  ["notifications/resources/updated"] = "updated",
}

local function listen(self: State, wanted: McpClient.Subscription, on_notice: function(McpClient.Notice),
                      on_ack?: function(McpClient.Subscription)): (true) | (false, Failure)
  local asked: mut {string: Json.Value} = {}
  if wanted.tools == true then asked["toolsListChanged"] = true end
  if wanted.prompts == true then asked["promptsListChanged"] = true end
  if wanted.resources == true then asked["resourcesListChanged"] = true end
  local named: mut {string: boolean} = {}
  local uris = wanted.uris or {}
  for _, uri in ipairs(uris) do named[uri] = true end
  if #uris > 0 then asked["resourceSubscriptions"] = wire.strings(uris) end
  local acked = false
  local function heard_notice(message: wire.Message)
    local method = message.method or ""
    if method == "notifications/subscriptions/acknowledged" then
      if acked then return end
      acked = true
      if on_ack ~= nil then on_ack(agreed_of(message.params)) end
      return
    end
    -- The acknowledgment comes first; a notice before it, or of what was not asked, is passed over.
    local kind = NOTICE_KINDS[method]
    if not acked or kind == nil then return end
    if kind == "updated" then
      local p, _ = Json.to_object(message.params)
      local uri = if p ~= nil then p["uri"] else nil end
      if uri is string and named[uri] == true then on_notice({ kind = kind, uri = uri }) end
    elseif (kind == "tools" and wanted.tools == true) or (kind == "prompts" and wanted.prompts == true) or
        (kind == "resources" and wanted.resources == true) then
      on_notice({ kind = kind })
    end
  end
  local response, why = ask(self, "subscriptions/listen", { notifications = asked },
    { on_notice = heard_notice, forever = true })
  if response == nil then return false, why end
  return true
end

local function discover(self: State): (Mcp.Discovery) | (nil, Failure)
  local response, why = ask(self, "server/discover", {})
  if response == nil then return nil, why end
  return wire.discovery(response.result)
end

--- A session over its state.
local class Running is McpClient.Session
  state: State

  function discover(self): (Mcp.Discovery) | (nil, Failure) return discover(self.state) end
  function tools(self): ({Mcp.Tool}) | (nil, Failure) return tools(self.state) end
  function call(self, name: string, arguments?: {string: Json.Value}, opts?: McpClient.CallOptions): (Mcp.ToolResult) | (nil, Failure)
    return call(self.state, name, arguments, opts)
  end
  function resources(self): ({Mcp.Resource}) | (nil, Failure) return resources(self.state) end
  function templates(self): ({Mcp.ResourceTemplate}) | (nil, Failure)
    return templates(self.state)
  end
  function read(self, uri: string): ({Mcp.ResourceContents}) | (nil, Failure)
    return read(self.state, uri)
  end
  function prompts(self): ({Mcp.Prompt}) | (nil, Failure) return prompts(self.state) end
  function listen(self, wanted: McpClient.Subscription, on_notice: function(McpClient.Notice),
                  on_ack?: function(McpClient.Subscription)): (true) | (false, Failure)
    return listen(self.state, wanted, on_notice, on_ack)
  end
  function prompt(self, name: string, arguments?: {string: string}): (Mcp.PromptResult) | (nil, Failure)
    return prompt(self.state, name, arguments)
  end
  function complete(self, asked: Mcp.Completing): (Mcp.Completion) | (nil, Failure)
    return complete(self.state, asked)
  end
  function close(self): (true) | (false, Failure)
    local s = self.state
    if s.closed then return true end
    s.closed = true
    return s.finish()
  end
end

local function session(send: Send, opts?: McpClient.Options, http: boolean,
                       finish: function(): (true) | (false, Failure)): McpClient.Session
  local o: McpClient.Options = opts or {}
  local running: Running = {
    state = { send = send, info = o.info or DEFAULT_INFO, http = http, next_id = 0, mirrors = {}, outputs = {}, finish = finish,
      closed = false, elicit = o.elicit },
  }
  return running
end

--- Gives `req` the notice `message` where it is one of `req`'s: to `on_progress` a notice of its progress, to
--- `on_notice` a notice of its subscription.
local function heard(req: Request, message: wire.Message)
  if message.method == nil or message.id ~= nil then return end
  local on_notice = req.on_notice
  if on_notice ~= nil and message.method ~= "notifications/progress" then
    if wire.subscription_id(message.params) == req.id then on_notice(message) end
    return
  end
  local on_progress = req.on_progress
  if on_progress == nil or message.method ~= "notifications/progress" then return end
  local progress, token = wire.progress_of(message.params)
  if progress == nil or token ~= req.id then return end
  local last = req.last_progress
  if last ~= nil and progress.progress <= last then return end
  req.last_progress = progress.progress
  on_progress(progress)
end

-- stdio.

--- The most notices one request holds for its task to take: past it, the request fails, as the server sends faster
--- than the caller takes them.
local MAX_NOTICES <const> = 256

--- A request waiting for its response over stdio.
local record Waiter
  req: Request
  --- Woken when its response, a notice or its failure is in, or when it is its turn to read; nil outside a
  --- task, where the caller reads for itself.
  wake?: Poll.Notifier
  mut message?: wire.Message
  mut failure?: Failure
  --- Its notices, read by another task and held for its own to give, in order.
  notices: mut {wire.Message}
  --- Its task waits on `wake` now: only such a waiter is handed the reading, as a notice sent while none waits is lost.
  mut parked: boolean
  --- What a callback given one of its notices raised, raised again once the request is put away.
  mut raised?: any
end

--- One stdio connection to a server, which every task of the session shares. Each request waits for its own
--- response. One waiting task at a time reads, and hands each message to the request it belongs to; when it is
--- done, it hands the reading to another. No task reads while none waits, so a run with no request in flight ends.
local record Link
  lines: Stream.Lines
  writer: Stream.Writer
  waiting: mut {string: Waiter}
  --- A task reads now.
  mut reading: boolean
  --- A task writes now: a line is written whole, one at a time.
  mut writing: boolean
  --- The tasks waiting for their turn to write.
  writers: mut {Poll.Notifier}
  --- Why the link failed, for each request after.
  mut broken?: Failure
end

--- Calls `fn` shielded from a cancel where it runs in a task, as it is.
local function whole(fn: function())
  if Poll.in_task() then Poll.shielded(fn) else fn() end
end

--- Writes `text` as one line on `link`, whole, after any other task's line; it is shielded from a cancel once it
--- begins, so a line is never cut.
local function write_line(link: Link, text: string): (true) | (false, Failure)
  if link.writing then
    local turn = Poll.notifier()
    link.writers[#link.writers + 1] = turn
    local why: Failure? = nil
    while link.writing do
      local ok, failed = turn:wait()
      if not ok then
        why = failed
        break
      end
    end
    for i, each in ipairs(link.writers) do
      if each == turn then
        table.remove(link.writers, i)
        break
      end
    end
    if why ~= nil then return false, why end
  end
  link.writing = true
  local ok, trouble = true, ""
  whole(function()
    ok, trouble = link.writer:write(text .. "\n")
  end)
  link.writing = false
  -- Each waiting writer looks again, so the turn is never lost to one whose task was cancelled meanwhile.
  for _, turn in ipairs(link.writers) do turn:notify_one() end
  if not ok then return false, Failure.new("mcp: writing to the server: " .. trouble) end
  return true
end

--- Wakes `w`'s task, where it waits in one.
local function woken(w: Waiter)
  local wake = w.wake
  if wake ~= nil then wake:notify_one() end
end

--- Gives `message` to the request it belongs to: a response, a notice of progress, a subscription's notice.
local function route(link: Link, message: wire.Message)
  local key: string? = nil
  if message.method == nil then
    key = message.id
  elseif message.id == nil and message.method == "notifications/progress" then
    local _, token = wire.progress_of(message.params)
    key = token
  elseif message.id == nil then
    key = wire.subscription_id(message.params)
  end
  if key == nil then return end
  local w = link.waiting[key]
  if w == nil then return end
  if message.method == nil then
    w.message = message
  elseif #w.notices >= MAX_NOTICES then
    w.failure = Failure.new("mcp: " .. w.req.method .. ": the server sent more than " ..
        String.counted(MAX_NOTICES, "notice") .. " before they were taken")
  else
    w.notices[#w.notices + 1] = message
  end
  woken(w)
end

--- Fails every request waiting on `link` with `why`, and each after.
local function break_link(link: Link, why: Failure)
  link.broken = why
  for _, w in pairs(link.waiting) do
    w.failure = why
    woken(w)
  end
end

--- Reads one message from `link` and routes it: false where the read was cancelled, which leaves the lines as they
--- were, or where the link broke (the server is done, or wrote what is not a message).
local function read_one(link: Link): boolean
  local line, trouble = link.lines:read()
  if line == nil then
    if trouble == Poll.CANCELLED or trouble == Poll.TIMEOUT then return false end
    if trouble ~= "" then
      break_link(link, Failure.new("mcp: reading from the server: " .. trouble))
    else
      break_link(link, Failure.new("mcp: the server closed its output"))
    end
    return false
  end
  if line:find("%S") ~= nil then
    local message, bad = wire.message(line)
    if message == nil then
      break_link(link, Failure.new("mcp: the server wrote a line that is not a message: " .. bad.message))
      return false
    end
    route(link, message)
  end
  return true
end

--- Hands the reading on to a request still waiting, where no task reads.
local function hand_on(link: Link)
  if link.reading then return end
  for _, w in pairs(link.waiting) do
    if w.parked then
      woken(w)
      return
    end
  end
end

--- Gives `w`'s request the notices held for it, in order.
local function give(w: Waiter)
  while #w.notices > 0 and w.raised == nil do
    local message = assert(table.remove(w.notices, 1))
    local ok, err = pcall(heard, w.req, message)
    if not ok then
      w.raised = err
      w.failure = Failure.new("mcp: " .. w.req.method .. ": a callback raised")
    end
  end
end

--- Whether `w` is done: its response or its failure is in.
local function done(w: Waiter): boolean
  return w.message ~= nil or w.failure ~= nil
end

--- Waits in a task for `w`'s response, reading for every request while no other task does: false where the task
--- is cancelled.
local function wait_in_task(link: Link, w: Waiter): boolean
  local wake = assert(w.wake)
  while true do
    give(w)
    if done(w) then return true end
    if #w.notices == 0 then
      if not link.reading then
        link.reading = true
        local ok = read_one(link)
        link.reading = false
        if not ok and link.broken == nil then return false end
      else
        w.parked = true
        local ok, _ = wake:wait()
        w.parked = false
        if not ok then return false end
      end
    end
  end
end

--- Tells the server `req` is cancelled, as stdio has no stream of it to close.
local function cancelled(link: Link, req: Request)
  local note: {string: Json.Value} = { requestId = assert(math.tointeger(tonumber(req.id))), reason = "the caller cancelled" }
  whole(function()
    local _, _ = write_line(link, wire.notification("notifications/cancelled", note))
  end)
end

--- Sends `req` over `link` and returns its response, or why there is none.
local function link_send(link: Link, req: Request): (wire.Message) | (nil, Failure)
  local broken = link.broken
  if broken ~= nil then return nil, broken end
  local in_task = Poll.in_task()
  local wake: Poll.Notifier? = nil
  if in_task then wake = Poll.notifier() end
  local w: Waiter = { req = req, wake = wake, notices = {}, parked = false }
  link.waiting[req.id] = w
  local wrote, wwhy = write_line(link, wire.request(req.id, req.method, req.params))
  if not wrote then
    link.waiting[req.id] = nil
    return nil, wwhy
  end
  if in_task then
    local ok = wait_in_task(link, w)
    link.waiting[req.id] = nil
    hand_on(link)
    if not ok then
      cancelled(link, req)
      return nil, Failure.cancelled("mcp: " .. req.method .. " was cancelled")
    end
  else
    -- Outside a task nothing else runs: the caller reads until its response is in.
    while not done(w) do
      give(w)
      if not read_one(link) and not done(w) then
        w.failure = link.broken or Failure.new("mcp: reading from the server was cut off")
      end
    end
    give(w)
    link.waiting[req.id] = nil
  end
  local failure = w.failure
  if failure ~= nil then
    -- Failed here, not by the server, which may still run it: a listen past MAX_NOTICES, a callback that raised.
    if w.message == nil and link.broken == nil then cancelled(link, req) end
    local raised = w.raised
    if raised ~= nil then error(raised, 0) end
    return nil, failure
  end
  local message = assert(w.message)
  local err = message.error
  if err ~= nil then return nil, refused(err) end
  if message.result == nil then
    return nil, Failure.new("mcp: the server answered " .. req.method .. " with no result")
  end
  return message
end

--- The [`Send`] of a stdio connection over `lines` and `writer`.
local function stdio_send(lines: Stream.Lines, writer: Stream.Writer): Send
  local link: Link = { lines = lines, writer = writer, waiting = {}, reading = false, writing = false, writers = {} }
  return function(req: Request): (wire.Message) | (nil, Failure)
    return link_send(link, req)
  end
end

--- A session over a server's output, `reader`, and its input, `writer`,
--- one message a line: a server this program started, or a socket.
--- Closing the session closes `writer`, which tells the server to end.
function McpClient.stdio(reader: Stream.Reader, writer: Stream.Writer, opts?: McpClient.Options): McpClient.Session
  local lines = Stream.lines(reader, Mcp.MAX_MESSAGE_BYTES)
  return session(stdio_send(lines, writer), opts, false,
    function(): (true) | (false, Failure)
      local ok, why = writer:close()
      if not ok then return false, Failure.new("mcp: " .. why) end
      return true
    end)
end

--- Starts the server `argv` as [`Child.start`] does, with `opts`, its
--- stdin and stdout the session's ([`McpClient.stdio`]), and its stderr
--- where `opts.stderr` says. Closing the session closes the server's
--- stdin and waits for it to exit, ending it where it does not within
--- 5 seconds. `opts.stdin` and `opts.stdout` are this function's and
--- must be nil; `opts.sandbox` holds the server to a policy.
function McpClient.spawn(argv: {string}, opts: Child.Options, client_opts?: McpClient.Options): (McpClient.Session) | (nil, Failure)
  if opts.stdin ~= nil or opts.stdout ~= nil then
    error("mcp: spawn: opts.stdin and opts.stdout are the session's; leave them nil", 2)
  end
  local given: Child.Options = {
    env = opts.env, cwd = opts.cwd, stdin = "stream", stdout = "stream", stderr = opts.stderr, fds = opts.fds,
    capture_limit = opts.capture_limit, process_group = opts.process_group, timeout_ns = opts.timeout_ns,
    sandbox = opts.sandbox,
  }
  local handle, why = Child.start(argv, given)
  if handle == nil then
    return nil, Failure.new("mcp: starting " .. (argv[1] or "") .. ": " .. tostring(why))
  end
  local reader, writer = handle.stdout_stream, handle.stdin_stream
  if reader == nil or writer == nil then return nil, Failure.new("mcp: the server has no pipes") end
  local lines = Stream.lines(reader, Mcp.MAX_MESSAGE_BYTES)
  return session(stdio_send(lines, writer), client_opts, false,
    function(): (true) | (false, Failure)
      local _, _ = writer:close()
      local result, _ = handle:wait(5 * 1000000000)
      if result == nil then
        local closed, trouble = handle:close()
        if not closed then
          return false, Failure.new("mcp: ending the server: " .. tostring(trouble))
        end
      end
      return true
    end)
end

-- Streamable HTTP.

--- The protocol's own headers, which `opts.headers` may not name.
local OWN_HEADERS <const>: {string: boolean} = {
  ["content-type"] = true, accept = true, ["mcp-protocol-version"] = true, ["mcp-method"] = true, ["mcp-name"] = true,
}

--- The response to `id` among `messages`, the text of each; with
--- `lenient`, one that is not a message is passed over (an event a server
--- or a proxy sends that is not the protocol's), else it fails.
local function response_in(messages: {string}, id: string, lenient: boolean): (wire.Message | false) | (nil, Failure)
  for _, text in ipairs(messages) do
    local message, bad = wire.message(text)
    if message == nil then
      if not lenient then
        return nil, Failure.new("mcp: the server answered what is not a message: " .. bad.message)
      end
    elseif message.method == nil and message.id == id then
      return message
    end
  end
  return false
end

--- The failure of `req` that `trouble`, the words of a transport, says: of kind "cancelled" where its task was
--- cancelled.
local function trouble_of(req: Request, trouble: string): Failure
  local message = "mcp: " .. req.method .. ": " .. trouble
  if trouble == Poll.CANCELLED then return Failure.cancelled(message) end
  return Failure.new(message)
end

--- The response to `req` read from `response`, an event stream, giving `req`'s `on_progress` each notice of its
--- progress as it comes.
local function streamed_response(response: Http.Response, req: Request): (wire.Message | false) | (nil, Failure)
  local splitter = wire.splitter()
  while true do
    local chunk, trouble = response:read()
    if chunk == nil and trouble ~= "" then return nil, trouble_of(req, trouble) end
    local datas = if chunk ~= nil then splitter.feed(chunk) else splitter.finish() end
    if datas == nil then
      return nil, Failure.new("mcp: " .. req.method .. ": an event is longer than a message may be")
    end
    for _, text in ipairs(datas) do
      local message, _ = wire.message(text)
      if message ~= nil then
        heard(req, message)
        if message.method == nil and message.id == req.id then return message end
      end
    end
    if chunk == nil then return false end
  end
end

--- The response message to `id` in `got`, or nil and why there is none.
local function http_response(got: Http.Body, id: string, method: string): (wire.Message) | (nil, Failure)
  local kind = ((got.headers["content-type"] or ""):match("^%s*([^;%s]+)") or ""):lower()
  local messages: {string} = {}
  if kind == "text/event-stream" then
    messages = wire.events(got.body)
  elseif kind == "application/json" then
    messages = { got.body }
  end
  local found, bad = response_in(messages, id, kind == "text/event-stream")
  if found == nil then return nil, bad end
  if found is wire.Message then return found end
  if kind == "application/json" and got.status // 100 ~= 2 then
    -- An error with no id: one the server could not tie to the request.
    local message, _ = wire.message(got.body)
    if message ~= nil and message.error ~= nil then return message end
  end
  if got.status // 100 ~= 2 then
    return nil, Failure.new("mcp: " .. method .. ": HTTP " .. tostring(got.status))
  end
  return nil, Failure.new("mcp: " .. method .. ": the server answered with no response to the request")
end

--- A session with the server whose MCP endpoint is `url`, one POST a
--- request. Redirects are not followed: a request to a server that
--- moves fails, naming the status. `opts.headers` go with every
--- request; one that names a header the protocol sets raises. So do
--- headers with a plain `http://` URL whose host is not loopback: they
--- would go in the clear, and a token among them could be read on the way.
function McpClient.http(url: string, opts: McpClient.HttpOptions): McpClient.Session
  local parts, unread = Url.parse(url)
  if next(opts.headers or {}) ~= nil and parts == nil and url:sub(1, 8):lower() ~= "https://" then
    error("mcp: http: opts.headers go only to a URL that can be read: " .. tostring(unread), 2)
  end
  if parts ~= nil and parts.scheme == "http" and next(opts.headers or {}) ~= nil and not Net.is_loopback(parts.host) then
    error("mcp: http: opts.headers would go in the clear over http:// to " .. parts.host ..
        "; use an https:// URL, or a loopback host such as 127.0.0.1", 2)
  end
  for name in pairs(opts.headers or {}) do
    local lower = name:lower()
    if OWN_HEADERS[lower] == true or lower:sub(1, 10) == "mcp-param-" then
      error("mcp: http: opts.headers may not name " .. name .. ", which the protocol sets", 2)
    end
    if opts.oauth ~= nil and lower == "authorization" then
      error("mcp: http: opts.headers may not name Authorization with opts.oauth, which sets it", 2)
    end
  end
  local oauth = opts.oauth
  local auth = if oauth ~= nil then McpOAuth.new(url, oauth) else nil end
  -- `refusal` takes the status and challenge of a response that refused the token, for `send` to sign in by:
  -- one table for each request, so requests in flight at once do not take each other's.
  local once = function(req: Request, refusal: mut {integer: string}): (wire.Message) | (nil, Failure)
    local headers: mut {string: string} = {}
    for k, v in pairs(opts.headers or {}) do headers[k] = v end
    if auth ~= nil then
      local authorization = auth.authorization()
      if authorization ~= nil then headers["Authorization"] = authorization end
    end
    headers["Content-Type"] = "application/json"
    headers["Accept"] = "application/json, text/event-stream"
    headers["MCP-Protocol-Version"] = Mcp.VERSION
    headers["Mcp-Method"] = req.method
    if req.name ~= nil then headers["Mcp-Name"] = Mcp.header_text(req.name) end
    for header, value in pairs(req.mirrored or {}) do
      headers["Mcp-Param-" .. header] = Mcp.header_text(value)
    end
    local body = wire.request(req.id, req.method, req.params)
    local got: Http.Body
    local message: wire.Message
    local timeout_ns = if req.forever then Http.FOREVER else opts.timeout_ns end
    local opened, owhy = Http.open(url, { method = "POST", timeout_ns = timeout_ns, headers = headers,
      body = body, follow = false })
    if opened == nil then return nil, trouble_of(req, tostring(owhy)) end
    local response <close> = opened
    if auth ~= nil and (response.status == 401 or response.status == 403) then
      refusal[response.status] = response.headers["www-authenticate"] or ""
      return nil, Failure.new("mcp: " .. req.method .. ": HTTP " .. tostring(response.status))
    end
    local kind = ((response.headers["content-type"] or ""):match("^%s*([^;%s]+)") or ""):lower()
    if kind == "text/event-stream" and response.status // 100 == 2 then
      -- Read as it comes, so each notice of progress is given as it is sent.
      local found, bad = streamed_response(response, req)
      if found == nil then return nil, bad end
      if not found is wire.Message then
        return nil, Failure.new("mcp: " .. req.method .. ": the server answered with no response to the request")
      end
      got = { status = response.status, headers = response.headers, body = "" }
      message = found
    else
      local text, rwhy = Stream.read_up_to(response, Mcp.MAX_MESSAGE_BYTES + 1)
      if text == nil then
        return nil, Failure.new("mcp: " .. req.method .. ": " .. tostring(rwhy))
      end
      if #text > Mcp.MAX_MESSAGE_BYTES then
        return nil, Failure.new("mcp: " .. req.method .. ": the answer is longer than a message may be")
      end
      got = { status = response.status, headers = response.headers, body = text }
      local found, bad = http_response(got, req.id, req.method)
      if found == nil then return nil, bad end
      message = found
    end
    local err = message.error
    if err ~= nil then
      local failure = refused(err)
      if got.status // 100 ~= 2 then
        failure = Failure.coded(failure.message .. " (HTTP " .. tostring(got.status) .. ")", err.code)
      end
      return nil, failure
    end
    if message.result == nil then
      return nil, Failure.new("mcp: the server answered " .. req.method .. " with no result")
    end
    return message
  end
  local send = function(req: Request): (wire.Message) | (nil, Failure)
    -- A 401 refreshes or signs in, and one after a refresh signs in; a 403 may step up. A sign-in serves each status
    -- once, so a server that refuses every token ends.
    local answered: mut {integer: boolean} = {}
    local may_refresh = true
    while true do
      local refusal: mut {integer: string} = {}
      local said, why = once(req, refusal)
      if said ~= nil then return said end
      if auth == nil then return nil, why end
      local status, header = next(refusal)
      if status == nil or header == nil or answered[status] == true then return nil, why end
      local remedy, awhy = auth.challenged(status, if header ~= "" then header else nil end, may_refresh)
      if remedy == nil then return nil, awhy end
      if remedy == "refreshed" then may_refresh = false else answered[status] = true end
    end
  end
  return session(send, { info = opts.info, elicit = opts.elicit }, true,
    function(): (true) | (false, Failure) return true end)
end

return McpClient

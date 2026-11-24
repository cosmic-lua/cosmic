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
--- A tool's handler is given its arguments once they hold to the tool's
--- `inputSchema` ([`cosmic.jsonschema`], compiled by [`McpServer.new`],
--- which raises for a schema it cannot check); arguments that do not are
--- answered as a result with `isError` that says where they fail, and the
--- handler is not called. An argument sent as `null` is [`Json.null`],
--- for the schema and the handler both, not absent: `{"x": null}` is not
--- `{}`. A tool that runs and fails answers its failure,
--- which the client is sent as a result with `isError`, for the model to
--- read; a handler that raises is answered as an internal error, its words
--- withheld from the client and given to [`McpServer.Spec.on_error`]. A
--- tool with an `outputSchema` answers `structuredContent` that holds to it
--- ([`Mcp.structured`]) in each result that is not an error; one that does
--- not is answered as an internal error too, so a client never reads a
--- structure the tool did not promise.
---
--- Security: over HTTP every request passes `authorize` or `oauth`, one
--- of which the handler's spec must state ([`McpServer.bearer`] checks a
--- token, [`McpServer.anyone`] lets every caller in, and `oauth` makes the
--- endpoint an OAuth 2.1 resource server whose access tokens
--- [`McpServer.jwt`] checks, a tool's `scopes` checked for each call),
--- and a request whose `Origin`
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
local Cipher = require("cosmic.cipher")
local Clock = require("cosmic.clock")
local Codec = require("cosmic.codec")
local Env = require("cosmic.env")
local Errors = require("cosmic.errors")
local Failure = require("cosmic.failure")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Jose = require("cosmic.jose")
local Json = require("cosmic.json")
local JsonSchema = require("cosmic.jsonschema")
local Mcp = require("cosmic.mcp")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Rand = require("cosmic.rand")
local Sandbox = require("cosmic.sandbox")
local Shape = require("cosmic.shape")
local Stream = require("cosmic.stream")
local String = require("cosmic.string")
local Url = require("cosmic.url")
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
    --- Who the request's access token stands for and what it grants,
    --- where the endpoint is a resource server ([`HttpSpec.oauth`]);
    --- nil elsewhere.
    grant?: Grant
    --- Tells the client how far the request has come, where it asked to
    --- be told (a `progressToken` in its `_meta`) over a transport that
    --- carries a notice before the answer: [`McpServer.Instance.serve_stdio`],
    --- or an HTTP request that accepts `text/event-stream`. `progress`
    --- must grow with each call; a call that does not grow it, one with
    --- a value that is not finite, and one after the request is answered
    --- or cancelled, send nothing, and a `message` past 4 KiB is left
    --- out. Over HTTP a notice the client has not read when the next
    --- comes is replaced by it. Elsewhere it does nothing.
    progress: function(progress: number, total?: number, message?: string)
    --- Whether the client has cancelled the request: over stdio with
    --- `notifications/cancelled`, over HTTP by closing the response's
    --- stream. The handler's task is cancelled then too, so each wait in
    --- it (a child's, a socket's) fails with [`Poll.CANCELLED`]; what the
    --- handler answers after is not sent.
    cancelled: function(): boolean
    --- The person's answer to `elicitation`, asked under `key` (1 to 64
    --- bytes, one for each thing the handler asks): a tool call, a
    --- prompt's get or a resource's read may ask the client for input
    --- before it answers. Where the request carries the answer, as the
    --- client's retry does, it is given, an accepted form's content held
    --- to `requestedSchema`. Where it does not, the answer is nil and a
    --- Failure the handler returns as it is (`return nil, why`): the
    --- server then answers that it needs input, with each elicitation
    --- the handler asked for, and the client asks again with the
    --- answers. A client that cannot be asked in that mode is a Failure
    --- of its own, for the handler to answer as an error or work
    --- around. The protocol is stateless, so the handler runs again
    --- from its start on the retry: what it must carry over, it gives
    --- `keep`. The answer is the client's word, and a client may send
    --- one unasked: an `accept` of a `url` says the person says they are
    --- done there, so check at the far end (the sign-in, the payment)
    --- that they are. A form that is not flat, or a URL that is not
    --- http or https, raises.
    elicit: function(key: string, elicitation: Mcp.Elicitation): (Mcp.Elicited) | (nil, Failure)
    --- What the handler gave `keep` in the round before this one, once
    --- the server has checked that it sealed it, for this method, name
    --- and arguments, for this caller ([`HttpSpec.principal`]), and
    --- within [`Spec.state_ttl_ms`]; nil in the first round. The client
    --- sees none of it. A client may send it back more than once within
    --- that time: a handler whose step must happen once records it.
    state?: string
    --- Gives the next round `state`, sealed (encrypted and
    --- authenticated) under the server's key: at most 64 KiB.
    keep: function(state: string)
  end

  --- A tool, and what calls it.
  record ToolSpec
    --- The tool, as `tools/list` lists it.
    tool: Mcp.Tool
    --- Runs the tool on `arguments`, as the client sent them once they hold
    --- to the tool's `inputSchema`. A failure answered is sent as a result
    --- with `isError`, its words for the model to read.
    call: function(arguments: {string: Json.Value}, call: Call): (Mcp.ToolResult) | (nil, Failure)
    --- The scopes an access token must grant for a call of the tool,
    --- where the endpoint is a resource server ([`HttpSpec.oauth`]): a
    --- call without them is answered 403, naming them all, for the client
    --- to ask for more. Over stdio, and over HTTP without `oauth`, they
    --- are not checked.
    scopes?: {string}
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
    --- Values for one argument of a prompt or one variable of a
    --- resource template, as typed so far (`completion/complete`). The
    --- server checks first that the prompt or template is one of its own
    --- and the argument one it names, and answers at most
    --- [`Mcp.MAX_COMPLETIONS`] values, saying where there were more.
    --- `asked.context` holds what the client sent, unchecked. A
    --- completion may not ask the person for input: `call.elicit` fails.
    complete?: function(asked: Mcp.Completing, call: Call): (Mcp.Completion) | (nil, Failure)
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
    --- The key that seals what handlers `keep` between the rounds of a
    --- request that needs input: [`Cipher.key_length`] bytes nobody can
    --- guess. Servers that share a client's requests (behind a load
    --- balancer) share one; nil makes one at random, so the client's
    --- retry must reach this process.
    state_key?: string
    --- How long sealed state stays good, in milliseconds (10 minutes).
    state_ttl_ms?: integer
  end

  --- What [`McpServer.Instance.handler`] serves over HTTP.
  record HttpSpec
    --- Whether the request may be answered: false is answered 401.
    --- [`McpServer.bearer`] checks a token; [`McpServer.anyone`] lets each in.
    --- One of `authorize` and `oauth` is given, not both.
    authorize?: function(HttpServer.Request): boolean
    --- Makes the endpoint an OAuth 2.1 resource server, as the
    --- protocol's authorization has it: a request needs an access token
    --- `verify` takes, and one without is answered 401 with a
    --- `WWW-Authenticate` that names where to find the authorization
    --- servers (the protected resource metadata, served at
    --- `/.well-known/oauth-protected-resource` and the endpoint's path).
    oauth?: OAuth
    --- The origins a browser's request may come from, each as
    --- `scheme://host[:port]`; a request whose `Origin` is not one is
    --- refused 403. Nil or empty for none: a request with no `Origin`,
    --- which a browser always sends where it matters, is let through
    --- to `authorize`.
    origins?: {string}
    --- The path the endpoint answers ("/mcp"); any other is 404.
    path?: string
    --- Who asks, for a request `authorize` let in: what a handler
    --- `keep`s for a request is bound to, so another caller cannot send
    --- it back. Nil binds it to the [`Grant`]'s issuer and subject under
    --- `oauth`, and to the request's `Authorization` header under
    --- `authorize`; a server that knows its callers otherwise (a cookie, a client
    --- certificate, one token shared by many) names them here.
    principal?: function(HttpServer.Request): string
  end

  --- Who a request's access token stands for, and what it grants: what
  --- [`OAuth.verify`] answers.
  record Grant
    --- The authorization server that issued the token (`iss`).
    issuer: string
    --- Who the token is about (`sub`), as `issuer` names them: with
    --- `issuer`, what state a handler keeps is bound to, unless
    --- [`HttpSpec.principal`] says otherwise.
    subject: string
    --- The scopes it grants.
    scopes: {string}
    --- When it expires, in seconds since the epoch (`exp`): an event
    --- stream it opened ends then. Nil: when the stream ends by itself.
    expires?: integer
  end

  --- What makes an endpoint a resource server ([`HttpSpec.oauth`]).
  record OAuth
    --- This endpoint's canonical URI, the audience its tokens must be
    --- for: `https://mcp.example.com/mcp`, its path the endpoint's. http
    --- is taken only for a loopback host.
    resource: string
    --- The issuers of the authorization servers whose tokens it takes,
    --- at least one.
    authorization_servers: {string}
    --- The scopes a client asks for to use the server at all
    --- (`scopes_supported`), named in a 401's challenge. Each is a
    --- scope token of RFC 6749: printable ASCII, no space, `"` or `\`.
    scopes?: {string}
    --- The grant of the access token `token`, or nil and why it is
    --- refused: not signed by an authorization server named, past its
    --- time, or for another audience than `resource` (the endpoint's
    --- [`resource`], given), which it must refuse. [`McpServer.jwt`]
    --- makes one for JWT access tokens.
    verify: function(token: string, resource: string): (Grant) | (nil, Failure)
    --- Whether `granted` covers the scope `needed`, for scopes where a
    --- broader one holds narrower ones; nil: only `needed` itself does.
    covers?: function(granted: {string}, needed: string): boolean
  end

  --- What [`McpServer.jwt`] checks a JWT access token against.
  record JwtSpec
    --- The `iss` a token must hold: an authorization server's issuer.
    issuer: string
    --- The authorization server's signing keys ([`Jose.keys`] of its JWKS).
    keys: {Jose.Jwk}
    --- How far the issuer's clock may be from this one, in seconds (60).
    leeway?: integer
    --- The header's `typ` a token must have ("at+jwt", as RFC 9068
    --- says): so an ID token the issuer signed is not taken for one.
    typ?: string
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
    --- `input` ends and the requests in flight are answered, when it
    --- answers true. Each request runs in a task of its own, up to 32 at
    --- once, so an answer may come before one to an earlier request, a
    --- notice of progress goes out as the handler makes it, and
    --- `notifications/cancelled` cancels the request it names. Called
    --- outside a [`Poll.run`], it runs one of its own. A line longer than
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
    --- A request with a `progressToken` from a client whose `Accept` names
    --- `text/event-stream` is answered as an event stream: each notice of
    --- progress an event, then the answer. A client that closes it
    --- cancels the request, which the server finds at the next event it
    --- writes, a comment every 5 seconds where there is nothing else.
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
    --- Replaces the tools, resources, templates or prompts `changes`
    --- names, each list whole, checked as [`McpServer.new`] checks them
    --- (a list that does not hold raises, and nothing changes), and
    --- tells each subscription that asked that its list changed
    --- (`notifications/tools/list_changed` and the others). A request
    --- in flight goes on with what it found.
    update: function(Instance, changes: Changes)
    --- Tells each subscription that named the resource `uri` that it
    --- changed (`notifications/resources/updated`), for it to read again.
    resource_updated: function(Instance, uri: string)
    --- Ends every subscription open, each answered as a graceful end, so
    --- its client knows not to listen again at once: for a server about to
    --- stop.
    end_subscriptions: function(Instance)
  end

  --- What [`McpServer.Instance.update`] replaces: each list given, whole.
  record Changes
    --- The tools in place of [`Spec.tools`].
    tools?: {ToolSpec}
    --- The resources in place of [`Spec.resources`].
    resources?: {ResourceSpec}
    --- The families of resources in place of [`Spec.templates`].
    templates?: {Mcp.ResourceTemplate}
    --- The prompts in place of [`Spec.prompts`].
    prompts?: {PromptSpec}
  end
end

--- The options [`McpServer.Instance.main`] reads.
local MAIN_OPTIONS <const>: {string: boolean} = {
  ["--http"] = true, ["--token-env"] = true, ["--anyone"] = false, ["--origin"] = true, ["--path"] = true,
}

--- One server: its spec, read once, and its lists in order.
--- What a subscription asked to be told, as far as the server agreed.
local record Filter
  tools: boolean
  prompts: boolean
  resources: boolean
  --- The URIs of the resources whose updates it is told of.
  uris: mut {string: boolean}
end

--- One `subscriptions/listen` open.
local record Listener
  filter: Filter
  --- Its id, the request's, as a value: each notice carries it.
  id: Json.Value
  send: function(text: string)
  wake: Poll.Notifier
  --- The server ended it, to be answered as a graceful end.
  mut ended: boolean
end

--- The subscriptions open, which a server's changes are told to.
local record Hub
  listeners: mut {Listener}
end

local record State
  mut spec: McpServer.Spec
  mut tools: {McpServer.ToolSpec}
  mut by_tool: {string: McpServer.ToolSpec}
  --- The header mirrors of each tool, by its name.
  mut mirrors: {string: {Mcp.Mirror}}
  --- Each tool's `inputSchema`, compiled, by its name.
  mut inputs: {string: JsonSchema.Schema}
  --- Each tool's `outputSchema`, compiled, by its name: only the tools that have one.
  mut outputs: {string: JsonSchema.Schema}
  mut resources: {McpServer.ResourceSpec}
  mut by_uri: {string: McpServer.ResourceSpec}
  mut templates: {Mcp.ResourceTemplate}
  mut prompts: {McpServer.PromptSpec}
  mut by_prompt: {string: McpServer.PromptSpec}
  page_size: integer
  ttl_ms: integer
  cache_scope: McpServer.CacheScope
  hub: Hub
  --- What seals the state handlers keep, and for how long it holds.
  state_key: string
  state_ttl_ns: integer
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
--- Whether `scope` is a scope token of RFC 6749: one or more of %x21 / %x23-5B / %x5D-7E.
local function is_scope(scope: string): boolean
  if #scope < 1 then return false end
  for i = 1, #scope do
    local b = assert(scope:byte(i))
    if b < 0x21 or b > 0x7E or b == 0x22 or b == 0x5C then return false end
  end
  return true
end

local function state_of(spec: McpServer.Spec): State
  local by_tool: mut {string: McpServer.ToolSpec} = {}
  local mirrors: mut {string: {Mcp.Mirror}} = {}
  local inputs: mut {string: JsonSchema.Schema} = {}
  local outputs: mut {string: JsonSchema.Schema} = {}
  for _, t in ipairs(spec.tools or {}) do
    local name = t.tool.name
    if #name < 1 or #name > 128 or name:find(TOOL_NAME) == nil then
      refuse("tool name " .. Json.quote(name) .. " is not 1 to 128 of A-Z a-z 0-9 _ - .")
    end
    if by_tool[name] ~= nil then refuse("tool " .. name .. " is named twice") end
    for _, scope in ipairs(t.scopes or {}) do
      if not is_scope(scope) then
        refuse("tool " .. name .. ": scope " .. Json.quote(scope) .. " is not a scope token")
      end
    end
    if t.tool.inputSchema["type"] ~= "object" then
      refuse("tool " .. name .. ": inputSchema must have \"type\": \"object\"")
    end
    local found, why = Mcp.mirrors(t.tool.inputSchema)
    if found == nil then refuse("tool " .. name .. ": " .. tostring(why)) end
    local input, iwhy = JsonSchema.compile(t.tool.inputSchema)
    if input == nil then refuse("tool " .. name .. ": inputSchema: " .. tostring(iwhy)) end
    local out = t.tool.outputSchema
    if out ~= nil then
      if out["type"] ~= "object" then
        refuse("tool " .. name .. ": outputSchema must have \"type\": \"object\"")
      end
      local output, owhy = JsonSchema.compile(out)
      if output == nil then refuse("tool " .. name .. ": outputSchema: " .. tostring(owhy)) end
      outputs[name] = output
    end
    by_tool[name] = t
    mirrors[name] = found
    inputs[name] = input
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
  local state_key = spec.state_key
  if state_key == nil then
    local made, why = Rand.entropy(Cipher.key_length)
    if made == nil then refuse("making a state key: " .. why) end
    state_key = made
  end
  if #state_key ~= Cipher.key_length then
    refuse("state_key must be " .. String.counted(Cipher.key_length, "byte"))
  end
  local state_ttl_ms = spec.state_ttl_ms or 600000
  if state_ttl_ms < 1 then refuse("state_ttl_ms must be at least 1") end
  return {
    spec = spec, tools = spec.tools or {}, by_tool = by_tool, mirrors = mirrors, inputs = inputs, outputs = outputs,
    resources = spec.resources or {}, by_uri = by_uri, templates = spec.templates or {},
    prompts = spec.prompts or {}, by_prompt = by_prompt, page_size = page_size, ttl_ms = ttl_ms,
    cache_scope = spec.cache_scope or "private", hub = { listeners = {} },
    state_key = state_key, state_ttl_ns = Clock.ms(state_ttl_ms),
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
  --- The `progressToken`, a string or an integer, where the request has one.
  progress_token?: Json.Value
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
  local token = meta["progressToken"]
  local progress_token: Json.Value? = nil
  if token is string or math.type(token) == "integer" then progress_token = token end
  return { version = version, capabilities = capabilities, client = client, progress_token = progress_token }
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
  if #self.tools > 0 then c["tools"] = { listChanged = true } end
  if #self.resources > 0 or #self.templates > 0 or self.spec.read ~= nil then
    c["resources"] = { listChanged = true, subscribe = true }
  end
  if #self.prompts > 0 then c["prompts"] = { listChanged = true } end
  if self.spec.complete ~= nil then
    local none: {string: Json.Value} = {}
    c["completions"] = none
  end
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

-- Multi round-trip requests: a handler that needs input.

--- The most a handler may keep for the next round, and the most it may ask for in one.
local MAX_KEPT <const> = 64 * 1024
local MAX_ASKED <const> = 16

--- What a request that may need input carries and gathers: the client's answers, what the handler asks, what it
--- keeps.
local record Inputs
  --- The client's answers, by key, as the retry carries them.
  given: {string: Json.Value}
  --- The elicitations asked this round, by key, as they are sent.
  asked: mut {string: Json.Value}
  mut count: integer
  mut kept?: string
  --- What `elicit` answers for an answer not yet given: a handler that returns it has the server ask for input.
  needed: Failure
  --- What the sealed state is bound to: the method, what it names, and who asks.
  context: string
end

--- The params a retry adds.
local record RetryParams
  inputResponses?: any
  requestState?: any
  name?: string
  uri?: string
  arguments?: any
end

local RETRY_PARAMS <const>: Shape.Typed<RetryParams> = Shape.record_of("RetryParams")

--- `state` sealed for `context`, with the time it stops holding, as text a client carries.
local function seal(self: State, context: string, state: string): string
  local nonce, why = Rand.entropy(Cipher.nonce_length)
  if nonce == nil then error("mcp: sealing state: " .. why) end
  local plain = string.pack(">i8", Clock.now_ns() + self.state_ttl_ns) .. state
  return Codec.base64url(nonce .. Cipher.seal("chacha20-poly1305", self.state_key, nonce, plain, context))
end

--- The state `text` seals for `context`, or why it does not hold: not sealed by this server's key for this
--- request, or past its time.
local function unseal(self: State, context: string, text: string): (string) | (nil, string)
  local bytes, _ = Codec.unbase64url(text)
  if bytes == nil or #bytes < Cipher.nonce_length then return nil, "it is not this server's" end
  local nonce, sealed = bytes:sub(1, Cipher.nonce_length), bytes:sub(Cipher.nonce_length + 1)
  local plain, _ = Cipher.open("chacha20-poly1305", self.state_key, nonce, sealed, context)
  if plain == nil or #plain < 8 then
    return nil, "it is not this server's, or not for this request"
  end
  local expiry = string.unpack(">i8", plain)
  if Clock.now_ns() > expiry then return nil, "it is past its time: ask again from the start" end
  return plain:sub(9)
end

--- Whether the client declares that it may be asked for input in `mode`: a client that names neither mode takes
--- forms.
local function elicits(declared: {string: Json.Value}, mode: Mcp.ElicitMode): boolean
  local raw = declared["elicitation"]
  if raw == nil then return false end
  local e = Json.object_of(raw)
  if e == nil then return false end
  if mode == "url" then return e["url"] ~= nil end
  return e["form"] ~= nil or e["url"] == nil
end

--- The types a form's field may be.
local FIELD_TYPES <const>: {string: boolean} = { string = true, number = true, integer = true, boolean = true }

--- Why `schema` is not a form a client can show, "" where it is: an object whose properties are each a string, a
--- number, an integer, a boolean or an enum, with no nesting.
local function flat_form(schema: {string: Json.Value}): string
  if schema["type"] ~= "object" then return "its type must be \"object\"" end
  local properties = Json.object_of(schema["properties"])
  if properties == nil then return "it has no properties object" end
  for name, raw in pairs(properties) do
    local field = Json.object_of(raw)
    local kind = if field ~= nil then field["type"] else nil end
    local listed = if field ~= nil then Json.array_of(field["enum"]) else nil end
    if not (kind is string and FIELD_TYPES[kind] == true) and listed == nil then
      return "the field " .. Json.quote(name) .. " is not a string, a number, an integer, a boolean or an enum"
    end
  end
  return ""
end

--- The client's answer to `elicitation`, or why there is none yet, as [`McpServer.Call.elicit`] says.
local function elicit(inputs: Inputs, declared: {string: Json.Value}, key: string,
                      elicitation: Mcp.Elicitation): (Mcp.Elicited) | (nil, Failure)
  if #key < 1 or #key > 64 then error("mcp: elicit: key must be 1 to 64 bytes", 3) end
  -- What the handler asks is checked before it is sent, so a form that cannot be is never filled in.
  local compiled: JsonSchema.Schema? = nil
  if elicitation.mode == "form" then
    local schema = elicitation.requestedSchema
    if schema == nil then error("mcp: elicit: a form needs a requestedSchema", 3) end
    local flat = flat_form(schema)
    if flat ~= "" then error("mcp: elicit: requestedSchema: " .. flat, 3) end
    local made, cwhy = JsonSchema.compile(schema)
    if made == nil then error("mcp: elicit: requestedSchema: " .. tostring(cwhy), 3) end
    compiled = made
  else
    local url = elicitation.url or ""
    if url:find("^https?://[^%s]+$") == nil then
      error("mcp: elicit: a url must be http or https", 3)
    end
  end
  if not elicits(declared, elicitation.mode) then
    return nil, Failure.new("mcp: the client cannot be asked for input in a " .. elicitation.mode)
  end
  local raw = inputs.given[key]
  if raw ~= nil then
    local answer, _ = wire.elicited_of(raw)
    local fits = answer ~= nil
    local content = if answer ~= nil then answer.content else nil end
    if answer ~= nil and answer.action == "accept" and compiled ~= nil then
      local held, _ = compiled:check(content or {})
      fits = held
    end
    -- An answer that does not fit is asked for again, as the protocol has a server do.
    if answer ~= nil and fits then return answer end
  end
  if inputs.asked[key] == nil then
    if inputs.count >= MAX_ASKED then
      return nil, Failure.new("mcp: a handler may ask for at most " .. String.counted(MAX_ASKED, "input") .. " at once")
    end
    inputs.count = inputs.count + 1
    local request = wire.elicitation(elicitation)
    inputs.asked[key] = { method = request.method, params = request.params }
  end
  return nil, inputs.needed
end

--- The result that asks the client for what `inputs` gathered.
local function input_required(self: State, inputs: Inputs): Json.Value
  local out: mut {string: Json.Value} = { resultType = "input_required",
    _meta = { [META_SERVER] = wire.implementation(self.spec.info) } }
  if inputs.count > 0 then out["inputRequests"] = inputs.asked end
  local kept = inputs.kept
  if kept ~= nil then out["requestState"] = seal(self, inputs.context, kept) end
  return out
end

local function list_tools(self: State, params: any): (Json.Value) | (nil, Refusal)
  local w, wrong = window(self, params, #self.tools)
  if w == nil then return nil, wrong end
  local out: mut {Json.Value} = {}
  for i = w.first, w.last do out[#out + 1] = wire.tool(assert(self.tools[i]).tool) end
  local fields: mut {string: Json.Value} = { tools = Json.array(out) }
  if w.next ~= nil then fields["nextCursor"] = w.next end
  return cacheable(self, fields)
end

local function call_tool(self: State, params: any, call: McpServer.Call, inputs: Inputs): (Json.Value) | (nil, Refusal)
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
  local held, unheld = assert(self.inputs[p.name]):check(arguments)
  if not held then
    return result(self, wire.tool_result(Mcp.result({ "the arguments do not hold to the tool's inputSchema: " .. tostring(unheld) }, true)))
  end
  local answered: Mcp.ToolResult? = nil
  local failure: Failure? = nil
  local ok, trouble = traced(function()
    local value, failed = t.call(arguments, call)
    answered, failure = value, failed
  end)
  if not ok then
    if not call.cancelled() then report(self, "tool " .. p.name, trouble) end
    return nil, raised
  end
  if answered == nil and rawequal(failure, inputs.needed) then
    return input_required(self, inputs)
  end
  local done = answered
  if done == nil then
    done = Mcp.result({ if failure ~= nil then tostring(failure) else "the tool failed" end }, true)
  end
  local output = self.outputs[p.name]
  if output ~= nil and done.isError ~= true then
    local structured = done.structuredContent
    if structured == nil then
      report(self, "tool " .. p.name, "its result has no structuredContent, though the tool has an outputSchema")
      return nil, raised
    end
    local fits, unfit = output:check(structured)
    if not fits then
      report(self, "tool " .. p.name, "its structuredContent does not hold to its outputSchema: " .. tostring(unfit))
      return nil, raised
    end
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

local function read_resource(self: State, params: any, call: McpServer.Call, inputs: Inputs): (Json.Value) | (nil, Refusal)
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
    if not call.cancelled() then report(self, "resource " .. uri, trouble) end
    return nil, raised
  end
  local got = contents
  if got == nil and rawequal(failure, inputs.needed) then return input_required(self, inputs) end
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

local function get_prompt(self: State, params: any, call: McpServer.Call, inputs: Inputs): (Json.Value) | (nil, Refusal)
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
    if not call.cancelled() then report(self, "prompt " .. p.name, trouble) end
    return nil, raised
  end
  local done = answered
  if done == nil and rawequal(failure, inputs.needed) then return input_required(self, inputs) end
  if done == nil then
    report(self, "prompt " .. p.name, if failure ~= nil then tostring(failure) else "failed" end)
    return nil, raised
  end
  return result(self, wire.prompt_result(done))
end

--- Why `asked` names no argument the server knows: a prompt or template not its own, or an argument it does not name.
local function unknown(self: State, asked: Mcp.Completing): string?
  local prompt, template = asked.prompt, asked.template
  if prompt ~= nil then
    local spec = self.by_prompt[prompt]
    if spec == nil then return "no such prompt: " .. Json.quote(prompt) end
    for _, a in ipairs(spec.prompt.arguments or {}) do
      if a.name == asked.argument then return nil end
    end
    return "prompt " .. prompt .. " takes no argument " .. Json.quote(asked.argument)
  end
  local uri = assert(template)
  for _, t in ipairs(self.templates) do
    if t.uriTemplate == uri then
      for _, name in ipairs(wire.template_variables(uri)) do
        if name == asked.argument then return nil end
      end
      return "the template " .. uri .. " has no variable " .. Json.quote(asked.argument)
    end
  end
  return "no such resource template: " .. Json.quote(uri)
end

local function complete(self: State, params: any, call: McpServer.Call): (Json.Value) | (nil, Refusal)
  local asked, why = wire.completing_of(params)
  if asked == nil then return nil, refusal(Mcp.INVALID_PARAMS, why) end
  local wrong = unknown(self, asked)
  if wrong ~= nil then return nil, refusal(Mcp.INVALID_PARAMS, "completion/complete: " .. wrong) end
  local handler = assert(self.spec.complete)
  local answered: Mcp.Completion? = nil
  local failure: Failure? = nil
  local ok, trouble = traced(function()
    local value, failed = handler(asked, call)
    answered, failure = value, failed
  end)
  local what = "completion of " .. asked.argument .. " of " ..
    (if asked.prompt ~= nil then "prompt " .. assert(asked.prompt) else "template " .. assert(asked.template) end)
  if not ok then
    if not call.cancelled() then report(self, what, trouble) end
    return nil, raised
  end
  local done = answered
  if done == nil then
    report(self, what, if failure ~= nil then tostring(failure) else "failed" end)
    return nil, raised
  end
  return result(self, wire.completion(done))
end

local function discover(self: State): Json.Value
  local fields: mut {string: Json.Value} = {
    supportedVersions = wire.strings({ Mcp.VERSION }),
    capabilities = capabilities(self),
  }
  local instructions = self.spec.instructions
  if instructions ~= nil then fields["instructions"] = instructions end
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
  if method == "completion/complete" then return self.spec.complete ~= nil end
  if method == "subscriptions/listen" then
    return #self.tools > 0 or #self.prompts > 0 or #self.resources > 0 or #self.templates > 0 or self.spec.read ~= nil
  end
  return false
end

--- One request as it runs: what its client asked to be told of it, and whether the client cancelled it.
local record Flight
  --- Where a notice of it goes, a message's text; nil where the transport sends nothing before the answer. A
  --- `lossy` notice (progress) may be replaced by the next where the client has not read it yet.
  mut emit?: function(text: string, lossy: boolean)
  --- The `progressToken` its `_meta` names.
  mut token?: Json.Value
  --- The last progress sent.
  mut last?: number
  --- Answered or cancelled: no notice of it is sent after.
  mut done: boolean
  mut cancelled: boolean
  --- Who asks, as [`McpServer.HttpSpec.principal`] names them: what state a handler keeps is bound to; nil over
  --- stdio, where one client is all there is.
  principal?: string
  --- What the request's access token grants, over a resource server.
  grant?: McpServer.Grant
end

--- Whether `n` is a number JSON can hold: not NaN, not infinite.
local function finite(n: number): boolean
  return n == n and n ~= math.huge and n ~= -math.huge
end

--- The longest `message` a notice of progress carries; a longer one is left out.
local MAX_PROGRESS_MESSAGE <const> = 4096

--- [`McpServer.Call.progress`] for `flight`.
local function progress_of(flight: Flight): function(progress: number, total?: number, message?: string)
  return function(progress: number, total?: number, message?: string)
    local token, emit, last = flight.token, flight.emit, flight.last
    if token == nil or emit == nil or flight.done or not finite(progress) then return end
    if last ~= nil and progress <= last then return end
    flight.last = progress
    local params: mut {string: Json.Value} = { progressToken = token, progress = progress }
    if total ~= nil and finite(total) then params["total"] = total end
    if message ~= nil and #message <= MAX_PROGRESS_MESSAGE and utf8.len(message) ~= nil then
      params["message"] = message
    end
    emit(wire.notification("notifications/progress", params), true)
  end
end

--- The most subscriptions a server holds open at once.
local MAX_LISTENERS <const> = 64

--- The most resources one subscription names, and the longest URI it names.
local MAX_SUBSCRIBED <const> = 256
local MAX_URI_BYTES <const> = 2048

local META_SUBSCRIPTION <const> = wire.META_SUBSCRIPTION

--- The params of `subscriptions/listen`.
local record ListenParams
  notifications?: Asked
end

--- What a `subscriptions/listen` asks to be told.
local record Asked
  toolsListChanged?: boolean
  promptsListChanged?: boolean
  resourcesListChanged?: boolean
  resourceSubscriptions?: {string}
end

local LISTEN_PARAMS <const>: Shape.Typed<ListenParams> = Shape.record_of("ListenParams")

--- A notice of `method` with `params` for `listener`, its id in the `_meta`.
local function notice(listener: Listener, method: string, params?: {string: Json.Value}): string
  local out: mut {string: Json.Value} = {}
  for k, v in pairs(params or {}) do out[k] = v end
  out["_meta"] = { [META_SUBSCRIPTION] = listener.id }
  return wire.notification(method, out)
end

--- Tells each subscription `wants` says yes to of `method`, with `params`.
local function announce(self: State, wants: function(Filter): boolean, method: string, params?: {string: Json.Value})
  -- Over a copy: a send may wait, and a subscription that ends meanwhile leaves the list.
  local now: {Listener} = table.move(self.hub.listeners, 1, #self.hub.listeners, 1, {})
  for _, listener in ipairs(now) do
    if not listener.ended and wants(listener.filter) then
      listener.send(notice(listener, method, params))
    end
  end
end

--- `subscriptions/listen`: the subscription's acknowledgment, then each notice it asked for until the client
--- cancels it (no answer is sent then) or the server ends it, answered as a graceful end.
local function listen(self: State, params: any, flight: Flight, id: string): (Json.Value) | (nil, Refusal)
  local emit = flight.emit
  if emit == nil then
    return nil, refusal(Mcp.INVALID_REQUEST,
      "subscriptions/listen needs a stream to send its notices on: over HTTP, Accept text/event-stream")
  end
  local p, why = LISTEN_PARAMS:into(params)
  if p == nil then return nil, refusal(Mcp.INVALID_PARAMS, "subscriptions/listen: " .. why) end
  local asked: Asked = p.notifications or {}
  local uris = asked.resourceSubscriptions or {}
  if #uris > MAX_SUBSCRIBED then
    return nil, refusal(Mcp.INVALID_PARAMS, "subscriptions/listen names more than " .. String.counted(MAX_SUBSCRIBED, "resource"))
  end
  if #self.hub.listeners >= MAX_LISTENERS then
    return nil, refusal(Mcp.INTERNAL_ERROR, "the server holds " .. String.counted(MAX_LISTENERS, "subscription") .. " already")
  end
  local has_resources = #self.resources > 0 or #self.templates > 0 or self.spec.read ~= nil
  local filter: Filter = {
    tools = asked.toolsListChanged == true and #self.tools > 0,
    prompts = asked.promptsListChanged == true and #self.prompts > 0,
    resources = asked.resourcesListChanged == true and has_resources,
    uris = {},
  }
  local agreed_uris: mut {Json.Value} = {}
  if has_resources then
    for _, uri in ipairs(uris) do
      if #uri <= MAX_URI_BYTES and utf8.len(uri) ~= nil and filter.uris[uri] == nil then
        filter.uris[uri] = true
        agreed_uris[#agreed_uris + 1] = uri
      end
    end
  end
  local decoded_id, _ = Json.decode(id)
  local id_value: Json.Value = id
  if decoded_id ~= nil then id_value = decoded_id end
  local listener: Listener = { filter = filter, id = id_value, wake = Poll.notifier(), ended = false,
    send = function(text: string) emit(text, false) end }
  local agreed: mut {string: Json.Value} = {}
  if filter.tools then agreed["toolsListChanged"] = true end
  if filter.prompts then agreed["promptsListChanged"] = true end
  if filter.resources then agreed["resourcesListChanged"] = true end
  if #agreed_uris > 0 then agreed["resourceSubscriptions"] = Json.array(agreed_uris) end
  -- Held before the acknowledgment is sent, as a send may wait: a change meanwhile is told after it, as the lines
  -- go out in turn, and the count of subscriptions holds.
  local listeners = self.hub.listeners
  listeners[#listeners + 1] = listener
  listener.send(notice(listener, "notifications/subscriptions/acknowledged", { notifications = agreed }))
  while not listener.ended and not flight.cancelled do
    local ok, _ = listener.wake:wait()
    if not ok then break end
  end
  for i, each in ipairs(listeners) do
    if each == listener then
      table.remove(listeners, i)
      break
    end
  end
  if not listener.ended then
    return nil, refusal(Mcp.INTERNAL_ERROR, "the subscription was cancelled")
  end
  return {
    resultType = "complete",
    _meta = { [META_SERVER] = wire.implementation(self.spec.info), [META_SUBSCRIPTION] = listener.id },
  }
end

--- The answer to the request of `method` with `params`.
local function dispatch(self: State, method: string, params: any, flight: Flight, id: string,
                        http?: HttpServer.Request): (Json.Value) | (nil, Refusal)
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
  flight.token = meta.progress_token
  local retry, _ = RETRY_PARAMS:into(params)
  local given: {string: Json.Value} = {}
  local state: string? = nil
  local may_ask = method == "tools/call" or method == "prompts/get" or method == "resources/read"
  -- The state is bound to the request it was kept for: its method, what it names (by the field the method reads),
  -- its arguments, and who asks.
  local named = ""
  local digest = ""
  if retry ~= nil then
    local field = if method == "resources/read" then retry.uri else retry.name end
    named = field or ""
    if retry.arguments ~= nil then
      local value, _ = Json.to_value(retry.arguments)
      local text: string? = nil
      if value ~= nil then
        local encoded, _ = Json.encode(value)
        if encoded ~= nil then
          local canonical, _ = Json.canonical(encoded)
          text = canonical
        end
      end
      digest = Hash.sha256(text or "")
    end
  end
  local context = method .. "\0" .. Hash.sha256(named) .. Hash.sha256(flight.principal or "") .. digest
  if may_ask and retry ~= nil then
    local raw = retry.inputResponses
    if raw ~= nil then
      local answers, _ = Json.to_object(raw)
      if answers == nil or Json.is_array(raw) then
        return nil, refusal(Mcp.INVALID_PARAMS, method .. ": inputResponses must be an object")
      end
      given = answers
    end
    local sealed = retry.requestState
    if sealed ~= nil and not sealed is string then
      return nil, refusal(Mcp.INVALID_PARAMS, method .. ": requestState must be a string")
    end
    if sealed is string then
      local opened, why = unseal(self, context, sealed)
      if opened == nil then
        return nil, refusal(Mcp.INVALID_PARAMS, method .. ": requestState does not hold: " .. why)
      end
      state = opened
    end
  end
  local inputs: Inputs = { given = given, asked = {}, count = 0, context = context,
    needed = Failure.new("mcp: the client is asked for input first") }
  local declared = meta.capabilities
  local call: McpServer.Call = { client = meta.client, capabilities = declared, http = http, grant = flight.grant,
    progress = progress_of(flight), cancelled = function(): boolean return flight.cancelled end,
    state = state,
    elicit = function(key: string, elicitation: Mcp.Elicitation): (Mcp.Elicited) | (nil, Failure)
      if not may_ask then return nil, Failure.new("mcp: " .. method .. " may not ask for input") end
      return elicit(inputs, declared, key, elicitation)
    end,
    keep = function(kept: string)
      if #kept > MAX_KEPT then
        error("mcp: keep: at most " .. String.counted(MAX_KEPT, "byte"), 2)
      end
      inputs.kept = kept
    end }
  if method == "server/discover" then return discover(self) end
  if method == "tools/list" and #self.tools > 0 then return list_tools(self, params) end
  if method == "tools/call" and #self.tools > 0 then
    return call_tool(self, params, call, inputs)
  end
  local has_resources = #self.resources > 0 or #self.templates > 0 or self.spec.read ~= nil
  if method == "resources/list" and has_resources then return list_resources(self, params) end
  if method == "resources/templates/list" and has_resources then
    return list_templates(self, params)
  end
  if method == "resources/read" and has_resources then
    return read_resource(self, params, call, inputs)
  end
  if method == "prompts/list" and #self.prompts > 0 then return list_prompts(self, params) end
  if method == "prompts/get" and #self.prompts > 0 then
    return get_prompt(self, params, call, inputs)
  end
  if method == "completion/complete" and self.spec.complete ~= nil then
    return complete(self, params, call)
  end
  if method == "subscriptions/listen" then return listen(self, params, flight, id) end
  return nil, refusal(Mcp.METHOD_NOT_FOUND, "Method not found: " .. method)
end

--- The answer to the message `message`, from HTTP's `http` where given.
local function answer_message(self: State, message: wire.Message, http?: HttpServer.Request, flight?: Flight): McpServer.Answer
  local method = message.method
  if method == nil then
    return { body = wire.error(message.id, Mcp.INVALID_REQUEST, "a client sends requests and notifications, not responses"),
      status = 400 }
  end
  local id = message.id
  if id == nil then
    -- A notification: this revision has the client send none but
    -- notifications/cancelled, which serve_stdio reads before it gets
    -- here, and over HTTP a client cancels by closing the stream.
    return { body = nil, status = 202 }
  end
  local running: Flight = flight or { done = false, cancelled = false }
  local answered, refused_with = dispatch(self, method, message.params, running, id, http)
  running.done = true
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

--- The most requests a stdio server runs at once; a line past them is read once one of them ends.
local MAX_IN_FLIGHT <const> = 32

--- A Reader of the descriptor `fd` whose read, in a task, first waits for it to be readable, so the run's other
--- tasks go on while it waits; a read of a descriptor in blocking mode would hold them all.
local class WaitingReader is Stream.Reader
  inner: Stream.Reader
  fd: integer

  function read(self, max_bytes?: integer): string?, string
    if Poll.in_task() then
      local ok, why = Poll.readable(self.fd)
      if not ok then return nil, why.message end
    end
    return self.inner:read(max_bytes)
  end

  function close(self): boolean, string return self.inner:close() end
end

--- A request a stdio server is running.
local record Entry
  message: wire.Message
  --- Whether it takes one of the [`MAX_IN_FLIGHT`] places: a subscription, which runs until it is cancelled, does not.
  counted: boolean
  --- Its id, as the message holds it.
  key: string
  flight: Flight
  --- Its task, once it runs: nil while it waits for a place.
  mut task?: Poll.Task
end

--- The params of `notifications/cancelled`.
local record CancelParams
  requestId: any
  reason?: string
end

local CANCEL_PARAMS <const>: Shape.Typed<CancelParams> = Shape.record_of("CancelParams")

--- A request's id as [`wire.Message`] holds it, JSON's text of it, from the `requestId` that names it; nil for one
--- that is not a string or an integer.
local function id_text(id: any): string?
  if id is string then return Json.quote(id) end
  if math.type(id) == "integer" then return tostring(id) end
  return nil
end

--- The most lines read ahead of the requests they start; past it, reading waits.
local MAX_INBOX <const> = 64

--- The most requests that wait for one of the [`MAX_IN_FLIGHT`] to end; one more is refused at once.
local MAX_PENDING <const> = 1024

--- Serves `lines`, writing to `writer`, in a task: each request in a task of its own, so a notice of progress goes
--- out as it is made, and `notifications/cancelled` ends the request it names. The lines are read in a task of
--- their own, so a cancel is read while every request runs, and a failed write ends the server at once.
local function serve_lines(self: State, lines: Stream.Lines, writer: Stream.Writer): (true) | (false, Failure)
  local running: mut {string: Entry} = {}
  local pending: mut {Entry} = {}
  local count = 0
  local wake = Poll.notifier()
  local failure: Failure? = nil
  local inbox: mut {string} = {}
  local ended = false
  local read_trouble = ""
  -- One line is written at a time, whole: shielded, so a request cancelled mid-write does not tear its line.
  local writing = false
  local turn = Poll.notifier()
  local function send(text: string)
    while writing do
      local ok, _ = turn:wait()
      if not ok then return end
    end
    if failure ~= nil then return end
    writing = true
    local ok, why = true, ""
    Poll.shielded(function()
      ok, why = writer:write(text .. "\n")
    end)
    writing = false
    turn:notify_one()
    if not ok then
      failure = Failure.new("mcp: " .. why)
      wake:notify_all()
    end
  end
  local function start(entry: Entry)
    if entry.counted then count = count + 1 end
    entry.task = Poll.spawn(function()
      local said = answer_message(self, entry.message, nil, entry.flight)
      if running[entry.key] == entry then running[entry.key] = nil end
      if entry.counted then count = count - 1 end
      if not entry.flight.cancelled and said.body ~= nil then send(said.body) end
      -- The loop starts the next one waiting.
      wake:notify_all()
    end)
  end
  local function launch()
    while count < MAX_IN_FLIGHT and #pending > 0 do
      local waiting = assert(table.remove(pending, 1))
      if not waiting.flight.cancelled then start(waiting) end
    end
  end
  local function cancel(params: any)
    local p, _ = CANCEL_PARAMS:into(params)
    if p == nil then return end
    local key = id_text(p.requestId)
    if key == nil then return end
    local entry = running[key]
    if entry == nil then return end
    running[key] = nil
    entry.flight.cancelled = true
    entry.flight.done = true
    local task = entry.task
    if task ~= nil then task:cancel() end
  end
  local function handle(line: string)
    if line:find("%S") == nil then return end
    local message, why = wire.message(line)
    if message == nil then
      send(wire.error(nil, why.code or Mcp.INVALID_REQUEST, why.message))
    elseif message.method == "notifications/cancelled" and message.id == nil then
      cancel(message.params)
    elseif message.method ~= nil and message.id ~= nil then
      if #pending >= MAX_PENDING then
        send(wire.error(message.id, Mcp.INTERNAL_ERROR, "the server is running too many requests: try again"))
        return
      end
      if running[message.id] ~= nil then
        -- Another with this id runs: a cancel could not tell them apart.
        send(wire.error(message.id, Mcp.INVALID_REQUEST, "a request with this id is running"))
        return
      end
      local entry: Entry = { message = message, key = message.id,
        counted = message.method ~= "subscriptions/listen",
        flight = { emit = function(text: string, _: boolean) send(text) end, done = false, cancelled = false } }
      running[entry.key] = entry
      if entry.counted then
        pending[#pending + 1] = entry
        launch()
      else
        start(entry)
      end
    else
      local said = answer_message(self, message)
      if said.body ~= nil then send(said.body) end
    end
  end
  local reader = Poll.spawn(function()
    while true do
      while #inbox >= MAX_INBOX and failure == nil do
        local ok, _ = wake:wait()
        if not ok then return end
      end
      local line, trouble = lines:read()
      if line == nil then
        ended, read_trouble = true, trouble
        wake:notify_all()
        return
      end
      inbox[#inbox + 1] = line
      wake:notify_all()
    end
  end)
  while failure == nil do
    launch()
    if #inbox > 0 then
      handle(assert(table.remove(inbox, 1)))
      wake:notify_all()
    elseif ended and count == 0 and #pending == 0 then
      break
    else
      local ok, why = wake:wait()
      if not ok then failure = Failure.new("mcp: " .. tostring(why)) end
    end
  end
  local failed = failure
  if failed ~= nil then
    reader:cancel()
    for _, entry in pairs(running) do
      entry.flight.cancelled = true
      local task = entry.task
      if task ~= nil then task:cancel() end
    end
    return false, failed
  end
  -- The client is gone, so are its subscriptions: what runs now is one of them.
  for _, entry in pairs(running) do
    entry.flight.cancelled = true
    local task = entry.task
    if task ~= nil then task:cancel() end
  end
  if read_trouble ~= "" and read_trouble ~= Poll.CANCELLED then
    return false, Failure.new("mcp: " .. read_trouble)
  end
  return true
end

--- Serves the protocol over stdio, in a run of its own where it is called outside one.
local function serve_stdio(self: State, input?: Stream.Reader, output?: Stream.Writer): (true) | (false, Failure)
  local stdin: WaitingReader = { inner = Stream.from_fd(0), fd = 0, skip = nil }
  local reader: Stream.Reader = input or stdin
  local writer = output or Stream.to_fd(1)
  local lines = Stream.lines(reader, Mcp.MAX_MESSAGE_BYTES)
  if Poll.in_task() then return serve_lines(self, lines, writer) end
  local served: Failure? = nil
  local ok = false
  Poll.run(function()
    local done, why = serve_lines(self, lines, writer)
    ok, served = done, why
  end)
  if not ok then return false, served or Failure.new("mcp: the server ended") end
  return true
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

--- How long an event stream goes with nothing to say before it says a comment, so a client gone is found at the
--- comment's write and its request cancelled.
local KEEPALIVE_NS <const> = 5 * 1000000000

--- The most notices an event stream holds for a client that has not read them; past it the stream ends, as a
--- client too slow to keep up is told by its end to start again.
local MAX_QUEUED <const> = 256

--- The body of a request answered as an event stream: its notices, then its answer, then the end. A notice of
--- progress not yet read when the next comes is dropped for it, so a client that reads slowly holds the server to
--- one; the others (a subscription's) are queued, to [`MAX_QUEUED`]. Closed before the answer (the client gone,
--- the server stopping), it cancels the request.
local class EventReader is Stream.Reader
  notifier: Poll.Notifier
  flight: Flight
  mut queue: mut {integer: string}
  --- The first queued notice not yet read, and the next free place.
  mut head: integer
  mut tail: integer
  mut latest?: string
  mut answer?: string
  mut task?: Poll.Task
  mut finished: boolean
  --- When the stream ends, its grant's time past, in nanoseconds since the epoch; nil: never by time.
  ends_ns?: integer

  function read(self, _max_bytes?: integer): string?, string
    while true do
      local latest, final = self.latest, self.answer
      local queued = self.queue[self.head]
      if queued ~= nil then
        self.queue[self.head] = nil
        self.head = self.head + 1
        return "event: message\ndata: " .. queued .. "\n\n", ""
      end
      if latest ~= nil then
        self.latest = nil
        return "event: message\ndata: " .. latest .. "\n\n", ""
      end
      if final ~= nil then
        self.answer = nil
        self.finished = true
        return "event: message\ndata: " .. final .. "\n\n", ""
      end
      if self.finished then return nil, "" end
      local wait_ns = KEEPALIVE_NS
      local ends_ns = self.ends_ns
      if ends_ns ~= nil then
        local left = ends_ns - Clock.now_ns()
        if left <= 0 then
          -- The token it was opened with is past its time: the client asks again with a new one.
          local _, _ = self:close()
          return nil, ""
        end
        if left < wait_ns then wait_ns = left end
      end
      local ok, why = self.notifier:wait(wait_ns)
      if not ok then
        if why.kind ~= "timeout" then return nil, why.message end
        return ": working\n\n", ""
      end
    end
  end

  function close(self): boolean, string
    if not self.finished then
      self.finished = true
      self.flight.cancelled = true
      self.flight.done = true
      local task = self.task
      if task ~= nil then task:cancel() end
    end
    self.queue, self.head, self.tail, self.latest, self.answer = {}, 1, 1, nil, nil
    return true, ""
  end
end

--- `message` answered as an event stream, its handler in a task of its own.
local function streamed(self: State, message: wire.Message, req: HttpServer.Request, principal: string,
                        grant?: McpServer.Grant): HttpServer.Reply
  local notifier = Poll.notifier()
  local flight: Flight = { done = false, cancelled = false, principal = principal, grant = grant }
  local expires = if grant ~= nil then grant.expires else nil end
  local body: EventReader = { notifier = notifier, flight = flight, queue = {}, head = 1, tail = 1, finished = false,
    latest = nil, answer = nil, task = nil, skip = nil,
    ends_ns = if expires ~= nil then expires * 1000000000 else nil end }
  flight.emit = function(text: string, lossy: boolean)
    if body.finished then return end
    if lossy then
      body.latest = text
    elseif body.tail - body.head >= MAX_QUEUED then
      local _, _ = body:close()
    else
      body.queue[body.tail] = text
      body.tail = body.tail + 1
    end
    notifier:notify_all()
  end
  body.task = Poll.spawn(function()
    local said = answer_message(self, message, req, flight)
    if flight.cancelled then return end
    -- An answer always comes: a request with none (a notification) is not streamed.
    body.answer = said.body or wire.error(message.id, Mcp.INTERNAL_ERROR, raised.message)
    notifier:notify_all()
  end)
  return { status = 200, headers = { ["Content-Type"] = "text/event-stream", ["Cache-Control"] = "no-cache, no-transform" },
    body = body }
end

--- Whether `accept` names `want` itself, not by a wildcard: a client that asks for an event stream says so.
local function names(accept: string?, want: string): boolean
  if accept == nil then return false end
  for item in accept:gmatch("[^,]+") do
    local kind = item:match("^%s*([^;%s]+)")
    if kind ~= nil and kind:lower() == want then return true end
  end
  return false
end

--- Whether `host` is this machine's loopback, where a resource may be http.
local function loopback(host: string): boolean
  return host == "localhost" or host == "127.0.0.1" or host == "::1" or host == "[::1]"
end

--- What a resource server answers beside its endpoint: where its metadata is, and the metadata.
local record Protected
  oauth: McpServer.OAuth
  --- The path the metadata is served at, and its whole URL.
  path: string
  url: string
  --- The metadata's JSON text.
  body: string
end

--- The resource server `oauth` makes of an endpoint at `path`; raises where it does not hold.
local function protected(oauth: McpServer.OAuth, path: string): Protected
  local parts, why = Url.parse(oauth.resource)
  if parts == nil then error("mcp: handler: oauth.resource: " .. tostring(why), 4) end
  if not (parts.scheme == "https" or (parts.scheme == "http" and loopback(parts.host))) then
    error("mcp: handler: oauth.resource must be https (http only for loopback)", 4)
  end
  if parts.query ~= nil or parts.fragment ~= nil or parts.userinfo ~= nil then
    error("mcp: handler: oauth.resource has a query, a fragment or a user: a canonical URI has none", 4)
  end
  local at = if parts.path == "" then "/" else parts.path end
  if at ~= path then
    error("mcp: handler: oauth.resource's path " .. Json.quote(at) .. " is not the endpoint's, " .. Json.quote(path), 4)
  end
  if #oauth.authorization_servers < 1 then
    error("mcp: handler: oauth.authorization_servers is empty", 4)
  end
  local host = if parts.host:find(":", 1, true) ~= nil and parts.host:sub(1, 1) ~= "[" then
    "[" .. parts.host .. "]" else parts.host end
  local origin = parts.scheme .. "://" .. host .. (if parts.port ~= nil then ":" .. tostring(parts.port) else "" end)
  local metadata_path = "/.well-known/oauth-protected-resource" .. (if at == "/" then "" else at end)
  local doc: mut {string: Json.Value} = { resource = oauth.resource,
    authorization_servers = wire.strings(oauth.authorization_servers),
    bearer_methods_supported = wire.strings({ "header" }) }
  local scopes = oauth.scopes
  if scopes ~= nil then
    for _, scope in ipairs(scopes) do
      if not is_scope(scope) then
        error("mcp: handler: oauth.scopes: " .. Json.quote(scope) .. " is not a scope token", 4)
      end
    end
    doc["scopes_supported"] = wire.strings(scopes)
  end
  local body, bad = Json.encode(doc)
  if body == nil then error("mcp: handler: oauth: " .. tostring(bad), 4) end
  return { oauth = oauth, path = metadata_path, url = origin .. metadata_path, body = body }
end

--- `text` as the value of a challenge's parameter: quoted, its quotes and backslashes escaped.
local function quoted(text: string): string
  return '"' .. text:gsub('[\\"]', "\\%0") .. '"'
end

--- The answer that challenges a request: 401 for a token missing or refused, 403 for one that grants too little;
--- `scopes` are what to ask for.
local function challenge(p: Protected, status: integer, err?: string, scopes?: {string}, words?: string): HttpServer.Reply
  local parts: mut {string} = { "resource_metadata=" .. quoted(p.url) }
  if err ~= nil then parts[#parts + 1] = "error=" .. quoted(err) end
  if scopes ~= nil and #scopes > 0 then
    local named = "scope=" .. quoted(table.concat(scopes, " "))
    parts[#parts + 1] = named
  end
  local reply = refused(status, Mcp.INVALID_REQUEST, words or (if status == 403 then "Forbidden" else "Unauthorized" end))
  local headers: mut {string: string} = { ["Content-Type"] = "application/json" }
  headers["WWW-Authenticate"] = "Bearer " .. table.concat(parts, ", ")
  reply.headers = headers
  return reply
end

--- The access token of an `Authorization` header (`Bearer <token>`, the scheme in any case), or nil.
local function bearer_token(header?: string): string?
  if header == nil then return nil end
  local scheme, credentials = header:match("^(%S+) +(%S+)%s*$")
  if scheme == nil or credentials == nil or scheme:lower() ~= "bearer" then return nil end
  return credentials
end

--- Whether `granted` holds `needed`, as `oauth` reads scopes.
local function holds(oauth: McpServer.OAuth, granted: {string}, needed: string): boolean
  local covers = oauth.covers
  if covers ~= nil then return covers(granted, needed) end
  for _, g in ipairs(granted) do
    if g == needed then return true end
  end
  return false
end

--- The handler [`McpServer.Instance.handler`] answers.
local function handler(self: State, spec: McpServer.HttpSpec): function(HttpServer.Request): HttpServer.Reply
  local path = spec.path or "/mcp"
  local origins = spec.origins or {}
  local authorize = spec.authorize
  local oauth = spec.oauth
  if (authorize == nil) == (oauth == nil) then
    error("mcp: handler: give one of authorize and oauth", 3)
  end
  local resource = if oauth ~= nil then protected(oauth, path) else nil end
  local given_principal = spec.principal
  local function principal_of(req: HttpServer.Request, grant?: McpServer.Grant): string
    if given_principal ~= nil then return given_principal(req) end
    if grant ~= nil then return "iss " .. grant.issuer .. "\0sub " .. grant.subject end
    return req.headers["authorization"] or ""
  end
  return function(req: HttpServer.Request): HttpServer.Reply
    if resource ~= nil and req.path == resource.path then
      if req.method ~= "GET" then
        local reply = refused(405)
        reply.headers = { Allow = "GET" }
        return reply
      end
      return { status = 200, headers = { ["Content-Type"] = "application/json", ["Access-Control-Allow-Origin"] = "*" },
        body = resource.body }
    end
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
    local grant: McpServer.Grant? = nil
    if resource ~= nil then
      local token = bearer_token(req.headers["authorization"])
      if token == nil then return challenge(resource, 401, nil, resource.oauth.scopes) end
      local granted, _ = resource.oauth.verify(token, resource.oauth.resource)
      if granted == nil then
        return challenge(resource, 401, "invalid_token", resource.oauth.scopes)
      end
      grant = granted
    elseif authorize ~= nil and not authorize(req) then
      return refused(401, Mcp.INVALID_REQUEST, "Unauthorized")
    end
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
    if resource ~= nil and grant ~= nil and message.method == "tools/call" then
      -- Every scope the tool needs, named at once, so one authorization gets them all.
      local named, _ = NAMED:into(message.params)
      local tool = if named ~= nil and named.name ~= nil then self.by_tool[named.name] else nil end
      local none: {string} = {}
      local needs = if tool ~= nil then tool.scopes or none else none end
      for _, needed in ipairs(needs) do
        if not holds(resource.oauth, grant.scopes, needed) then
          -- Asked for with those granted, so the token that comes back does not lose them.
          local wanted: mut {string} = {}
          local seen: mut {string: boolean} = {}
          for _, list in ipairs({ grant.scopes, needs }) do
            for _, each in ipairs(list) do
              if seen[each] == nil and is_scope(each) then
                seen[each] = true
                wanted[#wanted + 1] = each
              end
            end
          end
          return challenge(resource, 403, "insufficient_scope", wanted,
            "Forbidden: the tool " .. tostring(assert(named).name) .. " needs the scopes " .. table.concat(needs, " "))
        end
      end
    end
    local principal = principal_of(req, grant)
    if message.method ~= nil and message.id ~= nil and names(req.headers["accept"], "text/event-stream") and
        Poll.in_task() then
      local meta, _ = meta_of(message.params)
      if meta ~= nil and (meta.progress_token ~= nil or message.method == "subscriptions/listen") then
        return streamed(self, message, req, principal, grant)
      end
    end
    local said = answer_message(self, message, req, { done = false, cancelled = false, principal = principal, grant = grant })
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

  function update(self, changes: McpServer.Changes)
    local old = self.state
    local spec = old.spec
    local next_spec: McpServer.Spec = {
      info = spec.info, instructions = spec.instructions, tools = changes.tools or spec.tools,
      resources = changes.resources or spec.resources, templates = changes.templates or spec.templates,
      read = spec.read, prompts = changes.prompts or spec.prompts, complete = spec.complete, page_size = spec.page_size,
      ttl_ms = spec.ttl_ms,
      cache_scope = spec.cache_scope, on_error = spec.on_error, state_key = old.state_key,
      state_ttl_ms = spec.state_ttl_ms,
    }
    local fresh = state_of(next_spec)
    old.spec, old.tools, old.by_tool, old.mirrors = fresh.spec, fresh.tools, fresh.by_tool, fresh.mirrors
    old.inputs, old.outputs = fresh.inputs, fresh.outputs
    old.resources, old.by_uri, old.templates = fresh.resources, fresh.by_uri, fresh.templates
    old.prompts, old.by_prompt = fresh.prompts, fresh.by_prompt
    if changes.tools ~= nil then
      announce(old, function(f: Filter): boolean return f.tools end, "notifications/tools/list_changed")
    end
    if changes.resources ~= nil or changes.templates ~= nil then
      announce(old, function(f: Filter): boolean return f.resources end, "notifications/resources/list_changed")
    end
    if changes.prompts ~= nil then
      announce(old, function(f: Filter): boolean return f.prompts end, "notifications/prompts/list_changed")
    end
  end

  function resource_updated(self, uri: string)
    announce(self.state, function(f: Filter): boolean return f.uris[uri] == true end, "notifications/resources/updated",
      { uri = uri })
  end

  function end_subscriptions(self)
    for _, listener in ipairs(self.state.hub.listeners) do
      listener.ended = true
      listener.wake:notify_all()
    end
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

--- The scopes a token's claims grant: `scope`, a space-separated string, or `scp`, an array of strings.
local function scopes_of(claims: {string: Json.Value}): {string}
  local out: mut {string} = {}
  local scope = claims["scope"]
  if scope is string then
    for each in scope:gmatch("%S+") do out[#out + 1] = each end
    return out
  end
  for _, each in ipairs(Json.array_of(claims["scp"]) or {}) do
    if each is string then out[#out + 1] = each end
  end
  return out
end

--- An [`OAuth.verify`] for JWT access tokens (RFC 9068): a token one of
--- `spec.keys` signed, of `typ` "at+jwt", whose `iss` is `spec.issuer`,
--- whose `aud` holds the endpoint's resource, that has a `sub` and an
--- `exp` and is within its time. Its grant is its `iss`, its `sub`, its
--- `exp` and the scopes of its `scope` (or `scp`).
---
---     local keys = assert(Jose.keys(jwks))
---     local verify = McpServer.jwt{ issuer = "https://auth.example.com", keys = keys }
function McpServer.jwt(spec: McpServer.JwtSpec): function(token: string, resource: string): (McpServer.Grant) | (nil, Failure)
  if #spec.keys < 1 then error("mcp: jwt: spec.keys is empty", 2) end
  local typ = spec.typ or "at+jwt"
  return function(token: string, resource: string): (McpServer.Grant) | (nil, Failure)
    local claims, why = Jose.verify_jwt(token, spec.keys, { issuer = spec.issuer, audience = resource,
      leeway = spec.leeway, require_exp = true, typ = typ })
    if claims == nil then return nil, why end
    return { issuer = claims.iss, subject = claims.sub, scopes = scopes_of(claims.claims), expires = claims.exp }
  end
end

--- An `authorize` that lets every request in: for a server bound to
--- loopback whose every caller may use every tool, or one behind a proxy
--- that authorizes.
function McpServer.anyone(_: HttpServer.Request): boolean
  return true
end

return McpServer

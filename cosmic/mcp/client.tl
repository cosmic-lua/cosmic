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
--- revision answers the first request with the versions it speaks,
--- which the failure names.
---
--- Every fallible call answers its value, or nil and a [`Failure`]:
--- `code` holds the JSON-RPC code where the server refused the request
--- ([`Mcp.METHOD_NOT_FOUND`], [`Mcp.UNSUPPORTED_VERSION`]), and nil where
--- the request never got an answer (a pipe closed, a connection
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
local JsonSchema = require("cosmic.jsonschema")
local Mcp = require("cosmic.mcp")
local Stream = require("cosmic.stream")
local String = require("cosmic.string")
local wire = require("cosmic.mcp.wire")

local record McpClient
  --- What [`McpClient.http`] takes.
  record HttpOptions
    --- How long one request may take, as [`Http.Options.timeout_ns`].
    timeout_ns: integer
    --- Headers sent with each request: `Authorization`, say. The
    --- protocol's own are set here and cannot be given.
    headers?: {string: string}
    --- How this client names itself (`cosmic`).
    info?: Mcp.Implementation
  end

  --- What [`McpClient.stdio`] and [`McpClient.spawn`] take.
  record Options
    --- How this client names itself (`cosmic`).
    info?: Mcp.Implementation
  end

  --- Where a client's requests go. Each call is one request (a list,
  --- one per page), answered before it returns. A session over stdio
  --- is one task's: two tasks calling it at once read each other's
  --- answers, so give each task a session of its own.
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
    --- Calls the tool `name` with `arguments`. A tool that ran and
    --- failed is a result with `isError`; a call the server refused is
    --- a failure. Where [`Session.tools`] listed the tool with an
    --- `outputSchema` this client can check, a result that is not an
    --- error and whose `structuredContent` does not hold to it is a
    --- failure too.
    call: function(Session, name: string, arguments?: {string: Json.Value}): (Mcp.ToolResult) | (nil, Failure)
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
    --- Ends the session: closes the server's stdin and waits for a
    --- spawned server to exit. Safe to call more than once.
    close: function(Session): (true) | (false, Failure)
  end
end

--- The most pages of one list a client reads, so a server that answers
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
end

--- Sends one request and answers its response, which holds a result,
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
end

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
local function params_of(self: State, fields: {string: Json.Value}): {string: Json.Value}
  local out: mut {string: Json.Value} = {}
  for k, v in pairs(fields) do out[k] = v end
  local capabilities: {string: Json.Value} = {}
  out["_meta"] = {
    [META_VERSION] = Mcp.VERSION,
    [META_CLIENT] = wire.implementation(self.info),
    [META_CAPABILITIES] = capabilities,
  }
  return out
end

--- Sends `method` with `fields`, and answers the result once it is a
--- final one.
local function ask(self: State, method: string, fields: {string: Json.Value}, name?: string,
                   mirrored?: {string: string}): (wire.Message) | (nil, Failure)
  if self.closed then return nil, Failure.new("mcp: the session is closed") end
  self.next_id = self.next_id + 1
  local req: Request = { id = tostring(self.next_id), method = method, params = params_of(self, fields), name = name,
    mirrored = mirrored }
  local response, why = self.send(req)
  if response == nil then return nil, why end
  local complete, kind = wire.complete(response.result)
  if not complete then return nil, kind end
  return response
end

--- Reads each page of the list `method` answers, `each` taking its
--- items and answering the next cursor, false at the last.
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

--- The failure of a list `method` answers more than [`MAX_ITEMS`] of.
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

local function call(self: State, name: string, arguments?: {string: Json.Value}): (Mcp.ToolResult) | (nil, Failure)
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
  local response, failed = ask(self, "tools/call", fields, name, headers)
  if response ~= nil then return checked(self, name, response.result) end
  if not (self.http and failed.code == Mcp.HEADER_MISMATCH) then return nil, failed end
  -- The tool's schema may have changed since it was listed: list again,
  -- and send the headers it names now.
  local listed, lwhy = tools(self)
  if listed == nil then return nil, lwhy end
  local again, awhy = mirrored()
  if again == nil then return nil, awhy end
  local retried, rwhy = ask(self, "tools/call", fields, name, again)
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
  local response, why = ask(self, "resources/read", { uri = uri }, uri)
  if response == nil then return nil, why end
  return wire.read(response.result)
end

local function prompt(self: State, name: string, arguments?: {string: string}): (Mcp.PromptResult) | (nil, Failure)
  local args: mut {string: Json.Value} = {}
  for k, v in pairs(arguments or {}) do args[k] = v end
  local response, why = ask(self, "prompts/get", { name = name, arguments = args }, name)
  if response == nil then return nil, why end
  return wire.prompt_result_of(response.result)
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
  function call(self, name: string, arguments?: {string: Json.Value}): (Mcp.ToolResult) | (nil, Failure)
    return call(self.state, name, arguments)
  end
  function resources(self): ({Mcp.Resource}) | (nil, Failure) return resources(self.state) end
  function templates(self): ({Mcp.ResourceTemplate}) | (nil, Failure)
    return templates(self.state)
  end
  function read(self, uri: string): ({Mcp.ResourceContents}) | (nil, Failure)
    return read(self.state, uri)
  end
  function prompts(self): ({Mcp.Prompt}) | (nil, Failure) return prompts(self.state) end
  function prompt(self, name: string, arguments?: {string: string}): (Mcp.PromptResult) | (nil, Failure)
    return prompt(self.state, name, arguments)
  end
  function close(self): (true) | (false, Failure)
    local s = self.state
    if s.closed then return true end
    s.closed = true
    return s.finish()
  end
end

local function session(send: Send, info?: Mcp.Implementation, http: boolean,
                       finish: function(): (true) | (false, Failure)): McpClient.Session
  local running: Running = {
    state = { send = send, info = info or DEFAULT_INFO, http = http, next_id = 0, mirrors = {}, outputs = {}, finish = finish,
      closed = false },
  }
  return running
end

-- stdio.

--- The answer to `req`, read from `lines` after writing it to `writer`:
--- the response whose id is the request's, the notifications before it
--- passed over.
local function stdio_send(lines: Stream.Lines, writer: Stream.Writer): Send
  return function(req: Request): (wire.Message) | (nil, Failure)
    local ok, wtrouble = writer:write(wire.request(req.id, req.method, req.params) .. "\n")
    if not ok then return nil, Failure.new("mcp: writing to the server: " .. wtrouble) end
    while true do
      local line, trouble = lines:read()
      if line == nil then
        if trouble ~= "" then
          return nil, Failure.new("mcp: reading from the server: " .. trouble)
        end
        return nil, Failure.new("mcp: the server closed its output before it answered " .. req.method)
      end
      if line:find("%S") ~= nil then
        local message, bad = wire.message(line)
        if message == nil then
          return nil, Failure.new("mcp: the server wrote a line that is not a message: " .. bad.message)
        end
        if message.method == nil and message.id == req.id then
          local err = message.error
          if err ~= nil then return nil, refused(err) end
          if message.result == nil then
            return nil, Failure.new("mcp: the server answered " .. req.method .. " with no result")
          end
          return message
        end
      end
    end
  end
end

--- A session over a server's output, `reader`, and its input, `writer`,
--- one message a line: a server this program started, or a socket.
--- Closing the session closes `writer`, which tells the server to end.
function McpClient.stdio(reader: Stream.Reader, writer: Stream.Writer, opts?: McpClient.Options): McpClient.Session
  local lines = Stream.lines(reader, Mcp.MAX_MESSAGE_BYTES)
  local info = if opts ~= nil then opts.info else nil end
  return session(stdio_send(lines, writer), info, false,
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
    return nil, Failure.new("mcp: starting " .. (argv[1] or "") .. ": " .. why)
  end
  local reader, writer = handle.stdout_stream, handle.stdin_stream
  if reader == nil or writer == nil then return nil, Failure.new("mcp: the server has no pipes") end
  local lines = Stream.lines(reader, Mcp.MAX_MESSAGE_BYTES)
  local info = if client_opts ~= nil then client_opts.info else nil end
  return session(stdio_send(lines, writer), info, false,
    function(): (true) | (false, Failure)
      local _, _ = writer:close()
      local result, _ = handle:wait(5 * 1000000000)
      if result == nil then
        local closed, trouble = handle:close()
        if not closed then return false, Failure.new("mcp: ending the server: " .. trouble) end
      end
      return true
    end)
end

-- Streamable HTTP.

--- The protocol's own headers, which `opts.headers` may not name.
local OWN_HEADERS <const>: {string: boolean} = {
  ["content-type"] = true, accept = true, ["mcp-protocol-version"] = true, ["mcp-method"] = true, ["mcp-name"] = true,
}

--- The JSON-RPC messages an event stream holds, each the data of one
--- event: its `data:` lines joined by newlines.
local function events(body: string): {string}
  local out: mut {string} = {}
  local data: mut {string} = {}
  local function flush()
    if #data > 0 then
      local joined = table.concat(data, "\n")
      out[#out + 1] = joined
      data = {}
    end
  end
  -- A line ends at CRLF, LF or CR; an event, at a blank line, and one
  -- the stream ends inside is dropped, as the event stream format has it.
  local text = body:gsub("\r\n", "\n"):gsub("\r", "\n")
  for line in text:gmatch("([^\n]*)\n") do
    if line == "" then
      flush()
    else
      local field, value = line:match("^([^:]*):? ?(.*)$")
      if field == "data" and value ~= nil then data[#data + 1] = value end
    end
  end
  return out
end

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

--- The response message to `id` in `got`, or nil and why there is none.
local function http_response(got: Http.Body, id: string, method: string): (wire.Message) | (nil, Failure)
  local kind = ((got.headers["content-type"] or ""):match("^%s*([^;%s]+)") or ""):lower()
  local messages: {string} = {}
  if kind == "text/event-stream" then
    messages = events(got.body)
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
--- request. Redirects are not followed: a server that moves answers
--- with a failure naming the status. `opts.headers` go with every
--- request; one that names a header the protocol sets raises.
function McpClient.http(url: string, opts: McpClient.HttpOptions): McpClient.Session
  for name in pairs(opts.headers or {}) do
    local lower = name:lower()
    if OWN_HEADERS[lower] == true or lower:sub(1, 10) == "mcp-param-" then
      error("mcp: http: opts.headers may not name " .. name .. ", which the protocol sets", 2)
    end
  end
  local send = function(req: Request): (wire.Message) | (nil, Failure)
    local headers: mut {string: string} = {}
    for k, v in pairs(opts.headers or {}) do headers[k] = v end
    headers["Content-Type"] = "application/json"
    headers["Accept"] = "application/json, text/event-stream"
    headers["MCP-Protocol-Version"] = Mcp.VERSION
    headers["Mcp-Method"] = req.method
    if req.name ~= nil then headers["Mcp-Name"] = Mcp.header_text(req.name) end
    for header, value in pairs(req.mirrored or {}) do
      headers["Mcp-Param-" .. header] = Mcp.header_text(value)
    end
    local got, why = Http.request("POST", url, {
      timeout_ns = opts.timeout_ns, headers = headers, body = wire.request(req.id, req.method, req.params),
      follow = false, max_bytes = Mcp.MAX_MESSAGE_BYTES,
    })
    if got == nil then return nil, Failure.new("mcp: " .. req.method .. ": " .. why) end
    local message, bad = http_response(got, req.id, req.method)
    if message == nil then return nil, bad end
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
  return session(send, opts.info, true, function(): (true) | (false, Failure) return true end)
end

return McpClient

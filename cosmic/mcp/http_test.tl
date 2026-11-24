--- [`cosmic.mcp.server`]'s Streamable HTTP handler under
--- [`cosmic.http.server`] on the worker's loopback, asked by
--- [`cosmic.mcp.client`] and by requests written by hand, in one run.

local Client = require("cosmic.mcp.client")
local Clock = require("cosmic.clock")
local Failure = require("cosmic.failure")
local Http = require("cosmic.http")
local HttpServer = require("cosmic.http.server")
local Json = require("cosmic.json")
local Mcp = require("cosmic.mcp")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Server = require("cosmic.mcp.server")
local Stream = require("cosmic.stream")
local Test = require("cosmic.test")

Test.policy{ loopback = { "127.0.0.1" } }

local WAIT <const> = Clock.seconds(20)
local TOKEN <const> = "0123456789abcdef-token"

local function count_tool(): Server.ToolSpec
  local schema: {string: Json.Value} = {
    type = "object",
    properties = { n = { type = "integer", ["x-mcp-header"] = "N" } },
  }
  return {
    tool = { name = "count", inputSchema = schema },
    call = function(_: {string: Json.Value}, _: Server.Call): (Mcp.ToolResult) | (nil, Failure)
      return Mcp.result({ "ok" })
    end,
  }
end

local function region_tool(): Server.ToolSpec
  local schema: {string: Json.Value} = {
    type = "object",
    properties = { region = { type = "string", ["x-mcp-header"] = "Region" }, query = { type = "string" } },
  }
  return {
    tool = { name = "where", inputSchema = schema },
    call = function(args: {string: Json.Value}, call: Server.Call): (Mcp.ToolResult) | (nil, Failure)
      local region = args["region"]
      local seen = if call.http ~= nil then call.http.headers["mcp-param-region"] or "" else "" end
      return Mcp.result({ (if region is string then region else "?" end) .. " " .. seen })
    end,
  }
end

local function server(): Server.Instance
  return Server.new{
    info = { name = "web", version = "1" },
    tools = {
      {
        tool = { name = "echo", inputSchema = Mcp.object_schema({ text = { type = "string" } }) },
        call = function(args: {string: Json.Value}, _: Server.Call): (Mcp.ToolResult) | (nil, Failure)
          local text = args["text"]
          return Mcp.result({ if text is string then text else "" end })
        end,
      },
      region_tool(),
      count_tool(),
    },
  }
end

--- Serves `handle` on loopback and runs `client` with the endpoint's
--- URL, then stops.
local function serving(handle: function(HttpServer.Request): HttpServer.Reply, client: function(url: string))
  assert(HttpServer.serve{
    listeners = { Net.tcp("127.0.0.1", 0) },
    handle = handle,
    on_ready = function(addresses: {Net.Address}, running: Net.Server)
      local at = assert(addresses[1])
      client("http://127.0.0.1:" .. tostring(at.port) .. "/mcp")
      running:stop()
    end,
  })
end

local function test_the_client_calls_tools_over_http_with_its_token()
  serving(server():handler{ authorize = Server.bearer(TOKEN) }, function(url: string)
    local session = Client.http(url, { timeout_ns = WAIT, headers = { Authorization = "Bearer " .. TOKEN } })
    local d = assert(session:discover())
    assert(assert(d.supportedVersions[1]) == Mcp.VERSION)
    local tools = assert(session:tools())
    assert(#tools == 3)
    local said = assert(session:call("echo", { text = "héllo\nthere" }))
    assert(assert(said.content[1]).text == "héllo\nthere")
    local where = assert(session:call("where", { region = "us-west1", query = "q" }))
    assert(assert(where.content[1]).text == "us-west1 us-west1", "the argument went in its header too")
    local odd = assert(session:call("where", { region = " pad " }))
    assert(assert(odd.content[1]).text == " pad  =?base64?IHBhZCA=?=", assert(odd.content[1]).text)
    assert(session:close())
    local stranger = Client.http(url, { timeout_ns = WAIT })
    local none, why = stranger:tools()
    assert(none == nil and tostring(why):find("401", 1, true) ~= nil, tostring(why))
    local wrong = Client.http(url, { timeout_ns = WAIT, headers = { Authorization = "Bearer " .. TOKEN .. "x" } })
    local refused, _ = wrong:tools()
    assert(refused == nil)
    local lower = Client.http(url, { timeout_ns = WAIT, headers = { Authorization = "bearer " .. TOKEN } })
    local listed, _ = lower:tools()
    assert(listed ~= nil, "the scheme is read in any case")
  end)
end

--- A hand-written POST to `url`.
local function post(url: string, body: string, headers: {string: string}): Http.Body
  local all: mut {string: string} = { ["Content-Type"] = "application/json", Accept = "application/json, text/event-stream" }
  for k, v in pairs(headers) do all[k] = v end
  local got = assert(Http.request("POST", url, { timeout_ns = WAIT, headers = all, body = body }))
  return got
end

local META <const> = '"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}'

local function test_the_handler_refuses_what_the_transport_refuses()
  serving(server():handler{ authorize = Server.anyone, origins = { "https://ok.example" } }, function(url: string)
    local list = '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{' .. META .. "}}"
    local good = { ["MCP-Protocol-Version"] = Mcp.VERSION, ["Mcp-Method"] = "tools/list" }
    assert(post(url, list, good).status == 200)
    local evil: mut {string: string} = { Origin = "https://evil.example" }
    for k, v in pairs(good) do evil[k] = v end
    assert(post(url, list, evil).status == 403, "a foreign origin is refused")
    local ok_origin: mut {string: string} = { Origin = "https://ok.example" }
    for k, v in pairs(good) do ok_origin[k] = v end
    assert(post(url, list, ok_origin).status == 200)
    local no_version = post(url, list, { ["Mcp-Method"] = "tools/list" })
    assert(no_version.status == 400 and no_version.body:find("-32020", 1, true) ~= nil, no_version.body)
    local wrong_method = post(url, list, { ["MCP-Protocol-Version"] = Mcp.VERSION, ["Mcp-Method"] = "tools/call" })
    assert(wrong_method.status == 400 and wrong_method.body:find("-32020", 1, true) ~= nil)
    local call = '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"where","arguments":{"region":"a"},' .. META .. "}}"
    local no_param = post(url, call, { ["MCP-Protocol-Version"] = Mcp.VERSION, ["Mcp-Method"] = "tools/call", ["Mcp-Name"] = "where" })
    assert(no_param.status == 400 and no_param.body:find("Mcp-Param-Region", 1, true) ~= nil, no_param.body)
    local wrong_name = post(url, call, { ["MCP-Protocol-Version"] = Mcp.VERSION, ["Mcp-Method"] = "tools/call", ["Mcp-Name"] = "echo",
      ["Mcp-Param-Region"] = "a" })
    assert(wrong_name.status == 400)
    local absent = post(url, '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"where","arguments":{},' .. META .. "}}",
      { ["MCP-Protocol-Version"] = Mcp.VERSION, ["Mcp-Method"] = "tools/call", ["Mcp-Name"] = "where", ["Mcp-Param-Region"] = "admin" })
    assert(absent.status == 400, "a header for an argument the body does not hold is refused")
    local count = '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"count","arguments":{"n":42},' .. META .. "}}"
    local function counted(header: string): integer
      return post(url, count, { ["MCP-Protocol-Version"] = Mcp.VERSION, ["Mcp-Method"] = "tools/call", ["Mcp-Name"] = "count",
        ["Mcp-Param-N"] = header }).status
    end
    assert(counted("42") == 200 and counted("42.0") == 200)
    assert(counted("0x2A") == 400 and counted("4.2e1") == 400 and counted("43") == 400)
    local missing = post(url, '{"jsonrpc":"2.0","id":3,"method":"no/such","params":{' .. META .. "}}",
      { ["MCP-Protocol-Version"] = Mcp.VERSION, ["Mcp-Method"] = "no/such" })
    assert(missing.status == 404 and missing.body:find("-32601", 1, true) ~= nil)
    local note = post(url, '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{}}', {})
    assert(note.status == 202 and note.body == "")
    local text = assert(Http.request("POST", url, { timeout_ns = WAIT, headers = { ["Content-Type"] = "text/plain" }, body = list }))
    assert(text.status == 415)
    local get = assert(Http.get(url, { timeout_ns = WAIT }))
    assert(get.status == 405)
    local elsewhere = assert(Http.request("POST", url:gsub("/mcp$", "/other"), { timeout_ns = WAIT, body = list }))
    assert(elsewhere.status == 404)
  end)
end

--- An answer as an event stream, as a server may send one: the client
--- reads the response to its request among the events.
local function test_the_client_reads_a_response_sent_as_events()
  serving(function(req: HttpServer.Request): HttpServer.Reply
    local body = '{"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","supportedVersions":["2026-07-28"],' ..
      '"capabilities":{},"ttlMs":0,"cacheScope":"private"}}'
    local _ = req
    return { status = 200, headers = { ["Content-Type"] = "text/event-stream" },
      body = ": keep-alive\n\ndata: ping\n\nevent: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{}}\n\n" ..
        "data: " .. body .. "\n\n" }
  end, function(url: string)
    local session = Client.http(url, { timeout_ns = WAIT })
    local d = assert(session:discover())
    assert(assert(d.supportedVersions[1]) == "2026-07-28" and d.serverInfo == nil)
  end)
end

local function test_a_header_the_protocol_sets_cannot_be_given()
  Test.raises(function()
    Client.http("http://127.0.0.1:1/mcp", { timeout_ns = WAIT, headers = { ["mcp-method"] = "x" } })
  end,
    "the protocol sets")
  Test.raises(function() server():handler{ authorize = Server.bearer("short") } end, "at least 16 bytes")
end

local function test_headers_go_over_plain_http_only_to_a_loopback_host()
  local secret = { Authorization = "Bearer 0123456789abcdef" }
  Test.raises(function()
    Client.http("http://192.0.2.1/mcp", { timeout_ns = WAIT, headers = secret })
  end,
    "in the clear over http:// to 192.0.2.1; use an https:// URL")
  Test.raises(function()
    Client.http("HTTP://example.com:8080/mcp", { timeout_ns = WAIT, headers = secret })
  end,
    "to example.com")
  Test.raises(function()
    Client.http("http://exa mple.com/mcp", { timeout_ns = WAIT, headers = secret })
  end,
    "a URL that can be read")
  for _, url in ipairs({ "http://127.0.0.1@example.com/mcp", "http://127.0.0.1:1@example.com/mcp",
      "http://localhost/mcp", "http://127.0.0.1./mcp" }) do
    Test.raises(function() Client.http(url, { timeout_ns = WAIT, headers = secret }) end, "in the clear")
  end
  Client.http("HTTP://127.0.0.1:1/mcp", { timeout_ns = WAIT, headers = secret })
  Client.http("http://[::ffff:127.0.0.1]:1/mcp", { timeout_ns = WAIT, headers = secret })
  Client.http("https://example.com/a b", { timeout_ns = WAIT, headers = secret })
  Client.http("http://exa mple.com/mcp", { timeout_ns = WAIT })
  Client.http("http://127.0.0.1:1/mcp", { timeout_ns = WAIT, headers = secret })
  Client.http("http://[::1]:1/mcp", { timeout_ns = WAIT, headers = secret })
  Client.http("https://example.com/mcp", { timeout_ns = WAIT, headers = secret })
  Client.http("http://192.0.2.1/mcp", { timeout_ns = WAIT })
end

--- A tool that tells its progress `steps` times, a pause apart, and notes in `seen` when it finds itself cancelled.
local function slow_tool(name: string, steps: integer, seen: mut {string}): Server.ToolSpec
  return {
    tool = { name = name, inputSchema = Mcp.object_schema({}) },
    call = function(_: {string: Json.Value}, call: Server.Call): (Mcp.ToolResult) | (nil, Failure)
      for i = 1, steps do
        call.progress(i, steps, "step " .. tostring(i))
        call.progress(i, steps, "the same again, dropped")
        local ok, why = Clock.sleep(Clock.ms(20))
        if not ok or call.cancelled() then
          local said = "cancelled: " .. tostring(why)
          seen[#seen + 1] = said
          return nil, Failure.new("cancelled")
        end
      end
      return Mcp.result({ "done" })
    end,
  }
end

local function test_progress_comes_as_events_and_a_closed_stream_cancels()
  local seen: mut {string} = {}
  local troubles: mut {string} = {}
  local instance = Server.new{ info = { name = "slow", version = "1" }, tools = { slow_tool("slow", 3, seen),
    slow_tool("long", 500, seen) },
    on_error = function(trouble: string) troubles[#troubles + 1] = trouble end }
  serving(instance:handler{ authorize = Server.anyone }, function(url: string)
    local session = Client.http(url, { timeout_ns = WAIT })
    local heard: mut {Mcp.Progress} = {}
    local done = assert(session:call("slow", {}, { on_progress = function(p: Mcp.Progress)
      heard[#heard + 1] = p
    end }))
    assert(assert(done.content[1]).text == "done")
    assert(#heard == 3, "each step once: " .. tostring(#heard))
    local first = assert(heard[1])
    assert(first.progress == 1 and first.total == 3 and first.message == "step 1")
    local plain = assert(session:call("slow"))
    assert(assert(plain.content[1]).text == "done", "a call that asks for no progress is answered as JSON")
    -- A caller that gives up mid-call closes the stream, and the tool finds itself cancelled.
    local caller = Poll.spawn(function()
      local _, _ = session:call("long", {}, { on_progress = function(_: Mcp.Progress) end })
    end)
    assert(Clock.sleep(Clock.ms(50)))
    caller:cancel()
    local _, _ = caller:join(WAIT)
    for _ = 1, 500 do
      if #seen > 0 then break end
      assert(Clock.sleep(Clock.ms(10)))
    end
    assert(#seen == 1 and assert(seen[1]):find("cancelled", 1, true) ~= nil, table.concat(seen, "; "))
  end)
  assert(#troubles == 0, table.concat(troubles, "\n"))
end

--- A subscription over HTTP is one event stream: the acknowledgment, each notice asked for, then the graceful end
--- the server sends as it stops. One that asks without a stream is refused.
local function test_a_subscription_comes_as_events_and_ends_with_the_server()
  local instance = server()
  serving(instance:handler{ authorize = Server.anyone }, function(url: string)
    local session = Client.http(url, { timeout_ns = WAIT })
    local agreed: Client.Subscription? = nil
    local notices: mut {string} = {}
    local result: boolean? = nil
    local listener = Poll.spawn(function()
      local ok, why = session:listen({ tools = true, prompts = true, uris = { "note://x" } },
        function(n: Client.Notice) notices[#notices + 1] = n.kind end,
        function(a: Client.Subscription) agreed = a end)
      assert(ok, tostring(why))
      result = ok
    end)
    for _ = 1, 2000 do
      if agreed ~= nil then break end
      assert(Clock.sleep(Clock.ms(10)))
    end
    local a = assert(agreed, "the acknowledgment comes first")
    assert(a.tools == true and a.prompts == false and #assert(a.uris) == 0, "it agrees only to what it offers")
    assert(session:call("echo", { text = "meanwhile" }))
    instance:update({ tools = { count_tool() } })
    for _ = 1, 2000 do
      if #notices > 0 then break end
      assert(Clock.sleep(Clock.ms(10)))
    end
    instance:end_subscriptions()
    assert(listener:join(WAIT))
    assert(result == true and table.concat(notices, "|") == "tools", table.concat(notices, "|"))
    local plain = post(url, '{"jsonrpc":"2.0","id":9,"method":"subscriptions/listen","params":{"notifications":{},' ..
        '"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}',
      { Accept = "application/json", ["MCP-Protocol-Version"] = Mcp.VERSION, ["Mcp-Method"] = "subscriptions/listen" })
    assert(plain.body:find("text/event-stream", 1, true) ~= nil, plain.body)
  end)
end

--- A tool that asks for a link to be opened, then answers what the person did.
local function linking(): Server.Instance
  return Server.new{ info = { name = "links", version = "1" }, tools = { {
    tool = { name = "connect", inputSchema = Mcp.object_schema({}) },
    call = function(_: {string: Json.Value}, call: Server.Call): (Mcp.ToolResult) | (nil, Failure)
      call.keep("asked")
      local answer, why = call.elicit("signin", Mcp.elicit_url("Sign in to connect.", "https://example.com/signin"))
      if answer == nil then return nil, why end
      return Mcp.result({ answer.action .. " " .. (call.state or "-") })
    end,
  } } }
end

--- Over HTTP a tool asks for input as it does over stdio, and the state it keeps holds only for the caller whose
--- `Authorization` it was kept for.
local function test_a_tool_asks_for_input_over_http_and_its_state_is_the_callers()
  serving(linking():handler{ authorize = Server.anyone }, function(url: string)
    local shown: mut {string} = {}
    local session = Client.http(url, { timeout_ns = WAIT, headers = { Authorization = "Bearer one" },
      elicit = function(e: Mcp.Elicitation): (Mcp.Elicited) | (nil, Failure)
        local line = e.mode .. " " .. tostring(e.url)
        shown[#shown + 1] = line
        return { action = "accept" }
      end })
    local said = assert(session:call("connect"))
    assert(assert(said.content[1]).text == "accept asked", assert(said.content[1]).text)
    assert(#shown == 1 and shown[1] == "url https://example.com/signin", table.concat(shown, "; "))
    local caps = '"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",' ..
      '"io.modelcontextprotocol/clientCapabilities":{"elicitation":{"url":{}}}}'
    local headers: {string: string} = { ["MCP-Protocol-Version"] = Mcp.VERSION, ["Mcp-Method"] = "tools/call",
      ["Mcp-Name"] = "connect", ["Authorization"] = "Bearer one" }
    local first, fwhy = Json.decode(post(url, '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"connect",' ..
        caps .. "}}", headers).body)
    assert(first ~= nil, tostring(fwhy))
    local result = assert(Json.object_of(assert(Json.object_of(first))["result"]))
    local state = result["requestState"]
    assert(state is string)
    local other: mut {string: string} = {}
    for k, v in pairs(headers) do other[k] = v end
    other["Authorization"] = "Bearer two"
    local stolen = post(url, '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"connect",' ..
        '"requestState":' .. Json.quote(state) .. ',"inputResponses":{"signin":{"action":"accept"}},' .. caps .. "}}", other)
    assert(stolen.body:find("requestState does not hold", 1, true) ~= nil, stolen.body)
  end)
end

--- A body that gives its text a byte at a time.
local class Trickle is Stream.Reader
  mut text: string

  function read(self, _max?: integer): string?, string
    if self.text == "" then return nil, "" end
    local byte = self.text:sub(1, 1)
    self.text = self.text:sub(2)
    return byte, ""
  end

  function close(self): boolean, string return true, "" end
end

--- An event stream sent a byte at a time, its lines ended CRLF, is read whole: each notice once, a notice that
--- does not grow its progress passed over, then the answer.
local function test_the_client_reads_events_sent_a_byte_at_a_time()
  local progress = '{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":1,"progress":%d}}'
  local answer = '{"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","content":[{"type":"text","text":"ok"}]}}'
  local text = "data: " .. progress:format(1) .. "\r\n\r\n" .. ": comment\r\n\r\n" .. "data: " .. progress:format(2) ..
    "\r\n\r\ndata: " .. progress:format(2) .. "\r\n\r\ndata: " .. answer .. "\r\n\r\n"
  serving(function(_: HttpServer.Request): HttpServer.Reply
    local body: Trickle = { text = text, skip = nil }
    return { status = 200, headers = { ["Content-Type"] = "text/event-stream" }, body = body }
  end, function(url: string)
    local session = Client.http(url, { timeout_ns = WAIT })
    local heard: mut {number} = {}
    local said = assert(session:call("x", {}, { on_progress = function(p: Mcp.Progress)
      heard[#heard + 1] = p.progress
    end }))
    assert(assert(said.content[1]).text == "ok")
    assert(#heard == 2 and heard[1] == 1 and heard[2] == 2, tostring(#heard))
  end)
end

--- A call whose client closes its connection while the tool works in silence (no progress to write) is cancelled
--- within a second: the stream asks whether the client has gone, rather than waiting for a write to fail.
local function test_a_quiet_call_is_cancelled_soon_after_its_client_closes()
  local cancelled_ns: integer? = nil
  local quiet: Server.ToolSpec = {
    tool = { name = "quiet", inputSchema = Mcp.object_schema({}) },
    call = function(_: {string: Json.Value}, call: Server.Call): (Mcp.ToolResult) | (nil, Failure)
      local until_ns = Clock.monotonic_ns() + Clock.seconds(10)
      while Clock.monotonic_ns() < until_ns do
        local ok, _ = Poll.delay(Clock.ms(10))
        if not ok or call.cancelled() then
          cancelled_ns = Clock.monotonic_ns()
          return nil, Failure.new("cancelled")
        end
      end
      return Mcp.result({ "done" })
    end,
  }
  local instance = Server.new{ info = { name = "quiet", version = "1" }, tools = { quiet } }
  local closed_ns = 0
  serving(instance:handler{ authorize = Server.anyone }, function(url: string)
    local port = assert(math.tointeger(tonumber(url:match(":(%d+)/"))))
    local body = '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"quiet","arguments":{},' ..
      '"_meta":{"progressToken":"p","io.modelcontextprotocol/protocolVersion":"2026-07-28",' ..
      '"io.modelcontextprotocol/clientCapabilities":{}}}}'
    local conn = assert(Net.connect(Net.tcp("127.0.0.1", port), { timeout_ns = WAIT }))
    assert(conn:write("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\n" ..
        "Accept: application/json, text/event-stream\r\nMCP-Protocol-Version: " .. Mcp.VERSION .. "\r\n" ..
        "Mcp-Method: tools/call\r\nMcp-Name: quiet\r\nContent-Length: " .. tostring(#body) .. "\r\n\r\n" .. body))
    local got = ""
    while not got:find("\r\n\r\n", 1, true) do
      local piece, why = conn:read()
      assert(piece ~= nil, "reading the head: " .. why)
      got = got .. piece
    end
    assert(got:find("^HTTP/1%.1 200") ~= nil and got:find("text/event-stream", 1, true) ~= nil, got)
    assert(Poll.delay(Clock.ms(300)))
    assert(cancelled_ns == nil, "the call was cancelled while its client was there")
    closed_ns = Clock.monotonic_ns()
    assert(conn:close())
    local until_ns = closed_ns + Clock.seconds(3)
    while cancelled_ns == nil and Clock.monotonic_ns() < until_ns do
      assert(Poll.delay(Clock.ms(10)))
    end
  end)
  local at = assert(cancelled_ns, "the call was never cancelled")
  assert(at - closed_ns < Clock.seconds(1), tostring(at - closed_ns))
end

--- Fuzz properties for what [`cosmic.mcp`] reads from a peer it does not trust: [`wire.message`] and the decoders of
--- each result, the event stream splitter, the `Bearer` challenge parser, and a server's reply to any text. Each is
--- total, returning for whatever it is handed and never raising, and the splitter gives the events a stream holds
--- however it is cut. `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (cosmic/fuzz.tl).

local Failure = require("cosmic.failure")
local Fuzz = require("cosmic.fuzz")
local Json = require("cosmic.json")
local Mcp = require("cosmic.mcp")
local Server = require("cosmic.mcp.server")
local wire = require("cosmic.mcp.wire")

--- Messages as a peer sends them, to mutate.
local MESSAGES <const>: {string} = {
  '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"},' ..
    '"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}',
  '{"jsonrpc":"2.0","id":"a","result":{"tools":[{"name":"echo","inputSchema":{"type":"object"}}],"nextCursor":"2"}}',
  '{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"bad","data":{"x":[1,2]}}}',
  '{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"p","progress":1,"total":2}}',
  '{"jsonrpc":"2.0","id":3,"result":{"resultType":"input_required","inputRequests":{"k":{"method":"elicitation/create",' ..
    '"params":{"mode":"form","message":"name?","requestedSchema":{"type":"object","properties":{"n":{"type":"string"}}}}}},' ..
    '"requestState":"s"}}',
}

--- Results as a server sends them, to mutate and hand each decoder.
local RESULTS <const>: {string} = {
  '{"tools":[{"name":"echo","description":"d","inputSchema":{"type":"object"},"outputSchema":{"type":"object"},' ..
    '"annotations":{"readOnlyHint":true}}],"nextCursor":"c"}',
  '{"content":[{"type":"text","text":"hi"},{"type":"image","data":"AA==","mimeType":"image/png"}],' ..
    '"structuredContent":{"a":1},"isError":false}',
  '{"contents":[{"uri":"file:///a","mimeType":"text/plain","text":"x"},{"uri":"file:///b","blob":"AA=="}]}',
  '{"description":"p","messages":[{"role":"user","content":{"type":"text","text":"hi"}}]}',
  '{"serverInfo":{"name":"s","version":"1"},"supportedVersions":["2026-07-28"],"capabilities":{"tools":{}}}',
  '{"resultType":"input_required","inputRequests":{"k":{"method":"elicitation/create","params":{"mode":"url",' ..
    '"message":"go","url":"https://example.com/x"}}},"requestState":"s"}',
  '{"action":"accept","content":{"n":"ada","ok":true,"k":3}}',
  '{"completion":{"values":["python","perl"],"total":2,"hasMore":false}}',
  '{"ref":{"type":"ref/resource","uri":"repo://{owner}/{name}"},"argument":{"name":"name","value":"co"},' ..
    '"context":{"arguments":{"owner":"will"}}}',
}

--- Event streams as a server sends them, to mutate: every line end, an event cut off by the end, one the end's CR
--- completes, a byte order mark, a NUL, and blank lines with no event between.
local STREAMS <const>: {string} = {
  "event: message\r\ndata: {\"a\":1}\r\n\r\n: working\n\ndata: one\ndata: two\n\nid: 3\rdata: x\r\r" ..
    "data: tail",
  "data: a\r\ndata: b\r\r\ndata: end\r\r",
  "\239\187\191data: bom\n\ndata: n\0ul\n\n\n\n\ndata:x\ndata\n\n",
}

local CHALLENGE <const> = 'Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource/mcp", ' ..
  'error="insufficient_scope", scope="files:read files:write"'

--- Whether a refusal says why.
local function said(why?: Failure): boolean
  return why ~= nil and why.message ~= ""
end

local function test_message_is_total(tmp: string)
  Fuzz.run({
    name = "read a changed message",
    dir = tmp,
    requires = { "accepted", "refused" },
    gen = function(src: Fuzz.Source): string
      if src:int(0, 9) == 0 then return Fuzz.bytes(src, 200) end
      return Fuzz.mutate(src, Fuzz.pick(src, MESSAGES), 6)
    end,
    check = function(input: string): boolean, string
      local message, why = wire.message(input)
      if message == nil then
        Fuzz.label("refused")
        if not said(why) or why.code == nil then
          return false, "a refusal with no reason or no JSON-RPC code"
        end
        return true, ""
      end
      Fuzz.label("accepted")
      local id = message.id
      if id ~= nil then
        -- The id is the JSON of a string or an integer, so a reply can name it.
        local back, _ = Json.decode(id)
        if not (back is string or math.type(back) == "integer") then
          return false, "an id that is not a string or an integer"
        end
      end
      return true, ""
    end,
  })
end

local function test_decoders_are_total(tmp: string)
  local decoders: {function(any): boolean} = {
    function(v: any): boolean
      local r, w = wire.tools(v)
      return r ~= nil or said(w)
    end,
    function(v: any): boolean
      local r, w = wire.tool_result_of(v)
      return r ~= nil or said(w)
    end,
    function(v: any): boolean
      local r, w = wire.read(v)
      return r ~= nil or said(w)
    end,
    function(v: any): boolean
      local r, w = wire.prompt_result_of(v)
      return r ~= nil or said(w)
    end,
    function(v: any): boolean
      local r, w = wire.discovery(v)
      return r ~= nil or said(w)
    end,
    function(v: any): boolean
      local r, w = wire.needs_of(v)
      return r ~= nil or said(w)
    end,
    function(v: any): boolean
      local r, w = wire.elicited_of(v)
      return r ~= nil or said(w)
    end,
    function(v: any): boolean
      local r, w = wire.resources(v)
      return r ~= nil or said(w)
    end,
    function(v: any): boolean
      local r, w = wire.prompts(v)
      return r ~= nil or said(w)
    end,
    function(v: any): boolean
      local r, w = wire.completion_of(v)
      if r ~= nil and #r.values > Mcp.MAX_COMPLETIONS then return false end
      return r ~= nil or said(w)
    end,
    function(v: any): boolean
      local r, w = wire.completing_of(v)
      if r ~= nil and (r.prompt == nil) == (r.template == nil) then return false end
      return r ~= nil or w ~= ""
    end,
  }
  Fuzz.run({
    name = "decode a changed result",
    dir = tmp,
    requires = { "json" },
    gen = function(src: Fuzz.Source): string
      return Fuzz.mutate(src, Fuzz.pick(src, RESULTS), 6)
    end,
    check = function(input: string): boolean, string
      local decoded, _ = Json.decode(input)
      if decoded == nil then return true, "" end
      Fuzz.label("json")
      for i, decode in ipairs(decoders) do
        if not decode(decoded) then
          return false, "decoder " .. tostring(i) .. " refused with no reason"
        end
      end
      local object = Json.object_of(decoded)
      if object ~= nil then
        local e, why = wire.elicitation_of(object)
        if e == nil and not said(why) then return false, "elicitation_of refused with no reason" end
        if e ~= nil and e.url ~= nil and assert(e.url):find("^https?://") == nil then
          return false, "elicitation_of took a url that is not http or https"
        end
      end
      return true, ""
    end,
  })
end

--- The events the splitter gives for `text` fed in pieces of the sizes `cuts` cycles through, and then its end; a
--- piece of size 0 is an empty chunk.
local function split(text: string, cuts: {integer}): {string}?
  local splitter = wire.splitter()
  local out: mut {string} = {}
  local at, i = 1, 1
  while at <= #text do
    local size = assert(cuts[(i - 1) % #cuts + 1])
    local chunk = text:sub(at, at + size - 1)
    if chunk:sub(-1) == "\r" and at + size <= #text then Fuzz.label("CR ends a chunk") end
    local got = splitter.feed(chunk)
    if got == nil then return nil end
    for _, each in ipairs(got) do out[#out + 1] = each end
    at = at + size
    i = i + 1
    -- Only empty chunks: give the rest in one piece.
    if i > #cuts * 2 and at == 1 then cuts = { #text } end
  end
  local last = splitter.finish()
  if #last > 0 then Fuzz.label("the end completes an event") end
  for _, each in ipairs(last) do out[#out + 1] = each end
  return out
end

--- What [`wire.events`] and the splitter read of streams whose events are known.
local function test_events_are_read_as_the_format_has_them()
  local function same(a: {string}, b: {string}): boolean
    if #a ~= #b then return false end
    for i, each in ipairs(a) do
      if b[i] ~= each then return false end
    end
    return true
  end
  local record Case
    text: string
    events: {string}
  end
  local cases: {Case} = {
    { text = "data: a\r\r", events = { "a" } },
    { text = "data: a\r\n\r\n", events = { "a" } },
    { text = "data: a\n\n", events = { "a" } },
    { text = "data:x\n\n", events = { "x" } },
    { text = "data:  x\n\n", events = { " x" } },
    { text = "data\n\n", events = { "" } },
    { text = ": a comment\ndata: a\n\n", events = { "a" } },
    { text = "data: a\n\ndata: cut off", events = { "a" } },
    { text = "data: one\ndata: two\n\n", events = { "one\ntwo" } },
    { text = "event: x\nid: 1\n\n", events = {} },
    { text = "\n\n\n", events = {} },
    { text = "\239\187\191data: bom\n\n", events = { "bom" } },
    { text = "\239\187data: no\n\n", events = {} },
    { text = "data: a\n\n\239\187\191data: b\n\n", events = { "a" } },
  }
  for _, case in ipairs(cases) do
    local text, want = case.text, case.events
    assert(same(wire.events(text), want), text)
    for size = 1, #text do
      local got = assert(split(text, { size }), text)
      assert(same(got, want), text .. " cut every " .. tostring(size))
    end
  end
  -- The end, given twice or with nothing before it, gives no event again.
  local splitter = wire.splitter()
  assert(#assert(splitter.feed("data: a\r")) == 0)
  assert(#assert(splitter.feed("\r")) == 0)
  assert(same(splitter.finish(), { "a" }))
  assert(#splitter.finish() == 0)
  assert(#wire.splitter().finish() == 0)
end

--- An event as long as a message may be is read; one byte more held is refused, and the end never is.
local function test_the_splitter_holds_no_more_than_a_message()
  local MAX <const> = Mcp.MAX_MESSAGE_BYTES
  local whole = "data: " .. string.rep("a", MAX - 7) .. "\n"
  assert(#whole == MAX)
  local splitter = wire.splitter()
  for at = 1, #whole, 65536 do assert(splitter.feed(whole:sub(at, at + 65535))) end
  local got = assert(splitter.feed("\n"))
  assert(#got == 1 and #assert(got[1]) == MAX - 7)
  local over = wire.splitter()
  assert(over.feed(whole) ~= nil)
  assert(over.feed("a") == nil, "one byte more than a message is refused")
  -- Held to the limit, a CR at the end, and then the end: not refused, and nothing whole to give.
  local edge = wire.splitter()
  assert(edge.feed(whole:sub(1, -2) .. "a\r") ~= nil)
  assert(#edge.finish() == 0)
end

local function test_a_stream_splits_alike_however_it_is_cut(tmp: string)
  Fuzz.run({
    name = "split a changed event stream",
    dir = tmp,
    requires = { "events", "CR ends a chunk", "the end completes an event" },
    gen = function(src: Fuzz.Source): string
      local cuts: mut {string} = {}
      for _ = 1, src:int(1, 4) do
        cuts[#cuts + 1] = tostring(if src:int(0, 9) == 0 then src:int(10, 200) else src:int(0, 9) end)
      end
      return Fuzz.pack({ Fuzz.mutate(src, Fuzz.pick(src, STREAMS), 8), table.concat(cuts, ",") })
    end,
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local text, spec = fields[1] or "", fields[2] or "1"
      local cuts: mut {integer} = {}
      for n in spec:gmatch("%d+") do
        cuts[#cuts + 1] = math.max(0, math.tointeger(tonumber(n)) or 0)
      end
      if #cuts == 0 then cuts[1] = 1 end
      local whole = wire.events(text)
      local pieces = split(text, cuts)
      if pieces == nil then return false, "the splitter refused a stream shorter than a message" end
      if #whole > 0 then Fuzz.label("events") end
      if #pieces ~= #whole then
        return false, "cut, the stream gave " .. tostring(#pieces) .. " events; whole, " .. tostring(#whole)
      end
      for i, each in ipairs(whole) do
        if pieces[i] ~= each then
          return false, "event " .. tostring(i) .. " differs when the stream is cut"
        end
      end
      return true, ""
    end,
  })
end

local function test_a_challenge_is_read_and_reading_is_total(tmp: string)
  local clean = assert(wire.challenge(CHALLENGE))
  assert(clean.error == "insufficient_scope" and clean.resource_metadata ==
      "https://mcp.example.com/.well-known/oauth-protected-resource/mcp")
  local scope = assert(clean.scope)
  assert(#scope == 2 and scope[1] == "files:read" and scope[2] == "files:write")
  -- The word inside another scheme's value is not the scheme, a comma in it included.
  assert(wire.challenge('Basic realm="bearer x"') == nil)
  assert(wire.challenge('Basic realm="a, bearer x"') == nil)
  assert(wire.challenge('Basic realm="x", Bearer error="invalid_token"') ~= nil)
  -- A Bearer challenge with nothing more is one, and a token68 before it is passed over.
  local bare = assert(wire.challenge("Bearer"))
  assert(bare.error == nil and bare.scope == nil and bare.resource_metadata == nil)
  assert(assert(wire.challenge("Negotiate abc==, Bearer error=invalid_token")).error == "invalid_token")
  -- Another scheme's parameters are its own.
  local first = assert(wire.challenge('Bearer error="invalid_token", Basic realm="r", scope="evil"'))
  assert(first.error == "invalid_token" and first.scope == nil)
  -- A token68 may hold a `/`: what follows it is not a scheme.
  assert(wire.challenge("Negotiate a/Bearer") == nil)
  assert(wire.challenge('Negotiate a/Bearer, scope="evil"') == nil)
  assert(assert(assert(wire.challenge('Negotiate a/Bearer+c=, Bearer scope="good"')).scope)[1] == "good")
  -- A quoted string where no parameter stands is passed over whole.
  assert(wire.challenge('Foo "Bearer scope=x"') == nil)
  -- An escaped quote is the value's.
  assert(assert(wire.challenge('bearer error="a\\"b,c"')).error == 'a"b,c')
  Fuzz.run({
    name = "read a changed challenge",
    dir = tmp,
    requires = { "bearer" },
    gen = function(src: Fuzz.Source): string
      return Fuzz.mutate(src, CHALLENGE, 6)
    end,
    check = function(input: string): boolean, string
      local got = wire.challenge(input)
      if got ~= nil then Fuzz.label("bearer") end
      if got ~= nil and input:lower():find("bearer", 1, true) == nil then
        return false, "a challenge read from a header with no Bearer"
      end
      return true, ""
    end,
  })
  -- A header made of known parameters, among other schemes, reads back as made.
  local NAMES <const>: {string} = { "resource_metadata", "scope", "error", "realm", "error_description" }
  local KEYS <const>: {string} = { "resource_metadata", "scope", "error" }
  Fuzz.run({
    name = "read a made challenge",
    dir = tmp,
    requires = { "quoted", "token", "another scheme first", "another scheme after" },
    gen = function(src: Fuzz.Source): string
      local parts: mut {string} = {}
      local want: mut {string: string} = {}
      if src:int(0, 2) == 0 then
        parts[#parts + 1] = Fuzz.pick(src, { 'Basic realm="a, bearer b=c"', "Negotiate abc==", "Negotiate ab/Bearer+c=",
          "Digest nonce=x, qop=auth" })
      end
      local params: mut {string} = {}
      for _ = 1, src:int(0, 5) do
        local name = Fuzz.pick(src, NAMES)
        local value = Fuzz.bytes(src, 24)
        local text: string
        if value:find("^[%w%-._~+/:]+$") ~= nil and src:int(0, 1) == 0 then
          text = value
        else
          local escaped = value:gsub('[\\"]', "\\%0")
          text = '"' .. escaped .. '"'
        end
        params[#params + 1] = (if src:int(0, 1) == 0 then name:upper() else name end) .. Fuzz.pick(src, { "=", " = " }) .. text
        if want[name] == nil then want[name] = value end
      end
      local bearer = Fuzz.pick(src, { "Bearer", "bearer", "BEARER" })
      parts[#parts + 1] = if #params > 0 then bearer .. " " .. table.concat(params, ", ") else bearer end
      if src:int(0, 2) == 0 then parts[#parts + 1] = 'Basic realm="r", scope="evil", error=evil' end
      local fields: mut {string} = { table.concat(parts, ", ") }
      for _, key in ipairs(KEYS) do
        local value = want[key]
        fields[#fields + 1] = if value ~= nil then "1" .. value else "0" end
      end
      return Fuzz.pack(fields)
    end,
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local header = fields[1] or ""
      if header:find('"', 1, true) ~= nil then Fuzz.label("quoted") end
      if header:find("=[^\" ]", 1) ~= nil then Fuzz.label("token") end
      if header:find("^Basic") ~= nil or header:find("^Negotiate") ~= nil or header:find("^Digest") ~= nil then
        Fuzz.label("another scheme first")
      end
      if header:find("scope=\"evil\"", 1, true) ~= nil then Fuzz.label("another scheme after") end
      local got = wire.challenge(header)
      if got == nil then return false, "no challenge read from a Bearer header" end
      local read_as: mut {string: string} = {}
      local metadata, error_code = got.resource_metadata, got.error
      if metadata ~= nil then read_as["resource_metadata"] = metadata end
      if error_code ~= nil then read_as["error"] = error_code end
      for i, key in ipairs(KEYS) do
        local field = fields[i + 1] or "0"
        local want: string? = if field:sub(1, 1) == "1" then field:sub(2) else nil end
        if key == "scope" then
          local words: mut {string} = {}
          for each in (want or ""):gmatch("%S+") do words[#words + 1] = each end
          local listed = got.scope
          if (want == nil) ~= (listed == nil) then
            return false, "scope read where none was given, or not read"
          end
          if listed ~= nil then
            if #listed ~= #words then
              return false, "scope read as " .. tostring(#listed) .. " words"
            end
            for j, each in ipairs(words) do
              if listed[j] ~= each then return false, "scope word " .. tostring(j) .. " differs" end
            end
          end
        elseif read_as[key] ~= want then
          return false, key .. " read as " .. tostring(read_as[key]) .. ", made as " .. tostring(want)
        end
      end
      return true, ""
    end,
  })
end

local function test_a_server_answers_any_text(tmp: string)
  local server = Server.new{ info = { name = "fuzzed", version = "1" }, tools = {
    {
      tool = { name = "echo", inputSchema = Mcp.object_schema({ text = { type = "string" } }) },
      call = function(args: {string: Json.Value}, _: Server.Call): (Mcp.ToolResult) | (nil, Failure)
        return Mcp.result({ tostring(args["text"]) })
      end,
    },
  } }
  Fuzz.run({
    name = "answer a changed request",
    dir = tmp,
    requires = { "answered", "notified" },
    gen = function(src: Fuzz.Source): string
      return Fuzz.mutate(src, Fuzz.pick(src, MESSAGES), 6)
    end,
    check = function(input: string): boolean, string
      local answer = server:answer(input)
      local body = answer.body
      local asked, _ = wire.message(input)
      if asked ~= nil and asked.method ~= nil and asked.id == nil then
        Fuzz.label("notified")
        if body ~= nil then return false, "the server answered a notification" end
      end
      if body == nil then return true, "" end
      Fuzz.label("answered")
      local message, why = wire.message(body)
      if message == nil then
        return false, "the server answered what is not a message: " .. tostring(why)
      end
      if message.method ~= nil then return false, "the server answered a request with a request" end
      if (message.error == nil) == (message.result == nil) then
        return false, "an answer with both or neither of result and error"
      end
      -- A reply to a request names it; one to what is not a message names none.
      if asked == nil and message.id ~= nil then
        return false, "the answer to what is not a message names " .. tostring(message.id)
      end
      if asked ~= nil and asked.method ~= nil and asked.id ~= nil and message.id ~= asked.id then
        return false, "the answer names " .. tostring(message.id) .. ", the request " .. tostring(asked.id)
      end
      return true, ""
    end,
  })
end

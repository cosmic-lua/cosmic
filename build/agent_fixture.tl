--- What the tests of [`cosmic.agent`] share (cosmic/agent/*_test.tl): a
--- Messages API that streams set replies and keeps each request, a
--- signer, and a session kept in a database of its own. Test support.

local Agent = require("cosmic.agent")
local Auth = require("cosmic.agent.auth")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Http = require("cosmic.http")
local Json = require("cosmic.json")
local Sessions = require("cosmic.agent.sessions")
local Sqlite = require("cosmic.sqlite")
local Tools = require("cosmic.agent.tools")

local record agent_fixture
  --- A Messages API that replies with each of `replies` in turn, keeping each request.
  record Api
    replies: {string}
    sent: mut {{string: Json.Value}}
    bodies: mut {string}
    headers: mut {{string: string}}
    --- Sends a request to it, as an agent's `send`.
    send: Agent.Send
  end
  --- What the model said and the tools it called, in order.
  record Seen
    texts: mut {string}
    tools: mut {string}
    --- What notes them, to set as an agent's `on`.
    on: function(event: Agent.Event)
  end
  --- A tool of the tests, for the model: it answers its `text`, the last 10000 bytes of it where it is longer with
  --- the whole as `raw`, as a tool that cuts its output does; with `wait` true it first waits until the turn is stopped
  --- or its time runs out, as a call that runs past them is ended.
  SAY: Tools.Tool
  --- A session kept in a database of its own, and the API it sends to.
  record Kept
    session: Agent.Session
    api: Api
    db: Sqlite.Handle
  end
end

local type Api = agent_fixture.Api
local type Seen = agent_fixture.Seen

local NONE <const>: {string: Json.Value} = {}

--- Signs with the API key `key`.
function agent_fixture.keyed(key: string): Auth.Sign
  return (assert(Auth.from(function(name: string): string?
    if name == "ANTHROPIC_API_KEY" then return key end
    return nil
  end, "https://api.test")))
end

--- The text of the file at `path`, or "" where there is none.
function agent_fixture.slurp(path: string): string
  local text, _ = Fs.read(path)
  return text or ""
end

--- A fresh directory of its own.
function agent_fixture.scratch(): string
  return (assert(Fs.mkdtemp("agent-test-")))
end

--- Runs the tool `name` on `input` in `cwd`, unsandboxed.
function agent_fixture.run(name: string, input: Json.Value, cwd: string): Tools.Result
  local given, _ = Json.to_object(input)
  return Tools.run(name, given or {}, { cwd = cwd })
end

--- `reply`, a message, as the API streams it: its events, in pieces
--- of 7 bytes, so an event is split across reads.
local function streamed(reply: string): function(): string?, string
  local m = assert(Json.decode_object(reply))
  local events: mut {Json.Value} = {}
  local usage: mut {string: Json.Value} = {}
  local given, _ = Json.to_object(m["usage"])
  for k, v in pairs(given or {}) do usage[k] = v end
  local out = usage["output_tokens"]
  usage["output_tokens"] = nil
  local start: mut {string: Json.Value} = { type = "message", role = "assistant", content = Json.array({}),
    usage = usage }
  for _, k in ipairs({ "model", "id", "diagnostics" }) do
    local v = m[k]
    if v ~= nil then start[k] = v end
  end
  events[#events + 1] = { type = "message_start", message = start }
  local content, _ = Json.to_array(m["content"])
  for i, item in ipairs(content or {}) do
    local block = assert(Json.to_object(item))
    local index = i - 1
    local first: mut {string: Json.Value} = {}
    for k, v in pairs(block) do first[k] = v end
    local deltas: mut {Json.Value} = {}
    local kind = block["type"]
    if kind == "text" then
      first["text"] = ""
      local text = block["text"]
      if text is string then
        deltas[#deltas + 1] = { type = "text_delta", text = text:sub(1, 2) }
        deltas[#deltas + 1] = { type = "text_delta", text = text:sub(3) }
      end
    elseif kind == "tool_use" then
      first["input"] = NONE
      local input = block["input"]
      local json = assert(Json.encode(if input == nil then NONE else input end))
      deltas[#deltas + 1] = { type = "input_json_delta", partial_json = json:sub(1, 3) }
      deltas[#deltas + 1] = { type = "input_json_delta", partial_json = json:sub(4) }
    elseif kind == "compaction" then
      first["content"] = Json.null
      local summary = block["content"]
      if summary is string then
        deltas[#deltas + 1] = { type = "compaction_delta", content = summary }
      end
    elseif kind == "thinking" then
      first["thinking"], first["signature"] = "", ""
      local thought, signature = block["thinking"], block["signature"]
      assert(thought ~= nil and signature ~= nil)
      deltas[#deltas + 1] = { type = "thinking_delta", thinking = thought }
      deltas[#deltas + 1] = { type = "signature_delta", signature = signature }
    end
    events[#events + 1] = { type = "content_block_start", index = index, content_block = first }
    for _, d in ipairs(deltas) do
      events[#events + 1] = { type = "content_block_delta", index = index, delta = d }
    end
    events[#events + 1] = { type = "content_block_stop", index = index }
  end
  local delta: mut {string: Json.Value} = {}
  local stop = m["stop_reason"]
  if stop ~= nil then delta["stop_reason"] = stop end
  events[#events + 1] = { type = "message_delta", delta = delta, usage = { output_tokens = if out == nil then 0 else out end } }
  events[#events + 1] = { type = "message_stop" }
  local wire: mut {string} = {}
  for _, e in ipairs(events) do
    local name = assert(Json.to_object(e))["type"]
    wire[#wire + 1] = "event: " .. tostring(name) .. "\ndata: " .. assert(Json.encode(e)) .. "\n\n"
  end
  local text = table.concat(wire)
  local at = 1
  return function(): string?, string
    if at > #text then return nil, "" end
    local piece = text:sub(at, at + 6)
    at = at + 7
    return piece, ""
  end
end

--- The API, which replies to each request with the next of `replies`: a
--- message, streamed, or a string not JSON, sent whole with status 500.
function agent_fixture.api(replies: {Json.Value}): Api
  local texts: mut {string} = {}
  for _, r in ipairs(replies) do
    local text = if r is string then r else assert(Json.encode(r)) end
    texts[#texts + 1] = text
  end
  local sent: mut {{string: Json.Value}} = {}
  local bodies: mut {string} = {}
  local headers: mut {{string: string}} = {}
  local function send(url: string, opts: Http.Options): Agent.Reply?, string
    assert(opts.method == "POST" and url == "https://api.test/v1/messages", url)
    local body = assert(Json.decode_object(opts.body or ""))
    sent[#sent + 1] = body
    bodies[#bodies + 1] = opts.body or ""
    headers[#headers + 1] = opts.headers or {}
    local reply = texts[#sent]
    if reply == nil then return nil, "no more replies" end
    if reply:sub(1, 1) ~= "{" then
      local whole: string? = reply
      -- "400 ..." is sent with status 400, anything else with 500.
      local status = if reply:sub(1, 4) == "400 " then 400 else 500 end
      return { status = status, headers = {}, close = function() end, read = function(): string?, string
        local piece = whole
        whole = nil
        return piece, ""
      end }, ""
    end
    local h: {string: string} = { ["request-id"] = "req_1", ["anthropic-ratelimit-tokens-remaining"] = "9",
      ["server"] = "x", ["set-cookie"] = "c" }
    -- A request not streamed (a warm one) gets the reply whole.
    if body["stream"] == false then
      local whole: string? = reply
      return { status = 200, headers = h, close = function() end, read = function(): string?, string
        local piece = whole
        whole = nil
        return piece, ""
      end }, ""
    end
    return { status = 200, headers = h, read = streamed(reply), close = function() end }, ""
  end
  return { replies = texts, sent = sent, bodies = bodies, headers = headers, send = send }
end

--- The `i`th request `a` was sent, as the text sent.
function agent_fixture.said_whole(a: Api, i: integer): string
  return (assert(a.bodies[i], "no request " .. tostring(i)))
end

--- The `i`th request `a` was sent.
function agent_fixture.sent(a: Api, i: integer): {string: Json.Value}
  return (assert(a.sent[i], "no request " .. tostring(i)))
end

--- The messages of that request, as JSON text.
function agent_fixture.said(a: Api, i: integer): string
  local m = agent_fixture.sent(a, i)["messages"]
  assert(m ~= nil)
  return (assert(Json.encode(m)))
end

--- The headers of that request.
function agent_fixture.header(a: Api, i: integer): {string: string}
  return (assert(a.headers[i]))
end

--- A reply of one text block, stopped for `stop` (end_turn).
function agent_fixture.text_reply(text: string, stop?: string): Json.Value
  return { content = { { type = "text", text = text } }, stop_reason = stop or "end_turn" }
end

--- Events that note what the model says and the tools it calls.
function agent_fixture.events(): Seen
  local texts: mut {string} = {}
  local tools: mut {string} = {}
  return { texts = texts, tools = tools, on = function(e: Agent.Event)
    if e.kind == "text" then
      texts[#texts + 1] = e.text
    elseif e.kind == "tool" then
      tools[#tools + 1] = e.name
    end
  end }
end

-- The most bytes SAY answers.
local SAID <const> = 10000

agent_fixture.SAY = {
  name = "say", snippet = "Say a text", guidelines = {}, description = "Answers its text.",
  schema = { type = "object", properties = { text = { type = "string" }, wait = { type = "boolean" } } },
  run = function(input: Tools.Object, context: Tools.Context): Tools.Result
    if input["wait"] == true then
      local stopped = context.stopped
      while not (stopped ~= nil and stopped()) do
        local deadline = context.deadline_ns
        if deadline ~= nil and Clock.monotonic_ns() >= deadline then
          return { text = "(no output)\n\nTimed out", is_error = true }
        end
        local _, _ = Clock.sleep(Clock.ms(10))
      end
      return { text = "Stopped", is_error = true }
    end
    local text = input["text"]
    local said = if text is string then text else "" end
    if #said <= SAID then return { text = said, is_error = false } end
    return { text = said:sub(#said - SAID + 1), is_error = false, raw = said }
  end,
}

--- A tool call `id` of [`agent_fixture.SAY`], answering `text`, or waiting first where `wait` is true.
function agent_fixture.say_call(id: string, text: string, wait?: boolean): Json.Value
  return { type = "tool_use", id = id, name = "say", input = { text = text, wait = wait == true } }
end

--- A session kept in a database of its own, sending `replies`.
function agent_fixture.kept(replies: {Json.Value}, messages?: {Json.Value}, model?: string): agent_fixture.Kept
  local db = assert(Sessions.open(agent_fixture.scratch() .. "/sessions.db"))
  local a = agent_fixture.api(replies)
  local s = Agent.new({ model = model or "m", effort = "low", sign = agent_fixture.keyed("k"),
    base_url = "https://api.test", system = "", cwd = "/", send = a.send, messages = messages,
    tools = { Tools.find(Tools.all(), "run")!, agent_fixture.SAY },
    db = db, id = assert(Sessions.start(db, "/", "m", 0)) })
  for _, m in ipairs(messages or {}) do assert(Sessions.add(db, assert(s.id), m, "m")) end
  return { session = s, api = a, db = db }
end

return agent_fixture

--- The agent loop against a stand-in Messages API: the requests it
--- sends, why it stops, what it keeps of each request, and a turn left
--- unfinished taken up again.

local Agent = require("cosmic.agent")
local agent_fixture = require("build.agent_fixture")
local Auth = require("cosmic.agent.auth")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Http = require("cosmic.http")
local Json = require("cosmic.json")
local Sandbox = require("cosmic.sandbox")
local Sessions = require("cosmic.agent.sessions")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")

Test.policy{ env = { "TMPDIR" }, grants = { { path = "/bin/sh", letters = "r" } } }

local keyed = agent_fixture.keyed
local slurp = agent_fixture.slurp
local scratch = agent_fixture.scratch
-- How often a turn is started again.
local RESTARTS <const> = 5

local function api(replies: {Json.Value}): Api, Agent.Send
  local a = agent_fixture.api(replies)
  return a, a.send
end
local said_whole = agent_fixture.said_whole
local sent = agent_fixture.sent
local said = agent_fixture.said
local header = agent_fixture.header
local text_reply = agent_fixture.text_reply
local bash_call = agent_fixture.bash_call
local function kept(replies: {Json.Value}, messages?: {Json.Value}, model?: string): Agent.Session, Api,
                    Sqlite.Handle
  local k = agent_fixture.kept(replies, messages, model)
  return k.session, k.api, k.db
end
local type Api = agent_fixture.Api

local function test_the_loop_runs_tools_until_the_turn_ends()
  local dir = scratch()
  local a, send = api({
    { content = {
      { type = "thinking", thinking = "", signature = "sig" },
      { type = "text", text = "writing" },
      { type = "tool_use", id = "t1", name = "write", input = { path = "out.txt", content = "made" } },
    }, stop_reason = "tool_use" },
    text_reply("done"),
  })
  local s = Agent.new({ model = Agent.MODELS.opus, effort = "high", sign = keyed("k"), base_url = "https://api.test",
    system = "sys", cwd = dir, send = send })
  local seen = agent_fixture.events()
  s.on = seen.on
  local ok, why = s:prompt("make out.txt")
  assert(ok, why)
  assert(slurp(dir .. "/out.txt") == "made")
  assert(#a.sent == 2 and seen.texts[1] == "writing" and seen.texts[2] == "done" and seen.tools[1] == "write")
  local first = sent(a, 1)
  assert(first["model"] == "claude-opus-5-5" and first["fallbacks"] == "default")
  -- The system prompt is a block with a cache mark of its own, and the working directory a block after it.
  local whole = assert(Json.encode(first))
  assert(whole:find('"system":[{"cache_control":{"type":"ephemeral"},"text":"sys","type":"text"},{"text":"<cwd>\\n' ..
      dir .. '\\n</cwd>","type":"text"}]', 1, true) ~= nil, whole)
  assert(whole:find('"content":"make out.txt"', 1, true) ~= nil, whole)
  -- The tools offered by default run no program: no bash, no jobs.
  local tools, _ = Json.to_array(first["tools"])
  assert(tools ~= nil and #tools == 5 and not assert(Json.encode(tools)):find('"name":"bash"', 1, true))
  local h = header(a, 1)
  assert(h["x-api-key"] == "k" and h["anthropic-version"] == "2026-10-21", h["x-api-key"])
  assert(h["anthropic-beta"] == "server-side-fallback-2026-07-01,cache-diagnosis-2026-04-07,compact-2026-01-12", h["anthropic-beta"])
  -- The first names no reply for its cache diagnosis; compaction is asked for.
  local whole_first = assert(Json.encode(first))
  assert(said_whole(a, 1):find('"diagnostics":{"previous_message_id":null}', 1, true) ~= nil, whole_first)
  assert(whole_first:find('"context_management":{"edits":[{"type":"compact_20260112"}]}', 1, true) ~= nil)
  -- The second request carries the reply as it came, and the result.
  local text = said(a, 2)
  assert(text:find('"signature":"sig"', 1, true) ~= nil, text)
  assert(text:find('"tool_result"', 1, true) ~= nil and text:find('"tool_use_id":"t1"', 1, true) ~= nil, text)
  assert(#s.messages == 4)
  -- A chat goes on from where it was.
  local b, send2 = api({ text_reply("again") })
  s.send = send2
  assert(s:prompt("more"))
  local again, _ = Json.to_array(sent(b, 1)["messages"])
  assert(again ~= nil and #again == 5)
end

--- The sandbox is a list of layers, held stacked: a write one layer lets and another does not is refused, and
--- layers that do not join block the call, naming why.
local function test_the_sandbox_layers_are_held_stacked()
  local dir = scratch()
  local write = function(id: string): Json.Value
    return { content = { { type = "tool_use", id = id, name = "write", input = { path = "out.txt", content = "made" } } },
      stop_reason = "tool_use" }
  end
  local _, send = api({ write("t1"), text_reply("done") })
  local writes: Sandbox.Policy = { grants = { { path = dir, letters = "rwc" } } }
  local reads: Sandbox.Policy = { grants = { { path = dir, letters = "r" } } }
  local s = Agent.new({ sign = keyed("k"), base_url = "https://api.test", system = "sys", cwd = dir, send = send,
    sandbox = { writes, reads } })
  local seen = agent_fixture.events()
  s.on = seen.on
  assert(s:prompt("make out.txt"))
  local none, _ = Fs.read(dir .. "/out.txt")
  assert(none == nil)
  local refused = assert(Json.encode(Json.array(s.messages)))
  assert(refused:find("does not let the agent write", 1, true) ~= nil, refused)
  -- One layer alone lets it.
  local _, send2 = api({ write("t2"), text_reply("done") })
  s.send, s.sandbox = send2, { writes }
  assert(s:prompt("again"))
  assert(slurp(dir .. "/out.txt") == "made")
  -- Layers that do not join hold nothing: the call is blocked.
  assert(Fs.remove(dir .. "/out.txt"))
  local _, send3 = api({ write("t3"), text_reply("done") })
  local mapped: Sandbox.Policy = { grants = { { path = dir, from = "/elsewhere", letters = "r" } } }
  s.send, s.sandbox = send3, { writes, mapped }
  assert(s:prompt("once more"))
  local blocked = assert(Json.encode(Json.array(s.messages)))
  assert(blocked:find("Blocked: the sandbox's layers do not join", 1, true) ~= nil, blocked)
  local still, _ = Fs.read(dir .. "/out.txt")
  assert(still == nil)
  -- No layer is no sandbox only as nil: an empty list blocks the call.
  local _, send4 = api({ write("t4"), text_reply("done") })
  s.send, s.sandbox = send4, {}
  assert(s:prompt("and again"))
  local empty = assert(Json.encode(Json.array(s.messages)))
  assert(empty:find("Blocked: the sandbox has no layer", 1, true) ~= nil, empty)
  local left, _ = Fs.read(dir .. "/out.txt")
  assert(left == nil)
end

local function test_the_loop_says_why_it_stops()
  local function once(replies: {Json.Value}, sign?: Auth.Sign): boolean, string, Api
    local a, send = api(replies)
    local s = Agent.new({ model = Agent.MODELS.sonnet, effort = "low", sign = sign or keyed("k"),
      base_url = "https://api.test", system = "", cwd = "/", send = send })
    local ok, why = s:prompt("hi")
    return ok, why, a
  end
  local ok, why = once({ text_reply("no", "refusal") })
  assert(not ok and why == "the model refused", why)
  ok, why = once({ text_reply("cut", "max_tokens") })
  assert(not ok and why:find("max_tokens") ~= nil, why)
  ok, why = once({ "overloaded" })
  assert(not ok and why == "HTTP 500: overloaded", why)
  ok, why = once({ { content = Json.array(), stop_reason = "end_turn" } })
  assert(ok, why)
  ok, why = once({})
  assert(not ok and why == "no more replies", why)
  local a: Api
  local token = assert(Auth.from(function(name: string): string?
    if name == "ANTHROPIC_AUTH_TOKEN" then return "tok" end
    return nil
  end, "https://api.test"))
  ok, why, a = once({ text_reply("hi") }, token)
  assert(ok, why)
  assert(header(a, 1)["authorization"] == "Bearer tok", header(a, 1)["authorization"])
  assert(header(a, 1)["anthropic-beta"] == "server-side-fallback-2026-07-01,cache-diagnosis-2026-04-07,compact-2026-01-12,oauth-2025-04-20")
  assert(sent(a, 1)["model"] == "claude-sonnet-5-5")
  local unsigned = Auth.from(function(_: string): string? return nil end, "https://api.test", nil)
  assert(unsigned == nil)
  local failing = function(): {string: string}?, string
    local _, refusal = Auth.from(function(_: string): string? return nil end, "https://api.test")
    return nil, refusal
  end
  ok, why = once({ text_reply("hi") }, failing)
  assert(not ok and why:find("no credential") ~= nil, why)
end

local function test_each_request_is_kept_with_its_usage_and_cost()
  local reply: Json.Value = { model = "claude-opus-5-5", id = "msg_1",
    diagnostics = { cache_miss_reason = { type = "system_changed", cache_missed_input_tokens = 10 } },
    content = { { type = "compaction", content = "what came before" }, { type = "text", text = "hi" } },
    stop_reason = "end_turn", usage = { input_tokens = 1000, output_tokens = 2000, cache_read_input_tokens = 100000,
      cache_creation_input_tokens = 3000, cache_creation = { ephemeral_5m_input_tokens = 2000,
        ephemeral_1h_input_tokens = 1000 } } }
  local s, a_kept, db = kept({ reply, "down" }, nil, "claude-opus-5-5")
  local seen: mut {Sessions.Request} = {}
  s.on = function(e: Agent.Event)
    if e.kind == "request" then seen[#seen + 1] = e.request end
  end
  assert(s:prompt("go"))
  assert(not s:prompt("again"))
  -- 1000 x $4 + 2000 x $20 + 100000 x $0.20 + 2000 x $5 + 1000 x $8, a million tokens each.
  local cost = (4000 + 40000 + 20000 + 10000 + 8000) / 1e6
  local first = assert(seen[1])
  assert(#seen == 2 and first.seq == 2 and math.abs(assert(first.cost) - cost) < 1e-12)
  local rows = assert(db:rows([[SELECT seq, served, stop_reason, context, cache_write_1h, status,
    (SELECT text FROM systems WHERE id = system), reply IS NOT NULL, error FROM requests ORDER BY id]]))
  local one, two = assert(rows[1]), assert(rows[2])
  assert(one:integer(1) == 2 and one:text(2) == "claude-opus-5-5" and one:text(3) == "end_turn")
  assert(one:integer(4) == 104000 and one:integer(5) == 1000 and one:integer(6) == 200 and one:text(7) == "")
  assert(one:integer(8) == 1 and one:is_null(9))
  assert(two:is_null(1) and two:integer(6) == 500 and two:text(9) == "HTTP 500: down")
  local headers = assert(db:rows("SELECT headers, request_id FROM requests WHERE status = 200"))
  assert(assert(headers[1]):text(1) == '{"anthropic-ratelimit-tokens-remaining":"9","request-id":"req_1","server":"x"}',
    assert(headers[1]):text(1))
  assert(assert(headers[1]):text(2) == "req_1")
  -- The next request names the reply for its cache diagnosis, and sends the
  -- compaction block back as it came; why the cache missed is a column.
  local again = said(a_kept, 2)
  local diagnosed = sent(a_kept, 2)["diagnostics"]
  assert(diagnosed ~= nil)
  local named = assert(Json.encode(diagnosed))
  assert(named == '{"previous_message_id":"msg_1"}', named)
  assert(again:find('{"content":"what came before","type":"compaction"}', 1, true) ~= nil, again)
  local missed = assert(assert(db:rows("SELECT cache_miss, cache_missed FROM requests ORDER BY id"))[1])
  assert(missed:text(1) == "system_changed" and missed:integer(2) == 10)
  -- A reply the API will not diagnose against: the request goes again naming none.
  local s2, a2 = kept({ "400 diagnostics.previous_message_id: not found", text_reply("ok") })
  s2.last_reply = "msg_gone"
  assert(s2:prompt("go"))
  assert(#a2.sent == 2 and said_whole(a2, 1):find('"previous_message_id":"msg_gone"', 1, true) ~= nil)
  assert(said_whole(a2, 2):find('"previous_message_id":null', 1, true) ~= nil, said_whole(a2, 2))
  -- The headers sent, less the key; and how soon the reply began.
  local asked = assert(db:rows("SELECT request_headers, first_ms, build FROM requests WHERE status = 200"))
  local sent_headers = assert(asked[1]):text(1)
  assert(sent_headers:find("anthropic-version", 1, true) ~= nil and sent_headers:find("x-api-key", 1, true) == nil and
      sent_headers:find('"k"', 1, true) == nil, sent_headers)
  assert(not assert(asked[1]):is_null(2))
  -- The whole body sent is its shape, its system prompt and the messages before its reply.
  local shapes = assert(db:rows([[SELECT count(DISTINCT shape), count(*), (SELECT count(*) FROM shapes),
    (SELECT body FROM shapes) FROM requests]]))
  local shaped = assert(shapes[1])
  assert(shaped:integer(1) == 1 and shaped:integer(2) == 2 and shaped:integer(3) == 1, shaped:text(4))
  local body = assert(Json.decode_object(shaped:text(4)))
  assert(body["model"] == "claude-opus-5-5" and body["tools"] ~= nil and body["messages"] == nil and
      body["system"] == nil, shaped:text(4))
  assert(Agent.cost("claude-sonnet-5-5", { output_tokens = 1000000 }) == 10)
  -- A fallback's reply is priced by the model that served it.
  assert(Agent.cost("claude-opus-5", { input_tokens = 1000000, cache_read_input_tokens = 1000000 }) == 5.5)
  assert(Agent.cost("another", { output_tokens = 1 }) == nil)
  -- After a fallback, each attempt at its own model's price.
  local fell: {string: Json.Value} = { input_tokens = 1000000, iterations = {
    { type = "message", model = "claude-opus-5-5", input_tokens = 1000000, output_tokens = 0 },
    { type = "fallback_message", model = "claude-sonnet-5-5", input_tokens = 1000000, output_tokens = 0 } } }
  assert(Agent.billed("claude-sonnet-5-5", fell) == 6, tostring(Agent.billed("claude-sonnet-5-5", fell)))
  assert(Agent.billed("claude-sonnet-5-5", { input_tokens = 1000000 }) == 2)
  local hour: {string: Json.Value} = { cache_creation = { ephemeral_1h_input_tokens = 1000000 }, iterations = {
    { type = "fallback_message", model = "claude-sonnet-5-5", cache_creation_input_tokens = 1000000 } } }
  assert(Agent.billed("claude-sonnet-5-5", hour) == 4, tostring(Agent.billed("claude-sonnet-5-5", hour)))
  assert(Agent.billed("claude-sonnet-5-5", { iterations = { { model = "another", output_tokens = 1 } } }) == nil)
  local systems = assert(db:rows("SELECT count(*) FROM systems"))
  assert(assert(systems[1]):integer(1) == 1)
end

--- A warm request sends the conversation as the last request did, asking
--- for no reply, unstreamed; it is kept as any request, and the next
--- names the turn's reply, not its own.
local function test_warm_sends_the_last_request_again_asking_for_nothing()
  local s, a, db = kept({ text_reply("hi") }, nil, "claude-sonnet-5-5")
  -- Nothing was sent yet: there is nothing to keep warm.
  assert(s:warm())
  assert(#a.sent == 0 and s.sent_ns == nil)
  assert(s:prompt("go"))
  local before = assert(s.sent_ns)
  local named = s.last_reply
  local bodies: mut {{string: Json.Value}} = {}
  local status, answer = 200, assert(Json.encode({ id = "msg_warm", model = "claude-sonnet-5-5", content = Json.array(),
    stop_reason = "max_tokens", usage = { input_tokens = 0, output_tokens = 0, cache_read_input_tokens = 1000000 } }))
  s.send = function(url: string, opts: Http.Options): Agent.Reply?, string
    assert(url == "https://api.test/v1/messages" and opts.method == "POST")
    local body = assert(Json.decode_object(opts.body or ""))
    bodies[#bodies + 1] = body
    local whole: string? = answer
    return { status = status, headers = { ["request-id"] = "req_w" }, close = function() end,
      read = function(): string?, string
        local piece = whole
        whole = nil
        return piece, ""
      end }, ""
  end
  local seen: mut {Sessions.Request} = {}
  s.on = function(e: Agent.Event)
    if e.kind == "request" then seen[#seen + 1] = e.request end
  end
  assert(s:warm())
  local w = assert(bodies[1])
  assert(w["max_tokens"] == 0 and w["stream"] == false and w["model"] == "claude-sonnet-5-5")
  -- The model's last reply is left out: the API takes no conversation that ends in it.
  local messages = assert(Json.to_array(w["messages"]))
  assert(#messages == 1 and #s.messages == 2)
  assert(assert(s.sent_ns) >= before and s.last_reply == named)
  local q = assert(seen[1])
  assert(q.max_tokens == 0 and q.stop_reason == "max_tokens" and q.cache_read == 1000000 and q.cost == 0.1)
  local rows = assert(db:rows("SELECT max_tokens, status, cost, (SELECT body FROM shapes WHERE id = shape) " ..
      "FROM requests ORDER BY id"))
  local row = assert(rows[2])
  assert(#rows == 2 and row:integer(1) == 0 and row:integer(2) == 200, row:text(4))
  assert(row:text(4):find('"max_tokens":0', 1, true) ~= nil and row:text(4):find('"stream":false', 1, true) ~= nil,
    row:text(4))
  -- The next request, after a resume too, names the turn's reply, not the warm one's.
  assert(Sessions.last_reply(db, assert(s.id)) == named)
  -- A refusal is said, and kept; no warm request follows it, as it would only repeat it.
  status, answer = 400, "stream cannot be true when max_tokens is 0"
  local ok, why = s:warm()
  assert(not ok and why == "HTTP 400: stream cannot be true when max_tokens is 0", why)
  assert(#assert(db:rows("SELECT id FROM requests")) == 3 and s.sent_ns == nil)
  assert(s:warm())
  assert(#bodies == 2)
end

--- A reply that compacts is not kept warm: the next request reads from
--- its compaction block on, which a warm request would not send.
local function test_a_compacting_reply_is_not_kept_warm()
  local s, a = kept({ { content = { { type = "compaction", content = "before" }, { type = "text", text = "hi" } },
    stop_reason = "end_turn" } })
  assert(s:prompt("go"))
  assert(s.sent_ns == nil and s:warm())
  assert(#a.sent == 1)
end

--- A turn's budget: the first limit reached ends it for good, the tool
--- calls of its last reply answered as stopped, and the next prompt gets
--- a budget of its own.
local function test_a_turn_ends_where_its_budget_is_spent()
  local function calling(id: string, n: integer): Json.Value
    return { content = { bash_call(id, "true") }, stop_reason = "tool_use",
      usage = { input_tokens = n, output_tokens = n, cache_read_input_tokens = n, cache_creation_input_tokens = n } }
  end
  -- turns: the reply of the last request asks for a tool, which is answered, not run.
  local s, a = kept({ calling("t1", 10), calling("t2", 10), text_reply("never") }, nil, "claude-sonnet-5-5")
  s.budget = { turns = 2 }
  local seen = agent_fixture.events()
  s.on = seen.on
  local ok, why = s:prompt("go")
  assert(not ok and why == Agent.BUDGET_SPENT .. ": 2 requests, of 2", why)
  assert(#a.sent == 2 and #seen.tools == 1 and not s:unfinished())
  local answered = s.messages[#s.messages]
  assert(answered ~= nil)
  local last = assert(Json.encode(answered))
  assert(last:find("Stopped: " .. Agent.BUDGET_SPENT .. ": 2 requests, of 2.", 1, true) ~= nil, last)
  -- tokens: input, output and the cache write, 30 a request; the cache read is not counted.
  s, a = kept({ calling("t1", 10), calling("t2", 10), text_reply("never") })
  s.budget = { tokens = 50 }
  ok, why = s:prompt("go")
  assert(not ok and why == Agent.BUDGET_SPENT .. ": 60 tokens, of 50" and #a.sent == 2, why)
  -- cost: at sonnet's prices, 1000000 output tokens are $10.
  s, a = kept({ { content = { bash_call("t1", "true") }, stop_reason = "tool_use",
    usage = { input_tokens = 0, output_tokens = 1000000 } }, text_reply("never") }, nil, "claude-sonnet-5-5")
  s.budget = { cost = 5 }
  ok, why = s:prompt("go")
  assert(not ok and why == Agent.BUDGET_SPENT .. ": $10.0000, of $5.0000" and #a.sent == 1, why)
  -- time: none left sends no request at all.
  s, a = kept({ text_reply("never") })
  s.budget = { seconds = 0 }
  ok, why = s:prompt("go")
  assert(not ok and why:find(Agent.BUDGET_SPENT .. ": ", 1, true) == 1 and why:find("of 0 s", 1, true) ~= nil, why)
  assert(#a.sent == 0)
  -- time: a command that runs past it is ended, and the turn ends with why.
  s, a = kept({ { content = { bash_call("t1", "while :; do :; done") }, stop_reason = "tool_use" }, text_reply("never") })
  s.budget = { seconds = 1 }
  local began = Clock.monotonic_ns()
  ok, why = s:prompt("go")
  assert(not ok and why:find(Agent.BUDGET_SPENT .. ": ", 1, true) == 1 and #a.sent == 1, why)
  assert(Clock.monotonic_ns() - began < Clock.seconds(10))
  -- A turn that ends inside its budget is a turn like any other; each prompt has its own.
  s, a = kept({ text_reply("one"), text_reply("two") })
  s.budget = { turns = 1 }
  assert(s:prompt("go") and s:prompt("again") and #a.sent == 2)
end

local function test_a_turn_left_unfinished_is_resumed()
  local asked: Json.Value = { role = "assistant", content = { bash_call("t1", "echo one"), bash_call("t2", "echo two") } }
  local s, a, db = kept({ text_reply("finished") }, { { role = "user", content = "go" }, asked })
  -- The first call ended and was kept; the second never did.
  assert(Sessions.output(db, assert(s.id), { tool = "bash", input = "{}", text = "one\n", is_error = false, call = "t1" }))
  assert(s:settle())
  local third = s.messages[3]
  assert(third ~= nil)
  local answers = assert(Json.encode(third))
  assert(answers:find('"content":"one\\n"', 1, true) ~= nil, answers)
  assert(answers:find("Interrupted", 1, true) ~= nil, answers)
  assert(s:unfinished())
  local seen = agent_fixture.events()
  s.on = seen.on
  assert(s:resume())
  assert(#a.sent == 1 and seen.texts[1] == "finished" and not s:unfinished())
  local ok, why = s:resume()
  assert(not ok and why == "no unfinished turn", why)
  -- A turn is started again at most RESTARTS times.
  s, a, db = kept({ "down", "down", "down", "down", "down", "down" }, { { role = "user", content = "go" } })
  for _ = 1, RESTARTS do assert(not s:resume()) end
  ok, why = s:resume()
  assert(not ok and why:find("5 times", 1, true) ~= nil and #a.sent == RESTARTS, why)
  local loaded = assert(Sessions.load(db, assert(s.id)))
  assert(loaded.restarts == RESTARTS and not loaded.ended)
  -- A turn the model ended, empty or refused, is not taken up again.
  s = kept({ { content = Json.array(), stop_reason = "end_turn" }, text_reply("no", "refusal") })
  assert(s:prompt("go") and not s:unfinished())
  assert(not s:prompt("again") and not s:unfinished())
  ok, why = s:prompt("  ")
  assert(not ok and why == "the prompt is blank", why)
  s, a, db = kept({ "down", "down", "down", "down", "down", "down" }, { { role = "user", content = "go" } })
  for _ = 1, RESTARTS do assert(not s:resume()) end
  -- A new prompt starts the count again.
  local _, fine = api({ text_reply("fine") })
  s.send = fine
  assert(s:prompt("again") and s.restarts == 0)
end

--- Server-sent events on the wire: the formatting, a stream with its
--- heartbeats, a hub's fan-out and replay, a slow subscriber, the stop,
--- and the stream budget.

local Channel = require("cosmic.channel")
local Clock = require("cosmic.clock")
local Html = require("cosmic.html")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Sse = require("cosmic.web.sse")
local Test = require("cosmic.test")
local Web = require("cosmic.web")

Test.policy{ loopback = { "127.0.0.1" } }

--- How long the test client waits for anything.
local WAIT_NS <const> = Clock.seconds(3)

--- A heartbeat short enough to see within a test.
local BEAT_NS <const> = Clock.ms(40)

--- The message of the error `fn` raises; fails where it raises none.
local function raised(fn: function()): string
  local ok, err = pcall(function(): any
    fn()
    return nil
  end)
  assert(not ok, "expected a raise")
  return tostring(err)
end

--- An open stream: a connection past the head of the reply, and its chunks.
local record Feed
  conn: Net.Conn
  buf: string
  status: integer
  headers: {string:string}
  ended: boolean
end

local function fill(feed: Feed)
  local piece, why = feed.conn:read()
  assert(piece ~= nil, "reading the stream: " .. why)
  feed.buf = feed.buf .. piece
end

--- The next line of the reply, without its CRLF.
local function line(feed: Feed): string
  while true do
    local at = feed.buf:find("\r\n", 1, true)
    if at ~= nil then
      local found = feed.buf:sub(1, at - 1)
      feed.buf = feed.buf:sub(at + 2)
      return found
    end
    fill(feed)
  end
end

--- Sends a GET to `host` (`ip:port`) and reads the head of the reply.
local function open(host: string, path: string, headers?: {string:string}): Feed
  local ip, port = host:match("^(.-):(%d+)$")
  local conn = assert(Net.connect(Net.tcp(ip, math.tointeger(tonumber(port))), { timeout_ns = WAIT_NS }))
  conn:set_timeout(WAIT_NS)
  local lines = { "GET " .. path .. " HTTP/1.1", "Host: " .. host }
  for name, value in pairs(headers or {}) do lines[#lines + 1] = name .. ": " .. value end
  assert(conn:write(table.concat(lines, "\r\n") .. "\r\n\r\n"))
  local feed: Feed = { conn = conn, buf = "", status = 0, headers = {}, ended = false }
  feed.status = math.tointeger(tonumber(line(feed):match("^HTTP/1%.1 (%d+)"))) or 0
  while true do
    local header = line(feed)
    if header == "" then break end
    local name, value = header:match("^([^:]+):%s*(.*)$")
    feed.headers[name:lower()] = value
  end
  return feed
end

--- The next chunk of the body; nil once the last chunk has come.
local function chunk(feed: Feed): string | nil
  if feed.ended then return nil end
  local size = assert(tonumber(line(feed), 16))
  if size == 0 then
    feed.ended = true
    return nil
  end
  while #feed.buf < size + 2 do fill(feed) end
  local data = feed.buf:sub(1, size)
  feed.buf = feed.buf:sub(size + 3)
  return data
end

--- Waits until `done` is true, for at most `WAIT_NS`.
local function until_true(done: function(): boolean): boolean
  local deadline = Clock.monotonic_ns() + WAIT_NS
  while not done() do
    if Clock.monotonic_ns() > deadline then return false end
    assert(Poll.delay(Clock.ms(5)))
  end
  return true
end

--- An app whose `/events/:topic` streams a hub's topic, resuming after the
--- client's Last-Event-ID.
local function hub_app(hub: Sse.Hub, opts?: Sse.EventStreamOptions, spec?: Web.AppSpec): Web.App
  local given: Sse.EventStreamOptions = opts or { heartbeat_ns = BEAT_NS, retry_ms = 100 }
  local app_spec: Web.AppSpec = spec or {}
  app_spec.routes = { Web.get("/events/:topic", function(req: Web.Request): Web.Response
    local sub, why = hub:subscribe({ req.params.topic }, { after = Sse.last_event_id(req) })
    if sub == nil then
      return Web.text(why, { status = 503, headers = { ["Retry-After"] = "5" } })
    end
    return Sse.EventStream(req, sub, given)
  end) }
  return Web.app(app_spec)
end

local function test_format_event_splits_data_on_every_line_ending()
  assert(Sse.format_event({ data = "a\nb\r\nc\rd" }) == "data: a\ndata: b\ndata: c\ndata: d\n\n")
  assert(Sse.format_event({ data = "a\n" }) == "data: a\ndata: \n\n", "a trailing newline keeps its empty line")
  assert(Sse.format_event({ data = "" }) == "data: \n\n")
  assert(Sse.format_event({ data = "x\n\nevent: evil" }) == "data: x\ndata: \ndata: event: evil\n\n")
end

local function test_format_event_writes_each_field_once_and_a_comment_alone()
  assert(Sse.format_event({ id = "7", event = "tick", retry = 1500, data = " lead" }) ==
      "event: tick\nid: 7\nretry: 1500\ndata:  lead\n\n")
  assert(Sse.format_event({ comment = "ping" }) == ": ping\n\n")
  assert(Sse.format_event({ comment = "a\nb" }) == ": a\n: b\n\n")
  assert(Sse.format_event({}) == "" and Sse.format_event({ retry = 0 }) == "")
  assert(Sse.format_event({ id = "" }) == "id: \n\n", "an empty id resets the client's")
end

local function test_format_event_refuses_a_field_that_would_start_another()
  assert(raised(function() local _ = Sse.format_event({ id = "1\nevent: x" }) end):find("id must not hold", 1, true))
  assert(raised(function() local _ = Sse.format_event({ id = "a\0b" }) end):find("NUL", 1, true))
  assert(raised(function() local _ = Sse.format_event({ event = "a\rb" }) end):find("event must not hold", 1, true))
  assert(raised(function() local _ = Sse.format_event({ retry = -1 }) end):find("retry", 1, true))
  local fractional: any = { retry = 1.5 }
  assert(raised(function() local _ = Sse.format_event(fractional as Sse.Event) end):find("retry", 1, true))
end

local function test_event_helpers_name_the_event_and_escape_nothing_themselves()
  local html = Sse.Event.html("row", Html.escape("<b>"))
  assert(html.event == "row" and html.data == "&lt;b&gt;")
  assert(Sse.Event.json("n", { a = 1 }).data == '{"a":1}')
  assert(Sse.Event.text("t", "hi").data == "hi")
  assert(raised(function() local _ = Sse.Event.json("n", function() end) end):find("json", 1, true))
end

local function test_a_stream_sends_retry_events_and_heartbeats_then_ends_with_its_source()
  local queue: Channel.Queue<Sse.Event>
  local closed: {string} = {}
  local app = Web.app{ routes = { Web.get("/s", function(req: Web.Request): Web.Response
    queue = Channel.new()
    return Sse.EventStream(req, Sse.from_queue(queue), { heartbeat_ns = BEAT_NS, retry_ms = 250,
      initial = { { id = "0", data = "first" } },
      headers = { ["X-Extra"] = "1" }, on_close = function(why: string)
        closed[#closed + 1] = why
      end })
  end) } }
  Web.with_server(app, function(client: Web.LoopbackClient)
    local feed = open(client.host, "/s")
    assert(feed.status == 200)
    assert(feed.headers["content-type"] == "text/event-stream", feed.headers["content-type"])
    assert(feed.headers["cache-control"]:find("no-cache", 1, true))
    assert(feed.headers["x-accel-buffering"] == "no" and feed.headers["x-extra"] == "1")
    assert(feed.headers["transfer-encoding"] == "chunked" and feed.headers["content-length"] == nil)
    assert(chunk(feed) == "retry: 250\n\nid: 0\ndata: first\n\n")
    assert(queue:send({ event = "tick", data = "1\n2" }))
    assert(chunk(feed) == "event: tick\ndata: 1\ndata: 2\n\n")
    assert(chunk(feed) == ": ping\n\n", "a heartbeat comes when no event does")
    queue:close()
    assert(chunk(feed) == nil, "the stream ends cleanly with its source")
    assert(until_true(function(): boolean return #closed == 1 end))
    assert(closed[1] == "end")
  end)
end

local function test_a_source_that_fails_ends_the_stream_and_says_why()
  local closed: {string} = {}
  local app = Web.app{ routes = { Web.get("/s", function(req: Web.Request): Web.Response
    local source: Sse.EventSource = {
      next = function(_self: Sse.EventSource, _t?: integer): Sse.Event | nil, string
        return nil, "database gone"
      end,
      close = function(_self: Sse.EventSource) end,
    }
    return Sse.EventStream(req, source, { retry_ms = 0, on_close = function(why: string)
      closed[#closed + 1] = why
    end })
  end) } }
  Web.with_server(app, function(client: Web.LoopbackClient)
    local feed = open(client.host, "/s")
    assert(chunk(feed) == ":\n\n", "the reply begins at once even with nothing to send")
    assert(chunk(feed) == nil)
    assert(until_true(function(): boolean return #closed == 1 end))
    assert(closed[1] == "failed: database gone")
  end)
end

local function test_max_age_ends_a_stream_cleanly()
  local queue: Channel.Queue<Sse.Event>
  local app = Web.app{ routes = { Web.get("/s", function(req: Web.Request): Web.Response
    queue = Channel.new()
    return Sse.EventStream(req, Sse.from_queue(queue), { heartbeat_ns = 0, retry_ms = 0, max_age_ns = Clock.ms(80) })
  end) } }
  Web.with_server(app, function(client: Web.LoopbackClient)
    local feed = open(client.host, "/s")
    assert(chunk(feed) == ":\n\n")
    assert(chunk(feed) == nil)
    assert(queue:closed(), "the source is closed with the stream")
  end)
end

local function test_options_are_checked()
  assert(raised(function() local _ = Sse.new_hub({ overflow = "block" }) end):find("overflow must be", 1, true))
  assert(raised(function() local _ = Sse.new_hub({ replay = -1 }) end):find("replay", 1, true))
  local unknown: any = { nope = 1 }
  assert(raised(function() local _ = Sse.new_hub(unknown as Sse.HubOptions) end):find("no option nope", 1, true))
  assert(raised(function() Web.app{ max_streams = -1 } end):find("max_streams", 1, true))
end

local function test_last_event_id_replays_what_the_ring_holds_after_it()
  local hub = Sse.new_hub({ replay = 3, queue = 8 })
  for i = 1, 5 do assert(hub:publish("t", { data = "e" .. i }) == 0) end
  Web.with_server(hub_app(hub), function(client: Web.LoopbackClient)
    local feed = open(client.host, "/events/t", { ["Last-Event-ID"] = "3" })
    assert(chunk(feed) == "retry: 100\n\n")
    assert(chunk(feed) == "id: 4\ndata: e4\n\n")
    assert(chunk(feed) == "id: 5\ndata: e5\n\n")
    assert(hub:publish("t", { data = "e6" }) == 1)
    assert(chunk(feed) == "id: 6\ndata: e6\n\n", "live events follow the replay in order")
    local fresh = open(client.host, "/events/t")
    assert(chunk(fresh) == "retry: 100\n\n")
    assert(hub:publish("t", { data = "e7" }) == 2)
    assert(chunk(fresh) == "id: 7\ndata: e7\n\n", "no Last-Event-ID, no replay")
  end)
end

local function test_a_last_event_id_the_ring_lost_starts_with_a_reset()
  local hub = Sse.new_hub({ replay = 3 })
  for i = 1, 5 do hub:publish("t", { data = "e" .. i }) end
  Web.with_server(hub_app(hub), function(client: Web.LoopbackClient)
    for _, lost in ipairs({ "1", "99", "not a number" }) do
      local feed = open(client.host, "/events/t", { ["Last-Event-ID"] = lost })
      assert(chunk(feed) == "retry: 100\n\n")
      assert(chunk(feed) == "event: reset\nid: 5\ndata: \n\n", lost)
    end
    assert(hub:subscribers("t") == 3)
  end)
  local none = Sse.new_hub({ replay = 0 })
  none:publish("t", { data = "x" })
  Poll.run(function()
    local sub = assert(none:subscribe({ "t" }, { after = "1" }))
    assert(sub.gap, "a hub that keeps nothing cannot resume")
    local ev = assert(sub:next(Clock.ms(10)))
    assert(ev.event == "reset" and ev.id == nil)
  end)
end

local function test_a_topic_that_dropped_newer_events_makes_a_replay_across_topics_a_gap()
  Poll.run(function()
    local hub = Sse.new_hub({ replay = 2 })
    hub:publish("a", { data = "a1" })
    for i = 1, 5 do hub:publish("b", { data = "b" .. i }) end
    local sub = assert(hub:subscribe({ "a", "b" }, { after = "1" }))
    assert(sub.gap, "b has dropped events newer than the client's")
    assert(assert(sub:next(0)).event == "reset")
    local alone = assert(hub:subscribe({ "a" }, { after = "1" }))
    assert(not alone.gap and select(2, alone:next(0)) == Poll.TIMEOUT, "a alone lost nothing")
  end)
end

local function test_the_ring_boundary_is_oldest_minus_one_against_oldest()
  Poll.run(function()
    local hub = Sse.new_hub({ replay = 3 })
    for i = 1, 5 do hub:publish("t", { data = "e" .. i }) end
    local lost = assert(hub:subscribe({ "t" }, { after = "2" }))
    assert(lost.gap, "the event before the oldest is gone, and so may be its successors")
    local held = assert(hub:subscribe({ "t" }, { after = "3" }))
    assert(not held.gap)
    assert(assert(held:next(0)).id == "4" and assert(held:next(0)).id == "5")
  end)
end

local function test_subscribing_to_names_and_leaving_leaves_no_topic_behind()
  Poll.run(function()
    local hub = Sse.new_hub({})
    for i = 1, 50 do
      local sub = assert(hub:subscribe({ "fresh" .. i }, { after = "x" }))
      sub:close()
    end
    local none = Sse.new_hub({ replay = 0 })
    none:publish("gone", { data = "x" })
    local count = 0
    for _, each in ipairs({ hub, none }) do
      local inner: any = each
      for _ in pairs((inner as {string:{string:any}}).topics as {string:any}) do
        count = count + 1
      end
    end
    assert(count == 0, "topics left: " .. count)
    local keep = assert(hub:subscribe({ "live" }))
    hub:publish("live", { data = "x" })
    keep:close()
    local again = assert(hub:subscribe({ "live" }, { after = "1" }))
    assert(not again.gap, "a topic with a ring is kept")
  end)
end

local function test_an_empty_or_missing_id_gets_the_hubs_and_nul_in_event_is_refused()
  Poll.run(function()
    local hub = Sse.new_hub({})
    local sub = assert(hub:subscribe({ "t" }))
    hub:publish("t", { id = "", data = "a" })
    hub:publish("t", { id = "mine", data = "b" })
    assert(assert(sub:next(0)).id == "1" and assert(sub:next(0)).id == "mine")
    assert(raised(function() hub:publish("t", { event = "a\0b" }) end):find("NUL", 1, true))
    assert(raised(function() local _ = Sse.format_event({ event = "a\0b" }) end):find("NUL", 1, true))
  end)
end

local function test_replay_across_topics_is_in_publication_order()
  Poll.run(function()
    local hub = Sse.new_hub({})
    hub:publish("a", { id = "a1", data = "1" })
    hub:publish("b", { id = "b1", data = "2" })
    hub:publish("a", { id = "a2", data = "3" })
    hub:publish("c", { id = "c1", data = "other topic" })
    local sub = assert(hub:subscribe({ "a", "b", "a" }, { after = "a1" }))
    assert(not sub.gap)
    assert(assert(sub:next(0)).id == "b1" and assert(sub:next(0)).id == "a2")
    local ev, why = sub:next(Clock.ms(5))
    assert(ev == nil and why == Poll.TIMEOUT)
    assert(hub:subscribers() == 1 and hub:subscribers("a") == 1 and hub:subscribers("c") == 0)
  end)
end

local function test_a_hub_reaches_every_subscriber_of_a_topic_and_only_them()
  local hub = Sse.new_hub({})
  Web.with_server(hub_app(hub), function(client: Web.LoopbackClient)
    local feeds: {Feed} = {}
    for i = 1, 3 do
      feeds[i] = open(client.host, "/events/news")
      assert(chunk(feeds[i]) == "retry: 100\n\n")
    end
    local other = open(client.host, "/events/sport")
    assert(chunk(other) == "retry: 100\n\n")
    assert(hub:subscribers() == 4 and hub:subscribers("news") == 3)
    assert(hub:publish("news", Sse.Event.text("headline", "hello")) == 3)
    for _, feed in ipairs(feeds) do
      assert(chunk(feed) == "event: headline\nid: 1\ndata: hello\n\n")
    end
    assert(chunk(other) == ": ping\n\n", "the other topic saw only its heartbeat")
    feeds[1].conn:close()
    other.conn:close()
    assert(until_true(function(): boolean return hub:subscribers() == 2 end),
      "a gone client is noticed by a heartbeat's failed write")
    assert(hub:subscribers("sport") == 0)
  end)
end

local function test_a_subscriber_that_cannot_keep_up_is_cut_off_by_the_default_policy()
  Poll.run(function()
    local hub = Sse.new_hub({ queue = 2 })
    local slow = assert(hub:subscribe({ "t" }))
    local keen = assert(hub:subscribe({ "t" }))
    assert(hub:publish("t", { data = "1" }) == 2 and hub:publish("t", { data = "2" }) == 2)
    assert(assert(keen:next(0)).data == "1" and assert(keen:next(0)).data == "2")
    assert(hub:publish("t", { data = "3" }) == 1, "the full queue is not reached")
    assert(slow:closed() and not keen:closed() and hub:subscribers() == 1)
    assert(assert(slow:next(0)).data == "1" and assert(slow:next(0)).data == "2")
    local ev, why = slow:next(0)
    assert(ev == nil and why == "", "it is told the stream is over after what it held")
    assert(assert(keen:next(0)).data == "3")
  end)
end

local function test_the_drop_policies_keep_a_subscriber_without_ever_waiting_the_publisher()
  Poll.run(function()
    local oldest = Sse.new_hub({ queue = 2, overflow = "drop_oldest" })
    local sub = assert(oldest:subscribe({ "t" }))
    for i = 1, 5 do assert(oldest:publish("t", { data = tostring(i) }) == 1) end
    assert(sub:dropped() == 3 and not sub:closed())
    assert(assert(sub:next(0)).data == "4" and assert(sub:next(0)).data == "5")
    local newest = Sse.new_hub({ queue = 2, overflow = "drop_newest" })
    local kept = assert(newest:subscribe({ "t" }))
    for i = 1, 5 do newest:publish("t", { data = tostring(i) }) end
    assert(assert(kept:next(0)).data == "1" and assert(kept:next(0)).data == "2" and kept:dropped() == 3)
  end)
end

local function test_a_slow_client_over_the_wire_is_cut_off_and_reconnects_to_its_place()
  local hub = Sse.new_hub({ queue = 2, replay = 16 })
  Web.with_server(hub_app(hub, { heartbeat_ns = 0, retry_ms = 100 }), function(client: Web.LoopbackClient)
    local feed = open(client.host, "/events/t")
    assert(chunk(feed) == "retry: 100\n\n")
    -- Published with no wait between: the stream task has not run to drain the queue.
    for i = 1, 4 do hub:publish("t", { data = "e" .. i }) end
    assert(hub:subscribers() == 0, "overflow dropped the subscription")
    assert(chunk(feed) == "id: 1\ndata: e1\n\n" and chunk(feed) == "id: 2\ndata: e2\n\n")
    assert(chunk(feed) == nil, "its stream ends, so the browser reconnects")
    local again = open(client.host, "/events/t", { ["Last-Event-ID"] = "2" })
    assert(chunk(again) == "retry: 100\n\n")
    assert(chunk(again) == "id: 3\ndata: e3\n\n" and chunk(again) == "id: 4\ndata: e4\n\n")
  end)
end

local function test_hub_limits_and_a_closed_hub_refuse_a_subscription()
  Poll.run(function()
    local hub = Sse.new_hub({ max_per_topic = 1, max_total = 2 })
    local first = assert(hub:subscribe({ "a" }))
    local sub, why = hub:subscribe({ "a" })
    assert(sub == nil and why == "full")
    local _ = assert(hub:subscribe({ "b" }))
    sub, why = hub:subscribe({ "c" })
    assert(sub == nil and why == "full", "past the hub's total")
    first:close()
    first:close()
    assert(hub:subscribers() == 1 and hub:subscribe({ "a" }) ~= nil)
    hub:close()
    hub:close()
    assert(hub:subscribers() == 0)
    sub, why = hub:subscribe({ "a" })
    assert(sub == nil and why == "closed" and hub:publish("a", { data = "x" }) == 0)
  end)
end

local function test_an_event_the_hub_cannot_carry_raises()
  local hub = Sse.new_hub({ max_event_bytes = 8 })
  assert(raised(function() hub:publish("t", { data = ("x"):rep(9) }) end):find("over the hub's max_event_bytes", 1, true))
  assert(raised(function() hub:publish("t", { id = "a\nb" }) end):find("id must not hold", 1, true))
  assert(hub:publish("t", { data = ("x"):rep(8) }) == 0)
end

local function test_the_stream_budget_answers_503_past_it_and_frees_a_slot_when_a_stream_ends()
  local hub = Sse.new_hub({})
  local app = hub_app(hub, nil, { max_streams = 2 })
  Web.with_server(app, function(client: Web.LoopbackClient)
    local one = open(client.host, "/events/t")
    local two = open(client.host, "/events/t")
    assert(one.status == 200 and two.status == 200 and app.stream_count == 2)
    local over = open(client.host, "/events/t")
    assert(over.status == 503 and over.headers["retry-after"] == "5")
    assert(hub:subscribers() == 2, "a refused request holds no subscription")
    one.conn:close()
    assert(until_true(function(): boolean return app.stream_count == 1 end))
    assert(open(client.host, "/events/t").status == 200)
  end)
end

local function test_the_budget_is_half_the_connections_unless_the_app_says()
  local hub = Sse.new_hub({})
  local app = hub_app(hub)
  local seen: integer | nil = nil
  local ok, why = Web.serve(app, { listeners = { Net.tcp("127.0.0.1", 0) }, limits = { connections = 10 },
    on_ready = function(_addresses: {Net.Address}, server: Net.Server)
      seen = app.stream_limit
      server:stop()
    end })
  assert(ok, why)
  assert(seen == 5)
  assert(hub_app(hub, nil, { max_streams = 3 }).stream_limit == 3)
end

--- Serves `app` with a grace of `grace_ns`, and calls `fn` with the address and the server.
local function serving(app: Web.App, grace_ns: integer, fn: function(host: string, server: Net.Server))
  local failure: string | nil = nil
  local ok, why = Web.serve(app, { listeners = { Net.tcp("127.0.0.1", 0) }, grace_ns = grace_ns,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      local ran, trouble = pcall(function()
        fn("127.0.0.1:" .. assert(addresses[1].port), server)
      end)
      if not ran then failure = tostring(trouble) end
      server:stop()
    end })
  if failure ~= nil then error(failure, 0) end
  assert(ok, why)
end

local function test_stopping_the_server_ends_every_stream_long_before_the_grace()
  local hub = Sse.new_hub({})
  local queue: Channel.Queue<Sse.Event>
  local ended: {string} = {}
  local app = hub_app(hub, { heartbeat_ns = Clock.seconds(30), retry_ms = 100 }, { hubs = { hub } })
  local routes = assert(app.spec.routes)
  routes[#routes + 1] = Web.get("/queue", function(req: Web.Request): Web.Response
    queue = Channel.new()
    return Sse.EventStream(req, Sse.from_queue(queue), { heartbeat_ns = Clock.seconds(30),
      on_close = function(why: string) ended[#ended + 1] = why end })
  end)
  local started = Clock.monotonic_ns()
  serving(Web.app(app.spec), Clock.seconds(8), function(host: string, server: Net.Server)
    local feeds = { open(host, "/events/t"), open(host, "/events/u"), open(host, "/queue") }
    for _, feed in ipairs(feeds) do assert(feed.status == 200 and chunk(feed) ~= nil) end
    assert(hub:subscribers() == 2)
    server:stop()
    for _, feed in ipairs(feeds) do
      assert(chunk(feed) == nil, "each stream ends with its last chunk")
    end
    assert(hub:subscribers() == 0)
    assert(until_true(function(): boolean return #ended == 1 end))
    assert(ended[1] == "end" and queue:closed())
  end)
  assert(Clock.monotonic_ns() - started < Clock.seconds(3), "the grace of 8 s was not waited out")
end

local function test_a_stream_that_ignores_its_close_is_killed_at_the_grace_and_released()
  local closed: {string} = {}
  local stuck: Sse.EventSource = {
    next = function(_self: Sse.EventSource, _t?: integer): Sse.Event | nil, string
      local _, _ = Poll.delay(Clock.seconds(60))
      return nil, ""
    end,
    close = function(_self: Sse.EventSource) end,
  }
  local app = Web.app{ routes = { Web.get("/stuck", function(req: Web.Request): Web.Response
    return Sse.EventStream(req, stuck, { on_close = function(why: string)
      closed[#closed + 1] = why
    end })
  end) } }
  local started = Clock.monotonic_ns()
  serving(app, Clock.ms(150), function(host: string, server: Net.Server)
    local feed = open(host, "/stuck")
    assert(chunk(feed) == "retry: 3000\n\n" and app.stream_count == 1)
    server:stop()
  end)
  assert(app.stream_count == 0, "the kill released the slot")
  assert(closed[1] == "client" and #closed == 1)
  assert(Clock.monotonic_ns() - started < Clock.seconds(3))
end

local function test_a_stream_asked_for_while_the_app_is_stopping_is_refused()
  local queue: Channel.Queue<Sse.Event>
  local app = Web.app{ routes = { Web.get("/s", function(req: Web.Request): Web.Response
    queue = Channel.new()
    return Sse.EventStream(req, Sse.from_queue(queue))
  end) } }
  Web.with_client(app, function(client: Web.TestClient)
    app.stopped = true
    local res = client:get("/s")
    assert(res.status == 503 and res.headers["retry-after"] == "5")
    assert(queue:closed(), "the source it was given is closed")
    assert(app.stream_count == 0)
  end)
end

local function test_attach_closes_a_hub_when_the_app_stops()
  local hub = Sse.new_hub({})
  local app = hub_app(hub)
  hub:attach(app)
  serving(app, Clock.seconds(8), function(host: string, server: Net.Server)
    local feed = open(host, "/events/t")
    assert(chunk(feed) == "retry: 100\n\n")
    server:stop()
    assert(chunk(feed) == nil)
  end)
  assert(hub:subscribers() == 0)
end

local function test_a_response_the_handler_never_returns_releases_its_stream()
  local hub = Sse.new_hub({})
  local closed: {string} = {}
  local app = Web.app{ routes = { Web.get("/raises", function(req: Web.Request): Web.Response
    local sub = assert(hub:subscribe({ "t" }))
    local _ = Sse.EventStream(req, sub, { on_close = function(why: string)
      closed[#closed + 1] = why
    end })
    error("after the stream was made")
  end) }, sink = { line = function(_self: Web.Sink, _text: string) end } }
  Web.with_client(app, function(client: Web.TestClient)
    assert(client:get("/raises").status == 500)
    assert(app.stream_count == 0 and hub:subscribers() == 0)
    assert(closed[1] == "client" and #closed == 1)
  end)
end

local function test_a_response_middleware_replaces_releases_its_stream()
  local hub = Sse.new_hub({})
  local function replace(inner: Web.Handler): Web.Handler
    return function(req: Web.Request): Web.Response
      local _ = inner(req)
      return Web.text("replaced")
    end
  end
  local app = hub_app(hub, nil, { middleware = { replace } })
  Web.with_client(app, function(client: Web.TestClient)
    local res = client:get("/events/t")
    assert(res.status == 200 and res.body == "replaced")
    assert(app.stream_count == 0 and hub:subscribers() == 0)
  end)
end

local function test_a_bad_option_closes_the_source_it_was_given()
  local queues: {Channel.Queue<Sse.Event>} = {}
  local app = Web.app{ routes = { Web.get("/s", function(req: Web.Request): Web.Response
    local queue: Channel.Queue<Sse.Event> = Channel.new()
    queues[#queues + 1] = queue
    local wrong: any = { retry_ms = -1 }
    if #queues == 2 then wrong = { initial = { { id = "a\nb" } } } end
    return Sse.EventStream(req, Sse.from_queue(queue), wrong as Sse.EventStreamOptions)
  end) }, sink = { line = function(_self: Web.Sink, _text: string) end } }
  Web.with_client(app, function(client: Web.TestClient)
    assert(client:get("/s").status == 500 and client:get("/s").status == 500)
    assert(queues[1]:closed() and queues[2]:closed() and app.stream_count == 0)
  end)
end

local function test_a_quiet_stream_with_heartbeats_outlives_the_servers_timeouts()
  local hub = Sse.new_hub({})
  local app = hub_app(hub, { heartbeat_ns = Clock.ms(25), retry_ms = 100 })
  local failure: string | nil = nil
  local ok, why = Web.serve(app, { listeners = { Net.tcp("127.0.0.1", 0) },
    timeout_ns = Clock.ms(100), idle_ns = Clock.ms(100), grace_ns = Clock.seconds(1),
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      local ran, trouble = pcall(function()
        local feed = open("127.0.0.1:" .. assert(addresses[1].port), "/events/t")
        assert(chunk(feed) == "retry: 100\n\n")
        local beats = 0
        local started = Clock.monotonic_ns()
        while Clock.monotonic_ns() - started < Clock.ms(400) do
          assert(chunk(feed) == ": ping\n\n", "the stream was cut")
          beats = beats + 1
        end
        assert(beats >= 4)
        assert(hub:publish("t", { data = "late" }) == 1)
        assert(chunk(feed) == "id: 1\ndata: late\n\n")
      end)
      if not ran then failure = tostring(trouble) end
      server:stop()
    end })
  if failure ~= nil then error(failure, 0) end
  assert(ok, why)
end

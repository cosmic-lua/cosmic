--- Server-sent events for [`cosmic.web`]: [`Sse.format_event`] writes one
--- event in the wire format, [`Sse.EventStream`] answers a request with a
--- stream of them, and [`Sse.Hub`] fans events out to the streams of many
--- clients, with a replay ring for a browser that reconnects.
---
---     local hub = Sse.new_hub{}
---     local app = Web.app{
---       hubs = { hub },
---       routes = {
---         Web.get("/events", function(req: Web.Request): Web.Response
---           local sub, why = hub:subscribe({ "orders" }, { after = Sse.last_event_id(req) })
---           if sub == nil then
---             return Web.text(why, { status = 503, headers = { ["Retry-After"] = "5" } })
---           end
---           return Sse.EventStream(req, sub)
---         end),
---       },
---     }
---     hub:publish("orders", Sse.text("order-added", "order 17"))
---
--- A stream is a chunked `text/event-stream` reply whose body is read as it
--- is sent. The hub never makes a publisher wait: a subscriber that cannot
--- keep up is settled by its overflow policy, and a slow client costs only
--- its own queue. Everything runs in the tasks of one [`Poll.run`], so
--- nothing here is locked.

local Channel = require("cosmic.channel")
local Clock = require("cosmic.clock")
local Html = require("cosmic.html")
local Json = require("cosmic.json")
local Poll = require("cosmic.poll")
local Response = require("cosmic.web.response")
local Stream = require("cosmic.stream")
local Types = require("cosmic.web.types")

local record Sse
  --- One event. Every field is optional; a field that holds a line ending
  --- where the wire format could not carry it raises in [`Sse.format_event`].
  record Event
    --- The `id:` field: the client echoes the last one it saw in
    --- `Last-Event-ID`. Must not hold CR, LF or NUL (raises). An empty id
    --- resets the client's.
    id?: string
    --- The `event:` field (a client sees "message" when none): htmx's
    --- `sse-swap="name"` listens for it. Must not hold CR, LF or NUL
    --- (raises; a browser drops an event whose name holds NUL).
    event?: string
    --- The `data:` field; any line ending (LF, CR, CRLF) splits it into
    --- one `data:` line each, so a client rejoins them with LF. For htmx,
    --- an HTML fragment. A client drops an event that has no data.
    data?: string
    --- The `retry:` field, the client's reconnection delay in
    --- milliseconds; nil or 0 for none. Anything else but a positive
    --- integer raises.
    retry?: integer
    --- A comment (`: text` lines), which a client ignores: a heartbeat.
    comment?: string
  end

  --- Where a stream gets its events from.
  interface EventSource
    --- The next event, waiting at most `timeout_ns` (no limit when nil):
    --- nil and [`Poll.TIMEOUT`] when none came in time (the stream then
    --- sends a heartbeat), nil and "" at the end of the stream, and nil
    --- and why when it failed, which also ends the stream.
    next: function(EventSource, timeout_ns?: integer): Event | nil, string
    --- Ends the source: a `next` that waits wakes and answers the end.
    --- Safe to call twice, and never waits (the stream calls it from the
    --- app's stop and from a killed task's `<close>`).
    close: function(EventSource)
  end

  --- What [`Sse.EventStream`] takes.
  record EventStreamOptions
    --- A heartbeat comment every this many nanoseconds without an event
    --- (15 seconds when nil; 0 sends none). A write is how a client that
    --- left is found, so a stream without one outlives it.
    heartbeat_ns?: integer
    --- The `retry:` sent first, in milliseconds (3000 when nil; 0 sends
    --- none).
    retry_ms?: integer
    --- Events sent before the first of the source.
    initial?: {Event}
    --- Headers added to the response, replacing one of the same name; a
    --- list writes one line per element.
    headers?: {string: string | {string}}
    --- The longest the stream lives, in nanoseconds (none when nil): it
    --- ends cleanly then, and the browser reconnects with its
    --- `Last-Event-ID`. How a deploy rotates streams, and a session is
    --- checked again.
    max_age_ns?: integer
    --- Called once when the stream is over, with why: "end" (the source
    --- or `max_age_ns` ended it, also the app stopping), "client" (the
    --- server closed it unfinished: the client left, or the task was
    --- killed) or "failed: <why>" (the source failed). For a log line or
    --- a counter.
    on_close?: function(why: string)
  end

  --- A hub's subscription to some topics: an [`Sse.EventSource`] holding
  --- the events published since it began, in order.
  interface Subscription is EventSource
    --- True when the `after` it was given was not in the replay ring
    --- (older than it holds, or from before a restart): its first event is
    --- a synthetic `reset`, on which the page should fetch its state anew.
    gap: boolean
    --- Whether the subscription is over: closed, or cut off by its
    --- overflow policy. Its queued events are still delivered.
    closed: function(Subscription): boolean
    --- How many events its overflow policy discarded.
    dropped: function(Subscription): integer
  end

  --- Fan-out of events to the subscriptions of topics.
  interface Hub is Types.Closable
    --- Delivers `ev` to every subscription of `topic`, keeping it in the
    --- topic's replay ring, and returns how many it reached. Never waits.
    --- An event without an id, or with an empty one, gets the hub's next
    --- (a count, as text): an empty id would reset the client's, and the
    --- event could not be resumed after.
    --- Raises for an event [`Sse.format_event`] refuses and one whose data
    --- is over `max_event_bytes`: a fault of the program.
    publish: function(Hub, topic: string, ev: Event): integer
    --- A subscription to `topics`, starting after the event with id
    --- `opts.after` (the request's [`Sse.last_event_id`]) when a ring of
    --- one of the topics still holds it, else `gap` is set and it starts
    --- with a `reset` event. Without `after` it starts with the next
    --- publish. Nil and why when over a limit ("full") or the hub is
    --- closed ("closed").
    subscribe: function(Hub, topics: {string}, opts?: SubscribeOptions): Subscription | nil, string
    --- How many subscriptions are open, to `topic` when given.
    subscribers: function(Hub, topic?: string): integer
    --- Closes every subscription: their streams end and the browsers
    --- reconnect, to this process or its successor. A closed hub refuses
    --- `subscribe`. Safe to call twice.
    close: function(Hub)
    --- Closes the hub when the server of `app` begins to stop, as the
    --- app's `hubs` do.
    attach: function(Hub, app: Types.App)
  end

  --- What [`Sse.new_hub`] takes.
  record HubOptions
    --- Events kept per topic for `Last-Event-ID` replay (256 when nil; 0
    --- for none, which makes every reconnect a gap).
    replay?: integer
    --- Each subscription's queue, in events (256 when nil), beside the
    --- events its replay queues first.
    queue?: integer
    --- What a full queue does: "close" (the default: the subscription is
    --- cut off once it has delivered what it holds, and the browser
    --- reconnects and replays), "drop_oldest" (a view that wants only
    --- the latest) or "drop_newest". "block" is not offered: it would
    --- make a publisher wait.
    overflow?: Channel.Overflow
    --- Subscriptions per topic (no limit when nil).
    max_per_topic?: integer
    --- Subscriptions in all (no limit when nil).
    max_total?: integer
    --- The most bytes of data one event may hold (65536 when nil).
    max_event_bytes?: integer
  end

  --- What [`Sse.Hub.subscribe`] takes.
  record SubscribeOptions
    --- The id of the last event the client saw: untrusted text, compared
    --- to ids by equality alone.
    after?: string
  end

  --- Writes `ev` in the wire format.
  format_event: function(ev: Event): string

  --- A hub with no subscribers and no events kept. Raises for an option
  --- it does not take or one of the wrong kind.
  new_hub: function(opts?: HubOptions): Hub

  --- The `Last-Event-ID` the client sent.
  last_event_id: function(req: Types.Request): string | nil

  --- A source over a queue of events.
  from_queue: function(queue: Channel.Queue<Event>): EventSource

  --- A streaming SSE response for `req`, fed by `source`.
  EventStream: function(req: Types.Request, source: EventSource, opts?: EventStreamOptions): Types.Response
end

local DEFAULT_HEARTBEAT_NS <const> = Clock.seconds(15)
local DEFAULT_RETRY_MS <const> = 3000
local DEFAULT_REPLAY <const> = 256
local DEFAULT_QUEUE <const> = 256
local DEFAULT_EVENT_BYTES <const> = 65536
local LAST_EVENT_ID_BYTES <const> = 1024

local HEARTBEAT <const> = ": ping\n\n"

--- The lines of `text`, any of LF, CR and CRLF ending one; a final line
--- ending gives a last empty line.
local function lines_of(text: string): {string}
  local unified = text:gsub("\r\n", "\n")
  unified = unified:gsub("\r", "\n")
  local lines: {string} = {}
  for line in (unified .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
  return lines
end

--- Raises unless `value` is a string without the bytes in `forbidden`
--- (a pattern class).
local function field_text(name: string, value: any, forbidden: string): string
  if not value is string then error("sse: " .. name .. " must be a string", 3) end
  if value:find(forbidden) then
    error("sse: " .. name .. " must not hold a line ending" .. (forbidden:find("%z", 1, true) and " or NUL" or ""), 3)
  end
  return value
end

--- Writes `ev` in the wire format: lines `field: value`, ended by a
--- blank line. Whatever `ev` holds, the result is one event at most: a
--- line ending in `data` or `comment` starts another line of the same
--- field, and an `id`, `event` or `retry` that could start a field of
--- its own raises. An event with no field gives "". The text is not
--- checked to be UTF-8; a client reads bad bytes as U+FFFD.
local function format_event(ev: Sse.Event): string
  if type(ev) ~= "table" then error("sse: an event must be a table", 2) end
  local out: {string} = {}
  local comment = ev.comment
  if comment ~= nil then
    if type(comment) ~= "string" then error("sse: comment must be a string", 2) end
    for _, line in ipairs(lines_of(comment)) do out[#out + 1] = ": " .. line .. "\n" end
  end
  local event = ev.event
  if event ~= nil and event ~= "" then
    out[#out + 1] = "event: " .. field_text("event", event, "[\r\n%z]") .. "\n"
  end
  local id = ev.id
  if id ~= nil then
    out[#out + 1] = "id: " .. field_text("id", id, "[\r\n%z]") .. "\n"
  end
  local retry = ev.retry
  if retry ~= nil and retry ~= 0 then
    if math.type(retry) ~= "integer" or retry < 0 then
      error("sse: retry must be a positive integer of milliseconds", 2)
    end
    out[#out + 1] = ("retry: %d\n"):format(retry)
  end
  local data = ev.data
  if data ~= nil then
    if type(data) ~= "string" then error("sse: data must be a string", 2) end
    for _, line in ipairs(lines_of(data)) do out[#out + 1] = "data: " .. line .. "\n" end
  end
  if #out == 0 then return "" end
  out[#out + 1] = "\n"
  return table.concat(out)
end

--- An event named `name` whose data is the markup `body`; typed
--- [`Html.SafeHtml`] so a handler cannot send an unescaped string as
--- markup by accident.
function Sse.html(name: string, body: Html.SafeHtml): Sse.Event
  return { event = name, data = Html.raw(body) }
end

--- An event named `name` whose data is `value` as JSON; a value that
--- cannot be encoded raises.
function Sse.json(name: string, value: any): Sse.Event
  local text, why = Json.encode_any(value)
  if text == nil then error("sse: json: " .. why, 2) end
  return { event = name, data = text }
end

--- An event named `name` whose data is `text`.
function Sse.text(name: string, text: string): Sse.Event
  return { event = name, data = text }
end

--- The `Last-Event-ID` the client sent, which a reconnecting browser
--- sets; nil when absent, empty or over 1024 bytes.
local function last_event_id(req: Types.Request): string | nil
  local id = req.headers["last-event-id"]
  if id == nil or id == "" or #id > LAST_EVENT_ID_BYTES then return nil end
  return id
end

local record QueueSource is Sse.EventSource
  queue: Channel.Queue<Sse.Event>
  next: function(QueueSource, timeout_ns?: integer): Sse.Event | nil, string
  close: function(QueueSource)
end

function QueueSource.next(self: QueueSource, timeout_ns?: integer): Sse.Event | nil, string
  local ev, why = self.queue:receive(timeout_ns)
  if ev ~= nil then return ev, "" end
  if self.queue:closed() then return nil, "" end
  return nil, why
end

function QueueSource.close(self: QueueSource)
  self.queue:close()
end

--- A source over a queue of events, ended when the queue is closed and
--- drained; its `close` closes the queue. For a stream fed by tasks of
--- the program rather than by a hub.
local function from_queue(queue: Channel.Queue<Sse.Event>): Sse.EventSource
  local source: QueueSource = { queue = queue, next = QueueSource.next, close = QueueSource.close }
  return source
end

-- The stream.

local record Guard
  metamethod __close: function(Guard)
end

--- The Reader that is a stream's body.
local record Body is Stream.Reader
  app: Types.App
  source: Sse.EventSource
  heartbeat_ns: integer
  deadline?: integer
  on_close: function(why: string)
  pending: string
  started: boolean
  held: boolean
  done: boolean
  waiting: boolean
  guard?: Guard
  prologue: string
  read: function(Body, max_bytes?: integer): string | nil, string
  close: function(Body): boolean, string
end

--- Ends the stream once: frees its slot (if it took one), closes the
--- source, tells the caller. Never waits, and never raises (it may run in a `<close>`
--- handler of a killed task or inside the app's stop).
local function finish(self: Body, why: string)
  if self.done then return end
  self.done = true
  self.pending = ""
  local app = self.app
  if self.held then
    self.held = false
    app.streams[self] = nil
    app.stream_count = app.stream_count - 1
  end
  local source = self.source
  local on_close = self.on_close
  local ran, raised = pcall(function() source:close() end)
  if not ran then assert(app.spec.sink):line("sse: closing a source: " .. tostring(raised)) end
  if on_close ~= nil then
    ran, raised = pcall(function() on_close(why) end)
    if not ran then assert(app.spec.sink):line("sse: on_close: " .. tostring(raised)) end
  end
end

function Body.read(self: Body, max_bytes?: integer): string | nil, string
  if max_bytes ~= nil and (math.type(max_bytes) ~= "integer" or max_bytes < 1) then
    error("sse: read takes a positive integer of bytes", 2)
  end
  if self.done then return nil, "" end
  if not self.started then
    self.started = true
    -- The slot is taken here, as the reply begins, not when the response is
    -- made: a response a handler or middleware drops is never read. The
    -- limit was checked at the response, so streams made but not yet read
    -- can overshoot it by the few the server has yet to start.
    if self.app:stopping() then
      finish(self, "end")
      return nil, ""
    end
    self.held = true
    self.app.stream_count = self.app.stream_count + 1
    local source = self.source
    self.app.streams[self] = function() source:close() end
    self.pending = self.prologue
    self.prologue = ""
  end
  while self.pending == "" do
    local timeout = self.heartbeat_ns > 0 and self.heartbeat_ns or nil
    local self_deadline = self.deadline
    if self_deadline ~= nil then
      local left = self_deadline - Clock.monotonic_ns()
      if left <= 0 then
        finish(self, "end")
        return nil, ""
      end
      if timeout == nil or left < timeout then timeout = left end
    end
    local ev: Sse.Event | nil = nil
    local why = ""
    do
      -- The guard covers only a wait in `source:next`: a task killed there
      -- would otherwise leave the stream open, as the server closes a body
      -- only once it has sent or abandoned the reply. A wait that returns
      -- clears `waiting` first, so the guard then does nothing.
      self.waiting = true
      local _guard <close> = assert(self.guard)
      ev, why = self.source:next(timeout)
      self.waiting = false
    end
    if self.done then return nil, "" end
    if ev ~= nil then
      local ok, text = pcall(format_event, ev)
      if not ok then
        finish(self, "failed: " .. tostring(text))
        return nil, ""
      end
      self.pending = text
    elseif why == Poll.TIMEOUT then
      local deadline = self.deadline
      if deadline == nil or Clock.monotonic_ns() < deadline then
        self.pending = HEARTBEAT
      end
    elseif why == "" then
      finish(self, "end")
      return nil, ""
    else
      finish(self, "failed: " .. why)
      return nil, ""
    end
  end
  local take = max_bytes or #self.pending
  local chunk = self.pending:sub(1, take)
  self.pending = self.pending:sub(take + 1)
  return chunk, ""
end

function Body.close(self: Body): boolean, string
  finish(self, "client")
  return true, ""
end

local EVENT_STREAM_FIELDS <const>: {string:boolean} = {
  heartbeat_ns = true, retry_ms = true, initial = true, headers = true, max_age_ns = true, on_close = true,
}

--- Why `value` is no integer of at least `least`; nil when it is, or nil.
local function not_counted(what: string, value: integer | nil, least: integer): string | nil
  if value ~= nil and (math.type(value) ~= "integer" or value < least) then
    return ("sse: %s must be an integer of at least %d"):format(what, least)
  end
  return nil
end

--- Why `given` is no table or holds a field `known` lacks; nil when fine.
local function not_checked(given: any, known: {string:boolean}, what: string): string | nil
  if given == nil then return nil end
  if not given is {any:any} then return "sse: " .. what .. " takes a table of options" end
  for key in pairs(given) do
    if not (key is string and known[key]) then
      return ("sse: %s has no option %s"):format(what, tostring(key))
    end
  end
  return nil
end

--- Raises unless `value` is nil or an integer of at least `least`.
local function counted(what: string, value: integer | nil, least: integer)
  local why = not_counted(what, value, least)
  if why ~= nil then error(why, 3) end
end

--- Raises where `given` is no table or holds a field `known` lacks.
local function checked(given: any, known: {string:boolean}, what: string)
  local why = not_checked(given, known, what)
  if why ~= nil then error(why, 3) end
end

local function refused(source: Sse.EventSource, why: string): Types.Response
  source:close()
  return Response.text(why, { status = 503, headers = { ["Retry-After"] = "5" } })
end

--- A streaming SSE response for `req`, fed by `source`, which it takes
--- over (it closes it when the stream ends, whatever the way). Status
--- 200 with `Content-Type: text/event-stream`, `Cache-Control: no-cache,
--- no-transform` and `X-Accel-Buffering: no`; chunked, since a stream has
--- no length. The first chunk holds `retry:` and the `initial` events at
--- once, so the proxy sees the reply begin.
---
--- Answers 503 with `Retry-After: 5` instead, closing `source`, when the
--- app already has `max_streams` open (half the server's connections by
--- default) or is stopping. The stream ends cleanly when the app begins
--- to stop; a task killed at the grace has it released by a `<close>`
--- guard. Compression middleware must leave `text/event-stream` alone.
---
--- The stream takes its slot when the server starts to read it. A response
--- a handler or middleware drops instead is closed, with its source, once
--- the request is answered. A raise for a bad option closes `source` too.
--
-- TODO: cap the streams per client (assets.md 5.9) once Web.Request carries
-- a trusted client key; until then one client may hold every slot.
local function event_stream(req: Types.Request, source: Sse.EventSource,
                            opts?: Sse.EventStreamOptions): Types.Response
  local function bad(why: string | nil)
    if why ~= nil then
      source:close()
      error(why, 3)
    end
  end
  bad(not_checked(opts, EVENT_STREAM_FIELDS, "EventStream"))
  local given: Sse.EventStreamOptions = opts or {}
  bad(not_counted("heartbeat_ns", given.heartbeat_ns, 0))
  bad(not_counted("retry_ms", given.retry_ms, 0))
  bad(not_counted("max_age_ns", given.max_age_ns, 1))
  local app = req.app
  if app:stopping() then return refused(source, "the server is stopping") end
  if app.stream_count >= app.stream_limit then return refused(source, "too many open streams") end
  local retry_ms = given.retry_ms or DEFAULT_RETRY_MS
  local first: {string} = {}
  if retry_ms > 0 then first[1] = ("retry: %d\n\n"):format(retry_ms) end
  local initial: {Sse.Event} = given.initial or {}
  for _, ev in ipairs(initial) do
    local ok, text = pcall(format_event, ev)
    if not ok then bad(tostring(text)) end
    first[#first + 1] = text
  end
  local prologue = table.concat(first)
  if prologue == "" then prologue = ":\n\n" end
  local body: Body = {
    app = app, source = source, heartbeat_ns = given.heartbeat_ns or DEFAULT_HEARTBEAT_NS,
    on_close = given.on_close, pending = "", started = false, held = false, done = false, waiting = false,
    prologue = prologue, read = Body.read, close = Body.close,
  }
  local max_age_ns = given.max_age_ns
  if max_age_ns ~= nil then body.deadline = Clock.monotonic_ns() + max_age_ns end
  local guard: Guard = {}
  local guard_mt: metatable<Guard> = { __close = function()
    if body.waiting then
      body.waiting = false
      finish(body, "client")
    end
  end }
  body.guard = setmetatable(guard, guard_mt)
  req.bodies[#req.bodies + 1] = body
  local headers: {string: string | {string}} = {
    ["Cache-Control"] = "no-cache, no-transform", ["X-Accel-Buffering"] = "no",
  }
  for name, value in pairs(given.headers or {}) do headers[name] = value end
  return Response.stream(body, "text/event-stream", { headers = headers })
end

-- The hub.

--- One published event, kept for replay.
local record Entry
  seq: integer
  event: Sse.Event
end

local record Sub is Sse.Subscription
  queue: Channel.Queue<Sse.Event>
  detach: function()
  next: function(Sub, timeout_ns?: integer): Sse.Event | nil, string
  close: function(Sub)
  closed: function(Sub): boolean
  dropped: function(Sub): integer
end

function Sub.next(self: Sub, timeout_ns?: integer): Sse.Event | nil, string
  local ev, why = self.queue:receive(timeout_ns)
  if ev ~= nil then return ev, "" end
  if self.queue:closed() then return nil, "" end
  return nil, why
end

function Sub.close(self: Sub)
  self.queue:close()
  self.detach()
end

function Sub.closed(self: Sub): boolean return self.queue:closed() end
function Sub.dropped(self: Sub): integer return self.queue:dropped() end

--- A topic's subscriptions and replay ring (`first` to `last`, oldest first).
local record Topic
  subs: {Sub: boolean}
  ring: {integer: Entry}
  first: integer
  last: integer
  evicted: integer
end

local record State is Sse.Hub
  replay: integer
  queue_size: integer
  overflow: Channel.Overflow
  max_per_topic: integer
  max_total: integer
  max_event_bytes: integer
  topics: {string: Topic}
  total: integer
  seq: integer
  shut: boolean
  publish: function(State, topic: string, ev: Sse.Event): integer
  subscribe: function(State, topics: {string}, opts?: Sse.SubscribeOptions): Sse.Subscription | nil, string
  subscribers: function(State, topic?: string): integer
  close: function(State)
  attach: function(State, app: Types.App)
end

local HUB_FIELDS <const>: {string:boolean} = {
  replay = true, queue = true, overflow = true, max_per_topic = true, max_total = true,
  max_event_bytes = true,
}

local function topic_of(self: State, name: string): Topic
  local topic = self.topics[name]
  if topic == nil then
    -- TODO: drop the ring of a topic nothing has published to for a while;
    -- a hub keyed by user or order keeps one ring per name it has seen.
    topic = { subs = {}, ring = {}, first = 1, last = 0, evicted = 0 }
    self.topics[name] = topic
  end
  return topic
end

--- Forgets the topic `name` when it has no subscriber and holds no event,
--- so a name only ever subscribed to (or published to with no ring) costs
--- nothing once it is left.
local function release(self: State, name: string)
  local topic = self.topics[name]
  if topic ~= nil and next(topic.subs) == nil and topic.last < topic.first then
    self.topics[name] = nil
  end
end

function State.publish(self: State, name: string, ev: Sse.Event): integer
  if not name is string then error("sse: publish takes a topic name", 2) end
  format_event(ev)
  local ev_data = ev.data
  if ev_data ~= nil and #ev_data > self.max_event_bytes then
    error(("sse: the event's data (%d) is over the hub's max_event_bytes (%d)"):
        format(#ev_data, self.max_event_bytes), 2)
  end
  if self.shut then return 0 end
  self.seq = self.seq + 1
  local ev_id = ev.id
  -- Ids are a count that restarts at 1 with the process, so a Last-Event-ID
  -- from before a restart can match an unrelated event. That stays: the
  -- rings are lost with the process anyway, and an app whose clients must
  -- resume across restarts publishes ids of its own.
  local kept: Sse.Event = { id = (ev_id ~= nil and ev_id ~= "") and ev_id or tostring(self.seq), event = ev.event, data = ev.data,
    retry = ev.retry, comment = ev.comment }
  local topic = topic_of(self, name)
  if self.replay > 0 then
    topic.last = topic.last + 1
    topic.ring[topic.last] = { seq = self.seq, event = kept }
    while topic.last - topic.first + 1 > self.replay do
      topic.evicted = topic.ring[topic.first].seq
      topic.ring[topic.first] = nil
      topic.first = topic.first + 1
    end
  end
  local reached = 0
  local cut: {Sub} = {}
  for sub in pairs(topic.subs) do
    local sent, _ = sub.queue:try_send(kept)
    if sent then
      reached = reached + 1
    else
      cut[#cut + 1] = sub
    end
  end
  for _, sub in ipairs(cut) do sub.detach() end
  release(self, name)
  return reached
end

--- The events of the rings of `names` after the one with id `after`:
--- nil where no ring holds it.
local function replayed(self: State, names: {string}, after: string): {Sse.Event} | nil
  local found: integer | nil = nil
  for _, name in ipairs(names) do
    local topic = self.topics[name]
    if topic ~= nil then
      for at = topic.last, topic.first, -1 do
        local entry = topic.ring[at]
        if entry.event.id == after then
          if found == nil or entry.seq > found then found = entry.seq end
          break
        end
      end
    end
  end
  if found == nil then return nil end
  -- A topic that has dropped an event newer than `found` cannot replay
  -- what the client missed in it.
  for _, name in ipairs(names) do
    local topic = self.topics[name]
    if topic ~= nil and topic.evicted > found then return nil end
  end
  local later: {Entry} = {}
  for _, name in ipairs(names) do
    local topic = self.topics[name]
    if topic ~= nil then
      for at = topic.first, topic.last do
        if topic.ring[at].seq > found then later[#later + 1] = topic.ring[at] end
      end
    end
  end
  table.sort(later, function(a: Entry, b: Entry): boolean return a.seq < b.seq end)
  local events: {Sse.Event} = {}
  for i, entry in ipairs(later) do events[i] = entry.event end
  return events
end

--- The id of the newest event the rings of `names` hold.
local function head_id(self: State, names: {string}): string | nil
  local best: Entry | nil = nil
  for _, name in ipairs(names) do
    local topic = self.topics[name]
    if topic ~= nil and topic.last >= topic.first then
      local entry = topic.ring[topic.last]
      if best == nil or entry.seq > best.seq then best = entry end
    end
  end
  return best ~= nil and best.event.id or nil
end

function State.subscribe(self: State, topics: {string}, opts?: Sse.SubscribeOptions): Sse.Subscription | nil, string
  if not topics is {string} or #topics == 0 then
    error("sse: subscribe takes a list of topic names", 2)
  end
  local names: {string} = {}
  local seen: {string: boolean} = {}
  for _, name in ipairs(topics) do
    if not name is string then error("sse: subscribe takes a list of topic names", 2) end
    if not seen[name] then
      seen[name] = true
      names[#names + 1] = name
    end
  end
  local after: string | nil = nil
  if opts ~= nil then
    if type(opts) ~= "table" then error("sse: subscribe takes a table of options", 2) end
    if type(opts.after) == "string" and opts.after ~= "" then after = opts.after end
  end
  if self.shut then return nil, "closed" end
  if self.max_total ~= nil and self.total >= self.max_total then return nil, "full" end
  if self.max_per_topic ~= nil then
    for _, name in ipairs(names) do
      if self:subscribers(name) >= self.max_per_topic then return nil, "full" end
    end
  end
  local replay: {Sse.Event} = {}
  local gap = false
  if after ~= nil then
    local later = replayed(self, names, after)
    if later == nil then
      gap = true
      replay[1] = { event = "reset", data = "", id = head_id(self, names) }
    else
      replay = later
    end
  end
  local queue: Channel.Queue<Sse.Event> = Channel.new({
    capacity = self.queue_size + #replay, overflow = self.overflow })
  for _, ev in ipairs(replay) do assert(queue:try_send(ev)) end
  local sub: Sub = { queue = queue, gap = gap, next = Sub.next, close = Sub.close,
    closed = Sub.closed, dropped = Sub.dropped }
  local attachment = { attached = true }
  sub.detach = function()
    if not attachment.attached then return end
    attachment.attached = false
    queue:close()
    self.total = self.total - 1
    for _, name in ipairs(names) do
      local topic = self.topics[name]
      if topic ~= nil then topic.subs[sub] = nil end
      release(self, name)
    end
  end
  self.total = self.total + 1
  for _, name in ipairs(names) do topic_of(self, name).subs[sub] = true end
  return sub, ""
end

function State.subscribers(self: State, topic?: string): integer
  if topic == nil then return self.total end
  local found = self.topics[topic]
  if found == nil then return 0 end
  local n = 0
  for _ in pairs(found.subs) do n = n + 1 end
  return n
end

function State.close(self: State)
  self.shut = true
  local all: {Sub} = {}
  local seen: {Sub: boolean} = {}
  for _, topic in pairs(self.topics) do
    for sub in pairs(topic.subs) do
      if not seen[sub] then
        seen[sub] = true
        all[#all + 1] = sub
      end
    end
  end
  for _, sub in ipairs(all) do sub:close() end
end

function State.attach(self: State, app: Types.App)
  app:on_stop(function() self:close() end)
end

--- A hub with no subscribers and no events kept. Raises for an option it
--- does not take or one of the wrong kind.
local function new_hub(opts?: Sse.HubOptions): Sse.Hub
  checked(opts, HUB_FIELDS, "new_hub")
  local given: Sse.HubOptions = opts or {}
  counted("replay", given.replay, 0)
  counted("queue", given.queue, 1)
  counted("max_per_topic", given.max_per_topic, 1)
  counted("max_total", given.max_total, 1)
  counted("max_event_bytes", given.max_event_bytes, 1)
  local overflow = given.overflow or "close"
  if overflow ~= "close" and overflow ~= "drop_oldest" and overflow ~= "drop_newest" then
    error("sse: overflow must be \"close\", \"drop_oldest\" or \"drop_newest\"", 2)
  end
  local hub: State = {
    replay = given.replay or DEFAULT_REPLAY, queue_size = given.queue or DEFAULT_QUEUE,
    overflow = overflow, max_per_topic = given.max_per_topic, max_total = given.max_total,
    max_event_bytes = given.max_event_bytes or DEFAULT_EVENT_BYTES,
    topics = {}, total = 0, seq = 0, shut = false,
    publish = State.publish, subscribe = State.subscribe, subscribers = State.subscribers,
    close = State.close, attach = State.attach,
  }
  return hub
end

Sse.format_event = format_event
Sse.last_event_id = last_event_id
Sse.from_queue = from_queue
Sse.EventStream = event_stream
Sse.new_hub = new_hub

return Sse

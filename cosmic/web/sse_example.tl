--- Worked examples for [`cosmic.web.sse`], shown by `cosmic docs` under
--- the symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Channel = require("cosmic.channel")
local Html = require("cosmic.html")
local Sse = require("cosmic.web.sse")
local Web = require("cosmic.web")

local Example = {}

--- An event written for the wire: a data line for every line of the text,
--- so text from a user cannot start a field or end the event.
function Example.format_event()
  local wire = Sse.format_event({ event = "note", id = "7", data = "line one\nevent: forged" })
  print(wire)
  assert(wire == "event: note\nid: 7\ndata: line one\ndata: event: forged\n\n")
  local row = Sse.Event.html("order-added", Html.escape("<tr>17</tr>"))
  assert(Sse.format_event(row) == "event: order-added\ndata: &lt;tr&gt;17&lt;/tr&gt;\n\n")
end

--- A hub streaming a topic to a page: the route subscribes, resuming after
--- the browser's `Last-Event-ID`, and an event published later reaches the
--- stream. The app's `hubs` close the stream when the server stops.
function Example.hub()
  local hub = Sse.new_hub({ replay = 16 })
  local app = Web.app{
    hubs = { hub },
    routes = {
      Web.get("/events", function(req: Web.Request): Web.Response
        local sub, why = hub:subscribe({ "orders" }, { after = Sse.last_event_id(req) })
        if sub == nil then
          return Web.text(why, { status = 503, headers = { ["Retry-After"] = "5" } })
        end
        return Sse.EventStream(req, sub, { retry_ms = 1000 })
      end),
    },
  }
  Web.with_client(app, function(client: Web.TestClient)
    hub:publish("orders", Sse.Event.text("order-added", "order 16"))
    local res = client:get("/events", { stream = true, headers = { ["Last-Event-ID"] = "0" } })
    local body = assert(res.stream)
    print(res.status, res.headers["content-type"])
    assert(res.status == 200 and res.headers["content-type"] == "text/event-stream")
    assert(body:read() == "retry: 1000\n\n")
    assert(body:read() == "event: reset\nid: 1\ndata: \n\n", "id 0 is not held: the page should fetch anew")
    hub:publish("orders", Sse.Event.text("order-added", "order 17"))
    local live = assert(body:read())
    print(live)
    assert(live == "event: order-added\nid: 2\ndata: order 17\n\n")
    assert(body:close())
    assert(hub:subscribers() == 0)
  end)
end

--- A stream fed by the program's own tasks: a queue of events is the
--- source, and closing it ends the stream.
function Example.queue()
  local queue: Channel.Queue<Sse.Event> | nil = nil
  local app = Web.app{ routes = { Web.get("/progress", function(req: Web.Request): Web.Response
    queue = Channel.new()
    return Sse.EventStream(req, Sse.from_queue(queue), { retry_ms = 0 })
  end) } }
  Web.with_client(app, function(client: Web.TestClient)
    local res = client:get("/progress", { stream = true })
    local body = assert(res.stream)
    local events = assert(queue, "the route never ran")
    assert(events:send(Sse.Event.json("progress", { done = 40 })))
    assert(body:read() == ":\n\n", "the stream begins with a comment when it has no retry to send")
    local update = assert(body:read())
    print(update)
    assert(update == 'event: progress\ndata: {"done":40}\n\n')
    events:close()
    local ended, why = body:read()
    assert(ended == nil and why == "")
  end)
end

return Example

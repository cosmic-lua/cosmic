# web live updates

<!-- policy: profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } -->

A page that shows what other people just did needs the server to speak
first. [`cosmic.web.sse`] streams server-sent events: a `Hub` fans events
out to the streams of many pages by topic, and htmx's SSE extension swaps
what arrives into the page. This guide builds `board`, a list of notes that
every open page shares. It starts from an empty directory and needs only
what [web apps](web.md) says about routes and templates.

## the pieces

- A **hub** ([`Sse.new_hub`]) holds subscriptions by topic and a short
  replay ring of the last events of each. `publish` never waits, and a
  slow client costs only its own queue: when the queue is full the
  subscription is cut off and the browser reconnects.
- A **stream** ([`Sse.EventStream`]) answers a request with a
  `text/event-stream` body read from a subscription. It sends a heartbeat
  so a client that left is found.
- An **event** names itself (`event:`), may carry an id (`id:`) and has
  data. [`Sse.Event.html`] makes one whose data is markup, typed
  [`Html.SafeHtml`] so a handler cannot send an unescaped string.
- The app is given the hub in `hubs`, which closes its streams when the
  server stops, so shutting down does not wait for streams that never end.

## reconnection

A browser that loses its stream reconnects by itself and says where it
stopped in `Last-Event-ID`. The route passes it to `subscribe` with
[`Sse.last_event_id`]. If the hub's ring still holds that event, the stream
resumes with the events after it. If it does not (the ring is shorter than
the gap, or the process restarted), the stream begins with a `reset` event,
on which the page fetches its state anew. The hub gives each event an id
unless it has one, in the order published.

## the page

`rows.tmpl` is the list. The page opens a stream with `sse-connect` and
swaps in whatever the server sends under the event name `notes`; on `reset`
it fetches the list from `/notes`. [`Htmx.head`] with `sse = true` loads the
extension that reads these attributes, from the binary like htmx itself.
The page is a whole document because `{{.head}}` is Teal: `<script src>`
takes no slot in a template.

```teal file=pages/data.tl
local Html = require("cosmic.html")

--- What the templates beside it render.
local record data
  record Note
    text: string
  end
  record Notes
    notes: {Note}
  end
  record Page
    head: Html.SafeHtml
    rows: Html.SafeHtml
  end
end

return data
```

```teal file=pages/rows.tmpl
{{type Notes from pages.data}}
{{range .notes}}<li>{{.text}}</li>{{else}}<li>no notes yet</li>{{end}}
```

```teal file=pages/index.tmpl
{{type Page from pages.data}}{{use htmx}}
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>board</title>
{{.head}}
</head>
<body>
<h1>board</h1>
<form hx-post="/notes" hx-swap="none">
  <input name="text" placeholder="say something">
  <button>post</button>
</form>
<ul id="notes" hx-ext="sse" sse-connect="/events" sse-swap="notes" hx-get="/notes" hx-trigger="sse:reset">{{.rows}}</ul>
</body>
</html>
```

## the app

A post adds a note and publishes the whole list, so an event that was
missed costs nothing: the next one carries everything. The stream route
subscribes to the topic from `Last-Event-ID` on, and answers 503 with
`Retry-After` when the hub is full or closed. This app has no CSRF check,
to keep the subject in view; a page that changes state adds the layers
[the security guide](web-security.md) builds before it ships.

```teal file=board.tl
--- The board: notes in memory, shown to every open page.

local Html = require("cosmic.html")
local Htmx = require("cosmic.web.htmx")
local Input = require("cosmic.web.input")
local Sse = require("cosmic.web.sse")
local Url = require("cosmic.url")
local Web = require("cosmic.web")
local data = require("pages.data")
local index = require("pages.index")
local rows = require("pages.rows")

local record Board
end

--- The app, with its notes and its hub.
function Board.app(): Web.App
  local notes: {data.Note} = {}
  local hub = Sse.new_hub{}

  local function list(): Html.SafeHtml
    return rows.render({ notes = notes })
  end

  return Web.app{
    hubs = { hub },
    routes = {
      Web.get("/", function(_req: Web.Request): Web.Response
        return Web.html(index.render({ head = Htmx.head{ sse = true }, rows = list() }))
      end),

      Web.get("/notes", function(_req: Web.Request): Web.Response
        return Web.html(list())
      end),

      Web.post("/notes", function(req: Web.Request): Web.Response
        local read = Input.form(req)
        if read.invalid ~= nil then return Web.abort(read.invalid.status, read.invalid.message) end
        local text = Url.query_last(assert(read.value), "text") or ""
        if text == "" then return Web.abort(422, "say something") end
        notes[#notes + 1] = { text = text }
        hub:publish("notes", Sse.Event.html("notes", list()))
        return Web.empty(204)
      end),

      Web.get("/events", function(req: Web.Request): Web.Response
        local sub, why = hub:subscribe({ "notes" }, { after = Sse.last_event_id(req) })
        if sub == nil then
          return Web.text(why, { status = 503, headers = { ["Retry-After"] = "5" } })
        end
        return Sse.EventStream(req, sub)
      end, { name = "events" }),
    },
  }
end

return Board
```

## the tests

A stream needs an event loop, so the tests run under [`Web.with_client`],
which runs the lifespan and a loop around them; `stream = true` leaves the
body unread in `reply.stream`, and `read()` waits for the next chunk. The
first chunk of a stream is `retry: 3000`, the delay a browser waits before
it reconnects.

```teal file=board_test.tl
local Board = require("board")
local Web = require("cosmic.web")

local function test_the_page_opens_a_stream()
  local page = Web.test_client(Board.app()):get("/")
  assert(page.status == 200 and page.body:find('sse-connect="/events"', 1, true))
  assert(page.body:find("/_web/htmx-ext-sse", 1, true), "the extension is loaded")
end

local function test_a_new_note_reaches_an_open_page()
  Web.with_client(Board.app(), function(client: Web.TestClient)
    local open = client:get("/events", { stream = true })
    assert(open.status == 200 and open.headers["content-type"] == "text/event-stream")
    local body = assert(open.stream)
    assert(body:read() == "retry: 3000\n\n")
    assert(client:post("/notes", { form = { text = "hello" } }).status == 204)
    local event = assert(body:read())
    assert(event:find("event: notes", 1, true) and event:find("hello", 1, true), event)
    assert(body:close())
  end)
end

local function test_a_reconnect_resumes_after_the_last_id()
  Web.with_client(Board.app(), function(client: Web.TestClient)
    for _, text in ipairs({ "one", "two", "three" }) do
      client:post("/notes", { form = { text = text } })
    end
    local body = assert(client:get("/events", { stream = true, headers = { ["Last-Event-ID"] = "2" } }).stream)
    assert(body:read() == "retry: 3000\n\n")
    local missed = assert(body:read())
    assert(missed:find("id: 3", 1, true) and missed:find("three", 1, true), missed)
    assert(body:close())
  end)
end

local function test_an_id_the_ring_does_not_hold_starts_with_a_reset()
  Web.with_client(Board.app(), function(client: Web.TestClient)
    client:post("/notes", { form = { text = "one" } })
    local body = assert(client:get("/events", { stream = true, headers = { ["Last-Event-ID"] = "0" } }).stream)
    assert(body:read() == "retry: 3000\n\n")
    assert(assert(body:read()):find("event: reset", 1, true), "the page should fetch its state anew")
    assert(body:close())
  end)
end

local function test_a_blank_note_is_refused()
  assert(Web.test_client(Board.app()):post("/notes", { form = { text = "" } }).status == 422)
end
```

`cosmic test` builds the project and runs the file; the next block does it
through [`cosmic.child`], as the guide for the command line does.

```teal
local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Proc = require("cosmic.proc")
local Clock = require("cosmic.clock")

local relaunch = assert(Proc.relaunch())
local env = Env.all()
for name, value in pairs(relaunch.env) do env[name] = value end
env["COSMIC_TEST_SANDBOX"] = "0"
local argv = { table.unpack(relaunch.argv) }
argv[#argv + 1] = "test"
local said = assert(Child.run(argv,
  { env = env, fds = relaunch.fds, cwd = tmp, stdout = "capture", stderr = "capture",
    timeout_ns = Clock.seconds(120) }))
print(((said.stderr or "") .. (said.stdout or "")):match("test: %d+ tests? passed"))
```

```output
test: 5 tests passed
```

[`cosmic.child`]: ../../cosmic/child.tl
[`cosmic.web.sse`]: ../../cosmic/web/sse.tl
[`Html.SafeHtml`]: ../../cosmic/html.tl
[`Htmx.head`]: ../../cosmic/web/htmx.tl
[`Sse.Event.html`]: ../../cosmic/web/sse.tl
[`Sse.EventStream`]: ../../cosmic/web/sse.tl
[`Sse.last_event_id`]: ../../cosmic/web/sse.tl
[`Sse.new_hub`]: ../../cosmic/web/sse.tl
[`Web.with_client`]: ../../cosmic/web/init.tl

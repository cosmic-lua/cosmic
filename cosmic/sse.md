# sse

 Server-Sent Events: parse a stream of them, format one for the wire.
 parse() reads SSE from any stream.Reader (a fetch.Reader, an fd
 Handle wrapping a socket, a child's stdout) and yields complete
 events, following the WHATWG event stream processing model:
 unterminated events at EOF are discarded, empty-data dispatches
 reset the event type buffer, the last event ID updates as soon as
 an `id:` line is seen, and `retry:` accepts only ASCII digits.
 format() is the serializing half, so a cosmic program can serve SSE
 without hand-writing the wire framing.

## Types

### Event

 A parsed SSE event.

```teal
local record Event
  data: string
  event: string
  id: string
  retry_ms: integer
end
```

### EventStream

 An open SSE event stream.

```teal
local record EventStream
  --  Next parsed event: an Event, or bare nil on a graceful close. On
  --  a mid-stream transport failure it yields nil plus the error
  --  message once, then plain nil — so truncation is distinguishable
  --  from a graceful close. The positive branch narrows the yield
  --  (a guard before a break does not):
  --    while true do
  --      local ev = s:next()
  --      if ev then handle(ev) else break end
  --    end
  next: function(self: EventStream): Event | nil, string
  --  The last seen event ID (nil until an id: line is seen), for
  --  reconnecting with a Last-Event-ID request header. Updates as soon
  --  as an id: line is parsed, even when no event is dispatched.
  last_event_id: function(self: EventStream): string | nil
end
```

### SseModule

```teal
local record SseModule
  parse: function(reader: stream.Reader): EventStream
  format: function(ev: Event): string
end
```

## Functions

### parse

```teal
function parse(reader: stream.Reader): EventStream
```

 Parse SSE events from a streaming reader.
 Returns an EventStream whose :next() yields Event values (see the
 record for the loop shape and the truncation-vs-close contract). A
 partially accumulated event at end-of-stream is discarded per the
 SSE spec, not dispatched. :last_event_id() exposes the id for
 reconnects.

**Parameters:**

- `reader` (stream.Reader) - the reader to parse events from

**Returns:**

- EventStream - the open event stream

### format

```teal
function format(ev: Event): string
```

 Serialize one Event to its wire form: `event:`/`id:`/`retry:`
 fields when present, one `data:` line per newline-separated data
 segment, and the dispatching blank line. The inverse of parse for a
 dispatchable event (data ~= ""): parse(format(ev)) yields ev back.
 Infallible.

**Parameters:**

- `ev` (Event) - the event to serialize

**Returns:**

- string - the wire bytes, terminator included

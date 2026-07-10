# sse

 Server-Sent Events parser for streaming HTTP responses.
 Parses SSE format from any stream.Reader (a fetch.Reader, an fd
 Handle wrapping a socket, a child's stdout) and yields complete
 events, following the WHATWG event stream processing model:
 unterminated events at EOF are discarded, empty-data dispatches
 reset the event type buffer, the last event ID updates as soon as
 an `id:` line is seen, and `retry:` accepts only ASCII digits.

## Types

### Event

 A parsed SSE event.

```teal
local record Event
  data: string
  event: string
  id: string
  retry: number
end
```

### Stream

 An open SSE event stream.

```teal
local record Stream
  --  Iterator over parsed events: yields Event values; on a mid-stream
  --  transport failure yields nil plus the error message once, then
  --  plain nil — so truncation is distinguishable from a graceful close.
  next: function(): Event | nil, string
  --  The last seen event ID (nil until an id: line is seen), for
  --  reconnecting with a Last-Event-ID request header. Updates as soon
  --  as an id: line is parsed, even when no event is dispatched.
  last_event_id: function(): string
end
```

### sse

```teal
local record sse
  Event: Event
  Stream: Stream
  events: function(reader: stream.Reader): Stream
end
```

# sse

 Server-Sent Events parser for streaming HTTP responses.
 Parses SSE format from a fetch.Reader and yields complete events.

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

### sse

```teal
local record sse
  Event: Event
  events: function(reader: fetch.Reader): function(): Event, string
end
```

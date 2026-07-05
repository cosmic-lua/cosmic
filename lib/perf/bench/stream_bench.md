# stream_bench

 Streaming HTTP line-iteration against a loopback server.
 A forked child serves one large multi-line HTTP/1.1 body; the scenario
 times fetch.stream() + Reader:lines() consuming every line — the path SSE
 clients drive. The body is big enough that the reader's line-buffering
 cost (not the loopback transfer) dominates. The check pins the line count
 and the last line's content, so a buffering bug that drops or corrupts
 lines fails instead of winning.

## Types

### LineStats

 A single line-iteration outcome, checked after timing.

```teal
local record LineStats
  count: integer
  last: string
end
```

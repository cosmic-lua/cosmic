# calling a rate-limited api politely

A rate-limited API answers too many requests in a row with 429 or 503,
and often says when to come back. This guide fetches a list of items
from one with [`cosmic.http`]: a pacer spaces the requests out, `retry`
waits out the refusals that still come, and the loop stops cleanly when
the server will not serve it or the user presses Ctrl-C.

## a loop over items

A request is paced by passing the same [`Http.pacer`] to each call as
`pace`. The pacer holds the time of the last request it let start, and
each request sent with it first waits until its interval has passed. The
first request does not wait. Make one pacer per API, before the loop, and
share it: two pacers know nothing of each other's requests.

`retry` is the other half. When a response's status is 429 or 503 and
attempts are left, the request is sent again after a wait, the pacer
spacing that attempt too.

The examples answer from `script`, one canned reply per connection, so
they run without a network, in one program from top to bottom. Each call starts its script over, and
with `retry`, attempt N reads entry N. A real call leaves `script` out.

```teal
local Clock = require("cosmic.clock")
local Http = require("cosmic.http")
local Signal = require("cosmic.signal")
local sys = require("cosmic.sys")

local function reply(status: string, headers: string, body: string): string
  return "HTTP/1.1 " .. status .. "\r\nContent-Length: " .. tostring(#body) .. "\r\n" ..
    headers .. "Connection: close\r\n\r\n" .. body
end

local busy = reply("429 Too Many Requests", "Retry-After: 0\r\n", "slow down")
local canned: mut {integer: {string}} = {
  [1] = { reply("200 OK", "", "one") },
  [2] = { busy, reply("200 OK", "", "two") },
  [3] = { reply("200 OK", "", "three") },
}

local api = Http.pacer(Clock.ms(20))

local function fetch(id: integer): Http.Body?, string
  return Http.get("http://api.test/items/" .. tostring(id), {
    pace = api, retry = { attempts = 3 }, script = canned[id],
  })
end

local began = Clock.monotonic_ns()
for id = 1, 3 do
  local got = assert(fetch(id))
  print(id, got.status, got.body)
end
-- Four requests started: the second item was sent twice.
assert(Clock.monotonic_ns() - began >= 3 * Clock.ms(20))
```

## what retry waits for

The wait before a retry is the response's `Retry-After`, in seconds or
as an HTTP date (a date in the past is no wait). Without one, or with
one the module cannot read, it is `backoff_ns` (1 second), twice as long
with each retry, never more than `max_wait_ns` (60 seconds).

A `Retry-After` longer than `max_wait_ns` is not waited out: the
response comes back at once, as it is, so that the caller decides. So
does the last response when the attempts run out. A 429 or 503 is a
response, not a failure, like any other status, so `assert` on the call
passes and the loop reads `status`.

```teal continue
local past = "Retry-After: Wed, 21 Oct 2015 07:28:00 GMT\r\n"
local limited = reply("429 Too Many Requests", past, "slow down")
local sent_again = assert(Http.get("http://api.test/items/9", {
  retry = { attempts = 2 }, script = { limited, reply("200 OK", "", "nine") },
}))
local gave_up = assert(Http.get("http://api.test/items/9", {
  retry = { attempts = 2 }, script = { limited, limited },
}))
local too_long = assert(Http.get("http://api.test/items/9", {
  retry = { attempts = 5 },
  script = { reply("503 Service Unavailable", "Retry-After: 3600\r\n", "") },
}))
print(sent_again.status, gave_up.status, too_long.status, too_long.headers["retry-after"])
```

What the loop does with a 429 or 503 that comes back is its own
decision, since the server has refused after the waits it was given.
Stopping is the polite one: keep what was fetched, say where it stopped
and what the server asked, and let the next run start from there.

```teal continue
local function crawl(ids: {integer}): {string}, string
  local bodies: mut {string} = {}
  for _, id in ipairs(ids) do
    local got, trouble = fetch(id)
    if got == nil then return bodies, trouble end
    if got.status == 429 or got.status == 503 then
      return bodies, ("item %d: HTTP %d, try again after %s s"):format(id, got.status,
        got.headers["retry-after"] or "?")
    end
    bodies[#bodies + 1] = got.body
  end
  return bodies, ""
end

canned[2] = { reply("429 Too Many Requests", "Retry-After: 3600\r\n", "") }
local kept, stopped_because = crawl({ 1, 2, 3 })
print(#kept, stopped_because)
```

## the server's own count

A server often says how much room is left in a header, such as
`x-ratelimit-remaining` and `x-ratelimit-reset`. The module does not read
them, and their names, units and meaning differ between APIs. This
recipe assumes the common reading: the requests left in this window, and
the seconds until it resets. It holds off for the rest of the window once
one request is left, rather than spending it and being refused.

Header names come back in lower case. `wait` sleeps in short slices so
that the caller's `stopped` can end it, as the module's own waits end.

```teal continue
local function hold_off(headers: {string: string}): integer
  local remaining = math.tointeger(headers["x-ratelimit-remaining"] or "")
  local reset = math.tointeger(headers["x-ratelimit-reset"] or "")
  if remaining == nil or reset == nil or remaining > 1 then return 0 end
  return Clock.seconds(reset)
end

local function wait(ns: integer, stopped: function(): boolean): boolean
  local left = ns
  while left > 0 and not stopped() do
    local slice = math.min(left, Clock.ms(100))
    assert(Clock.sleep_ns(slice))
    left = left - slice
  end
  return ns <= 0 or not stopped()
end

local nearly_out = hold_off({ ["x-ratelimit-remaining"] = "1", ["x-ratelimit-reset"] = "2" })
local plenty = hold_off({ ["x-ratelimit-remaining"] = "40", ["x-ratelimit-reset"] = "2" })
print(nearly_out // Clock.ms(1), plenty, hold_off({}))
```

The loop gains a call to `hold_off` after each response and a `wait` on
what it answers. `stopped` and `each`, a call after every item, are for
the next section.

```teal continue
local function crawl_slowly(ids: {integer}, stopped: function(): boolean,
    each: function(integer)): {string}, string
  local bodies: mut {string} = {}
  for _, id in ipairs(ids) do
    if stopped() then return bodies, "interrupted" end
    local got, trouble = fetch(id)
    if got == nil then return bodies, trouble end
    if got.status == 429 or got.status == 503 then
      return bodies, ("item %d: HTTP %d, try again after %s s"):format(id, got.status,
        got.headers["retry-after"] or "?")
    end
    bodies[#bodies + 1] = got.body
    each(id)
    if not wait(hold_off(got.headers), stopped) then return bodies, "interrupted" end
  end
  return bodies, ""
end

local window = "x-ratelimit-remaining: 0\r\nx-ratelimit-reset: 0\r\n"
for id = 1, 3 do canned[id] = { reply("200 OK", window, "item " .. tostring(id)) } end
local fetched, finished = crawl_slowly({ 1, 2, 3 }, function(): boolean return false end, function() end)
print(#fetched, finished == "")
```

## stopping on ctrl-c

[`Signal.guard`] catches SIGINT and SIGTERM until it closes, so that the
program can end its work before the signal ends it. While the innermost
guard has caught one, a wait of `retry` or `pace` ends and the call fails
with "interrupted", as does an open still waiting for its response. The
failure is the loop's cue to stop and report: the same `nil` and why as
any other, told apart by the word.

A signal that comes between two requests is the loop's to see. It asks the
guard, here through `stopped`, at the top of each round. This example
sends the process SIGINT after the first item, as a keystroke would. It
ends the guard with `release` in place of `close`: `close` delivers the
signal again, so that the process ends as it would have, which a program
does as its last act, or by letting a `<close>` variable do it. `release`
keeps the signal instead, so that the example goes on.

```teal continue
local function ctrl_c(id: integer) if id == 1 then assert(sys.kill(sys.getpid(), sys.SIGINT)) end end

local guard = assert(Signal.guard())
local function pressed(): boolean return guard:cancelled() ~= 0 end
local partial, cut_short = crawl_slowly({ 1, 2, 3 }, pressed, ctrl_c)
local signal = assert(guard:release())
print(#partial, cut_short, signal == sys.SIGINT)
```

The module's `cancelled` option ends the same waits when a function of
the caller's answers true, for a stop that is not a signal. A signal
that no request or wait has been told of, because it came before the
call and nothing has read the guard since, fails the call the same way:

```teal continue
local again = assert(Signal.guard())
assert(sys.kill(sys.getpid(), sys.SIGINT))
local none, interrupted = Http.get("http://api.test/items/1", {
  pace = Http.pacer(Clock.ms(20)), retry = { attempts = 3 }, script = canned[1],
})
local _ = assert(again:release())
print(none == nil, interrupted)
```

## what is not retried

`retry` answers a 429 or 503, which say the server did not act on the
request. A request that fails (`nil` and why: a refused or reset
connection, a timeout, a reply that is not HTTP) is not retried: the
server may have acted on it, so sending it again is the caller's
decision.

Only an idempotent request is safe to send again blindly: GET, HEAD, PUT
and DELETE do the same thing twice as once. A POST that creates something
may create it twice. The pacer spaces these attempts like any other, as
long as they are passed the same `pace`; "interrupted" is not a
transport failure, and ends the tries.

```teal continue
local function get_again(url: string, replies: {string}): Http.Body?, string
  local trouble = ""
  for _, canned_reply in ipairs(replies) do
    local got, why = Http.get(url, {
      pace = api, retry = { attempts = 3 }, script = { canned_reply },
    })
    if got ~= nil then return got, "" end
    if why == "interrupted" then return nil, why end
    trouble = why
  end
  return nil, trouble
end

local got = assert(get_again("http://api.test/items/1", { "not http\r\n\r\n", reply("200 OK", "", "one") }))
print(got.status, got.body)
```

All the examples are one program, and this is what it prints:

```output
1	200	one
2	200	two
3	200	three
200	429	503	3600
1	item 2: HTTP 429, try again after 3600 s
2000	0	0
3	true
1	interrupted	true
true	interrupted
200	one
```

[`cosmic.http`]: ../../cosmic/http/init.tl
[`Http.pacer`]: ../../cosmic/http/init.tl
[`Signal.guard`]: ../../cosmic/signal.tl

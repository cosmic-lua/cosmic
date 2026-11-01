# calling a rate-limited api politely

<!-- policy: cpu_features = true -->

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

A call is one request to the pacer, and so is each attempt `retry` makes.
The redirects a call follows are not paced ([every redirect
hop](#every-redirect-hop) says how to pace them), and a request that fails to
connect still counts as a start, since it loaded the API.

`retry` is the other half. When a response's status is 429 or 503 and
attempts are left, the request is sent again after a wait, the pacer
spacing that attempt too. `attempts` counts the first request: 3 is one
request and up to two more.

The examples run without a network, in one program from top to bottom,
and print at the end of the page. They answer from `script`, one canned
reply per connection: each call starts its script over, and with `retry`
attempt N reads entry N. `fetch` takes its `script` as an argument and
leaves it out in a real program, and the loops take the function that
fetches, so the code to copy has no canned replies in it.

The examples also shorten what would be long. A real API gets an
interval of a few hundred milliseconds and the default `backoff_ns` of 1
second. Here they are 20 and 50 milliseconds, and the run asserts that
the waits happened.

```teal
local Clock = require("cosmic.clock")
local Http = require("cosmic.http")
local Signal = require("cosmic.signal")
local sys = require("cosmic.sys")

local interval_ns = Clock.ms(20)
local backoff_ns = Clock.ms(50)
local api = Http.pacer(interval_ns)

-- `script` is for tests alone: a real call leaves it nil.
local function fetch(id: integer, script: {string}?): Http.Body?, string
  return Http.get("http://api.test/items/" .. tostring(id), {
    pace = api, retry = { attempts = 3, backoff_ns = backoff_ns }, script = script,
  })
end

local function crawl(ids: {integer},
    get: function(integer): Http.Body?, string): {string}, string
  local bodies: mut {string} = {}
  for _, id in ipairs(ids) do
    local got, trouble = get(id)
    if got == nil then return bodies, trouble end
    bodies[#bodies + 1] = got.body
  end
  return bodies, ""
end

-- The canned replies, and the replies to test with.
local function reply(status: string, headers: string, body: string): string
  return "HTTP/1.1 " .. status .. "\r\nContent-Length: " .. tostring(#body) .. "\r\n" ..
    headers .. "Connection: close\r\n\r\n" .. body
end

local canned: mut {integer: {string}} = {
  [1] = { reply("200 OK", "", "one") },
  [2] = { reply("429 Too Many Requests", "", "slow down"), reply("200 OK", "", "two") },
  [3] = { reply("200 OK", "", "three") },
}
local function get_canned(id: integer): Http.Body?, string return fetch(id, canned[id]) end

local began = Clock.monotonic_ns()
local items = assert(crawl({ 1, 2, 3 }, get_canned))
print(table.concat(items, " "))
-- Four requests started, and the second item's retry waited out its backoff.
assert(Clock.monotonic_ns() - began >= backoff_ns + interval_ns)
```

## every redirect hop

A call that follows redirects follows them inside one open, so the
pacer sees one request for the whole chain. To pace each hop, pass
`follow = false` and follow `Location` by hand, each hop through the
same pacer. [`Url.resolve`] turns a `Location`, which may be relative,
into the next URL.

This follows only what a GET needs: a 301, 302, 303, 307 or 308 with a
`Location` sends a GET again, and a GET stays a GET. It does not
reimplement the rules curl follows for other methods or bodies, and it
does not drop credentials when a hop leaves the host. So any credential
header (`Authorization`, `Cookie`, an API-key header) must be left off a
request whose redirects may cross hosts: the loop would send it to
whatever host a `Location` names. `follow = false` also skips
`redirect_protocols`, so the example refuses a change of scheme from
https to http itself.

```teal continue
local Url = require("cosmic.url")

local function get_paced(url: string, pacer: Http.Pacer, limit: integer,
    script_for: function(integer): {string}?): Http.Body?, string
  local here = url
  for hop = 0, limit do
    local got, trouble = Http.get(here, {
      pace = pacer, follow = false, script = script_for(hop),
    })
    if got == nil then return nil, trouble end
    local s = got.status
    local location = got.headers["location"]
    if (s ~= 301 and s ~= 302 and s ~= 303 and s ~= 307 and s ~= 308)
        or location == nil or location == "" then
      return got, ""
    end
    local next_url = Url.resolve(here, location)
    if here:find("^https:") and next_url:find("^http:") then
      return nil, "redirect from https to http refused"
    end
    here = next_url
  end
  return nil, "too many redirects"
end

-- The canned replies: a chain of two hops, then the item.
local chain: {{string}} = {
  { reply("302 Found", "Location: /moved\r\n", "") },
  { reply("301 Moved Permanently", "Location: http://api.test/items/7\r\n", "") },
  { reply("200 OK", "", "seven") },
}
local hop_ns = Clock.ms(100)
local hop_pacer = Http.pacer(hop_ns)
local chain_began = Clock.monotonic_ns()
local landed = assert(get_paced("http://api.test/old", hop_pacer, 5,
  function(hop: integer): {string}? return chain[hop + 1] end))
local chain_took = Clock.monotonic_ns() - chain_began
-- Three requests through the pacer: the last started two intervals after
-- the first. The upper bound is loose, for a slow host.
assert(chain_took >= 2 * hop_ns)
assert(chain_took < 2 * hop_ns + Clock.seconds(2))
assert(not get_paced("http://api.test/old", hop_pacer, 1,
  function(hop: integer): {string}? return chain[hop + 1] end))
print(landed.status, landed.body)
```

## what retry waits for

The wait before a retry is the response's `Retry-After`, in seconds or
as an HTTP date (a date in the past is no wait). Without one, or with
one the module cannot read, it is `backoff_ns`, twice as long with each
retry, never more than `max_wait_ns` (60 seconds by default). The
example above has no `Retry-After`, so it waited the 50 milliseconds.
The next one gives a date in the past, which is no wait, so that the run
stays quick.

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
local function refused(id: integer, got: Http.Body): string?
  if got.status ~= 429 and got.status ~= 503 then return nil end
  return ("item %d: HTTP %d, try again after %s s"):format(id, got.status,
    got.headers["retry-after"] or "?")
end

local function crawl_politely(ids: {integer}, get: function(integer): Http.Body?, string
    ): {string}, string
  local bodies: mut {string} = {}
  for _, id in ipairs(ids) do
    local got, trouble = get(id)
    if got == nil then return bodies, trouble end
    local why = refused(id, got)
    if why ~= nil then return bodies, why end
    bodies[#bodies + 1] = got.body
  end
  return bodies, ""
end

canned[2] = { reply("429 Too Many Requests", "Retry-After: 3600\r\n", "") }
local kept, stopped_because = crawl_politely({ 1, 2, 3 }, get_canned)
print(#kept, stopped_because)
```

## what retry sends again

`retry` sends the whole request again, body included, whatever its
method. A POST given a `retry` is posted again after a 429 or 503. A
429 says the server refused the request, but a 503 may come from a
gateway in front of a server that did the work, so neither proves it did
not act. Give a POST a `retry` only when sending it twice is harmless:
the API takes an idempotency key (a header the server uses to ignore the
second copy), or the POST only asks something. Otherwise leave `retry`
off and decide from the status.

## the server's own count

A server often says how much room is left in a header, such as
`x-ratelimit-remaining` and `x-ratelimit-reset`. The module does not read
them, and their names, units and meaning differ between APIs. This
recipe reads the requests left in this window and the seconds until it
resets, as delta-seconds. It holds off for the rest of the window once
one request is left, rather than spending it and being refused.

It reads digits only: a header that is missing or malformed (`0x10`, a
date, a fraction) means no hold-off. A value too large is capped at the
longest hold the caller names, `max_ns`, so that a header read wrongly
cannot sleep for years. `second_ns` is the length of a second, which a
real program passes as `Clock.seconds(1)`, and the example shortens.

```teal continue
local function digits(text: string?): integer?
  if text == nil or not text:find("^%d+$") then return nil end
  if #text > 18 then return math.maxinteger end
  return math.tointeger(text)
end

local function hold_off(headers: {string: string}, second_ns: integer, max_ns: integer): integer
  local remaining = digits(headers["x-ratelimit-remaining"])
  local reset = digits(headers["x-ratelimit-reset"])
  if remaining == nil or reset == nil or remaining > 1 then return 0 end
  return math.min(reset, max_ns // second_ns) * second_ns
end

local one_second, longest = Clock.seconds(1), Clock.seconds(30)
local nearly_out = hold_off({ ["x-ratelimit-remaining"] = "1", ["x-ratelimit-reset"] = "2" },
  one_second, longest)
local plenty = hold_off({ ["x-ratelimit-remaining"] = "40", ["x-ratelimit-reset"] = "2" },
  one_second, longest)
local huge = hold_off({ ["x-ratelimit-remaining"] = "0", ["x-ratelimit-reset"] = "99999999999" },
  one_second, longest)
local hex = hold_off({ ["x-ratelimit-remaining"] = "0", ["x-ratelimit-reset"] = "0x10" },
  one_second, longest)
local nothing_sent = hold_off({}, one_second, longest)
print(nearly_out // Clock.ms(1), plenty, nothing_sent, huge // Clock.ms(1), hex)
```

Some APIs, GitHub's among them, send `x-ratelimit-reset` as the time of
the reset, in seconds since 1970, not the seconds until it. For one of
those the recipe changes by a line, in `hold_off`, after `reset` is read:
`if reset ~= nil then reset = math.max(reset - os.time(), 0) end`.

The wait is the caller's, so it sleeps in short slices that the
caller's `stopped` can end, as the module's own waits end. The loop gains
a `wait` after each response, and none after the last item, where there
is nothing to wait for. `stopped` and `each`, a call after every item,
are for the next section.

```teal continue
local function wait(ns: integer, stopped: function(): boolean): boolean
  local left = ns
  while left > 0 and not stopped() do
    local slice = math.min(left, Clock.ms(100))
    assert(Clock.sleep_ns(slice))
    left = left - slice
  end
  return ns <= 0 or not stopped()
end

local function crawl_slowly(ids: {integer}, get: function(integer): Http.Body?, string,
    second_ns: integer, stopped: function(): boolean, each: function(integer)): {string}, string
  local bodies: mut {string} = {}
  for i, id in ipairs(ids) do
    if stopped() then return bodies, "interrupted" end
    local got, trouble = get(id)
    if got == nil then return bodies, trouble end
    local why = refused(id, got)
    if why ~= nil then return bodies, why end
    bodies[#bodies + 1] = got.body
    each(id)
    if i < #ids and not wait(hold_off(got.headers, second_ns, longest), stopped) then
      return bodies, "interrupted"
    end
  end
  return bodies, ""
end

local window = "x-ratelimit-remaining: 0\r\nx-ratelimit-reset: 1\r\n"
for id = 1, 3 do canned[id] = { reply("200 OK", window, "item " .. tostring(id)) } end
local never = function(): boolean return false end
local nothing = function(_: integer) end
local short_second = Clock.ms(200)
local waited_from = Clock.monotonic_ns()
local last_done = 0
local function note(id: integer) if id == 3 then last_done = Clock.monotonic_ns() end end
local fetched, finished = crawl_slowly({ 1, 2, 3 }, get_canned, short_second, never, note)
-- Two holds of "one second", here 200 ms each, and none after the last
-- item: the crawl ends a moment after the last item is done.
assert(last_done - waited_from >= 2 * short_second)
assert(Clock.monotonic_ns() - last_done < short_second)
print(#fetched, finished == "")
```

## stopping on ctrl-c

[`Signal.guard`] catches SIGINT and SIGTERM until it closes, so that the
program can end its work before the signal ends it. A program opens one
for the length of its work. The best way to close it is a `<close>`
variable, `local g <close> = assert(Signal.guard())`, which closes on
every way out of the block. These examples close it by hand:

```teal continue
local function fetch_all(ids: {integer}): {string}, string
  local guard = assert(Signal.guard())
  local bodies, why = crawl_slowly(ids,
    function(id: integer): Http.Body?, string return fetch(id, nil) end,
    one_second, function(): boolean return guard:cancelled() ~= 0 end, nothing)
  assert(guard:close())
  return bodies, why
end
assert(type(fetch_all) == "function")
```

Closing the guard delivers the signal again, so that the process ends as
it would have, after the loop has had its say.

While the innermost guard has caught a signal during a wait of `retry`
or `pace`, the wait ends and the call fails with "interrupted", and so
does an open still waiting for its response. The failure is the loop's
cue to stop and report: the same `nil` and why as any other, told apart
by the word.

A signal caught before the call is another matter. A wait that begins
after it does not end on it. What does refuse is the open, if nothing has
read the guard since: it fails with "interrupted" too. So the loop does
not leave the guard to the calls. It asks at the top of each round, as
`crawl_slowly` does through `stopped`, and while it waits.

The example below sends the process SIGINT after the first item, as a
keystroke would, and ends the guard with `release` in place of the
`close` above. `release` keeps the signal instead of delivering it, and
only so that the test survives it. The signal stops the hold-off after
the first item.

The example needs SIGINT not to be ignored: a process started with it
ignored, such as a background job of a non-interactive shell, never
catches it ([`cosmic.signal`]). That is a property of the process the
example runs in, not something it can make true, so it relies on the
test runner, whose workers do not ignore it, as the module's own tests
do.

```teal continue
local function ctrl_c(id: integer)
  if id == 1 then assert(sys.kill(sys.getpid(), sys.SIGINT)) end
end

local guard = assert(Signal.guard())
local function pressed(): boolean return guard:cancelled() ~= 0 end
local partial, cut_short = crawl_slowly({ 1, 2, 3 }, get_canned, short_second, pressed, ctrl_c)
local signal = assert(guard:release())
print(#partial, cut_short, signal == sys.SIGINT)
```

The module's `cancelled` option ends the same waits when a function of
the caller's answers true, for a stop that is not a signal. The refusal
of an open after a signal is this:

```teal continue
local again = assert(Signal.guard())
assert(sys.kill(sys.getpid(), sys.SIGINT))
local none, interrupted = Http.get("http://api.test/items/1", {
  pace = Http.pacer(interval_ns), retry = { attempts = 3 }, script = canned[1],
})
local _ = assert(again:release())
print(none == nil, interrupted)
```

## what is not retried

`retry` answers a 429 or 503. A request that fails (`nil` and why: a
refused or reset connection, a timeout, a reply that is not HTTP) is not
retried, since the server may have acted on it, and sending it again is
the caller's decision.

Only an idempotent request is safe to send again blindly: GET, HEAD, PUT
and DELETE do the same thing twice as once. A POST that creates something
may create it twice. `send_again` is for those alone. It counts its
tries, doubles its wait between them, and ends on "interrupted", which is
not a transport failure. Each try goes through the same `pace`, so the
pacer spaces them too.

```teal continue
-- Sends a request again when it fails with no response, `tries` in all, waiting
-- `first_wait_ns` and then twice as long between them. Idempotent requests only.
local function send_again(send: function(): Http.Body?, string, tries: integer,
    first_wait_ns: integer, stopped: function(): boolean): Http.Body?, string
  local trouble = ""
  local pause = first_wait_ns
  for try = 1, tries do
    local got, why = send()
    if got ~= nil then return got, "" end
    if why == "interrupted" then return nil, why end
    trouble = why
    if try < tries then
      if not wait(pause, stopped) then return nil, "interrupted" end
      pause = pause * 2
    end
  end
  return nil, trouble
end

-- In a real program, `send` is:
--   function() return Http.get(url, { pace = api, retry = { attempts = 3 } }) end
local replies = { "not http\r\n\r\n", "not http\r\n\r\n", reply("200 OK", "", "one") }
local tries_made = 0
local function flaky(): Http.Body?, string
  tries_made = tries_made + 1
  local script = { assert(replies[tries_made]) }
  return Http.get("http://api.test/items/1", { pace = api, script = script })
end

local got = assert(send_again(flaky, 3, Clock.ms(10), never))
print(got.status, got.body, tries_made)
```

All the examples are one program, and this is what it prints:

```output
one two three
200	seven
200	429	503	3600
1	item 2: HTTP 429, try again after 3600 s
2000	0	0	30000	0
3	true
1	interrupted	true
true	interrupted
200	one	3
```

[`cosmic.http`]: ../../cosmic/http/init.tl
[`cosmic.signal`]: ../../cosmic/signal.tl
[`Http.pacer`]: ../../cosmic/http/init.tl
[`Signal.guard`]: ../../cosmic/signal.tl
[`Url.resolve`]: ../../cosmic/url.tl

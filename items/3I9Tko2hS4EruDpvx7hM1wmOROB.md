## Goal

G3 — honest nil. `math.tointeger(tonumber(s))` returns nil for a digit
string too long to be an integer, and two parsers in quicksand's proxy
hand that nil on as a port typed `integer`. The nil is reachable from
an untrusted CONNECT target or absolute-form request line.

## Measurement (2026-08-22, main `aaf4af95`)

This item was filed as "9 untrusted-input parse sites carry no cast and
no narrowing". A per-site pass over the whole family found the framing
wrong in three ways and the defect real in two places.

**Where the declaration lives.** Not `_types/gentl.tl` — the spec's
Evidence section says so and is wrong. `tointeger: function(any):
integer` is in tl's own embedded stdlib type text, `tl.lua:291` of the
pinned v0.24.8 (`grep -n "tointeger" o/3p/tl/tl.lua`). Correcting it
means an entry in the carried patch `3p/tl/tl_patch.tl`, not a
generator change.

**Correcting it buys nothing — measured.** A throwaway worktree with a
carried-patch entry rewriting the anchor to
`tointeger: function(any): integer | nil` (both the `tl.lua` and
`tl.tl` twins), refetched and rebuilt: `bin/cosmic --make check` →
`check: PASS (513 files)`. Zero sites break, because **Teal admits nil
into every position except an index**. Probed against that build:

```
local function gi(): integer | nil ... end
local n = gi();          print(n + 1)             -- passes
local m: integer = gi(); print(m)                 -- passes
local function f(x: integer) ... end; f(gi())     -- passes
print(("abc"):sub(1, gi()))                       -- passes
local s = gs(); print(s:upper())   -- string | nil: ERRORS (an index)
```

So option (b) from the original spec — an honest declaration — would
neither break the tree nor force a single call site to narrow. It is a
documentation change with a carried-patch maintenance tax and no
enforcement, so it is retired here. The upstream report (D5,
upstream-first) is worth filing against tl on its own; it is not this
slice.

**Option (a), a `to_integer(s): integer | nil, string` helper, is
retired for the same reason**: it would not force narrowing either, and
the sites that need a guard already have one.

**The 68 call sites, walked.** `git grep -n "math.tointeger" -- '*.tl'`
returns 68. Every one under `cosmic/**` either takes a `%d`-constrained
capture, guards the nil result, or documents a deliberate nil:

| site | input | verdict |
|---|---|---|
| `cosmic/ip.tl:134` | `(%d+)` capture, length-capped to 3 first | safe |
| `cosmic/ip.tl:265` | `(%d+)`, 2 chars max, `if not bits` guard | safe |
| `cosmic/sse.tl:145` | `value:match("^%d+$")`; nil already means "no retry directive" and every read is `if ev.retry_ms then` | safe (an overlong retry is silently ignored, which is the spec's behavior for a bad value) |
| `cosmic/tar.tl:111` | `(%d+) ` capture, `if not len or len <= 0 then break` | safe |
| `cosmic/url.tl:134` | `if not port or port < 1 or port > 65535` | safe |
| `cosmic/url.tl:280` | `^%d+$` plus the same range guard | safe |
| `cosmic/time.tl:272,273,298,332,333,354,366,367` | fixed-width `(%d%d)` / `(%d%d%d%d)` captures | safe |
| `cosmic/init.tl:41` | `... or 1` fallback | safe |
| `cosmic/embed/floor.tl:52` | `if n and n >= DOS_EPOCH` | safe |
| `cosmic/quicksand/proxy/http.tl:171` | `if not n then return nil end` | safe |
| `cosmic/quicksand/proxy/rules.tl:55` | nil is the documented "any port" | safe, but the signature lies — filed separately |
| **`cosmic/quicksand/proxy/http.tl:106`** | `(%d+)` **unbounded**, no guard | **defect** |
| **`cosmic/quicksand/proxy/http.tl:129`** | `(%d+)` **unbounded**, no guard | **defect** |

**The trigger.** `tonumber` of 19+ digits yields a float, and
`math.tointeger` of a float is nil:

```
math.tointeger(tonumber(string.rep("9", 18)))  -->  999999999999999999
math.tointeger(tonumber(string.rep("9", 19)))  -->  nil
```

Reproduced against a built `o/bin/cosmic` at `aaf4af95`:

```
local http = require("cosmic.quicksand.proxy.http")
local big = string.rep("9", 19)
print(http.parse_connect_target("example.com:" .. big))
--> example.com    nil          (declared `string | nil, integer`)
local uri = http.parse_absolute_uri("http://example.com:" .. big .. "/x")
print(uri.host, uri.port)
--> example.com    nil          (AbsoluteUri.port is declared `integer`)
print(http.parse_connect_target("example.com:443"))
--> example.com    443          (control)
```

`cosmic/quicksand/proxy/serve.tl:177` and `:225` take that port
straight into `rules.match(idx, host, port)` and then
`dial.dial(host, port, …)`, whose last step is
`unix.connect(skfd, ip, port)` with a nil where the binding declares an
integer. A nil port also reads to `rules.match` as "no port
constraint": it cannot match a port-specific rule (`s.port == port`
fails against nil), but it does match an any-port rule and then
proceeds to dial.

Neither parser validates the RANGE either: a 6-digit port converts
fine and flows through as `999999`. `cosmic/url.tl` already validates
`1..65535` at both its port sites; these two do not.

## Change

Make both parsers in `cosmic/quicksand/proxy/http.tl` refuse a port
they cannot represent, the way `cosmic/url.tl:134` and `:280` already
do. Measured now: `wc -l cosmic/quicksand/proxy/http.tl` is 324 (176
lines of headroom under the 500-line cap) and
`cosmic/quicksand/proxy/http_test.tl` is 190.

- `parse_connect_target` (`:103-107`): after
  `local h, p = t:match("^([^:]+):(%d+)$")`, convert with
  `math.tointeger(tonumber(p))` into a local, and `return nil` when the
  conversion yields nil or the value is outside `1..65535`. The
  function already returns `nil` for an unparseable target and the
  caller already answers `http.BAD_REQUEST` on it
  (`serve.tl:178-180`), so this needs no new failure path.
- `parse_absolute_uri` (`:126-131`): same conversion and same range
  test on the `hp:match("^([^:]+):(%d+)$")` port; `return nil` instead
  of building an `AbsoluteUri` whose `port` field is nil.
  `serve.tl:221-223` already answers `BAD_REQUEST` for a nil return.
- Add both cases to `cosmic/quicksand/proxy/http_test.tl`: a
  19-nines port and a `70000` port, for each of the two parsers,
  asserting nil; plus the `example.com:443` control asserting 443.

## Non-goals

- no change to `3p/tl/tl_patch.tl` — the honest-`math.tointeger`
  declaration is measured to buy nothing and is retired above; the
  upstream report is a separate item.
- no new `to_integer` helper, in `cosmic/string.tl` or anywhere. The
  measurement found no site that a helper would fix.
- no change to the other 66 `math.tointeger` sites — each is walked in
  the table above and each is safe.
- `cosmic/quicksand/proxy/rules.tl`'s `parse_rule: function(key:
  string): string, integer` returns nil in slot 2 by design and its
  declared type says otherwise; `match`'s `port: integer` parameter has
  the same lie. Both are real and both are OUT of this slice — filed
  as their own item.
- no change to `serve.tl` or `dial.tl`: the fix belongs at the parse
  boundary, and both callers already handle a nil parser return.
- `cosmic/sse.tl:145` is not touched — nil is that field's existing
  "unset" value and every read guards it.

## Acceptance

```
bin/cosmic --make ci
bin/cosmic --make test cosmic/quicksand/proxy/http_test.tl
```

- `ci: PASS`, quoted in the PR description.
- the new tests fail on `main` and pass on the branch — show both runs
  in the PR description.
- the diff touches only `cosmic/quicksand/proxy/http.tl` and
  `cosmic/quicksand/proxy/http_test.tl`.
- `wc -l cosmic/quicksand/proxy/http.tl` stays under 500.

## Enablement

none needed — the two sites are named by `file:line`, the trigger is a
one-line repro, the fix has an in-tree precedent to copy
(`cosmic/url.tl:134`), and both callers' existing nil handling is
quoted by line.

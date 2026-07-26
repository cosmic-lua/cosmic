# 006 — non-2xx fetch responses are hashed instead of reported

severity: medium
type: bug (diagnostics), robustness
area: `_make/fetch.tl`

## issue

`cosmic.fetch`'s `Result.ok` is transport-level only — it is true for *any*
HTTP status (see `cosmic/fetch/init.tl:207-214`; 2xx is a separate
`is_success()`). `_make/fetch.one()` checks only `result.ok`, so a 404 error
page proceeds to `hash.sha256_hex(result.body)` and fails as:

```
make: 3p/tl/tl.pin.tl: sha256 mismatch for https://…
  want <pin sha>
  got  <hash of an HTML error page>
```

— the most misleading possible diagnostic for the most common failure (a
typo'd version in a pin url).

## where

- `_make/fetch.tl:90-94` — `if not result.ok then` is the only status check.
- contrast `_build/build-fetch.tl:55` — the older fetcher checks
  `result.status ~= 200` explicitly.

## also missing vs the older fetcher

- no `maxresponse` cap (`_build`'s uses 100 MB) — an unexpectedly huge
  response is buffered whole.
- no retry (`_build`'s uses `max_attempts = 8`) — a transient network blip
  fails the verb.

## suggested fix

after the `ok` check, refuse non-2xx with the status in the message:
`"make: <pin>: <url>: HTTP <status>"`. add a `maxresponse` in the fetch
options and modest retries, matching `_build/build-fetch.tl` until the two
pipelines merge (see 030).

## test to add

a fetch test against a stub server (or injected fetcher) returning 404,
asserting the error message names the status, not a digest mismatch.

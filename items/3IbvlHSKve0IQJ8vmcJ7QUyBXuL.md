## Change

Evidence (2026-08-29): the fleet exhausted the account's shared GitHub
API quota (5,000 REST/hr, 5,000 GraphQL points/hr, per user across ALL
tokens) and landing two accepted PRs was blocked for most of an hour.
Measured 2026-08-30: gitboard's API surface is `_work/api.tl` (89
lines) whose `api()` discards `resp.headers` (ApiResult carries only
status+value, though `cosmic.fetch` returns headers — see
`cosmic/fetch/extras.tl:250,303-304`); the only call sites are
`gh.pull` (`_work/gh.tl:56,104`) and the workflow-runs GET
(`_work/lanes.tl:70`); `sync` invokes `lanes.at_sync` at
`_work/gitverbs.tl:425`. No cache convention exists in `_work/**`.

Make gitboard frugal with the shared quota, all inside `_work/`:

1. `api.tl`: return response headers in ApiResult; send
   `If-None-Match` from a cached ETag and reuse the cached body on 304
   (GitHub does not count 304s against the REST limit). Cache lives
   under the board checkout's `o/` (untracked, disposable) keyed by
   request path.
2. `lanes.tl`/`gitverbs.tl`: a freshness window — `sync` skips the
   workflow-runs GET when the last observation is younger than a bound
   (minutes; CI cadence), overridable by an env var for a forced
   fresh read. The skipped read prints nothing new; the lanes verdicts
   reuse the last observation.
3. `api.tl`: read `x-ratelimit-remaining`/`x-ratelimit-reset` off every
   response; when remaining is low, the OPTIONAL lanes observation is
   skipped with one printed notice instead of failing the verb, and a
   403/429 refusal names the reset time.
4. Stay REST-only (`api.tl` already is; keep it that way).

Tests beside the code in the existing seams (`gh_test.tl`,
`lanes_test.tl`, `api`'s own): 304 reuse, freshness skip, low-remaining
degrade — mutation-verify at least the 304 path. Watch the 500-line
cap on every touched file.

## Non-goals

No GraphQL. No new verbs. No change to which verbs call the API. No
committed cache files (o/ only).

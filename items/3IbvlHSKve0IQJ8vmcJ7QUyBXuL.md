Evidence (2026-08-29): the fleet exhausted the account's GitHub API
rate limit mid-flow — GitHub's primary limits are per user across ALL
tokens (5,000 REST requests/hr, a separate 5,000 GraphQL points/hr),
and every session, review subagent, MCP call, and gitboard verb draws
from that one pool. Landing two accepted PRs (#1534, #1535) was blocked
for most of an hour on rate-limit errors. gitboard's own contribution
is one lanes read per `sync` (`lanes.at_sync`, called at
`_work/gitverbs.tl:425`, one GET of workflow runs in `_work/lanes.tl:70`)
and one PR read per `verdict`/`done`/`take --pr` (`gh.pull`,
`_work/gh.tl:56,104`) — small per verb, but sync runs after nearly
every mutation in every concurrent session, all day.

Make gitboard frugal with the shared quota:

1. Conditional requests: send `If-None-Match` with a cached ETag on the
   lanes and pull GETs and reuse the cached body on 304 — GitHub does
   NOT count 304 responses against the REST limit, so a quiet board
   polls for free. Cache beside the checkout under o/ (never
   committed).
2. Freshness window on the lanes read: `sync` skips the workflow-runs
   GET when the last observation is younger than a bound (the lanes
   verdicts change on CI cadence, minutes, not seconds); a
   `--fresh`/env override forces it.
3. Read and respect the rate-limit headers (`x-ratelimit-remaining`,
   `x-ratelimit-reset`) already returned on every response: when
   remaining is low, degrade loudly (skip the optional lanes
   observation with a printed notice) instead of failing the verb; a
   403/429 with a reset header names the wait in the refusal.
4. Stay on REST: gitboard already speaks only REST (`_work/api.tl`);
   keep it that way — the GraphQL pool is what dried up first today
   (auto-merge enable is GraphQL-only and stayed blocked while REST
   merges succeeded).

Measure before building: count the API calls one `sync` and one
`verdict` actually make (the api module is the single chokepoint —
instrument or trace it), and re-measure after. Refine into
file-disjoint slices if 1–3 do not fit one PR.

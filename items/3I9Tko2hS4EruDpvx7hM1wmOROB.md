## Evidence

Refining G3's cast-reduction epic (board item 3HyArM3A, wave 4 "to_integer"), I
re-measured every `-- cast: number to integer`/hex/decimal `as integer` site in the
tree (2026-08-19, `git grep -n -- "-- cast: number to integer" -- "*.tl"` and the
hex/decimal sites in `cosmic/literal.tl`/`cosmic/url.tl`) and found every one of them
already follows the verify-then-cast idiom `fs.octal.tl` established: the string is
regex-captured as pure digits/hex (`%d+`, `%x%x`) or explicitly bound-checked
(`cosmic/literal.tl`'s `\u{}` codepoint) before the cast, so the cast is justified and
inherent, not a removable gap. Wave 4 as scoped in 3HyArM3A ("a shared `to_integer`
parser for ~37 hex/decimal/%d sites") does not describe anything live in the tree
today — see the wave-plan retirement note in 3HyArM3A's spec.

Looking past the `-- cast:`-tagged sites (which the census only ever measured) turned
up a different, UNTAGGED defect: `math.tointeger` is used across the tree to parse
untrusted numeric strings via the idiom `math.tointeger(tonumber(x))`, relying on
`math.tointeger` to turn a non-integral or nil `tonumber` result into nil. But
`_types/gentl.tl`'s generated declaration types `math.tointeger` as
`function(number): integer` — non-nilable — so the checker never asks these call
sites to narrow, and a malformed or non-integral input silently produces whatever
`math.tointeger` returns for it (nil, assigned into an `integer`-typed local) with no
compile-time or runtime signal. This is the same class of bug D24/AGENTS.md's "honest
nil" rule exists to prevent, just not reachable by the cast ratchet because it carries
no `as` and no `-- cast:` comment.

Sites (2026-08-19, `git grep -n "math.tointeger(tonumber(" -- "*.tl" | grep -v _test`):

```
cosmic/init.tl:41:  os.exit(math.tointeger(code or (err and 1 or 0)) or 1)
cosmic/ip.tl:134:    local v = math.tointeger(tonumber(octet))
cosmic/ip.tl:265:  local bits = math.tointeger(tonumber(bp))
cosmic/sse.tl:145:              current_retry_ms = math.tointeger(tonumber(value))
cosmic/tar.tl:111:    local len = len_str and math.tointeger(tonumber(len_str))
cosmic/time.tl:272-273, 298, 332-333, 354, 366-367 (8 calls across the RFC3339/HTTP-date parsers)
cosmic/url.tl:134, 280
```

9 call sites (`init.tl` is a slightly different shape — `code or ...` is already an
`integer | nil` in practice, lowest priority of the set) across 6 public `cosmic/*`
files, all parsing untrusted input (IP octets, SSE retry directives, tar header
lengths, RFC3339/HTTP timestamps, URL ports).

## Why this is a capture, not a slice

Fixing this needs a design decision this refinement pass should not make alone: either
(a) a new honest `to_integer(s): integer | nil, string` helper (natural home
undecided — `cosmic/string.tl` documents itself as "all functions are infallible", so
it cannot go there without a doc amendment) that each site calls and narrows, or (b) a
correction to `_types/gentl.tl`'s `math.tointeger` declaration to the true
`function(number): integer | nil` shape, which would turn every existing call site in
the tree (test files included) into a type error until narrowed — a much larger,
tree-wide forcing change. Which is right, and whether the 9 sites' current behavior
(most default to some fallback via `and`/`or` already) is even observably wrong today,
needs its own measurement pass per-site before this is sized as a slice.

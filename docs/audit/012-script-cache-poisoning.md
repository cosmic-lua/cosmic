# 012 — script cache in shared `/tmp` executes unverified planted code

severity: high on multi-user hosts; low on single-user
type: security
area: `cosmic/_script_cache.tl`, `cosmic/teal.tl`, `cosmic/searcher.tl`

## issue

the compile cache directory defaults to `/tmp/cosmic-tl-cache` — a
world-shared location — with no ownership, permission, or sticky-bit check.
`load_cached` returns whatever bytes sit at
`sha256(path .. "\0" .. content .. "\0" .. build_id) .. ".lua"`, and
`teal.compile_cached` → the searcher then `load()`s and executes them. the
cache key is fully computable by another local user for any known script
(path, content, and build id are all public), so user A can pre-plant
`<key>.lua` and user B's `cosmic script.tl` — or any `require()` of a `.tl`
module through the public `cosmic.searcher`, which every embedded artifact
installs at boot — executes A's Lua. no compile ever happens, no error.

the behavior predates this branch (moved from `lib/cosmic/cli/`), but the
branch widened its reach: the searcher is now public and ships in every
artifact's boot path.

## where

- `cosmic/_script_cache.tl:24-27` — cache dir default, no ownership check.
- `cosmic/_script_cache.tl` `load_cached` — returns planted bytes as a hit.
- `cosmic/teal.tl:457` (`compile_cached`) and `cosmic/searcher.tl:48,60` —
  consume and `load()` the result.

## failure scenario

shared CI runner or multi-user dev host: attacker computes the key for a
well-known script (e.g. a repo's `main.tl` at its standard checkout path),
plants a trojan `.lua` in `/tmp/cosmic-tl-cache`, victim runs the script,
attacker's code executes as the victim.

## suggested fix

per-user cache: `$XDG_CACHE_HOME/cosmic` (fallback
`/tmp/cosmic-tl-cache-<uid>` created 0700), and refuse (or bypass cache) if
the directory exists with wrong ownership or group/world-writable bits.
optionally include uid in the key as defense in depth. keep the env override
for tests.

## test to add

a script-cache test asserting the default dir is user-private (mode 0700,
owned by the caller), and that a pre-existing dir owned by another uid (or
mode 0777) causes bypass-or-refuse rather than a cache hit. the uid case
needs root to set up, so gate it; the mode case runs anywhere.

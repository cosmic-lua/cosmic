## Evidence

Measured 2026-08-22 while refining `3I9Tko2h`, against a build of main
`aaf4af95`: **Teal admits `T | nil` into every position except an
index.** Probes, each a whole file that `--check types` accepts:

```
local function gi(): integer | nil ... end
local n = gi();          print(n + 1)              -- passes
local m: integer = gi(); print(m)                  -- passes
local function f(x: integer) ... end; f(gi())      -- passes
print(("abc"):sub(1, gi()))                        -- passes
local function gs(): string | nil ... end
local t: string = gs();  print(t)                  -- passes
print(gs() .. "x")                                 -- passes
local s = gs(); print(s:upper())                   -- ERRORS (an index)
```

Only the last one is refused — `cannot index key 'upper' in variable
's' of type string | nil`. Assignment to a declared non-nil type, an
argument in a non-nil parameter position, arithmetic, and concatenation
all pass the nil straight through.

Two consequences worth a decision:

1. **The "honest nil" doctrine is enforced only at index sites.**
   AGENTS.md and D24 tell writers to declare `T | nil` and narrow, and
   the carried tl patch (`3p/tl/tl_patch.tl`) invests in making the
   guards a Lua programmer writes actually narrow. But a `T | nil` that
   is never indexed is never asked to narrow at all — it just becomes a
   runtime nil somewhere downstream. `3I9Tko2h`'s defect is exactly
   that shape: a nil port assigned into a field typed `integer` and
   carried to a C binding.
2. **Making a declaration honest can therefore be a no-op.** Measured
   in the same pass: a carried-patch entry rewriting tl's own
   `tointeger: function(any): integer` (`tl.lua:291` of the pinned
   v0.24.8) to `integer | nil`, both twins, refetched and rebuilt, left
   `bin/cosmic --make check` at `check: PASS (513 files)` — zero sites
   broke, and zero were forced to narrow.

What to do with this is a decision, not a slice. Candidate shapes:
report the nil-admission upstream (D5, upstream-first) and see whether
tl considers it intended; extend the carried patch to refuse
`T | nil` in non-index positions and measure the blast radius on this
tree; or amend the doctrine to say plainly what the checker does and
does not enforce, so writers do not over-trust a `| nil` annotation.
The tl `math.tointeger` declaration report rides along with whichever
is chosen.

**Attach under `3HyRcW05`** (the cast/typing epic) — it bears directly
on what the cast waves are worth, since a cast removed at a site the
checker never policed changes nothing about safety.

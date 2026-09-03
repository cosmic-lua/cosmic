## Evidence

Measured 2026-09-03 against `origin/main` (`96afd807`), checks run
under the pinned release (`o/bootstrap/cosmic`, the `bin/cosmic.pin`
binary).

The class is 8 rows: `_make/init.tl` 7, `cosmic/searcher_test.tl` 1
(`git show origin/main:docs/design/cast-sites.tsv | awk -F'\t' '$3=="dynamic name lookup"'`).
The earlier spec's premise — a "loosely typed row" from the registry —
is false. `by_name` is already typed nilable:

    git show origin/main:_make/init.tl | sed -n '71p;326p'
    local by_name: function(name: string): Verb | nil
    by_name = function(name: string): Verb | nil

    git show origin/main:_make/init.tl | grep -n "as Verb"
    143:  local v = by_name("build") as Verb -- cast: the registry defines it
    184:    local b = by_name("build") as Verb -- cast: the registry defines it
    246:      return stage.run_graph(by_name("fmt") as Verb, proj, paths, cosmic)
    251:      return run_against_stage(by_name("test") as Verb, proj, paths, cosmic)
    283:      return run_against_stage(by_name("example") as Verb, proj, paths, cosmic)
    291:      return run_against_stage(by_name("benchmark") as Verb, proj, paths, cosmic)
    300:      local v = by_name("coverage") as Verb -- cast: the registry defines it

So every one is `Verb | nil` → `Verb`: the proved-value-narrowing
shape #1646 closed elsewhere, not a dynamic lookup. The carried patch
narrows it without a cast — probe (`--check types`, pinned binary):

    local a = by_name("x"); assert(a, "registry defines it"); use(a)
    local b = by_name("x"); if not b then error("no") end; use(b)
    → Type check passed

The two nil-consuming callers stay nilable: `_make/init.tl:428`
(`local v = by_name(name)`, argv dispatch) and `_make/policy.tl:316`
(`if not (v is Verb) then` … "ci names a verb that does not exist").

The eighth site, `cosmic/searcher_test.tl:57-58`, casts a
`package.searchers` entry before `pcall`; the pinned stdlib types the
entries already — probe:

    for _, s in ipairs(package.searchers) do local ok, why = pcall(s, "x") end
    → Type check passed

Headroom: `git show origin/main:_make/init.tl | wc -l` → 498 (cap 500),
so no helper fits there; `_make/policy.tl` → 376, and `init.tl` already
requires it (`init.tl:30`) and hands it `by_name` (`init.tl:296`).

## Change

- `_make/policy.tl`: add and export on `PolicyModule`
  `must_verb(by_name: function(string): Verb | nil, name: string): Verb`:
  `local v = by_name(name)`, then
  `assert(v, "make: no verb " .. name) -- assert: the registry is literal data in _make/init.tl and every name passed here is a row it defines`
  (D30's infallible-by-type contract boundary; the trailing `-- assert:`
  satisfies `assert-justify`), `return v`.
- `_make/init.tl`: at the seven lines above replace
  `by_name("<x>") as Verb -- cast: …` with `policy.must_verb(by_name, "<x>")`.
  Net line count must stay ≤ 500 (`wc -l`); the replacement removes no
  lines and adds none.
- `cosmic/searcher_test.tl:57-58`: delete the `-- cast:` line and call
  `pcall(s, missing)` directly.
- `_build/casts_baseline.tl`: `_make/init.tl` row 7 → gone,
  `cosmic/searcher_test.tl` 1 → gone; run
  `bin/cosmic --make run _build/casts.tl --baseline` and commit.
- `docs/design/cast-sites.tsv`: run
  `bin/cosmic --make run _build/cast_sites.tl --reconcile`; the class
  `dynamic name lookup` ends with zero rows, and
  `_build/cast_sites_test.tl` requires every heading to have a row, so
  delete the `### dynamic name lookup` section from
  `docs/design/casts.md` (precedent: `git show cf416d85 -- docs/design/casts.md | grep '^-###'`
  → `-### proved-value narrowing`) and fix every prose mention
  (`git grep -n "dynamic name lookup" origin/main -- docs _build` lists them).
- `bin/cosmic --make ci` ends `ci: PASS`.

## Non-goals

The `E*`/`SIG*` constant lookups (`binding constant by name`, 5 rows)
are item `3ISJHfNY` — untouched here.

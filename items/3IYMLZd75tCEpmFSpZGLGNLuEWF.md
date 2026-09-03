## Change

Close all 12 `proved-value narrowing` cast sites, then repair the two
files that map them so `bin/cosmic --make ci` stays green.

Measured against `9fcfff3f` (2026-09-02) with the class filter the
item's own text points at:

```text
$ awk -F'\t' '$3=="proved-value narrowing"' docs/design/cast-sites.tsv
_cli/build/steps.tl	279	proved-value narrowing
_make/imports.tl	182	proved-value narrowing
_make/root.tl	67	proved-value narrowing
_make/root_test.tl	187	proved-value narrowing
_make/root_test.tl	234	proved-value narrowing
_make/root_test.tl	248	proved-value narrowing
_make/runverb.tl	144	proved-value narrowing
_perf/perf_test.tl	31	proved-value narrowing
cosmic/re.tl	200	proved-value narrowing
cosmic/searcher.tl	98	proved-value narrowing
cosmic/searcher.tl	324	proved-value narrowing
cosmic/string_test.tl	234	proved-value narrowing
```

`docs/design/cast-legality.md`'s independent, stricter probe already
confirms every one of these 12 is closable — its by-class table (line
71) reads `| proved-value narrowing | 12 | 12 | 0 |`: all 12 refused
under the "operand type the checker can already see into" rule, zero
allowed, so none has an operand that is genuinely opaque. That file is
a dated snapshot (`e0580f41`) and is not touched by this change — see
Non-goals.

### 1. The three `_make/root_test.tl` sites — `check.must`

The file already uses the target idiom once, at line 71:
`local cwd = require("cosmic.check").must(fs.cwd())`. Apply the same
rewrite, verbatim in shape, at the three cast sites:

```text
187:  local saved = fs.cwd() as string -- cast: cwd exists in a test
234:  local saved = fs.cwd() as string -- cast: cwd exists in a test
248:  local saved = fs.cwd() as string -- cast: cwd exists in a test
```

becomes, at each of the three lines:

```teal
local saved = require("cosmic.check").must(fs.cwd())
```

Do not add a top-level `local check = require("cosmic.check")` — the
file's own precedent at line 71 is the inline form; match it rather
than introducing a second style for the same call in the same file.

### 2. Seven sites the carried patch already narrows — delete the cast

`3p/tl/tl_patch/narrow.tl` carries the exact rules these seven sites
need, already shipped:

- `narrow-or-fallback` (line 374): `x or fallback` drops the nil
  member when the fallback can't itself be nil.
- `narrow-truthiness` (line 406) and `narrow-eq-nil` (line 130) plus
  `narrow-exit-register`/`narrow-exit-special` (lines 202, 214): a
  branch ending in `error(...)` is a registered terminator (it never
  returns), so `if not x then error(...) end` / `if x == nil then
  error(...) end` narrows `x` below the guard exactly like `return`
  does.

Delete the ` as T` and its justification comment at each site, leaving
the underlying expression as-is:

```text
_cli/build/steps.tl:279
  local abs = (fs.resolve(named) or named) as string -- cast: scalar fallback
  → local abs = fs.resolve(named) or named
```

```text
_make/imports.tl:181-182
  -- cast: `or` keeps the nil in the union
  local under = (fs.find(abs) or {}) as {string}
  → local under = fs.find(abs) or {}
```
(delete the standalone comment line 181 too — it justifies only the cast)

```text
_make/root.tl:67
  local hits = (fs.glob(cmd, pattern) or {}) as {string} -- cast: or keeps the nil union
  → local hits = fs.glob(cmd, pattern) or {}
```

```text
_perf/perf_test.tl:31
  for _, p in ipairs(paths as {string}) do -- cast: narrowed by the nil guard above
  → for _, p in ipairs(paths) do
```
(`paths` is narrowed non-nil by the `if paths == nil then error(...) end` guard three lines above)

```text
cosmic/searcher.tl:98
  local lua_code = code as string -- cast: nil ruled out by the guard above
  → local lua_code = code
```

```text
cosmic/searcher.tl:324
  local lua_code = code as string -- cast: nil ruled out by the guard above
  → local lua_code = code
```
(both `code` locals are narrowed non-nil by an `if not code then error(...) end` immediately above)

### 3. `cosmic/string_test.tl:234` — delete the cast, tl's own type already covers it

```text
232:  local function test_to_integer_runtime_nil_refuses_rather_than_throws()
233:    -- cast: tl types string.match as string; it is nil at runtime
234:    local n, err = str.to_integer(("abc"):match("^(%d+)") as string)
```

tl's stdlib declares `string.match`'s return as plain `string`
(non-nullable) — the same fact the comment states — so the expression
is already typed `string` before any cast; `as string` asserts nothing
the checker doesn't already believe. Delete line 233 and the
` as string` suffix on line 234:

```teal
local function test_to_integer_runtime_nil_refuses_rather_than_throws()
  local n, err = str.to_integer(("abc"):match("^(%d+)"))
```

Leave the three-line comment above the function (lines 229-231,
explaining the test's PURPOSE) untouched — only the `-- cast:` line
and the cast itself go.

### 4. Two sites proved by a fact the checker cannot trace — guard with `assert`

These two are proved by an invariant that spans two separate
expressions (a paired multi-return, or a second unrelated call), which
none of `narrow.tl`'s rules reach — they narrow a single guarded
variable, not a cross-call fact. `assert` on the value itself closes
both, using only vanilla tl `is`-narrowing plus (for the plain-nil
case) the carried `narrow-assert`/`narrow-assert-decl` rules (lines 72
and 102 of `narrow.tl`) — `must` is confirmed by `cosmic/check.tl`'s
own doc comment on `must` (line 164) not to be the only way to do this:
"Plain `assert` also narrows a `T | nil` here."

`cosmic/re.tl:197-200`:

```text
    -- the guard above took the failure path, where the union's string
    -- arm lives; a match always carries the capture table
    -- cast: captures, past the no-match/failure guard
    return {text = m, caps = caps as {string}}
```

`caps`'s declared union (from `regex:match`) also admits the `string`
engine-error spelling, which a plain `assert(caps, ...)` cannot rule
out (it only drops `nil`) — use the `is`-typed form, which narrows to
exactly `{string}` regardless:

```teal
    -- the guard above took the failure path, where the union's string
    -- arm lives; a match always carries the capture table
    assert(caps is {string}, "a match always carries the capture table")
    return {text = m, caps = caps}
```

`_make/runverb.tl:144`:

```text
  local self = file_of(proj, path) as File -- cast: resolve() proved it
```

`file_of` returns `File | nil` only, so a plain-nil `assert` suffices;
extract to a local first so the argument is a bare variable (the
patch's `narrow-assert` only fires on `node.e2[1].kind == "variable"`):

```teal
  local self = file_of(proj, path)
  assert(self, "resolve() proved it")
```

Do not change `resolve`'s signature to return the `File` directly
instead — it is registered verbatim as `run = runverb.resolve` in
`_make/law.tl:81`, so widening its return shape is a `_make.law`
change, not a cast-closure one.

Do not weaken any of the guards above to make a cast removable — if a
guard turns out not to narrow the way this spec expects, add the
narrowest correct guard/assert that does, never loosen the condition
that already runs.

### 5. Regenerate the two derived maps, in the same commit

After all 12 sites above are closed (no `as` token remains at any of
them):

```text
bin/cosmic --make run _build/casts.tl --baseline
bin/cosmic --make run _build/cast_sites.tl --reconcile
```

The first lowers `_build/casts_baseline.tl`'s twelve affected rows
(gated by `_build/casts_test.tl`). The second drops all twelve rows
from `docs/design/cast-sites.tsv` (gated by `_build/cast_sites_test.tl`,
which lands this diff's own regression check for free — `--reconcile`
only ever carries a class forward or drops a gone row, so both
regenerations are safe to run in either order).

### 6. Remove the now-empty class section from `docs/design/casts.md`

With all 12 sites gone, `docs/design/cast-sites.tsv` carries zero rows
for `proved-value narrowing`. `_build/cast_sites_test.tl`'s
`test_every_class_has_a_heading_and_every_heading_has_a_row` fails any
`### ` heading in `docs/design/casts.md` with no matching row — this
is a real, already-landed gate (`_build/cast_sites_test.tl:68-102`),
not a hypothetical one. Delete lines 160-176 of `docs/design/casts.md`
in full — the `### proved-value narrowing` heading, its class
description, its `_make/root.tl:67` exemplar quote, and its closing
"What closes it here" paragraph — so line 159's blank line is followed
directly by line 177's `### enum relation` heading. Nothing else in
the tree references this heading (`git grep -n 'proved-value
narrowing'` outside `docs/design/cast-sites.tsv` and
`docs/design/cast-legality.md`, neither of which this change touches,
turns up only this one heading).

## Non-goals

- **Do not touch `docs/design/cast-legality.md`.** It documents itself
  as a snapshot ("Measured against `e0580f41`... The counts are a
  snapshot... re-running the Method command against a later tree is
  how a later pass re-derives them") and nothing gates it against the
  tree. Its `proved-value narrowing` row goes stale by design, same as
  every other row will as sibling closure items land.
- **Do not touch `docs/goals.md`** or the G3 floor wording — that is a
  separate decision (`ke6byr5h`).
- **Do not reclassify** any site, and do not touch any other class's
  heading, exemplar, or sites in `docs/design/casts.md` /
  `docs/design/cast-sites.tsv`.
- **Do not modify `_build/casts_test.tl` or `_build/cast_sites_test.tl`**
  — the ratchets themselves are out of scope; this change only feeds
  them a smaller tree.
- **Do not widen `_make/runverb.tl`'s `resolve` signature** or touch
  `_make/law.tl` — see the note in section 4.

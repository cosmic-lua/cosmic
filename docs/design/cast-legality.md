# cast legality

Measured against `e0580f41` on 2026-08-31.

Stock tl's `as` performs no relation check: it discards the operand's
static type and returns the target type unconditionally, so `"hi" as
integer` and a cast between two unrelated records both type-check
clean today. `3p/tl/tl_patch/cast.tl` carries a prototype rule that
does check: **`x as T` is legal only when `x`'s static type is one the
checker cannot see into** — `any`, a userdata record (`is userdata` in
a `.d.tl` or elsewhere), or a type variable bound by the enclosing
generic. Every other cast either asserts a relation the checker could
verify itself, or contradicts one it already knows, so it is refused.

The rule is gated behind `COSMIC_CAST_LEGALITY=1`, read once per cast
at check time; unset (the tree's own `--make ci`), the checker is
byte-for-byte what pinned tl 0.24.8 ships. This document is the census
that patch produces when the flag is on, run over every cast this tree
carries today — evidence for `ke6byr5h`, the wording decision on G3's
"no escape hatches" clause. **It decides nothing.**

## Method

```text
COSMIC_CAST_LEGALITY=1 xargs -a <(git ls-files '*.tl' | grep -v '/testdata/') \
  o/bin/cosmic --check types --include-dir . 2>&1 | grep -c 'cast-legality:'
```

reports **135 refusals** with the rule on, zero with it off — nothing
here is refused today, matching `docs/design/casts.md`'s own two probes
(`"hi" as integer` / `A as B` for unrelated records; `a as A` / `a as
any`) which both pass clean on the pinned checker.

Two lines carry two refused casts each, so the site count is **133 of
the tree's 198 cast sites** (`docs/design/cast-sites.tsv`). The 209
this item's own text cites has since moved: `daab8101` ("Add
check.is_exposed and route the type-defeating test probes it fits")
routed 13 of the 26 type-defeating-test-probe sites through that helper
and added one new site (the helper's own cast), landing that class at
14 — exactly what this census counts below — with one more site closed
elsewhere in the tree since, for a net 209 → 198. The join is exact: every
refused `(file, line)` matches a row already in the committed site
inventory, because the patch reports at the "op" node's own position,
which parsing sets to the `as`/`is` keyword token
(`o/3p/tl/tl.lua:3410`) — the same token `_cli.lint.cast_lines` (and so
`cast-sites.tsv`) keys on. No line drifted, no refusal landed on a spot
the inventory does not already track.

**A refusal names the operand's type**, via tl's own `show_type`, e.g.:

```text
cosmic/sqlite/bind.tl:40:37: error: cast-legality: 'as' operand is record
metatable, a type the checker can see into -- only 'any', a userdata
record, or a generic type variable may be cast
```

which is what every classification below is read from — the message,
not a guess.

## By class

One row per class, `docs/design/cast-sites.tsv`'s 21, allowed/refused
under the rule:

| class | sites | refused | allowed |
| --- | ---: | ---: | ---: |
| userdata boundary | 23 | 2 | 21 |
| tl compiler surface | 18 | 6 | 12 |
| binding contract shape | 16 | 12 | 4 |
| type-defeating test probe | 14 | 12 | 2 |
| proved-value narrowing | 12 | 12 | 0 |
| enum relation | 11 | 11 | 0 |
| metatable access | 10 | 6 | 4 |
| function shape | 10 | 6 | 4 |
| container variance | 9 | 8 | 1 |
| numeric narrowing | 9 | 9 | 0 |
| dynamic name lookup | 8 | 8 | 0 |
| module surface record | 8 | 4 | 4 |
| generic T | 8 | 4 | 4 |
| decoded data shaping | 7 | 3 | 4 |
| record union after guard | 7 | 6 | 1 |
| incremental record construction | 7 | 7 | 0 |
| pcall return shape | 5 | 5 | 0 |
| binding constant by name | 5 | 4 | 1 |
| runtime capability probe | 5 | 5 | 0 |
| map view of a declared value | 4 | 3 | 1 |
| sqlite row column read | 2 | 0 | 2 |
| **total** | **198** | **133** | **65** |

Eight classes refuse every site (`proved-value narrowing`, `enum
relation`, `numeric narrowing`, `dynamic name lookup`, `incremental
record construction`, `pcall return shape`, `runtime capability probe`)
or all but one (`container variance`, `record union after guard`,
`binding constant by name`, `map view of a declared value`) — these are
classes `docs/design/casts.md` already calls closable ("what closes it
here" / "what closes it upstream"), so the rule is doing exactly the
job it is meant to: catching relation-losing casts the checker could
already rule on, in classes with a known fix. Only `sqlite row column
read` refuses nothing, because its two sites' operand is `any` (a `Row`
field read) and its target is a scalar — the textbook legal shape.

## The five floor classes

`docs/design/casts.md`'s floor — the classes with the verdict "why it
is a floor" — is where the rule's own premise is tested: an operand
"genuinely opaque" should sail through untouched. It mostly does, but
not cleanly, and the shortfall in each case has a name.

| class | sites | refused | allowed |
| --- | ---: | ---: | ---: |
| userdata boundary | 23 | 2 | 21 |
| type-defeating test probe | 14 | 12 | 2 |
| metatable access | 10 | 6 | 4 |
| generic T | 8 | 4 | 4 |
| runtime capability probe | 5 | 5 | 0 |
| **floor total** | **60** | **29** | **31** |

**Userdata boundary — 21 allowed, 2 refused, both cheap.**
`cosmic/embed/init.tl:103` casts `unix.opendir`'s result
(`Dir | nil, string` — a real union, per
`o/_types/types_gen/cosmo/unix.d.tl:2728`) straight to `EmbedDirHandle`,
*before* the nil guard two lines below it; the rule sees the union, not
the userdata member, and refuses. Guarding first (`if not raw then
return err end`) and casting the narrowed, non-nil `raw` costs nothing
and would make this one legal. `cosmic/fs/dir_test.tl:170` casts a
hand-built Lua table — a test double standing in for `unix.Dir` — and
the rule is right to refuse it: the double is not opaque, it is a
plain table the checker can see straight through, which is exactly
what a userdata-boundary cast is supposed to guarantee it never is.

**Generic T is not one shape.** Half its sites cast a value already
known to be opaque (a plain `any`, or the type parameter `T` itself) —
allowed. The other half cast a *concrete, checker-visible* table to
`T`, or a `T` through a concrete map view for iteration — refused,
correctly:

Allowed — the operand is `any`:

```text
-- cosmic/deep.tl:52
  return copy_impl(value, {}) as T
```

Refused, in the very next function of the same file — the operand is
`merge_impl`'s declared return, `{any: any}`:

```text
-- cosmic/deep.tl:121
  return merge_impl(base as {any: any}, override as {any: any}) as T
```

`copy_impl` returns `any`; `merge_impl` is declared `function({any:
any}, {any: any}): {any: any}` — a concrete map, not opaque, so the
outer `as T` here is refused where `copy<T>`'s was not. Widening
`merge_impl`'s return to `any`, matching `copy_impl`'s own declared
contract, is the entire repair — no signature callers see changes,
because the function is local and only `merge` calls it. The other two
refused sites (`cosmic/fetch/extras.tl:239`, `cosmic/fs/walk.tl:146`)
are the same shape: a freshly built or shallow-copied map cast to `T`,
not `T` itself.

**Metatable access is the confirmed gap.** `getmetatable` is not typed
`any` in pinned tl — it returns a record-shaped type — so the operand
is known and the cast is refused, at all four of its call sites plus
the two `blob_mt`-identity-compare sites in `cosmic/sqlite/bind.tl`
(the metatable *value*, not `getmetatable`'s result, is the non-opaque
operand there). The four allowed sites are each the *second* cast in
the same two-step idiom — reading a metamethod off the map the first
cast already produced, e.g. `mt["__close"] as function(any, any)` where
`mt` is `{string: any}` because the line above cast it there. Closing
the gap needs a wrapper declared to return `any` (or a widened
`getmetatable` binding) — the same push-opacity-into-a-declaration move
as `merge_impl` above, landing upstream in `cosmic-lua/cosmopolitan`'s
tl fork or in this patch set, not at any of the ten call sites.

**Type-defeating test probe confirms the predicted repair, exactly.**
The two allowed sites are `check.refuses` and `check.is_exposed`
themselves (`cosmic/check.tl:121,139`) — both cast an `any`-typed
parameter, which the rule allows outright. The twelve refused sites are
every place that still casts at the call site instead of routing
through one of those two helpers:

```text
-- cosmic/hash_test.tl:233
  local ok, err = pcall(hash.digest, "md4" as hash.Algo, "abc")
```

Rewritten as `check.refuses(hash.digest, "md4", "abc")`, the cast
disappears entirely — `"md4"` passes into `check.refuses`'s
`...: any` with no cast needed, and the one cast that remains is
inside the helper, on an `any` operand, which the rule allows. This is
the shape the item's own worked example predicted, confirmed at scale:
compression, not new work, closes this class under the rule.

**Runtime capability probe does not get the same repair, and this
corrects the item's framing.** Its five sites split into two shapes
the item did not distinguish:

- `cosmic/stream.tl:237` — `local dr = r as stream.DelimReader`, where
  `r: stream.Reader` is `stream.lines`'s own declared, PUBLIC parameter
  type. There is no private call site to push a cast out of: making
  this legal means widening `stream.lines`'s own signature to `r: any`,
  trading a typed public parameter for an opaque one — a materially
  bigger cost than adding a two-line internal helper, and arguably the
  wrong fix rather than a cheap one.
- The other four (`cosmic/quicksand/box/init.tl:86`,
  `cosmic/sandbox/init.tl:175,180,195`) are schema-drift probes —
  `(fs as {string: any}).deny` checking a fully-typed `Options` record
  for a field that was renamed or removed — structurally identical to
  the record-to-open-map sites below, not to the duck-typing probe
  above. Grouping all five under one "known repair" over-states how
  much of this class compresses for free.

## Record-to-open-map: expected refused, partly confirmed

The item's strongest prior — "every `as {any: any}` / `as {string:
any}` site is an unrelated cast with a fully known operand, refused and
wanted" — holds for the majority, not all, of the pattern:

```text
git ls-files '*.tl' | grep -v '/testdata/' \
  | xargs grep -n 'as {any: any}\|as {string: any}'
```

finds 53 occurrences; 8 are inside `*_test.tl` files that hold the
literal text as fixture *data* (a string written to a scratch file,
never a real cast in that file's own source — the same divergence
`docs/design/casts.md`'s Method section already documents for the `--
cast: ` grep). Of the **45 real, tracked sites** (31 in closable
classes, 14 in floor classes — the floor share shrank from the item's
cited 22 as `check.is_exposed` closed test-probe sites), **28 are
refused and 17 are allowed**. The 17 are not a rule bug: each one's
operand is already `any` before the map-cast is reached — a `tl
compiler surface` AST field, a `module surface record`'s `require()`
result, a `decoded data shaping` literal-parse value, the one allowed
`generic T` site above — so the map cast asserts nothing new the rule
would object to. The pattern is refused exactly where the *thing being
mapped* is a record the checker already has a shape for, and allowed
exactly where an earlier, unrelated cast (or an untyped seam) already
made the value opaque first. Which one a given site is turns out to be
a property of the class it sits in, not of the `{any: any}` / `{string:
any}` spelling alone.

## The cost side

Enabling the rule today, before any of this is fixed, would force **104
sites** — the 133 refused minus the 29 refused floor-class sites above
— across the sixteen non-floor classes `docs/design/casts.md` already
holds a documented closing mechanism for. This item does not check the
work board for which of those 104 already sit behind an open item
(`gitboard` is out of this item's scope), so the number is not "sites
with nobody assigned" — it is the size of the gap between "a class has
a known fix" and "the fix has landed," which is what the wording
decision has to weigh against enabling the rule now versus after a
drive-down pass. The five floor classes' 29 refusals are not part of
this count: `docs/design/casts.md` already prices them as the cost of
G3's floor question, separately from whatever `ke6byr5h` decides about
`as` itself.

## What this is not

Not enabled. `3p/tl/tl_patch/cast.tl`'s rule runs only under
`COSMIC_CAST_LEGALITY=1`; the tree's own `--make ci`, and every ordinary
`--check types`, is unaffected — verified by re-running the Method
command with the variable unset (zero `cast-legality:` lines). Not a
fix: no cast site in this tree is touched. Not a decision: G3's wording
is `ke6byr5h`'s call, made by amending `docs/goals.md`, not here.

The counts are a snapshot of `e0580f41`. They will drift as classes
close; re-running the Method command against a later tree is how a
later pass re-derives them.

## Goal

G3 — an honest type layer, no escape hatches. This item measures; it decides
nothing. Its output is the census the `ke6byr5h` wording decision needs if a
type-decided cast rule is to be one of the candidates.

## Change

Prototype a cast-legality rule in the carried tl patch set, run it over the tree,
and record what it refuses, by class.

### The rule to prototype

> `x as T` is legal only when `x`'s static type is one the checker cannot see
> into — `any`, a userdata declared in a `.d.tl`, or a type variable bound by the
> enclosing generic. Every other cast is refused.

Its two halves are each independently defensible: if the operand's type already
relates to the target the cast asserts nothing, and if it does not relate the cast
is a lie. Both are accepted silently today — measured, on the pinned checker:

```
$ cosmic --check types a.tl     # "hi" as integer, and A as B for unrelated records A, B
Type check passed: a.tl
$ cosmic --check types b.tl     # a as A (redundant), a as any (redundant widening)
Type check passed: b.tl
```

So `as` performs no relation check at all, and any rule here is an improvement over
the status quo rather than a tightening of an existing one.

### Where it goes

A new group beside the three the tree already carries — `3p/tl/tl_patch/cast.tl`,
alongside `ast_cache.tl`, `closure.tl`, `narrow.tl`. Patches are declared data
(exact `find`/`replace`, must match exactly once), per `_make/patch.tl` and
[D21](docs/decisions/d21-carried-tl-patch.md).

**The rule must not be enabled for the tree in this item.** Gate it behind a flag
or a checker mode so `--make ci` is unaffected; enabling it is a later item that
the census argues for.

### What to produce

A census, written where the existing cast evidence lives (`docs/design/casts.md`
and `docs/design/cast-sites.tsv` carry the current classification of 209 sites into
21 classes):

- every refusal the rule produces over the tree, joined to the site's existing
  class, so each of the 21 classes gets a refused/allowed count;
- the five floor classes called out separately — type-defeating test probe (26),
  userdata boundary (22), metatable access (10), runtime capability probe (10),
  generic T (8) — since whether the rule preserves the floor is the whole question;
- a count of sites the rule refuses that no drive-down item covers, which is the
  cost side: those become new work the wording decision has to price.

### What is already known, and what the census must check

Reasoned from sampled sites, not from type analysis — confirming or correcting
these is the point of the item:

- **Expected allowed.** Userdata boundary (22) and generic T (8): the operand is
  genuinely opaque, which is exactly what the rule tests for.
- **Expected refused, and wanted.** Every `as {any: any}` / `as {string: any}`
  site — **53 of 209**, of which 31 sit in closable classes and 22 in floor
  classes. Record-to-open-map is an unrelated cast with a fully known operand.
- **Expected refused, with a known repair.** The test probes (26) and capability
  probes (10). A helper whose parameters are `any` removes the call-site cast
  entirely, leaving one cast inside the helper whose operand is `any` — which the
  rule allows. Measured:

  ```teal
  local function refuses(f: any, v: any): boolean
    local fn = f as function(any)          -- from `any`: allowed
    return not (pcall(fn, v))
  end
  print(refuses(needs_good, "not a record"))   -- call site: no cast, type-checks
  ```

  This is the same compression the board's probe-helper items already ask for; the
  rule would force it rather than request it.
- **A known gap.** Metatable access (10) is NOT covered. `getmetatable` is not
  typed `any` — it returns something record-shaped, so the cast's operand is known
  and the rule refuses it:

  ```
  $ cosmic --check types c.tl      # local m: {any: any} = getmetatable(a)
  c.tl:5:35: error: in local declaration: m: can't match a record to a map with
  non-string keys
  ```

  Closing it means declaring a wrapper that returns `any` — the same
  push-opacity-into-a-declaration move — which the census should price as a
  prerequisite rather than assume away.

## Non-goals

- **Does not enable the rule.** No tree-wide gate, no `--make ci` change.
- **Does not fix any cast site.**
- **Does not decide G3's wording.** That is `ke6byr5h`; this item gives it numbers.
- No change to `_build/casts.tl` or its baseline.

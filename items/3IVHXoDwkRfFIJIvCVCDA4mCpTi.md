## Evidence

The Teal checker accepts `return nil` from a function whose declared
return type is a bare non-nil type, and then lets callers index the
result. Measured against the tree's own binary (built from `main` at
`54aa87df`):

```teal
local function f(x: string): string
  if x == "" then
    return nil
  end
  return x
end
local out = f("a")
print(#out)
```

```
$ o/bin/cosmic --check types /tmp/nilret.tl
Type check passed: /tmp/nilret.tl
```

Both halves pass: the `return nil` against `: string`, and the `#out`
on a value the checker believes is a `string`. So a function can
declare an infallible contract, return nil anyway, and hand every
downstream caller a value the checker will never ask them to narrow.

**This is the inverse of the gap G3 is already chasing.** The known
hole is that an unnarrowed `T | nil` is DEMANDED only at an index
(`docs/guides/checking.md`, pinned in `cosmic/teal_narrowing_test.tl`).
This one is upstream of that: the union never forms in the first
place, because the declaration says it cannot. Every tool the project
built for honest nil — the narrowing patch, `check.must`, the
`fallible-returns` lint — operates on a type that admits nil, and none
of them fires when the annotation simply lies.

**It is reachable in practice, not a curiosity.** Found while reviewing
whilp/cosmic#1461, where `_work/gitverbs.tl`'s `base_refusal` declares
`: string`, returns `nil` on its happy path, and carries a doc comment
that correctly says `@return string | nil`. The author wrote the right
type in prose and the wrong one in the signature, `--make ci` passed,
and the only thing standing between that signature and a latent nil
was the single call site happening to narrow with `if stale then`.
That PR is fixing its own instance; the hole stands.

## What this item must settle

1. **Whether the checker can be made to refuse it**, and at what cost:
   whether this is a tl upstream behaviour, something the carried patch
   set (`3p/tl/tl_patch/`, mechanism in `_make/patch.tl`) can close as
   a sixth group, or something only a lint can see. The patch route is
   the one that would make the guarantee real rather than advisory.
2. **The tree-wide count**, before choosing: how many existing
   `return nil` sites sit under a bare non-nil declared return. That
   number decides whether this lands as a checker change with a sweep
   behind it or as a ratcheted lint. Nothing measured yet — the count
   is the first job.
3. **How it composes with 3IPXRRd2** (strict nil-flow mode, in `plan`,
   blocked). Strict mode makes the checker DEMAND narrowing at every
   non-nil sink; it does nothing about a declaration that never admits
   nil, so the two are complementary rather than alternatives, and
   whichever lands first should say so.

A ratcheted lint over `return nil` under a non-nil signature is the
cheap shape and is probably where this starts; the patch is the honest
one. The choice is this item's to make from the count.

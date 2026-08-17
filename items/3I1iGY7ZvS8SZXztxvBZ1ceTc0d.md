Imported from whilp/cosmic#1235.

## Goal
G5 — adversarial verification. `_fuzz` is the first consumer; a seedable
generator is what makes its replay promise hold under composition.

## The gap

`_fuzz/driver.tl` seeds `math.random` once from `FUZZ_SEED` and promises
that a failure is replayable: rerun with the reported seed and the loop
reaches the same input at the same iteration. Its own doc comment states
the limit — reproducibility holds only while generators draw from
`math.random`, because `cosmic.rand` is a CSPRNG and deliberately cannot
be seeded.

`math.random` is a single global stream, which makes that promise weaker
than it reads. Anything else that draws from it during a property run
consumes from the same stream and desynchronizes the replay. That is not
hypothetical — there is already one such caller in the library:

```facts
$ grep -rn &#39;math\.random&#39; cosmic/ --include=*.tl | grep -v _test | grep -v _example
cosmic/fetch/init.tl:286:      math.random() * math.min(max_delay_ms, base_delay_ms * 2 ^ (attempt - 1))))
$ wc -l &lt; cosmic/rand.tl
150
```

So a future fuzz property that exercises `fetch`&#39;s retry path — exactly
the kind of untrusted-input surface G5 names — would silently break the
replay guarantee of every property that runs after it in the same
process. The failure mode is the worst kind: the reported seed simply
does not reproduce, and nothing says why.

## What to decide (why this is `work:plan`, not `work:ready`)

The shape is constrained by
[D22](docs/decisions/d22-infallible-csprng.md), which settled that the
CSPRNG surface is infallible and treats a broken kernel CSPRNG as
unrecoverable. A seedable generator must not weaken that, so the open
questions are:

1. **Where it lives.** A separate module, or a new record inside
   `cosmic.rand`? D22&#39;s reasoning suggests the seedable generator must
   be impossible to confuse with `rand.bytes`/`rand.int` at a call site
   — a caller reaching for entropy must not get a reproducible stream by
   accident. That argues for a named, explicitly-insecure constructor
   returning an object, never a module-level `rand.seed()` that
   retroactively changes what the existing infallible functions do.
   Note `rand.insecure64()` already establishes the `insecure` naming
   precedent for the non-crypto half.
2. **Object or global.** An object with its own state (`local rng =
   rand.insecure_source(seed)`) gives each property an independent
   stream and fixes the composition hazard above; a seeded global
   repeats `math.random`&#39;s problem with better branding.
3. **The algorithm and its stability.** Whatever is chosen, the byte
   stream for a given seed becomes a compatibility surface — a recorded
   fuzz seed is worthless if the generator&#39;s output changes between
   releases. This needs an explicit stability statement (and probably a
   test that pins the first N outputs for a fixed seed), or an explicit
   statement that it is NOT stable across releases and seeds are only
   good within a build.
4. **Whether it needs a decision record.** If it lands as a second,
   deliberately-insecure surface beside an infallible CSPRNG, that is a
   tradeoff of the kind `docs/decisions/` exists for, and probably an
   amendment to D22 rather than a new record.

## Non-goals

- Do not make `rand.bytes`, `rand.int`, `rand.float`, `rand.token`, or
  `rand.shuffle` seedable, and do not add a module-level seed that
  changes their behavior. D22&#39;s contract on those is frozen.
- Not a change to `cosmo.*`; `cosmo.Rand64` and `cosmo.GetRandomBytes`
  stay as they are unless a follow-up slice establishes a need.
- Not a rewrite of `_fuzz/driver.tl`&#39;s public shape — the driver&#39;s
  `Options`/`run` contract and its failure-message format stay; only
  where it draws randomness from would change.

## Follow-on

Once this exists, `_fuzz/driver.tl` should hand each property its own
seeded source rather than seeding the global, and its doc comment&#39;s
reproducibility caveat gets replaced by the real guarantee. That is a
separate slice, blocked by this one.

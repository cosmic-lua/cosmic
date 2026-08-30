## Goal

G3 — an honest type layer, no escape hatches. `docs/design/casts.md`
classifies the tree's 214 justified `as` casts into 21 disjoint
classes; this is the **type-defeating test probe** class, 26 sites, the
largest of the 21. Files: `cosmic/fd_read_test.tl` 3;
`cosmic/hash_test.tl` 3; `cosmic/log_test.tl` 3;
`cosmic/quicksand/box/merge_test.tl` 3; `cosmic/sandbox/init_test.tl` 3;
`cosmic/check_assertions_test.tl` 2; `cosmic/string_test.tl` 2;
`cosmic/check.tl` 1; `cosmic/compress_test.tl` 1;
`cosmic/fs/traps_test.tl` 1; `cosmic/fuzzy_test.tl` 1;
`cosmic/quicksand/init_test.tl` 1; `cosmic/quicksand/proxy/rules_test.tl`
1; `cosmic/rand_test.tl` 1. The class's verdict in the census is **why
it is a floor**: a test that proves a runtime guard refuses input the
type forbids must first defeat the type, so the cast cannot be deleted
without deleting the test. It is compressible rather than closable.
Full class description and the tie-break against neighbouring classes
are the `### type-defeating test probe` section of
`docs/design/casts.md`; the per-site list is `docs/design/cast-sites.tsv`
filtered on that class name (`grep "type-defeating test probe"
docs/design/cast-sites.tsv` — 26 rows, verified against the file
counts above).

## Change

Verified against the tree (commands below): of the 26 sites, only 13
actually match either helper's mechanical shape. The other 12 —
throw-based probes, boolean-effect probes, and probes that test
tolerance/pass-through rather than refusal — do not fit `check.refuses`
or a presence check no matter how they're routed; see Non-goals. This
item closes the 13 that do fit, plus adds the second helper.

**1. Add `check.is_exposed` to `cosmic/check.tl`.** Place it beside
`refuses` (after its definition, ~line 133). Same shape as `refuses`:
takes the module through `any` so the probe needs no `{string: any}`
view of its own.

```teal
--- Report whether a module exposes a member by a given name, past
--- what its declared type carries — a removed export, a retired
--- alias, a name that should not resolve.
--- @param module any The module (or record) to probe
--- @param name string The member name to look up
--- @return boolean True when `module[name]` is non-nil
local function is_exposed(module: any, name: string): boolean
  -- cast: probe module surface for a name its declared type may not carry
  return (module as {string: any})[name] ~= nil
end
```

Wire it into `record CheckModule` (line 318, beside `refuses:
function(f: any, ...: any): string`) and into the `M` table (line 336,
beside `refuses = refuses`). This is the class's second library cast;
`check.refuses`'s own cast (`cosmic/check.tl:121`) is the first — the
census's floor of "two casts, one per helper" is these two.

Add tests mirroring the existing `-- refuses: one untyped call, a typed
message back` section of `cosmic/check_assertions_test.tl` (lines
384–409, 3 tests): a `-- is_exposed: ...` section with a present-member
case and an absent-member case, using a small local test table (not a
real `cosmic.*` module) the way the `refuses` tests use a local
`probe` function. `cosmic/check_assertions_test.tl` is 409 lines; this
adds well under the 500-line cap.

**2. Route the two `check.refuses`-shaped invalid-input sites.**
Verified return shapes: `hash.hash_password`
(`cosmic/hash.tl:188`) is `string | nil, string`; `sandbox.apply`
(`cosmic/sandbox/init.tl:295`) is `Availability | nil, string` — both
match `refuses`'s nil-on-failure contract exactly, so both drop their
manual cast entirely (args pass through `refuses`'s own `...: any`,
no per-site cast needed):

- `cosmic/hash_test.tl:151` (`test_password_invalid_variant`): replace
  `local bad = {variant = "invalid"} as hash.Options` +
  `hash.hash_password("password", bad)` + the two manual asserts with
  `local err = check.refuses(hash.hash_password, "password", {variant = "invalid"})`
  then `assert(err:match("invalid variant"), ...)`.
- `cosmic/sandbox/init_test.tl:48` (`local apply_any = sandbox.apply as
  function(any): boolean, string`, reused at lines 50–89 across 7
  calls in one test): drop the cast and the local; replace each
  `apply_any(x)` call with `check.refuses(sandbox.apply, x)`, keeping
  each call's existing assertion on the returned message.
- `cosmic/sandbox/init_test.tl:116` (a second, separate `apply_any`
  cast, used once at line 117 in a different test): same treatment —
  `check.refuses(sandbox.apply, {sys = {promises = all .. " not_a_promise"}})`.

**3. Route the absent/present-surface sites through `is_exposed`.**
Verified via `grep -n "cast:" <file>` per file:

- `cosmic/compress_test.tl:157` (`local m = compress as {string: any}`,
  3 asserts): replace with 3 calls to `not check.is_exposed(compress, "deflate")`
  etc.
- `cosmic/fuzzy_test.tl:79` (`local f = fuzzy as {string: any}`): the
  file has no `check` import yet — add `local check =
  require("cosmic.check")`; replace with `not
  check.is_exposed(fuzzy, "levenshtein")`.
- `cosmic/quicksand/init_test.tl:170` (`local q = quicksand as {string:
  any}`; `check` already imported): replace with `not
  check.is_exposed(quicksand, "Box")`.
- `cosmic/sandbox/init_test.tl:21` (`local sa = sandbox as {string:
  any}`, 2 asserts: `plan_landlock`, `available`): replace both with
  `not check.is_exposed(sandbox, "plan_landlock")` /
  `not check.is_exposed(sandbox, "available")`.
- `cosmic/string_test.tl:30` and `:32` (two separate inline
  `(str as {string: any})` casts, `upper`/`lower`): the file has no
  `check` import — add it; replace each with
  `not check.is_exposed(str, "upper")` / `"lower"`.
- `cosmic/fs/traps_test.tl:11` (`local fsa = fs as {string: any}`,
  `check` already imported): every other `fsa` use in the file —
  verified by `grep -n "fsa\b" cosmic/fs/traps_test.tl`: lines 120,
  121, 201, 216 (a loop over a `retired` name list), 226 (a loop over
  a `live` name list), 228, 229, 230 — becomes a `check.is_exposed(fs,
  name)` call (negated for the retired/absent checks, bare for the
  live/present checks — the `live`-loop's current `type(fsa[name]) ==
  "function"` narrows to presence-only, which is the helper's
  contract; every name in that list is in fact a function today, so
  nothing this test protects gets weaker). Drop the `fsa` local
  entirely. Update the file's header comment (lines 1–5, "except for
  the one removed-surface probe (fsa)...") to match — it no longer
  applies once `fsa` is gone.
- `cosmic/fd_read_test.tl:101` (`(cfd as {string: any}).sync == nil`):
  replace with `not check.is_exposed(cfd, "sync")`.
- `cosmic/fd_read_test.tl:102` and `:104` (reading `fs.sync_all` through
  a `{string: any}` view, then casting it back to `function()` to call
  it): drop both casts — `fs.sync_all` is already declared on the
  typed `fs` record (`cosmic/fs/init.tl:176`, `sync_all:
  function()`), so `type(fs.sync_all) == "function"` and `fs.sync_all()`
  need no cast or helper at all.

**4. Regenerate the two ratchets and commit the results** (in this
order, both are gated by `--make ci`):

```
bin/cosmic --make run _build/casts.tl --baseline
bin/cosmic --make run _build/cast_sites.tl --reconcile
```

The first rewrites `_build/casts_baseline.tl`'s per-file counts (down
for every file touched above, up by one for `cosmic/check.tl`). The
second drops the closed rows from `docs/design/cast-sites.tsv` and
carries the rest forward; `--reconcile` needs no new classification
since no site here is new, only closed. `_build/casts_test.tl` and
`_build/cast_sites_test.tl` fail on a stale baseline/tsv, so `--make
ci` is the gate that proves this step wasn't skipped.

**5. Update `docs/design/casts.md`'s `### type-defeating test probe`
section** (lines 89–104): it currently says "`check.refuses` is the
shared helper for the invalid-input half and carries the class's one
library cast" — name `check.is_exposed` alongside it as the
absent-surface half's helper, and change "one library cast" to "two."

Gate: `bin/cosmic --make ci` (fmt, check, example, lint, coverage) —
the new cast in `check.tl` needs its own `-- cast:` justification
(enforced by lint), and every routed site must still pass its test.

## Non-goals

These 12 sites (verified return-shape/behavior below) stay as
hand-written casts — neither helper's contract fits them, and
generalizing either helper to also cover them is a separate design
question this item does not take on:

- `cosmic/hash_test.tl:236`, `cosmic/hash_test.tl:271` (`hash.digest`,
  `hash.hmac` on an unknown algorithm): both **throw** on this input
  (`cosmic/hash.tl:100`, `:134`, each marked `-- throws: ... contract
  violated through a cast`), tested via `pcall`. `check.refuses` calls
  its function directly and inspects a `(value, err)` return; a throw
  propagates through it uncaught.
- `cosmic/rand_test.tl:95` (`rand.int(1.5, 3)`): `rand.int` returns a
  bare `integer` (`cosmic/rand.tl:51`, infallible by type) and throws
  on this input; same mismatch.
- `cosmic/log_test.tl:103`, `:114`, `:163` (`log.set_level`, `log.log`,
  `log.syslog_output` on a smuggled `Level`): `set_level` returns
  `boolean, string` (`cosmic/log.tl:186`) — a *false* value is not
  `nil`, so `check.refuses`'s `value ~= nil` check misreads a genuine
  Fallible-Effect refusal as a call that "returned a value." `log` and
  `syslog_output` (`:144`, `:98`) return nothing at all — both tests
  assert the garbage level is silently dropped, not refused with a
  message, so there is no `(value, err)` to inspect.
- `cosmic/quicksand/proxy/rules_test.tl:125`
  (`rules.auth_header(true as rules.ProxyRule)`): the function returns
  bare `nil` on this input (`cosmic/quicksand/proxy/rules.tl:195`) —
  no second return at all. `check.refuses` requires a non-nil,
  non-empty error message to count as a refusal; this is a
  pass-through-does-nothing test, not a refusal.
- `cosmic/quicksand/box/merge_test.tl:101`, `:151`, `:152`: `merge`
  returns a bare `types.BoxOptions` (`cosmic/quicksand/box/merge.tl:129`,
  infallible — it cannot fail). These sites test that an *unknown* key
  survives the merge (tolerance, the opposite of refusal) and inspect
  the merged result generically; neither helper applies.
- `cosmic/check_assertions_test.tl:101`, `:321`: these cast to exercise
  `check.not_equal` and `check.must` themselves across mismatched
  generic types — testing `check.tl`'s own assertions, not a
  `cosmic.*` module's runtime guard. Out of scope by construction.

The 26-site count in the title and Goal is the census class size, not
this item's scope — `_build/casts_baseline.tl` and
`docs/design/cast-sites.tsv` will still carry these 12 rows after this
lands.

## Goal

G3 — an honest type layer, no escape hatches. From the census in
`docs/design/casts.md`: the **enum relation** class, 11 sites. Files:
`cosmic/compress_test.tl` 3; `cosmic/hash.tl` 3; `cosmic/sys_test.tl`
2; `_fuzz/compress_fuzz_test.tl` 1; `cosmic/fetch/init.tl` 1;
`cosmic/sys.tl` 1. The shape is an enum value used where a plain
`string` is wanted, or one enum's word set used where a wider enum is
declared even though every word of the narrow set is a word of the wide
one — `CompressFormat` nesting inside `DecompressFormat` is the clean
example.

**Correction from this refinement, with commands run against this
tree's own pinned tl (`o/3p/tl/tl.lua`, v0.24.8, already fetched and
built as `o/bin/cosmic` in this checkout):** only HALF of the census's
"what closes it upstream" verdict holds.

- The subset half is real and missing. `tl.lua`'s
  `TypeChecker.subtype_relations["nominal"]["nominal"]` resolves two
  differently-named nominals and, when both resolve to `enum`, has no
  branch that compares their word sets — it falls straight through to
  the `are_same_nominals` failure. Confirmed by hand:
  ```
  $ cat > /tmp/t2.tl <<'EOF'
  local enum CompressFormat "zlib" "gzip" "raw" end
  local enum DecompressFormat "zlib" "gzip" "raw" "auto" end
  local function decompress(f: DecompressFormat) print(f) end
  local function widen(f: CompressFormat) decompress(f) end
  EOF
  $ o/bin/cosmic --check types --include-dir . /tmp/t2.tl
  /tmp/t2.tl:19:14: error: argument 1: CompressFormat is not a DecompressFormat
  ```
  This is the real gap this item closes.

- **The "every enum is a subtype of `string`" half already exists in
  tl 0.24.8 — it is not a missing rule.** `tl.lua` line ~9802:
  ```
  ["enum"] = {
    ["string"] = compare_true,
  },
  ```
  reached through `subtype_nominal` for any `enum`-backed nominal, so
  an enum value is already legal wherever a plain `string` is wanted.
  Confirmed by hand (no patch, no cast):
  ```
  $ cat > /tmp/t1.tl <<'EOF'
  local enum HostOs "linux" "macos" end
  local function host_os(): HostOs return "linux" end
  local s: string = host_os()
  print(s)
  EOF
  $ o/bin/cosmic --check types /tmp/t1.tl
  Type check passed
  ```
  So this rule buys nothing for any of the 11 sites. Tracing what
  those sites actually need: `cosmic/sys_test.tl:14`/`:29`
  (`sys.host_os() as string`) are not blocked by assigning the enum to
  a `string`-typed local — they are blocked one line later, comparing
  that local against `os_name:lower()` (a non-literal `string`) with
  `==`. Removing the cast and re-checking the file directly shows the
  real error:
  ```
  $ o/bin/cosmic --check types --include-dir . /tmp/sys_test_nocast.tl
  ...:15:18: error: string is not a member of HostOs
  ...:30:18: error: string "xnu" is not a member of HostOs
  ```
  `subtype_relations["string"]["enum"]` (tl.lua ~9805) already allows a
  `string` to satisfy an enum, but only when the string is a *compile-time
  literal* found in the enum's word set (`if not a.literal then return
  false ...`); `os_name:lower()` is a runtime value, so it can't be
  proven a member and the comparison is refused regardless of the
  enum-subtype-of-string rule. The other production sites in this
  class are the same shape in reverse — a plain `string` (an untyped
  binding return, a `string.upper()` result, a guard-narrowed value)
  cast INTO a narrower enum: `cosmic/hash.tl:104,141` (`cosmo.CryptoHashName`,
  whose word set is uppercase and disjoint from `Algo`'s lowercase
  one — not even a subset relation), `cosmic/sys.tl:46`,
  `cosmic/fetch/init.tl:214`, `cosmic/hash.tl:203`, and
  `cosmic/compress_test.tl:139` (`DecompressFormat` narrowed by a
  `~= "auto"` guard down to `CompressFormat`'s exact word set). None of
  these are the enum-subset-is-subtype relation, and none are fixed by
  either named rule; closing them needs a guard-based literal-narrowing
  mechanism (or, for `hash.tl:104/141`/`fetch/init.tl:214`, may not be
  soundly closeable by a checker rule at all — they cross from
  genuinely untyped runtime data into a fixed enum). That is not this
  item's scope.

Net: of the 11 sites, only 3 are the enum-subset-is-subtype relation
(`_fuzz/compress_fuzz_test.tl:76`, `cosmic/compress_test.tl:24`,
`cosmic/compress_test.tl:36` — all `CompressFormat` → `DecompressFormat`),
and this item does not even remove those three (see Change: the
cold-build rule forces the patch and the cast removal into separate
PRs). The other 8 sites stay open; they are not this item's job and no
future item should reach for "every enum is a subtype of `string`" to
close them, because that rule is already in tl.

## Change

Add exactly one new tl subtyping rule as a carried patch entry, and
nothing else in the tree that depends on it. No cast site changes in
this PR — see Non-goals for why.

1. **New file `3p/tl/tl_patch/enum.tl`**, in the exact shape of the
   existing `3p/tl/tl_patch/narrow.tl` (module doc comment describing
   the group, `_make/patch.tl` mechanism note, one `return { [name] = {
   file, find, replace, note }, ... }`), one entry:

   - name: `enum-subset-is-subtype`
   - `file = "tl.lua"`
   - target: `TypeChecker.subtype_relations["nominal"]["nominal"]` in
     `tl.lua` (pinned v0.24.8; lands at `o/3p/tl/tl.lua` after
     `bin/cosmic --make fetch`) — the function starting
     `function(self, a, b) local ok, errs = self:are_same_nominals(a, b)`
     around line 9767. After it resolves `ra`/`rb` via
     `self:resolve_nominal`, and before the final `return ok, errs`
     that reports the original mismatch, add: when `ra.typename ==
     "enum"` and `rb.typename == "enum"`, `ra` is a subtype of `rb`
     when every key of `ra.enumset` is also a key of `rb.enumset` (a
     `{string:boolean}` word set, confirmed by its existing use at
     `tl.lua` line ~9811 and ~9896) — return `true` in that case,
     otherwise fall through to the existing `return ok, errs`. This is
     a pure widening (a comparison that used to fail now succeeds in
     one more case, nothing that used to succeed can stop); write the
     `note` field citing this board item and the two commands above.
   - Locate the exact anchor text on the pinned source you fetch — do
     not assume the line numbers here are byte-exact; `_make/patch.tl`
     fails loudly if `find` doesn't match exactly once, which is the
     re-audit signal if it doesn't.

2. **Tests, in `3p/tl/tl_test.tl`** (currently 107 lines, well under
   the 500-line cap), following the file's own
   `tl.process_string(src, false, nil, chunkname)` /
   `result.type_errors` pattern already used by
   `test_new_env_checks_like_the_parse_path`. Three cases, each
   asserting on `#result.type_errors`:
   - a subset enum (word set `{"zlib","gzip","raw"}`) passed where a
     superset enum (`{"zlib","gzip","raw","auto"}`) is declared —
     `0` type errors (the CompressFormat/DecompressFormat shape,
     mirroring the real production sites without touching them).
   - the reverse — the superset enum passed where the subset enum is
     declared — still `1` type error (proves this is a genuine subset
     check, not blanket enum-to-enum compatibility; this is also
     exactly the shape `cosmic/compress_test.tl:139` needs and must
     keep needing a cast).
   - two same-size enums with disjoint words — still `1` type error
     (proves an unrelated enum pair stays rejected).

3. **Correct `docs/design/casts.md`'s `### enum relation` section**
   (the "What closes it upstream" paragraph and its `hash.tl:104`
   exemplar are the source of the wrong "both rules, 11 sites" claim
   this refinement found): state that only the subset relation is a
   real gap, that tl already treats every enum as a `string` subtype,
   name the 3 sites the new rule actually targets, and swap the
   exemplar to `_fuzz/compress_fuzz_test.tl:76` (a genuine subset
   case) since `hash.tl:104` casts a `string.upper()` result — already
   plain `string`, word sets not even overlapping — into an unrelated
   enum, which was never an instance of either named rule.

Verify with `bin/cosmic --make ci` (which converges: generation 1
builds under the CURRENT `bin/cosmic.pin`, generation 2 rebuilds
`tl.lua` with the new patch entry applied and re-runs everything,
including the new `3p/tl/tl_test.tl` cases, under it).

## Non-goals

- **No cast-site removal in this PR**, including the 3 sites the new
  rule would actually let through
  (`_fuzz/compress_fuzz_test.tl:76`, `cosmic/compress_test.tl:24`,
  `cosmic/compress_test.tl:36`). `_build/coldbuild_test.tl` type-checks
  the whole tree with `o/bootstrap/cosmic` — the CURRENT
  `bin/cosmic.pin`, which does not carry this patch — so any tree
  source that needs the new rule to check fails that test locally, not
  just in CI's cold lanes. Land the patch alone first; removing those
  3 casts (and rebaselining `_build/casts_baseline.tl`) is a follow-up
  item, pulled only after `bin/cosmic.pin` bumps to a release built
  with this patch.
- **No "enum is a subtype of `string`" patch entry.** That relation
  already exists in tl 0.24.8 (`subtype_relations["enum"]["string"] =
  compare_true`); adding it again is a no-op at best.
- **No attempt at the other 8 enum-relation sites**
  (`cosmic/compress_test.tl:139`; `cosmic/hash.tl:104,141,203`;
  `cosmic/sys.tl:46`; `cosmic/sys_test.tl:14,29`;
  `cosmic/fetch/init.tl:214`). Each casts a plain `string` — an
  untyped binding return, a `string.upper()` result, or a
  guard-narrowed value — INTO a narrower enum, the reverse direction
  from this item's rule, and needs guard-based literal narrowing (or,
  for the binding-boundary sites, may not be soundly closeable by a
  checker rule at all). That is separate, harder work for a future
  item, not a size cut of this one.
- **No upstream tl PR.** This session's write access does not reach
  `teal-language/tl`; the carried patch is the only route available
  here, per the Goal's own routing.

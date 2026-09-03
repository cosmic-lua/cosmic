## Evidence

`rLV8_r8a5` («casts: pcall return typing — the tl patch closing 5
pcall-return-shape sites») specified a `3p/tl/tl_patch/narrow.tl` entry
that, on a known-signature `pcall(f, ...)` call, keeps `f`'s own success
return types and unions slot 2 with `any` (to admit pcall's untyped
failure-arm value) when the callee returns at least one value, or adds an
`any`-typed slot 2 when it returns none.

A builder implemented this literally, built it into the checker
(`bin/cosmic --make build`), and ran `bin/cosmic --check types` over
every tree file containing `pcall(`. The union-widening half of the
design breaks `--make ci` at more than 9 files, dozens of call sites, far
outside the item's declared scope (`3p/tl/tl_patch/narrow.tl` and
`cosmic/teal_test.tl` only) — including six MORE sites inside
`cosmic/shm.tl`, the very file the item targets. Examples:

    _eval/score_test.tl:143:10: error: in return value: got integer | <any type>, expected integer
    _fuzz/shrink.tl:41:31: error: argument 2: got string | <any type>, expected string
    _types/gentype.tl:402: cannot index key 'syntax_errors' in variable 'result' of type Result | <any type>
    cmd/cosmic/main.tl:482: in return value: got string | <any type>, expected string
    cosmic/check_test.tl:379/394/404: cannot index / cannot use operator '..' ... string | <any type>
    cosmic/codec.tl:186: in return value: got string | <any type>, expected string | nil
    cosmic/searcher.tl:76/325/326/328: multiple union-widening errors
    cosmic/shm.tl:119/162/188/220/257/323: six more sites in the item's own target file
    cosmic/tty.tl:294: in return value: got string | <any type>, expected string | nil

The spec's premise ("a caller narrows by checking ok first, same as
today") does not hold: Teal's checker has no mechanism to correlate a
narrowed `ok`/`success` boolean with a separate return slot's type, so
every existing call site that checks `ok` then uses the success value
directly breaks once slot 2 is widened with `any`. Fixing this literally
means touching dozens of files far outside the item's stated scope.

The builder additionally diagnosed the 5 original sites individually,
finding they do not share one root cause:

- `cosmic/shm.tl:146,171` — genuinely the "zero-return case": the callee
  (`raw.write`/`raw.store`) returns 0 values on success, so `pcall`'s
  slot 2 is a hard compile error today
  (`assignment in declaration did not produce an initial value for
  variable 'err'`) without the cast. An `any`-typed slot 2 added ONLY
  when the callee's own return arity is 0 fixes these two sites with no
  collateral damage (verified: no pre-existing code relies on that
  slot, since it was a hard compile error before).
- `cosmic/sqlite/extras.tl:63,106` — the cast crosses an unrelated-type
  boundary (`boolean as string`) already legal without narrowing; the
  proposed union does not actually let this cast be removed.
- `cosmic/_teal_engine.tl:256` — a nominal-vs-structural mismatch
  between `Result` and a locally-declared `TlResult`; likewise not
  fixed by the proposed union.

## The question

The item's `## Change` as written (union slot 2 with `any` whenever the
callee returns ≥1 value) is not implementable within its stated scope —
it regresses dozens of unrelated call sites tree-wide. Before `rLV8_r8a5`
(or a successor) can proceed, a decision is needed on the patch's actual
shape:

1. Narrow the patch to the zero-return case only (fixes `shm.tl:146,171`
   cleanly, per the builder's verification above), and re-scope the item
   to those 2 sites — the other 3 (`sqlite/extras.tl:63,106`,
   `_teal_engine.tl:256`) do not share this root cause and need their own
   analysis/spec, not this patch.
2. Or find a design for the ≥1-return case that does not widen an
   already-precisely-typed slot 2 tree-wide (e.g. a narrower `pcall`
   special case that also threads the `ok` boolean's narrowing into
   slot 2 — if Teal's checker can express that at all; unconfirmed).

## Non-goals

Not re-litigating whether `pcall`'s return typing gap is real for the
zero-return case — it is, confirmed directly against the checker. Not
touching the 3 non-zero-return sites' own casts; they need separate
analysis once (or instead of) this question resolves.

## Goal

G3 — an honest type layer. The carried tl patch only reaches builders
through `bin/cosmic.pin`, so "does this candidate release's checker
actually carry entry E" is a fact every pin bump asserts. Today that
assertion is a hand-written probe judged by eye, and the judgement is
wrong in a way that always reads as success. This slice makes the
judgement a command with a verdict line, and gives the tree one
verified worked example.

## Evidence

`3ISVlHT6`'s narrow-pack-n probe does not discriminate the two pins the
way its spec says, and the wrong version travelled: the item's
`## Evidence` states it, its `## Enablement` calls it "the one fact a
puller must not invert", PR #1421's body repeats it, and the review
comment on that PR repeats it again. The claim is that under the
pre-patch checker `table.pack(1, "a").n` is `any`, so
`local s: string = t.n` PASSES, and that the new pin is therefore
"proven by the REFUSAL".

**Re-measured 2026-08-27** (this refinement pass), against three
release assets downloaded fresh and sha256-verified against the pin
lines they correspond to:

```
$ curl -sSL -o old-cosmic  https://github.com/whilp/cosmic/releases/download/2026-08-15-c497c04/cosmic-lua
$ curl -sSL -o afad-cosmic https://github.com/whilp/cosmic/releases/download/2026-08-27-afad5b5/cosmic-lua
$ curl -sSL -o new-cosmic  https://github.com/whilp/cosmic/releases/download/2026-08-27-6b88a0d/cosmic-lua
$ sha256sum old-cosmic afad-cosmic new-cosmic
5161fd8c7b6de8c3f2c49a8b5a02d87e2356955d154f81fca253ec2182165e9d  old-cosmic
9f81e916ed78afacbc04a8cd901b8dc77b15638785f9ecc2c944b215b55799dd  afad-cosmic
e770ce10251944d9ff08c77c34788db11349e0d322dcde19e530c17b196ca2c0  new-cosmic
```

`old` is the pin PR #1421 replaced, `afad` the pin it installed, `new`
the pin `bin/cosmic.pin` carried when this was written
(`2026-08-27-6b88a0d`).

**Re-measured at pull (2026-08-27, this slice's claim).** `origin/main`
has since moved the pin twice; it now carries
`2026-08-27-cb39b65`, `sha256 = c81de75b787a31cd60765a461497df76fa123dfa888f066cdba6b873e7ea1aad`.
Every finding below re-measures unchanged in shape against it: the
Finding 3 probe still type-checks clean (`exit 0`) under
`o/bootstrap/cosmic` at that pin, the Finding 1 mirror
(`local _s: string = t.n`) still exits 1 under both `old` and the
current binary with only the message differing, and the Finding 2
unused-variable trap still exits 1 under the current pin. The tree
facts also hold: `grep -c "pin-probe" docs/build.md` is 0,
`_build/pin_probe.tl` and `_build/testdata/` do not exist,
`3p/tl/tl_patch/**` still declares 32 entries, and `docs/build.md` is
148 lines with `## Bootstrap` at line 132.

**Finding 1 — the stated probe is vacuous.** On the two-line file
`local t = table.pack(1, "a")` / `local s: string = t.n`, with
`--check types`:

```
old:  packn-probe.tl:2:20: error: in local declaration: s: got <any type>, expected string   exit=1
afad: packn-probe.tl:2:20: error: in local declaration: s: got integer,    expected string   exit=1
new:  packn-probe.tl:2:20: error: in local declaration: s: got integer,    expected string   exit=1
```

Both REFUSE, both exit 1. A declared `local s: string = <any>` is a
type error under either checker, so pass-versus-refusal carries no
signal here. Only the MESSAGE differs (`got <any type>` vs
`got integer`), and a message is not an exit status.

**Finding 2 — the candidate replacement is vacuous too, for a second
and independent reason.** The item's own suggested inversion,
`local n: integer = table.pack(1, "a").n`, still exits 1 under BOTH
binaries — because `n` is unused and warnings are errors here:

```
old:  packn-accept.tl:2:7:  warning: unused variable n: integer
      packn-accept.tl:2:21: error: in local declaration: n: got <any type>, expected integer   exit=1
new:  packn-accept.tl:2:7:  warning: unused variable n: integer                               exit=1
```

Two independent ways to write a vacuous probe, one of which survived a
refinement pass, a build, a PR body and a review comment. Judging a
probe by eye is the defect; the probe text is only its symptom.

**Finding 3 — a probe that does discriminate, measured.** Prefixing the
local with `_` (the deliberately-unused marker) removes the warning and
leaves only the narrowing fact:

```
$ cat packn_probe.tl
local t = table.pack(1, "a")
local _n: integer = t.n

$ ./old-cosmic  --check types packn_probe.tl
packn_probe.tl:2:22: error: in local declaration: _n: got <any type>, expected integer   exit=1
$ ./afad-cosmic --check types packn_probe.tl
Type check passed: packn_probe.tl                                                        exit=0
$ ./new-cosmic  --check types packn_probe.tl
Type check passed: packn_probe.tl                                                        exit=0
```

Opposite exit statuses: this one is real proof. The mirror
(`local _s: string = t.n`) exits 1 under all three, confirming Finding
1 is about the shape and not about the warning.

Nothing landed wrong: PR #1421's quoted transcript happens to show
`got integer`, so the pin bump is correct and independently verified.
The risk is forward — and it is already spreading by reference:
3ITpcO21 ("per 3ISVlHT6's procedure verbatim") had to improvise a
substitute proof, and 3IU667WI cites 3ITpcO21 in turn. The pin-bump
procedure lives only in completed board-item prose, copied item to
item, with a proof step that cannot fail.

## Change

Three files, one new tool plus its fixture and its doc home.

1. **New `_build/pin_probe.tl`** — a dual-use module (`cosmic.proc`'s
   `is_main()` pattern, AGENTS.md) that decides whether a probe
   discriminates two cosmic binaries, instead of a reader deciding.
   - Exported pure function
     `verdict(baseline_code: integer, candidate_code: integer): string, boolean`
     returning the verdict TEXT and whether it discriminates. The four
     cases, exactly:
     - baseline non-zero, candidate zero →
       `"pin-probe: DISCRIMINATES (baseline refuses, candidate accepts)"`, true
     - baseline zero, candidate non-zero →
       `"pin-probe: DISCRIMINATES (baseline accepts, candidate refuses)"`, true
     - both zero →
       `"pin-probe: VACUOUS (both accept)"`, false
     - both non-zero →
       `"pin-probe: VACUOUS (both refuse; a differing message is not discrimination)"`,
       false
   - Script half: argv is `<probe.tl> <baseline-binary> <candidate-binary>`.
     For each binary run `{binary, "--check", "types", probe}` with
     `child.run`, following `_build/coldbuild_test.tl:60-83` (which
     already execs a cosmic binary this way and sets
     `COSMIC_COVERAGE = "0"` in the child's env for the same reason).
     `child.Result` carries `code: integer`, `ok: boolean`, `stdout`,
     `stderr` (`cosmic/child/types.tl:15-18`); read `code`.
   - Print, in order: a `baseline: <path>` block with that run's
     combined output and `exit=<code>`, the same for `candidate:`, then
     the single verdict line last. Printing BOTH transcripts is
     load-bearing — it is what shows a reader the two messages differed
     while the statuses did not.
   - Exit 0 when it discriminates, 1 when vacuous. Wrong argument count
     or an unreadable probe file: one error line and exit 2 (never 0,
     never 1 — a usage error must not read as either verdict).
   - Library rules apply: no throwing from the module half; the script
     half is a process boundary and may `os.exit` with a trailing
     `-- exits: <why>` (D30).

2. **New `_build/testdata/packn_probe.tl`** — the verified worked
   example from Finding 3, verbatim, two lines:
   ```
   local t = table.pack(1, "a")
   local _n: integer = t.n
   ```
   The `_` prefix is required (Finding 2) and a comment on line 1 must
   say so. `testdata/` is never embedded, and
   `_build/coldbuild_test.tl` already excludes `/testdata/` from its
   sweep (`_build/coldbuild_test.tl:49-53`), so this file is not held to
   the pinned checker — which is the whole point of it.

3. **New `_build/pin_probe_test.tl`** — header
   `--- reads: o/bootstrap/cosmic`, mirroring
   `_build/coldbuild_test.tl:1`.
   - Four pure tests over `verdict`, one per case above, asserting the
     exact verdict text and the boolean.
   - Two end-to-end tests running the PINNED bootstrap
     (`o/bootstrap/cosmic`, guarded by an `assert(fs.is_file(...))`
     with a message naming how to land it, as
     `_build/coldbuild_test.tl:63-64` does) as BOTH baseline and
     candidate: a probe of `local _x: integer = 1` written to
     `TEST_TMPDIR` must end `pin-probe: VACUOUS (both accept)`, and
     `local _x: integer = "s"` must end
     `pin-probe: VACUOUS (both refuse; …)`. Both outcomes hold under
     any checker, patched or not, so neither test can rot with a pin
     bump. The DISCRIMINATES arms need two different binaries and are
     covered by the pure tests only — say so in a comment.
   - Each `test_*` is called on the line after its `end` (AGENTS.md).

4. **`docs/build.md`** — under the existing `## Bootstrap` section
   (heading at line 132; the section's last paragraph ends at line
   148, and the file is 148 lines, well under the 500-line cap), add a
   short `### Proving a candidate carries a checker change`
   subsection: a carried tl patch reaches builders only through the
   pin, so a bump that means to obtain a patch entry must prove the
   candidate binary has it; the proof is opposite EXIT STATUS on one
   probe, never a differing message; the command is
   `o/bin/cosmic _build/pin_probe.tl <probe.tl> o/bootstrap/cosmic <candidate>`
   (the current pin's binary is already on disk at
   `o/bootstrap/cosmic` after any `bin/cosmic` run, and is the right
   baseline); `_build/testdata/packn_probe.tl` is a worked example;
   and name the unused-variable trap from Finding 2 in one sentence.
   Keep it to prose plus that one command — no procedure checklist.

`grep -c "pin-probe" docs/build.md` is 0 today; `_build/pin_probe.tl`
and `_build/testdata/` do not exist today (`ls` on both: no such file
or directory). The carried patch has 32 entries today
(`grep -h '^  \["' 3p/tl/tl_patch/*.tl | wc -l`).

## Non-goals

- **No change to how a candidate release is judged ELIGIBLE.** The
  `git merge-base --is-ancestor <feature-sha> <tag sha>` check, and the
  question of whether the tag sha is the sha the binary was built from,
  belong to item **3ITx1Gtr** and must not be touched, restated, or
  pre-empted here. This slice answers "does this binary carry the
  rule", never "is this the right binary to consider".
- **No pin bump.** `bin/cosmic.pin` is not edited.
- **No patch changes.** `3p/tl/tl_patch/**` and `_make/patch.tl` are
  untouched; no new entry, no entry renamed.
- **No per-entry probe corpus.** One worked example fixture only — not
  a probe for each of the 32 entries, and no requirement that entries
  declare probes.
- **No binary self-description.** Do not add a flag, payload, or
  manifest that makes a built cosmic report the patch entries it
  carries. That is a larger design and is not this slice.
- **No new CLI flag and no new `--make` verb.** The tool is a script
  run under a built binary, like `_perf/run.tl`.
- **No edit to `_build/coldbuild_test.tl`**, and no change to any
  existing verdict-line format.
- **No board-item edits.** Correcting the completed items 3ISVlHT6 and
  3ISPGV8z is board state, not a pull request, and completed items are
  history.
- **No release.yml or other workflow changes.**

## Acceptance

Run from the repo root.

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _build/pin_probe_test.tl` passes, including
  the four `verdict` cases and both end-to-end VACUOUS cases.
- `bin/cosmic --check types _build/testdata/packn_probe.tl` prints
  `Type check passed: _build/testdata/packn_probe.tl` and exits 0
  (measured at pull against release `2026-08-27-cb39b65`, the pin
  `origin/main` carries: exit 0).
- The tool names a vacuous probe as vacuous, with no network and one
  binary:
  `o/bin/cosmic _build/pin_probe.tl _build/testdata/packn_probe.tl o/bin/cosmic o/bin/cosmic`
  ends `pin-probe: VACUOUS (both accept)` and exits 1.
- The tool refuses a usage error distinctly:
  `o/bin/cosmic _build/pin_probe.tl _build/testdata/packn_probe.tl`
  exits 2.
- `grep -c "pin-probe" docs/build.md` prints at least 1 (today 0), and
  `grep -c "_build/pin_probe.tl" docs/build.md` prints at least 1
  (today 0).
- `wc -l < _build/pin_probe.tl` is ≤ 200 and
  `wc -l < _build/pin_probe_test.tl` is ≤ 200 (both well under the
  500-line cap; the bound is here so the tool stays a tool).
- `wc -l < _build/testdata/packn_probe.tl` is ≤ 4.
- `git diff --name-only origin/main` lists exactly
  `_build/pin_probe.tl`, `_build/pin_probe_test.tl`,
  `_build/testdata/packn_probe.tl`, `docs/build.md` — plus
  `.cosmic-coverage` and/or `_build/casts_baseline.tl` ONLY if a
  ratchet gate demands it, in which case run exactly the regen command
  that gate's failure message prints and commit its result. No gate is
  weakened any other way.

## Enablement

`none needed` — no blocker items, and the countermeasures for every
predicted wrong turn are inside this slice's own `Change`:

- *Writing the probe in the non-discriminating direction* — the tool
  being built is the countermeasure; a reader is no longer the judge.
- *Reading a differing error message as proof* — pinned as its own
  verdict string (`both refuse; a differing message is not
  discrimination`) and as one of the four `verdict` tests.
- *Tripping the unused-variable warning* (Finding 2, which no prose in
  the tree warns about) — the committed fixture carries the `_` prefix
  and a comment saying why, and `docs/build.md` names the trap.
- *Missing the fence's read grant for an exec'd binary* — the spec
  names `_build/coldbuild_test.tl:1` as the `--- reads:` pattern and
  `:60-83` as the `child.run` pattern.
- *Widening into eligibility or into a per-entry corpus* — walled in
  `Non-goals`, with 3ITx1Gtr named by id.

The one thing this slice cannot mechanize is a session choosing to run
the tool at all; that is what the `docs/build.md` paragraph is for, and
it is the correct rung (docs) because the pin bump is a human procedure
with no gate to hang a check on.

# audit — `cosmic --make` branch review

Findings from a review of this branch, originally at `180b0d3` ("close
the fixpoint") and re-reviewed at `4a15b92`, `1ca5fd1` and `a44fe32`.
The review kept one markdown file per finding — location, failure
scenario, suggested fix, test to add — on its own branch, and this
README is what survives it: ids are stable, and each entry below records
how that finding was closed. The per-finding text is in
[PR #807](https://github.com/whilp/cosmic/pull/807).

## open

**None.** All 60 are closed. Round 5 took the last 27 — the entries
below say how, because "closed" without a disposition is how a review
becomes decoration.

Two dispositions are worth naming up front, since they are the ones
where "closed" does not mean "the work is done":

- **The bridge-removal items became a plan, not a patch.** 051–056 plus
  058–060 were never defects; they are the sequencing of phase 3i, and
  each carried exit criteria rather than a fix. They now live as one
  ordered plan with a mechanism, a deletion order and a disposition
  table: [docs/design/make-3i.md](../design/make-3i.md). A review file
  per gap could not say what has to happen *before* what, which was the
  whole content of 056.
- **The design decisions went where decisions live.** 045 and 050 are
  recorded as D15 and D16 in
  [docs/decisions.md](../decisions.md), because a decision that lives
  only in a review file gets relitigated by the next person who does
  not read review files.

## how each was closed

### round 5 — the last 27

**bugs**

| id | what happened |
|---|---|
| 038 | the `\u{}` off-by-two. One line: a position capture is absolute. The reason it survived three fix passes was the test — every escape was written at the END of its string, the one position where an overshoot is invisible. Every form now has trailing text, so the tests pin each branch's resume index and not only its decoded value |
| 039 | one scanner (`_make/imports.tl`) replaces three. It walks strings and comments as UNITS, which answers by construction the three shapes a regex got wrong — a require inside `--[[ ]]`, a `--` inside a string, and `myrequire(...)` |

**security**

| id | what happened |
|---|---|
| 014 | the fence floor covers what a compile actually reads (`tlconfig.lua` and the include dirs, derived from `cosmic.teal` so they cannot drift). Gated from both sides: the enforce lane now asserts a real compile SUCCEEDS under the fence, because a denial test alone cannot tell a correct fence from one that denies everything; and what the plan CONTAINS is asserted in `driver_test`, where it runs without a kernel on every commit |

**stripped artifacts**

| id | what happened |
|---|---|
| 036 | `cosmic.literal` lexes for itself. Its only dependency is `cosmic.fs`, so the module the floor carries is a module the floor can load — option 2 of the two the entry offered, chosen because "a config file that cannot do anything" is pitched at exactly the projects that ship stripped |
| 037 | the searcher acquires the compiler through `pcall` and returns a MISS when there is none, which is what `package.searchers` asks of a searcher that cannot help. A typo'd module name reports its own name again |
| both | asserted from inside a real stripped artifact, in `_make/artifact_test.tl` — the floor is now tested for USABILITY, not only for presence |

**design / durability**

| id | what happened |
|---|---|
| 040 | `_make/artifact.tl` split on its runtime seam: generation (once per project) → `_make/generate.tl`, staging (once per binary) stays. `_make/build_test.tl` crossed the cap during this work and split the same way, on selection |
| 041 | one registry row per verb; `usage`, dispatch and the planned-verb stub all derive from it, and `build`'s post-step became build's own runner instead of a condition in the shared path |
| 042 | control characters refused in archive-controlled names, in tar and zip alike — closing the class at the guard rather than hardening each format that carries a name onward |
| 043 | `ROOT`, `out_dir` and `unit_label` name the sentinel that recurred five times ("the build and the build" was one symptom); `Selection.suffix` admits nil, which deletes the `sub(-0)` footgun comment |
| 044 | `parse_table` returns index and message separately (six casts gone); `fmt_kinds` is `{Kind: boolean}`, so every LOOKUP is typed. One cast survives at `pairs()`, which erases an enum key type in Teal 0.24.8 — a language boundary rather than a loose type |

**feature design**

| id | what happened |
|---|---|
| 045 | **D15**: shipping is opt-in. An artifact carries its modules plus `embed/**`. Cosmic's own binary declares the two non-module trees it ships |
| 046 | `embed.gen.tl` is its own kind (`payload-gen`) out of `classify`, with a validator rule for one where no binary lives |
| 047 | selection names targets of the verb's own kind: `build cmd/foo` builds foo, whole; a source path is refused, pointing at `check` |
| 048 | `example` and `lint` join the planned verbs, which is what lets `ci` be a list of verb names |
| 049 | folded into the 3i plan — neither fray can move while two pipelines read the same files, and after that phase only one does |
| 050 | **D16**: the version is read from a committed `.version`; `COSMIC_VERSION` becomes an override. The fixpoint test now passes none at all, which is what makes it a fixpoint over committed inputs |

**tests, ci and cleanup**

| id | what happened |
|---|---|
| 028 | resolution gated offline on every commit for EVERY declared platform key (not only this machine's row), plus a real networked `--make fetch` in the lane that already has one, asserting the unpack products and that a second run is a no-op |
| 030 | one pin reader. `_build/build-fetch.tl` calls `_make.pin` and keeps only its landing convention; verified end to end against the network |
| 031 | the retirement clock is written on `driver.build` with the deletion list, plus a `--help` note. Deliberately not stderr: `--build` is the build's inner loop |
| 032 | the shared scanner is memoized for one model build; facts output is identical but for `deps` no longer importing `validate` |
| 033 | `tar.parse_pax` left the public surface |
| 057 | `_build/workflows_test.tl` ratchets one container digest across every workflow, and every build job inside it. docs.yml had neither pin; it does now |
| 058–060 | the CI-convergence half of the 3i plan. 060's cheap option is done rather than planned: [`cosmic/coverage/SENSITIVITY.md`](../../cosmic/coverage/SENSITIVITY.md) is the inventory of environment-sensitive tests, so the next floor churn is diagnosable instead of rediscovered |
| 051–056 | the plan, above |

One measurement came out of 056 and is worth repeating here, since it
was an assumption for the whole phase: **`cosmic --make test` finds
exactly the same 173 targets `bin/make test` does.** Discovery parity is
exact. Its 46 failures are the test EXECUTION ENVIRONMENT — 25 of them
one missing thing, no binary under test on the path — not the graph.

### rounds 1–4

Fixed by `4a15b92` (001–027, less the residuals re-filed as 038/039),
`1ca5fd1` (007, 012, 013, 024, 026, 034, 035, most of 033) and
`a44fe32` (029, and the 027 payload gate its `check.needs` caught
silently skipping in every prior run) — all on this branch, before the
round-5 commits above.

## for the next review

Two rules made this one work, and both are worth keeping: **one file per
finding, with a failure scenario** — a finding you cannot state as "this
input produces that wrong output" is usually an opinion — and **delete
on resolution, recording the disposition**, so the list cannot quietly
become a list of things nobody did.

A third is worth adding, because it cost three fix passes here: when a
fix lands, ask what shape the new test does NOT cover. 038 was a
one-line bug that survived three rounds because every escape in its test
was written at the end of a string, which is the one position where the
bug is invisible.

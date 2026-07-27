# The Makefile bridge, and its removal

**Done.** The Makefile, `cook.mk`, `mk/**`, the seven module `cook.mk`s,
`bin/make`, the Makefile's fetch/stage/pack pipeline and its reporter,
the tests that tested the Makefile, and the `--build` flag are deleted.
`cosmic --make` builds this repo; `bin/cosmic` is the trust root and
carries the one pin. What the removal taught is recorded in
[phasing.md](phasing.md) under 3i.

Phase 3 landed every other slice *behind* the existing build: `-include
cosmic.mk` was the bridge, and the Makefile's gate stayed green through
all of it. This was the one slice where that was not available, because
the existing build was what went — so it was sequenced rather than
attempted, and the sequence held:

```
verb parity (ci, example, lint, coverage)
  → generation workflows (docs)
  → release parity (base-<variant>, so one build makes both binaries)
  → a release the pin can name        ← the hard gate; see below
  → trust-root swap (bin/make → bin/cosmic)
  → delete
```

**A pin older than a build-system change cannot build the tree.** The
step that could not be skipped: the pinned release predated the
`*_pin.tl`/`*_gen.tl` rename and D15, so it read this tree as having no
pins and no generator and produced a bare Lua interpreter. Nothing
published could build the tree, and the Makefile was the only thing that
could — which made deleting it in the same change circular. One release
in between broke it. A release is now built in two generations for the
same reason: the pinned cosmic builds one from the tree, and *that* one
builds what ships.

**The gate runs under the binary the tree builds.** Modules resolve from
the artifact before the tree, so `bin/cosmic --make ci` measures the
PIN — it will run the released formatter over a formatter fix and pass.
CI builds first and gates with the result. This is the single sharpest
edge in the new arrangement and the one most likely to be re-introduced
by someone simplifying a workflow.

## What is still ahead

Each pr.yml lane carries real logic as YAML-embedded bash, which is
exactly the orchestration the design assigns to policy verbs. Logic in
YAML is unrunnable locally, unversioned by the verbs' tests, and
per-forge. The convergence target is that every job is checkout + setup
+ **one verb**:

| YAML today | destination |
|---|---|
| the netns bring-up around the gate | the `offline` verb — the bring-up is already cosmic code |
| build, copy, clean, rebuild elsewhere, `cmp` | the `reproducible` verb |
| the enforce lane plus its canary | the `enforce` verb, printing its own evidence |
| `--make fetch` twice, asserting the second fetches nothing | `fetch`'s own idempotence check |
| "dump failing test output" (find + cat over `.got`/`.out`/`.err`) | **the reporter.** A failing gate should print the failing tests' captured output itself; the dump step exists because the summary does not, and every other consumer of the gate — a laptop, a downstream repo — lacks it too |

Do the reporter piece first: it is verb-independent, it shrinks every
lane, and it improves the local experience today.

`regen` and `benchmark` are named and planned; until they land,
`_types/gentype.tl`, `_types/gentl.tl` and `_perf/run.tl` run as
scripts.

## Two properties worth asserting rather than hoping

**The gate needs no git.** CI carries git plumbing because two recipes
shell out to git from inside the sandboxed build: `git ls-files` (lint's
file discovery, hence `safe.directory` in every lane) and `git describe`
(the Makefile-path version stamp, hence `fetch-depth: 0` in docs.yml).
Both are already scheduled to dissolve — the `--make` stamp reads a
committed `.version` (D16), and a `lint` verb discovers files from the
**model**, which computes exactly the tracked-shaped set minus `o/`.
What must *not* dissolve is docs.yml's push, which is a real git
operation and stays a workflow step.

This is a meaningful property, not tidiness: each git exec is host
surface inside a sandboxed recipe and a hostx grant the ratchets must
enumerate, and a git-free gate runs in a barer container, on a tarball
checkout, and under the derived fence without a git-shaped hole in its
floor. It is also easy to lose by accident — one new recipe that shells
to git re-acquires the whole apparatus. **Exit criterion for the gate:**
`bin/cosmic --make ci` passes in a container with no git installed, and
the fence refuses `git` as a recipe child.

**Coverage's environment-sensitivity is the root of the pinning.** Two
of CI's heaviest complications exist to hold the coverage ratchet's
inputs still: the digest-pinned container (an OS image roll moved the
floor) and the non-root builder in every lane (tests skip differently as
root). Both treatments are correct given the ratchet's design. The shape
to notice is that an environment-sensitive metric forced CI to pin the
environment *twice*, and each newly discovered sensitivity adds another
pin.

Options, none free:

1. **Skip-aware coverage** — exclude lines inside a test that reported
   skip (status 2) from the denominator, so a skipped path moves no
   floor. Requires the collector to know test boundaries; it may
   already, via the per-test `.got` contract. This is the structural
   fix if the data supports it.
2. **Floor on the intersection** — ratchet against lines covered in
   *every* lane, so environment-variable lines fall out by
   construction. Costs cross-lane aggregation.
3. **Accept and document** — keep the pins and add the missing half: a
   recorded inventory of known environment-sensitive tests, so the next
   floor churn is diagnosable in minutes instead of rediscovered. Cheap,
   and worth doing regardless of 1 and 2. The inventory lives in
   [`cosmic/coverage/SENSITIVITY.md`](../../../cosmic/coverage/SENSITIVITY.md).

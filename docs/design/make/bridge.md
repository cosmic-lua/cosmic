# Phase 3i: removing the Makefile bridge

Phase 3 landed every slice **behind** the existing build: `-include
cosmic.mk` is the bridge, and `bin/make ci` stayed green through all of
it. 3i is the slice that removes the bridge — and it is the one phase
where "land it behind the existing build" stops being available, because
the existing build is what goes.

So it is sequenced rather than attempted. This file is the sequence: the
mechanism it runs inside, the gaps each step has to close first, and the
exit criterion for each. The design itself is [README.md](README.md); the
phase list is [phasing.md](phasing.md), and the gap-by-gap parity work
is [bridge-parity.md](bridge-parity.md).

## The mechanism

**A dual gate.** Add a pr.yml lane running `cosmic --make ci` **beside**
`bin/make ci`, both required. Every bridge-removal slice lands behind
both gates green — the same discipline phase 3 used, now with the
replacement also gating. The lane starts as `check` + `test` + `build`
and grows a stage per delivered verb. The Makefile's gate is deleted
only when the two have been redundant for a full cycle.

**Why a dual gate and not a cutover:** a gate that cannot report its own
absence goes quietly decorative. That is not hypothetical here — audit
029 hardened graph tests to hard-fail in CI instead of skipping, and its
very first CI run caught the 027 payload gate silently skipping in every
prior run. Two gates that must agree is the shape that survives one of
them being wrong.

### Measured: what `--make test` does to this repo today

The plan used to say `--make test` "runs today" with nothing recording
a full run. It has now been run over the whole tree, from a clean
`git archive` copy seeded by `--make fetch` alone:

```
bin/make test        173 checks: 173 passed
cosmic --make test   173 checks: 121 passed, 46 failed, 6 skipped
```

**Discovery parity is exact** — the same 173 targets, `.lua` tests
included. That is the half worth checking first, because a test set that
silently shrinks is the failure mode nobody notices.

The 46 failures are **not 46 defects**. They reduce to a handful of
causes, and every one of them is the harness the Makefile provides and
`--make test` does not:

| n | cause | what it means |
|---|---|---|
| ~~25~~ | ~~`command not found: cosmic` (incl. `cosmic-debug`)~~ | **closed** — a test spawns the binary under test, and the verb now has a defined answer for which one: `test` assembles the project's binaries and `stage.binaries_on_path` puts `o/bin` on the child `PATH`. It was the single change that moved the number most, as predicted. |
| 4 | staged 3p trees (`TEST_DIR`, `o/tl/.staged`) | fixtures the Makefile's stage rules produce, not `fetch`'s landing layout |
| 3 | Makefile-only fixtures (`database.out`, `dry-run.out`, reporter PASS) | these tests test the MAKEFILE; they retire with it |
| 2 | `exec failed: EACCES` | the exec fence's resolution differs from the Makefile lane's |
| ~12 | assorted: `o/make` extraction, facts write paths, orphan-root discovery, symlink stat | individually small, each needing its own look |

So the honest status is: the graph and the discovery are right, and the
**test-execution environment is the gap**. That is a much smaller thing
than "the suite does not pass", and it is a prerequisite for the dual
gate rather than a blocker for the phase — the lane can start at
`check` + `build` and add `test` when the environment is defined.

The counts above are as of that run, and the tree has moved since: it
is 174 targets now, and in a *developed* tree — one whose `o/` the
Makefile has also populated — `cosmic --make test` runs all 174 green.
That is a weaker claim than the one above, because the Makefile's stage
rules have already produced the 3p fixtures that rows 2 and 3 are
about. Re-running the clean-`git archive` measurement is what would
retire this table, and it is worth doing once the remaining rows have
owners rather than after each one.

**A disposition table.** Every `##`-documented target gets a recorded
fate *before* deletion — the inventory is the Makefile, `mk/*.mk`,
`cook.mk`, and the module `cook.mk`s:

| fate | targets |
|---|---|
| verb, exists | build, test, clean, fetch/staged, format→fmt, teal→check |
| verb, needed | ci, example, lint, coverage, coverage-baseline, regen-types→regen, docs/doc-publish, benchmark/perf* |
| dissolves | model (is `check`), facts (the graph is the facts), bootstrap (the trust-root swap), help (usage + skills) |
| stays outside the build | doc-publish's git push (a workflow step); the perf harness's orchestration if it does not become a verb — **decide, do not drop** |

`_perf`'s targets are the easiest to lose by accident: no CI lane runs
them, so nothing fails when they break. Their home is part of the table,
not an afterthought.

## Deletion order

Dependencies, not preference. Each arrow is "cannot start until":

```
029 hard-fail (done)
  → dual-gate lane
  → verb parity          (ci, example, lint, coverage)
  → generation workflows (regen, docs)
  → fence default        (enforcement parity)
  → release parity
  → trust-root swap
  → delete the Makefile, mk/, cook.mk, the -include bridge,
    _build/build-fetch.tl, the --build flag, and
    makefile_ratchet_test.tl — the ratchet retires WITH the file it
    guards, last.
```

## The lanes themselves

Each pr.yml lane carries real logic as YAML-embedded bash — which is
exactly the orchestration the design assigns to policy verbs. Logic in
YAML is unrunnable locally, unversioned by the verbs' tests, and
per-forge. The convergence target is that every job is checkout + setup
+ **one verb**, with the YAML as transport:

| YAML today | destination |
|---|---|
| ci: `bin/make staged` online, then `unshare --net` + `bring_up("lo")` + the gate | the `offline` verb — the netns bring-up is already cosmic code, so the verb owns it |
| build: build, `cp`, `o=o2` build, `cmp`, echo a verdict | the `reproducible` verb (double-build + compare is also what `_make/fixpoint_test.tl` does for the `--make` artifact — two mechanisms today, one verb at the end) |
| build: `make enforce` + `make sandbox-canary` + always-dump | the `enforce` verb, canary included, printing its own evidence |
| build: `--make fetch` against the real pins, twice, asserting the second fetches nothing | the `fetch` verb's own idempotence check, once a verb can assert it |
| ci: "dump failing test output" (find + cat over `.got`/`.out`/`.err`) | **the reporter.** A failing `--make test`/`ci` should print the failing tests' captured output itself; the dump step exists because the summary does not, and every other consumer of the gate — a laptop, a downstream repo — lacks it too |
| smoke matrix assertions | mostly fine as YAML (real cross-OS runners are the point), but the assertion list duplicates what `_make/fixpoint_test.tl` smokes — worth one committed portable smoke script both invoke |

Three lanes, not six: `build` (the network-allowed lane) collects
everything that needs a built binary, a real network, or a real kernel,
because those steps all start from the same build and a separate job
would only re-do it. There is no network-allowed copy of the gate —
`ci` runs it fenced, and a green fenced run implies a green unfenced
one. That merge is what makes "every job is checkout + setup + one
verb" reachable at all: the count of lanes converges on the count of
policy verbs a job can't share.

Do the reporter piece **first**: it is verb-independent, it shrinks
every lane, and it improves the local experience today. As each policy
verb lands, delete the corresponding YAML in the same change — the
verb's exit criterion includes "the lane is one line".

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

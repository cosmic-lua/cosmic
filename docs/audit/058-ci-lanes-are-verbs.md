# 058 — lane logic lives in YAML bash; the policy verbs are its destination

severity: medium (the CI half of the 3i convergence; complements 051/056)
type: ci / design
area: `.github/workflows/pr.yml`, planned policy verbs

## observation

each pr.yml lane carries real logic as YAML-embedded bash — exactly
the orchestration the design assigns to policy verbs. the convergence
target is that every job becomes checkout + setup (057) + **one verb**,
with the YAML as transport only. what currently lives in YAML, and
where each piece goes:

| YAML fragment (today) | destination |
|---|---|
| offline lane: `bin/make staged` online, then `unshare --net` + quicksand `bring_up("lo")` + full gate | the `offline` verb: fetch online, then re-exec the gate network-denied; the netns bring-up is already cosmic code, so the verb owns it |
| reproducible lane: build, `cp`, `o=o2` build, `cmp`, echo verdict | the `reproducible` verb (double-build + compare is also what `_make/fixpoint_test.tl` now does for the `--make` artifact — two mechanisms today, one verb at the end) |
| enforce lane: `make enforce` + `make sandbox-canary` + always-dump | the `enforce` verb, canary included, printing its own evidence |
| build lane's "dump failing test output" (find + cat over `.got`/`.out`/`.err`) | the reporter: a failing `--make test`/`ci` should print the failing tests' captured output itself — the dump step exists because the summary does not, and it is the piece every *other* consumer of the gate (a laptop, a downstream repo) also lacks |
| smoke matrix assertions (`-e`, `--docs`, portable tests) | mostly fine as YAML (real cross-OS runners are the point), but the assertion list duplicates what `_make/fixpoint_test.tl` smokes — worth one shared list, e.g. a committed portable smoke script both invoke |

## why it matters beyond tidiness

logic in YAML is unrunnable locally, unversioned by the verbs' tests,
and per-forge. every fragment above that moves into a verb becomes
runnable on a laptop (`bin/cosmic --make offline`), testable, and
identical across CI providers. the design already made this argument
for the build; this is the same argument for the lanes.

## proposal

as each policy verb lands (051's sequencing), delete the corresponding
YAML bash in the same change — the verb's exit criterion includes "the
lane is one line." do the reporter piece (failing-output printing)
first: it is verb-independent, it shrinks every lane, and it improves
the local experience today.

# 052 — bridge removal: deleting the .mk files deletes today's only real sandbox

severity: blocker for 3i (sequencing constraint)
type: gap (enforcement parity)
area: cook.mk `.PLEDGE`/`.UNVEIL`/`.ENV`, `_cli/driver.tl` fence, audit 014

## the constraint

the repo's enforced sandboxing lives in the Makefile world: per-rule
`.PLEDGE`/`.UNVEIL` annotations (enforced by landlock-make, exercised
by CI with `.SANDBOXED := 1`), `.ENV` clamps, the hostx ratchet, and
the sandbox-canary that proves the mechanism is live. the `--make`
replacement — grants derived per verb, applied by `cosmic -c` — is
**opt-in (`COSMIC_FENCE=1`), exercised by one test in a privileged
lane, and its floor is incomplete for real compiles** (no
`tlconfig.lua`, no include-dir grants — audit 014).

remove the Makefile and its cook.mk annotations before the derived
fence is default, and the project silently goes from "an undeclared
read fails CI on a Landlock host" to "nothing is enforced anywhere."
the design promises the derived fence *replaces* the annotations; the
order of operations is what keeps the promise true at every commit.

## what has to land first (014, made concrete)

1. the fence floor covers the compile verbs' real reads (tlconfig,
   include dirs, derived from where the compile step finds them).
2. a Landlock-host CI lane runs a real compile and a real test under
   `COSMIC_FENCE=1` — the canary make-plan.md already requires.
3. the fence becomes default for `-c` (its own change, as the plan
   says), with the same denial produced by the in-process gate on
   non-Landlock hosts for generator/test units.
4. only then do `.PLEDGE`/`.UNVEIL`/`.ENV`, `.SANDBOXED`, the hostx
   ratchet, and the sandbox-canary retire — with the .mk files.

## exit criteria

a CI lane demonstrates a denied undeclared read under the derived
fence on a Landlock host, on a real recipe, before the first cook.mk
annotation is deleted. the enforcement gap between the two systems is
never open at HEAD.

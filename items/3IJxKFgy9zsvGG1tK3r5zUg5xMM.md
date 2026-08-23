## Goal

G6 — the defining paths, ratcheted. A ratchet is only as good as the
verdict that trips it, and `skills/optimize` today lets a session
declare a release-gating regression from evidence that has been
measured, in this project, to be insufficient. This adds the one rule
whilp/cosmopolitan#262 recommended and nobody landed.

## Evidence

Found while refining `3IHFD8b4` on 2026-08-22; re-measured on
`whilp/cosmic` at `83b4fd71`, 2026-08-23.

**The gap, in two commands.**

```
$ wc -l skills/optimize/*.md
  275 skills/optimize/SKILL.md
  254 skills/optimize/cosmopolitan.md
   63 skills/optimize/finding.md
  105 skills/optimize/measurement.md
  697 total
$ grep -n -i 'host state\|host-state\|across sessions\|separate session\|placement' skills/optimize/*.md
                                    # no matches, in any chapter
$ grep -c -i 'cross-session' skills/optimize/*.md
skills/optimize/SKILL.md:0   cosmopolitan.md:0   finding.md:0   measurement.md:0
```

(The capture said 622 lines across three chapters; there are four
chapters and 697 lines today. The grep result is unchanged: still
nothing.)

`measurement.md:13-20` gets close and stops short. It says the
report's `±%` is WITHIN-run spread and understates cross-run variance —
"a scenario can read ±2% across the 5 samples of one invocation yet
swing 10-15% between two separate invocations" — and attributes the
swing to frequency scaling, a noisy neighbor, or relink code layout.
Every one of those is a thing a session can control by interleaving
its A and B runs inside one sitting, which is what the chapter then
teaches. The term it does not name is the one that survives
interleaving.

**What #262/#263 established.** At one commit, byte-identical
binaries, the same reported CPU (family 6 / model 85 / stepping 7),
measured hours apart in the same container:

```
                       morning      afternoon
local default          173-182 us   123.7, 123.1 us
local rel (straddled)  196-198 us   122.4, 122.8 us   <- +34% penalty gone
local rel (padded)         --       139.8, 141.4 us   <- erratum-immune build LOSES 14%
release old (default)  146-166 us   132.2, 120.9 us
release new (rel)      197-217 us   124.9, 122.7 us   <- original regression gone
```

A single unchanged binary swung -38% between sessions. The morning's
+34-38% `codec_hex` regression had reproduced across SEVEN interleaved
isolated pairs on two independent build lineages and was still not
real. The microcode register is virtualized in the container, so
mitigation state is unobservable from inside; the container evidently
moved host placement between the two sessions. The recommendation
recorded on #262 was, verbatim: "add a measurement-discipline rule
instead of a build flag: a release-gating regression on a single
tight-loop scenario needs reproduction across separate sessions
(ideally days apart / different host placements) before it blocks a
pin."

**The cost of the gap, observed once.** Board item `3IHFD8b4` was
written on 2026-08-22 asserting a `tar_extract_tree` regression from a
single session's five interleaved pairings — the exact verdict shape
#262 calls insufficient — and its `Direction` then told a session to
merge whilp/cosmopolitan#263, a draft PR closed unmerged on
2026-08-15 with the conclusion "NOT a measured win... do not merge on
current evidence". Refining that item cost a full pass of re-reading
two issues and a closed PR to find the premise refuted.

**Where the two edits go, and what constrains them.**

`measurement.md:13-20` is the within-run-spread bullet; the new bullet
goes directly after it, because the new rule is the same subject one
term further out. `SKILL.md:177-194` is step 6 ("decide") of the loop,
and its surviving-regression clause at `:188-191` already carries the
sentence "ONE defined exception: … is decided by the isolated
re-measure procedure in `measurement.md` ("when a flag survives
triage"), not by revert" — a clause that names the chapter and quotes
the target heading words. The new clause is the second of that shape,
so the pattern to follow is in the file. `grep -c 'measurement.md'
skills/optimize/SKILL.md` is 5 today.

`_build/snippets_test.tl` declares `--- reads: skills` (`:5`) and
holds every fence tagged `teal` in that population to being a
formatter fixpoint AND compiling at full strictness. The table above
is data, not Teal, so it goes in a fence tagged `text` — the same
escape the chapter's existing shell transcripts use. Markdown is not
subject to the 500-line cap, which `cosmic --check lint` applies to
`.tl`.

## Change

**1. `skills/optimize/measurement.md`** — insert ONE bullet
immediately after the within-run-spread bullet that ends at `:20`
("…will flag these as \"regressions\" on pure noise."). The bullet
states, in the chapter's voice:

- the variance has a term no interleaving inside one session removes:
  host placement, invisible from inside a container because the
  microcode register is virtualized there;
- the rule that follows from it — **a release-gating regression on a
  single tight-loop or fixed-overhead scenario needs reproduction
  across SEPARATE SESSIONS, ideally days apart, before it blocks a pin
  or is written into a board item as a finding**;
- the #263 table above, in a fence tagged `text`, as the evidence,
  with the two facts a reader needs from it: one unchanged binary
  swung -38% between sessions, and the morning's regression had
  already reproduced across seven interleaved isolated pairs.

**2. `skills/optimize/SKILL.md`** — in step 6 ("decide"), extend the
surviving-regression bullet (`:183-191`) with a second defined
exception in the shape of the first: a surviving regression on a
single tight-loop or fixed-overhead scenario that is about to gate a
release or become a board item's finding is decided by the
cross-session rule in `measurement.md`, named by its heading words, not
by the one session's verdict. Keep the existing first exception
unchanged and keep the bullet's opening sentence ("a surviving
regression already reproduced against the binary itself, so it is
real") — the new clause narrows where that conclusion may be SPENT, it
does not weaken the gate.

Both edits are prose in two markdown files. No code moves.

## Non-goals

- **Do not reopen the build-flag question.** whilp/cosmopolitan#263
  (the `rel`-mode / padding build change) was closed unmerged as not a
  measured win. This rule is what #262 recommended INSTEAD of that
  flag; landing it must not be read as evidence for it, and the spec
  of the rule must not mention a build flag as a remedy.
- **Do not touch `_perf/compare.tl`, `TRIAGE_K`, the compare bar, or
  any gate code.** This is a rule about what a session may CONCLUDE,
  not a threshold change. `perf-compare` keeps exiting exactly as it
  does today.
- **Do not weaken the surviving-regression conclusion.** The A/A
  triage already in place stays the authority on whether a regression
  is reproducible; the new rule only governs when a single session's
  reproducible regression is enough to gate a release or be written
  down as a finding.
- **Do not widen it into a general "measure twice" rule.** It is
  scoped to a single tight-loop or fixed-overhead scenario, which is
  where the host-placement term dominates; a broad rule would tax
  every ordinary optimization loop for nothing.
- **Do not add a fence tagged `teal`.** `_build/snippets_test.tl`
  compiles those at full strictness; the table is data and takes a
  `text` fence.
- **Do not edit `skills/optimize/finding.md` or
  `skills/optimize/cosmopolitan.md`**, and do not restructure
  `measurement.md`'s existing bullets.

## Acceptance

```
bin/cosmic --make ci
bin/cosmic --make test _build/snippets_test.tl
grep -c -i "separate session" skills/optimize/measurement.md
grep -c -i "host placement" skills/optimize/measurement.md
grep -c "measurement.md" skills/optimize/SKILL.md
wc -l skills/optimize/measurement.md skills/optimize/SKILL.md
```

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _fuzz` is untouched by this change and is not
  part of the acceptance; `_build/snippets_test.tl` is run on its own
  because it is the one gate that reads `skills/`, and it must pass.
- `grep -c -i "separate session" skills/optimize/measurement.md` is
  **0 today** and must be at least 1 after.
- `grep -c -i "host placement" skills/optimize/measurement.md` is
  **0 today** and must be at least 1 after.
- `grep -c "measurement.md" skills/optimize/SKILL.md` is **5 today**
  and must be 6 after — the one new cross-reference, and no existing
  one removed.
- `wc -l` shows `measurement.md` grown from **105** and `SKILL.md` from
  **275**, each by fewer than 30 lines: this is two bullets, not a new
  chapter.

## Enablement

none needed, and skills-tier is the right rung by `enable.md`'s
ordering rather than a fallback: the countermeasure is "come back in
another session before you believe this number", which no type, lint
or gate can encode — core cannot make a session wait a day, and the
one thing a gate COULD do (fail a compare it has already triaged as
reproducible) is exactly what the Non-goals forbid.

Both edit sites are cited by `file:line` with the surrounding text
quoted, the existing clause the second edit imitates is quoted in
full, the evidence table is carried in this spec so the implementer
does not have to reach GitHub for it, the fence-tag constraint is
named with the gate that enforces it, and every Acceptance grep states
what it returns today.

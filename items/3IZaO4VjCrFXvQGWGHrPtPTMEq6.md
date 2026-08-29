## Goal

G8 — the flow system. `3IYYwdp7` deleted the identity review gate from
`_work/**`, and `3IYkPpb2` converges the `skills/work/**` prose on
`main`. Neither covers the prose left inside `_work/**` itself:
`3IYYwdp7`'s Changes named five doc comments and `3IYkPpb2`'s Non-goals
say "No change to `_work/**`". Sixteen passages in the machinery — two
of them the tool's own `--help` output — still describe the gate that no
longer runs. The title says six comments; a re-measure at `61cea198`
found fourteen, listed below.

The `--help` pair is the one that matters: `README.md` states that help
is "generated from the CLI, so neither can drift from the tool", and
these two option descriptions now do. A session that reads
`gitboard help verdict` is told the verb refuses a verdict it will in
fact record.

## Evidence

Measured 2026-08-29 against `board` at `db981771`, by running the
freshly built `o/bin/gitboard` and by reading the sources.

**The two `--help` strings, observed by running the verb.**
`gitboard help verdict` prints:

```
      --session SESSION  the reviewing session; refused when it built the item.
                         Omit to derive it from the environment
```

and `gitboard help next` prints:

```
      --session SESSION  this session; skips work another session claimed and
                         reviews of what this one built. Omit to derive it from
                         the environment (GITBOARD_SESSION, else a runner's own id)
```

Both are false. Measured against the same binary: a synthetic board with
a leaf in `check` whose `claim` and `builders` both name `builder-S`
answers `next --session builder-S` with `review <id>`, and
`verdict <id> accept --session builder-S` returns 0 and moves the item
out of `check`. The strings are `_work/gitboard.tl:110` and `:143`;
`gitboard.tl` was untouched by `db981771`.

**Fourteen code comments naming the deleted rule.** The six the title
counts, plus eight the first pass did not reach. Each was checked by
running the path it describes against a freshly built `o/bin/gitboard`
on a synthetic board, not by reading.

- `_work/action.tl:157-163` — the doc comment ON `reviewable`. It opens
  "The first item awaiting a verdict that this session did not build ...
  with what it stepped over on the way: its own builds", and repeats
  "every non-builder was handed the same top item". `ReviewPick.item`'s
  doc, "absent when nothing here is this session's to judge", is the
  same class.
- `_work/action.tl:38-47` — the module header: "The claim survives the
  move into `check`, so it also names who BUILT the thing awaiting a
  verdict — and this hands that item to somebody else". Run: `next
  --session builder-S` on an item in `check` claimed by `builder-S`
  answers `review <id>`. It hands it to nobody else.
- `_work/action.tl:96-102` — `draw`'s doc: the claim stays put on rework
  "because it is also the record of who BUILT the item and that is what
  keeps the next verdict at arm's length". Nothing keeps it at arm's
  length; the verdict from the claimant returns 0.
- `_work/item.tl:57-61` — the `builders` field doc: "the question the
  no-self-accept rule turns on ... whoever built stays disqualified as
  reviewer."
- `_work/item.tl:292` — `record_builder`'s doc, the same claim again.
- `_work/gitverbs.tl:186-189` — "The claim is what `next` reads to
  withhold a verdict from the item's builder". It withholds nothing.
  The refusal below it ("a handover to check names its builder") is
  live and stays — run, it refuses.
- `_work/gitverbs.tl:227-229` — "Claims on `check`/`land` mark the
  builder for review distance".
- `_work/gitverbs.tl:241-242` — "the takeover disqualifies the earlier
  holder as reviewer, so it goes through --force --why". The refusal is
  correct and stays; only its stated reason is false.
- `_work/gitverdict.tl:12-16` — "`--session` is the builder-distance
  half. A session that names itself as the item's claimant is refused."
  Run: it is not refused; the verdict returns 0 and the item moves.
- `_work/session.tl:19-20` — an unnamed session "collides with nobody
  and is offered no verdict on anything". Run with every SOURCES
  variable cleared, an unnamed session IS offered the review — even one
  another session holds a live review claim on.
- `_work/session_test.tl:2` — "A session's identity is what the board's
  whole review distance rests on".
- `_work/gitverdict_test.tl:114-116` — cites `"no session accepts its
  own work"` as the rule the commit subject makes auditable.
- `_work/gitreview_test.tl:89-90` — "from the claimant or any other
  non-builder", which implies builders are excluded.

Left alone, checked and true: `gitreview.tl:4-8` (already corrected —
the builder's claim "excludes nobody from reviewing"),
`gitverdict.tl:174-177` (the subject records who judged — run, the
commit reads `verdict <id> accept (check -> land) by builder-S`),
`session.tl:118`'s unnamed note (run, `status` prints it and every
clause holds), and `gitverdict_test.tl:93-96` (already documents the
absence of the gate).

**`builders` now has no reader.** `grep -rn builders _work/*.tl` outside
the tests hits only `item.tl` — the field, its `problems` repeat check,
encode/decode, and `record_builder`. `3IYYwdp7`'s KEEP paragraph says it
"stays written, read by `show`"; measured, `gitboard show --fields` on
an item carrying `builders = "builder-S builder-T"` prints no builders
line, and `_work/gitshow.tl` never mentions the field. The audit record
does survive in the committed item file and the git log, so nothing is
lost — but nothing surfaces it either, and the reason given for keeping
it is wrong.


**Eight more, found by a sweep rather than by another reading.** The
site count went 8 → 16 → 23 because each list was produced by the same
reading that missed the rest. A wrap-proof grep over the whole of
`_work/**` (the command is in Acceptance) surfaces every passage in one
pass, and triaging its output found these — each verified against the
freshly built `o/bin/gitboard`, not read.

- `_work/gitclaim_test.tl:3-7` — the file header: the claim "is the
  only thing standing between a session and a verdict on its own work
  … the review gate's foundation". Run: a session named on both `claim`
  and `builders` is offered `review <id>` by `next` and its
  `verdict <id> accept` returns 0.
- `_work/gitclaim_test.tl:20-23` — `builders` "is what `next` consults
  to withhold a verdict from whoever wrote the diff". `next` never
  reads the field: `grep -rn builders _work/*.tl` outside the tests
  hits only `item.tl`, and `action.tl` does not mention it.
- `_work/gitclaim_test.tl:99-100` — "The claim is what `next` reads to
  withhold a verdict from the item's builder", the exact sentence
  corrected in `gitverbs.tl:186` and left standing here.
- `_work/gitview.tl:133-135` — "the identity decides which work is
  withheld and which verdicts are refused". The first half is true; the
  second is not. Run with every `session.SOURCES` variable cleared, an
  unnamed session's `verdict <id> accept` exits 0 and moves the item out
  of `check`. `review` and `--take` DO refuse an unnamed session — those
  are claim refusals, and that distinction is what the rewrite keeps.
- `_work/converge_test.tl:7-9` — SAFETY described as including "no
  verdict on the asker's own work". The safety loop at `:313-356`
  asserts pull, refine and finish claims and nothing about verdicts,
  and `apply`'s `review` branch at `:122-136` tests no identity.
- `_work/converge_test.tl:215-216` — "a phase full of work the asker
  may not judge is a STARTING state".
- `_work/converge_test.tl:225-227` — "no verdict the asker may write
  drains the phase it is filling", contradicted by
  `action_test.tl:210-225`, which the previous slice converged.
- `_work/action.tl:292-296` — the fall-through comment: "every item in
  it is this session's or under another session's live review
  (`reviewable` would have returned any other)". `reviewable`
  (`:238-249`) skips ONLY items under another session's live,
  non-stale review claim; a session's own build is picked, not
  stepped over. The `this session's` disjunct is the deleted gate.

**`builders` does not record an in-place takeover.** `item.tl:57-62`
says the field records "who built and who took over". Measured: a
phase-crossing `move <id> <other-phase> --claim Z` appends (`builders`
goes `builder-X` → `builder-X third-Z`), but an in-place
`move <id> <same-phase> --claim Z --force --why` routes through
`gitgate.set_in_place` (`gitgate.tl:267-302`), which writes `it.claim`
and never calls `record_builder` — `builders` stays `builder-X` while
`claim` reads `other-Y`. The gap is pre-existing behaviour; only the
sentence is this item's, so the sentence is narrowed to what the field
actually records and the boundary is stated at the site. Changing
`set_in_place` is a behaviour change the Non-goals forbid.

## Change

`_work/{gitboard.tl,action.tl,item.tl,gitverbs.tl,gitverdict.tl,
session.tl,session_test.tl,gitverdict_test.tl,gitreview_test.tl}`,
prose and help strings only. No behaviour changes.

Each passage keeps what it says about CLAIMS and the review LEASE, and
drops what it says about an identity test withholding a verdict.

- `gitboard.tl:143` — `verdict --session` becomes the reviewing session
  and how it is derived, with no refusal promised.
- `gitboard.tl:110` — `next --session` keeps "skips work another session
  claimed", loses "and reviews of what this one built", and gains the
  review-claim skip that IS there.
- `action.tl` — the module header names `check`'s own lock (the review
  claim) as the second place a claim means something, `draw`'s rework
  paragraph gives the claim its real reason (it names who would
  ordinarily carry the rework on), and `reviewable` plus
  `ReviewPick.item` describe the walk the code performs.
- `item.tl:57-61` and `:292` — `builders` is described as the audit
  record of who has held the claim, readable in the committed file and
  the log, with its lack of readers stated rather than implied.
- `gitverbs.tl:186-189`, `:227-229` and `:241-242` — the three refusals
  keep their rules and lose "withhold a verdict from the item's
  builder", "review distance" and "disqualifies the earlier holder as
  reviewer" as their reasons.
- `gitverdict.tl:12-16` — `--session` is the audit half: nothing
  refuses on it, and the name rides in the commit subject.
- `session.tl:19-20` — an unnamed session collides with nobody, so no
  claim is withheld from it and its own moves record no holder.
- `session_test.tl:2` — matches the corrected `session.tl` header:
  distinct names are what make claims exclusive.
- `gitverdict_test.tl:114-116` and `gitreview_test.tl:89-90` — cite
  what is auditable and who may write a verdict, not a deleted rule.

Whether `gitboard show` should render `builders` is decided NO here:
rendering it is a behaviour change this item forbids, and the record is
already readable in the committed item file and the git log. The field
doc now says exactly that instead of claiming `show` prints it.

Second slice, after the sweep: `_work/{gitclaim_test.tl,gitview.tl,
converge_test.tl,action.tl,item.tl}`, same walls.

- `gitclaim_test.tl` — the header says what the file actually pins (the
  lease and what a handover must name), and the two `withhold a
  verdict` sentences give the claim its real job: it names the builder
  in the commit and the audit record, and it is a lock against
  concurrent writers.
- `gitview.tl:133-135` — the identity decides which work is WITHHELD
  and which CLAIMS are refused. Verdicts are not on that list.
- `converge_test.tl` — SAFETY drops the verdict clause it never
  asserted; `generate`'s two paragraphs keep the reason the asking
  session's own claims are drawn (a `do` claim is that session's to
  finish) and lose the verdict deadlock, which no longer exists.
- `action.tl:292-296` — the fall-through names the one thing
  `reviewable` steps over: another session's live review claim.
- `item.tl:57-62` — `builders` records the sessions a phase-crossing
  claim named, and says plainly that an in-place `--claim` takeover
  writes the claim without appending. `record_builder`'s doc
  (`:291-298`) is narrowed the same way.

## Non-goals

- No behaviour change anywhere in `_work/**`.
- Do not reintroduce an identity check under any name.
- Do not remove `builders`, `record_builder`, or the `problems` repeat
  validation.
- Do not touch `skills/work/**`; that is `3IYkPpb2`.
- Do not change the exact-string claim lock or its `--force --why`
  takeover.

## Acceptance

Run from a `board` checkout. Every "today" was measured 2026-08-29 at
`68eeafaa`.

**The sweep, not a list.** Three enumerations of this item's sites
(8 → 16 → 23) each missed passages, because each was a reading. This is
the check that is not: it joins comment runs and concatenated help
strings before matching, so a phrase wrapped across lines cannot hide,
and it covers every tracked file under `_work/`, `cmd/`, `docs/` and
`README.md` rather than a named subset. Save it as `sweep.sh` and run
it from the checkout root:

```sh
#!/bin/sh
# Sweep the board machinery's PROSE for the vocabulary of the deleted
# identity review gate. Comment runs and concatenated help strings are
# joined before matching, so a phrase wrapped across lines cannot hide;
# `verdict_line` is elided because it is a function name, not prose.
V='withh[eo]ld|disqualif|arm.s length|at a distance|(review|builder).distance'
V="$V"'|non.builder|self.accept|(accept|judge)[a-z]* its own|own (work|build|diff|item)'
V="$V"'|who(ever)? built|did not build|wrote the diff|exclude|elsewhere'
V="$V"'|somebody else|someone else|no verdict|verdicts? (are|is) refused'
V="$V"'|refus[a-z]* (a|the|any|every|its|this) verdict|(may|cannot|does) not judge|not hand'
for f in $(git ls-files _work cmd docs README.md); do
  tr '\n' ' ' < "$f" \
  | sed 's/verdict_line/VL/g; s/--*/ /g; s/"[[:space:]]*\.\.[[:space:]]*"/ /g;
         s/[[:space:]][[:space:]]*/ /g' \
  | grep -oiE ".{0,50}($V).{0,50}" \
  | sed "s|^|$f: |"
done
```

- `sh sweep.sh | wc -l` prints `63` today. The count is not the check —
  the OUTPUT is. Every hit must triage into one of three, and the
  reviewer re-runs it rather than trusting any list:
  - **irrelevant** — the vocabulary in another sense: `elsewhere` as a
    variable or as "tested elsewhere" (`fixture.tl`, `flow_test.tl`,
    `gitverbs_test.tl`, `gitview.tl:{doc}`, `intake.tl`,
    `refine_claim_test.tl`), "no verdict" as `land`'s missing-verdict
    refusal (`gitgate.tl`, `gitgate_test.tl`, `gitverbs_test.tl`,
    `flowstat_test.tl`), "somebody else" as a concurrent writer
    (`README.md`, `decision.tl`, `gitboard.tl`), "excluded" as
    `health.tl`'s rot horizon, "its own" as a spec's workaround
    (`gitgraph.tl`).
  - **true as written** — the CLAIM and the review LEASE, which both
    still exist: a live claim excludes a second holder
    (`gitreview.tl`, `gitreview_test.tl`, `refine_claim_test.tl`,
    `gitboard.tl:308`), a builder returns their own work freely
    (`gitverbs.tl:224-242`, `gitverbs_test.tl:286`,
    `gitboard.tl:315-317`), and the passages that state the gate's
    ABSENCE (`action_test.tl:132-133`, `:210-225`, `:382-384`,
    `gitverdict_test.tl:93-96`, `:114-116`, `:208-212`,
    `session.tl:19-20`, `gitreview.tl:4-8`).
  - **false** — zero permitted. Today's zero is what this item buys.
- `sh sweep.sh | grep -icE 'withhold a verdict|verdicts are refused|may not judge|non.builder|disqualif|arm.s length|(review|builder).distance|self.accept|verdict on the asker|no verdict this session|no verdict the asker'` prints `0` (`8` before this slice).
- `o/bin/gitboard help verdict` contains no "refused when it built".
- `o/bin/gitboard help next` contains no "what this one built".
- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _work/` ends `test: PASS (29 files)`.
- **No executable line changed.** `git diff <base> -- _work/ | grep -E
  '^[-+]' | grep -vE '^(\+\+\+|---)' | grep -vE '^[-+][[:space:]]*(--|$)'`
  prints only `help =` string-literal lines, and stripping every
  comment line from both revisions and diffing the result is empty.
- The three refusals this item's comments sit on still refuse, run
  literally: a handover to `check` with no claim on an unclaimed item,
  a leftward move out of `do` over another session's live claim, and a
  `--claim` that overwrites a live foreign claim each exit 1 with the
  message they carry today.
- The reversal still holds, run literally: a fixture item in `check`
  whose `claim` and `builders` both name `S` is offered to `S` by
  `next --session S` as a `review`, and `verdict <id> accept --session S`
  returns 0. This item must not move it.
- The claim refusals that DO exist still refuse, run literally with
  every `session.SOURCES` variable cleared: `review <id>` and
  `next --take` each exit 1 naming an unnamed session, while `next`,
  `status` and `verdict <id> accept` do not.
- `builders` still behaves as measured: a phase-crossing
  `move --claim Z` appends, an in-place `move <same-phase> --claim Z
  --force --why` does not, `record_builder` and the `problems` repeat
  check are byte-identical.

## Enablement

Nothing. The change is prose and two string literals in a tree that
already builds.

## Ordering

Lands after `3IYYwdp7`, which is what made these passages false. It is
independent of `3IYkPpb2` — that item converges the skill on `main`,
this one the machinery on `board`, and their Non-goals exclude each
other's files.

## Result

Landed by direct push to `board` — this slice carries a commit, not a
pull request, so the handover is `--evidence` and this section is what
the reviewer reads (`3IZZ1icV`).

**Pushed.** `3903d9357eec49c3c8d6a5a91daac84197214c38`, one commit,
`d63bede8..3903d935`. Diff stat: 9 files, +62 / -57, all under
`_work/**`:

```
_work/action.tl          | 38 +++++++++++++++---------------
_work/gitboard.tl        | 10 ++++-----
_work/gitreview_test.tl  |  4 ++--
_work/gitverbs.tl        | 23 ++++++++++--------
_work/gitverdict.tl      |  9 +++----
_work/gitverdict_test.tl |  5 ++--
_work/item.tl            | 19 ++++++++------
_work/session.tl         |  7 ++++--
_work/session_test.tl    |  4 ++--
```

No line of executable code changed: every hunk is a comment, a doc
comment, or a `help =` string literal.

**Gates.** `bin/cosmic --make ci` from the board worktree ends
`ci: PASS (4 stages)`, preceded by the expected orphan-branch note
(`ci: HEAD is not a descendant of origin/main`). Test stage inside it:
`29 checks: 29 passed`, `coverage ratchet ok`, `coverage: PASS (29
files)`. Board CI for the pushed sha: run `33236961682`, conclusion
`success`
(https://github.com/whilp/cosmic/actions/runs/33236961682).

**Acceptance, measured after the change.**

| check | result |
| --- | --- |
| `help verdict` contains "refused when it built" | 0 (was 1) |
| `help next` contains "what this one built" | 0 (was 1) |
| `grep -rc 'review distance' _work/*.tl` | 0 every file (was 2) |
| `grep -rc 'disqualif' _work/*.tl` | 0 every file (was 2) |
| `grep -c 'did not build' _work/action.tl` | 0 (was 1) |
| `grep -c 'non-builder' _work/action.tl` | 0 (was 1) |
| `grep -c 'no-self-accept' _work/item.tl` | 0 (was 2) |
| `grep -rcE "builder.distance\|arm.s length\|accepts its own work" _work/` | 0 every file (was 3) |
| `grep -c 'offered no verdict' _work/session.tl` | 0 (was 1) |
| `grep -c 'withhold a verdict' _work/gitverbs.tl` | 0 (was 1) |

The freshly built binary now prints:

```
      --session SESSION  the reviewing session; it rides in the commit subject.
                         Omit to derive it from the environment
      --session SESSION  this session; skips work and reviews another session
                         holds. Omit to derive it from the environment
                         (GITBOARD_SESSION, else a runner's own id)
```

**Every rewritten claim was run, not read.** On synthetic boards built
by the new `o/bin/gitboard`:

- `next --session builder-S` on an item in `check` whose `claim` and
  `builders` both name `builder-S` answers `review <id>` — so the new
  `next` help drops the builder clause, and `action.tl`'s header no
  longer says the item goes to somebody else.
- `verdict <id> accept --session builder-Q` on that item exits 0 and
  the item moves `check -> land`. The commit reads `verdict 3IZqJwOD
  accept (check -> land) by builder-Q` — which is the new `verdict`
  help string and the new `gitverdict.tl` header, verified.
- With a review claim held by `other-T`, `next --session builder-S`
  steps over the item and answers `promote` instead — the review-claim
  skip the new `next` help and `reviewable`'s doc now name.
- With every `session.SOURCES` variable unset, `status` prints
  `session: unnamed …` and `next` IS offered that same review — so
  `session.tl` no longer says an unnamed session "is offered no verdict
  on anything", and `reviewable`'s doc says it is offered the claimed
  item too. In the `do` shape the unnamed session is likewise handed
  `finish <id> … (claimed by builder-Q)` rather than stepped past it.
- The three refusals whose comments were rewritten still refuse,
  each exit 1 with its existing message: a handover to `check` with no
  claim on an unclaimed item ("a handover to check names its builder"),
  a leftward move out of `do` over another session's live claim
  ("abandons builder-Q's live claim"), and a `--claim` overwriting a
  live foreign claim ("take over a live claim with --force --why").
- `builders` accumulates as claimed: an item held by `builder-X` then
  taken over by `other-Y` carries `["builders"] = "builder-X other-Y"`.
  `gitboard show` prints no builders line, and `grep -rn builders
  _work/*.tl` outside the tests hits only `item.tl` — which is what the
  new field doc says.

**Scope note for the reviewer.** The title says six comments; the
re-measure found fourteen, and the Evidence and Change sections were
refreshed in place (compare-and-swap) before implementation to list
them. The eight beyond the original six are `action.tl`'s module header
and `draw` doc, `gitverbs.tl:186-189`, `gitverdict.tl:12-16`,
`session.tl:19-20`, `gitverdict_test.tl:114-116` and
`gitreview_test.tl:89-90` — each false for the same reason and each
verified false by running the path it describes.

**Not done, deliberately.** `gitboard show` still does not render
`builders`; rendering it is a behaviour change this item's Non-goals
forbid, so the field doc states the record is readable in the committed
file and the log instead. `builders`, `record_builder` and the
`problems` repeat validation are byte-identical.

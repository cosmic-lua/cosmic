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

## Non-goals

- No behaviour change anywhere in `_work/**`.
- Do not reintroduce an identity check under any name.
- Do not remove `builders`, `record_builder`, or the `problems` repeat
  validation.
- Do not touch `skills/work/**`; that is `3IYkPpb2`.
- Do not change the exact-string claim lock or its `--force --why`
  takeover.

## Acceptance

Run from the `board` worktree. Every "today" was measured 2026-08-29 at
`db981771`.

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _work/` ends `test: PASS (29 files)`.
- `o/bin/gitboard help verdict` contains no "refused when it built"
  (1 occurrence today).
- `o/bin/gitboard help next` contains no "what this one built"
  (1 today).
- `grep -rc 'review distance' _work/*.tl` prints `0` for every file
  (`gitverbs.tl` 1, `session_test.tl` 1 today).
- `grep -rc 'disqualif' _work/*.tl` prints `0` for every file
  (`item.tl` 1, `gitverbs.tl` 1 today).
- `grep -c 'did not build' _work/action.tl` prints `0` (`1` today).
- `grep -c 'non-builder' _work/action.tl` prints `0` (`1` today).
- `grep -c 'no-self-accept' _work/item.tl` prints `0` (`2` today).
- `grep -rcE 'builder.distance|arm.s length|accepts its own work' _work/`
  prints `0` for every file (`gitverdict.tl` 1, `action.tl` 1,
  `gitverdict_test.tl` 1 today).
- `grep -c 'offered no verdict' _work/session.tl` prints `0` (`1` today).
- `grep -c 'withhold a verdict' _work/gitverbs.tl` prints `0` (`1` today).
- The three refusals this item's comments sit on still refuse, run
  literally: a handover to `check` with no claim on an unclaimed item,
  a leftward move out of `do` over another session's live claim, and a
  `--claim` that overwrites a live foreign claim each exit 1 with the
  message they carry today.
- The reversal still holds, run literally: a fixture item in `check`
  whose `claim` and `builders` both name `S` is offered to `S` by
  `next --session S` as a `review`, and `verdict <id> accept --session S`
  returns 0. Unchanged from `db981771` — this item must not move it.

Read the files rather than trusting the counts: each phrase sits on one
line today and a reflow can pass a count for the wrong reason.

## Enablement

Nothing. The change is prose and two string literals in a tree that
already builds.

## Ordering

Lands after `3IYYwdp7`, which is what made these passages false. It is
independent of `3IYkPpb2` — that item converges the skill on `main`,
this one the machinery on `board`, and their Non-goals exclude each
other's files.

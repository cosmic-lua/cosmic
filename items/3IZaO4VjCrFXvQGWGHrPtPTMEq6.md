## Goal

G8 — the flow system. `3IYYwdp7` deleted the identity review gate from
`_work/**`, and `3IYkPpb2` converges the `skills/work/**` prose on
`main`. Neither covers the prose left inside `_work/**` itself:
`3IYYwdp7`'s Changes named five doc comments and `3IYkPpb2`'s Non-goals
say "No change to `_work/**`". Eight passages in the machinery — two of
them the tool's own `--help` output — still describe the gate that no
longer runs.

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

**Six code comments naming the deleted rule.**

- `_work/action.tl:157-163` — the doc comment ON `reviewable`, the
  function the change edited. It still opens "The first item awaiting a
  verdict that this session did not build ... with what it stepped over
  on the way: its own builds", and repeats "every non-builder was handed
  the same top item" — the same sentence the implementer corrected in
  `gitreview.tl`'s header and left here. `ReviewPick.item`'s doc,
  "absent when nothing here is this session's to judge", is the same
  class.
- `_work/item.tl:57-61` — the `builders` field doc: "the question the
  no-self-accept rule turns on ... whoever built stays disqualified as
  reviewer."
- `_work/item.tl:292` — `record_builder`'s doc, the same claim again.
- `_work/gitverbs.tl:227-229` — "Claims on `check`/`land` mark the
  builder for review distance".
- `_work/gitverbs.tl:241-242` — "the takeover disqualifies the earlier
  holder as reviewer, so it goes through --force --why". The refusal is
  correct and stays; only its stated reason is false.
- `_work/session_test.tl:2` — "A session's identity is what the board's
  whole review distance rests on", the mirror of the `session.tl`
  header `3IYYwdp7` did correct.

Two more are weaker and may be left: `_work/gitverdict_test.tl:115-116`
and `_work/gitreview_test.tl:89-90` cite the rule as a reason for tests
that still pass.

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

`_work/{gitboard.tl,action.tl,item.tl,gitverbs.tl,session_test.tl}`,
prose and help strings only. No behaviour changes.

Each passage keeps what it says about CLAIMS and the review LEASE, and
drops what it says about an identity test withholding a verdict.

- `gitboard.tl:143` — `verdict --session` becomes the reviewing session
  and how it is derived, with no refusal promised.
- `gitboard.tl:110` — `next --session` keeps "skips work another session
  claimed" and loses "and reviews of what this one built".
- `action.tl:157-163` — `reviewable`'s doc says what the walk now does:
  the first item awaiting a verdict that nobody else is reviewing, with
  the live review claims it stepped over.
- `item.tl:57-61` and `:292` — `builders` is described as the audit
  record of who has held the claim, which is what makes review isolation
  auditable after the fact.
- `gitverbs.tl:227-229` and `:241-242` — the `do` bound and the takeover
  refusal keep their rules and lose "review distance" and "disqualifies
  the earlier holder as reviewer" as their reasons.
- `session_test.tl:2` — matches the corrected `session.tl` header:
  distinct names are what make claims exclusive.

Whether `gitboard show` should render `builders` is a separate question;
decide it here or split it, but do not leave the field described as
something `show` prints.

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

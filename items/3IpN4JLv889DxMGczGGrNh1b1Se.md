## Evidence

Two builder agents under one `/work` pass (2026-09-03), transcripts mined:

- pawY_zI7x, attempt 1: read `wc -l _make/generate.tl` → 483 at its 4th
  call, then implemented the whole Change (calls 28-48, ~560 lines) and
  only learned at call 52 that `--check lint` refuses 561 > 500. Bounced
  correctly, then `git checkout -- _make/generate.tl` discarded the diff;
  attempt 2 rebuilt it from prose (28 min, 176 calls).
- zbl9_M8VS: ran the full `bin/cosmic --make ci` 4 times between edits
  (minutes each) where `--check types <file>` answers the same question
  in seconds; 155 calls, 28 min for a 43+/47- diff.

The builder brief template: `_work/brieftext.tl` (497 lines,
`wc -l _work/brieftext.tl`), builder steps at :47-61, the STOP rule at
:79 ("Do not improvise, do not widen scope to make it work, do not
push"). Nothing there says to keep the diff, to measure a named file's
headroom first, or to prefer a per-file check between edits.

## Change

`_work/brieftext.tl` is 3 lines under the cap, so first move the review
brief's text (the second `STOP` block at :160 onward, through the
review's mutation-test paragraph at :238) into a new
`_work/brieftext_review.tl` exposing the same function names; the
callers in `_work/brief.tl` import it. Then, in the builder brief:

- step 1 gains one sentence: "Before the first edit, `wc -l` every file
  the Change names; if the Change's additions cannot fit under the
  500-line cap, STOP now (report the count) rather than after
  implementing."
- step 3 gains one sentence: "Between edits, `bin/cosmic --check types
  <file>` on the files you touched; run the full gate once, before the
  push."
- the STOP rule gains one sentence: "Leave your diff committed on the
  item branch (unpushed), never reverted: the respec starts from it."

`_work/brieftext_test.tl` (or `brief_test.tl`) pins each sentence with a
`find` assertion, the way the existing `Board:` line is pinned.

## Non-goals

No change to the review, research, refine or decompose briefs beyond
the file move; no new gitboard verb.

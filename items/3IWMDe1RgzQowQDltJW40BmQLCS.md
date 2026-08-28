## Goal

G3 — an honest type layer, no escape hatches. A carried tl patch entry is
only worth what the probe that proved it is worth, and the probe written
the obvious way reports the opposite answer in silence.

`_make/patch.tl` carries `patch.reverse` and a `Probing an entry`
paragraph that states the trap. Measured 2026-08-28 against `origin/main`
at 6a4d0182, the pointer is in `_make/` and nowhere else:

    $ grep -rl "patch\.reverse" 3p cosmic _make docs
    _make/patch.tl
    _make/patch_test.tl
    $ grep -c "Probing an entry" _make/patch.tl 3p/tl/tl_patch/*.tl \
        cosmic/teal_narrowing_test.tl
    _make/patch.tl:1
    3p/tl/tl_patch/ast_cache.tl:0
    3p/tl/tl_patch/closure.tl:0
    3p/tl/tl_patch/narrow.tl:0
    cosmic/teal_narrowing_test.tl:0

A session probing an entry is editing `3p/tl/tl_patch/*.tl` and the
`cosmic/teal_*_test.tl` that pin its outcome. Neither mentions the trap,
and neither forces `_make/patch.tl` open.

The wrong form is still silent. Reproduced 2026-08-28 at 6a4d0182, both
probes in one process against one snippet, with `narrow-truthiness`
reversed out of `o/3p/tl/tl.lua` and THAT de-patched copy placed on
`package.path`:

    searchpath('tl')      = /tmp/wrongpath2/tl.lua
    WRONG (package.path)    chunk=@/zip/tl.lua                errors=0
    RIGHT (patch.reverse)   chunk=@/tmp/patch-reverse-rfdpyt/tl.lua errors=1
          cannot index key 'x' in variable 'r' of type R | nil

`package.searchpath` names the de-patched copy first; `require` loads the
binary's own `/zip/tl.lua` regardless and reports zero errors, which
reads as "stock tl already narrows this" — the opposite of the truth,
with nothing logged.

## Change

Append one paragraph to the shared header block of each of the three
`3p/tl/tl_patch/*.tl` files — `ast_cache.tl`, `closure.tl`, `narrow.tl` —
as the LAST lines of the header, directly above that file's `return {`
line, byte-identical in all three. Exactly these seven lines, verbatim
(a bare `--` separator, then six comment lines):

    --
    -- Probing an entry: reverse it with `_make.patch`'s `reverse`, which loads
    -- the de-patched copy into `package.loaded`, the table `require` reads
    -- before any searcher. A modified copy placed on `package.path` is ignored
    -- instead: the binary's own `/zip` searcher outranks the file searcher, so
    -- such a probe measures the shipped checker and reports a confident wrong
    -- answer with nothing logged.

Nothing else changes in those files, and no other file is touched.

Placement is settled, not open. The three files ALREADY carry a
byte-identical two-paragraph tail (`The mechanism is _make/patch.tl…` and
`Carried, not forked:…`) — verified 2026-08-28:

    $ for f in 3p/tl/tl_patch/*.tl; do \
        awk '/^-- The mechanism is _make\/patch.tl/,/^-- until the patch is re-audited/' \
        "$f" | md5sum; done
    e873abccfdd1d9688699611cb3be007b  -
    e873abccfdd1d9688699611cb3be007b  -
    e873abccfdd1d9688699611cb3be007b  -

so a third replicated paragraph is the file set's existing convention
rather than new duplication, and the replication is mechanically
checkable (Acceptance asserts one occurrence per file, three in total,
and that the extended block stays byte-identical). Duplication is the
right answer here because the alternative — one canonical copy the three
files point at — is the shape that already failed: `_make/patch.tl` IS
that canonical copy, and a session editing an entry never opens it.

Measured headroom against the 500-line cap, 2026-08-28:

    $ wc -l 3p/tl/tl_patch/*.tl
      168 3p/tl/tl_patch/ast_cache.tl
      348 3p/tl/tl_patch/closure.tl
      403 3p/tl/tl_patch/narrow.tl

seven lines each takes them to 175, 355 and 410.

## Non-goals

- No `cosmic/searcher.tl` change. Its `/zip` precedence is deliberate, a
  runtime warning there is a behaviour change in every artifact including
  a STRIPPED one, and there is no room: `wc -l cosmic/searcher.tl` is 498
  against the 500-line cap (measured 2026-08-28).
- No new test and no gate. `cosmic/searcher_test.tl`'s
  `test_the_zip_searcher_outranks_the_file_searcher` already pins the
  precedence that makes the wrong form wrong; what is missing is the
  pointer, not a check. This slice adds prose only.
- No change to `_make/patch.tl` — not its `reverse`, not its `Probing an
  entry` paragraph — and none to `_make/patch_test.tl`.
- No change to any `cosmic/teal_*_test.tl`.
- No `docs/guides/**`, `docs/design/**`, `docs/decisions/**` or AGENTS.md
  change.
- No new patch entry, and no edit to any entry's `find`, `replace` or
  `note`. The `find`/`replace` strings are exact anchors: a stray edit
  fails the next `--make fetch`.
- Do not reword, reflow or reorder the two existing shared paragraphs.
  Acceptance asserts the extended block is byte-identical across the
  three files, so any edit to one must be made to all three or the check
  fails — which is the point.
- Do not add a `note` field, a `--docs` entry, or any second home for the
  wording. One paragraph, three files, nothing else.

## Acceptance

A doc-only change exercises no gate stage: `--make ci` proves only that
nothing broke, never that the prose landed where the spec says. The
greps below are what prove that, and they are the contract.

- `git diff origin/main...HEAD --name-only` prints exactly these three
  lines and nothing else:

      3p/tl/tl_patch/ast_cache.tl
      3p/tl/tl_patch/closure.tl
      3p/tl/tl_patch/narrow.tl

- the paragraph is in each file exactly once:

      $ grep -c "^-- Probing an entry: reverse it with " 3p/tl/tl_patch/*.tl
      3p/tl/tl_patch/ast_cache.tl:1
      3p/tl/tl_patch/closure.tl:1
      3p/tl/tl_patch/narrow.tl:1

  (today, before the change, all three print `0`.)

- the shared block, extended, is byte-identical across the three:

      $ for f in 3p/tl/tl_patch/*.tl; do \
          awk '/^-- The mechanism is _make\/patch.tl/,/^-- answer with nothing logged\.$/' \
          "$f" | md5sum; done

  prints the same digest three times.

- the paragraph sits in the header, not in the data: the line number of
  the match is below `return {` in no file —

      $ for f in 3p/tl/tl_patch/*.tl; do \
          echo "$f $(grep -n '^-- Probing an entry' "$f" | cut -d: -f1)" \
               "$(grep -n '^return {' "$f" | cut -d: -f1)"; done

  prints, for each file, a first number smaller than the second:
  `ast_cache.tl 19 25`, `closure.tl 53 59`, `narrow.tl 18 24`.

- the files stay under the cap:

      $ wc -l 3p/tl/tl_patch/*.tl

  prints 175, 355 and 410 (each ≤ 500). A sibling PR that grows
  `narrow.tl` first shifts these numbers; re-measure and keep the ≤ 500
  bound, which is the contract.

- `bin/cosmic --make ci` ends `ci: PASS`.

- the three files' `.cosmic-coverage` entries are `covered = 0, total = 1`
  today (`grep '"3p/' .cosmic-coverage`), and a comment-only change does
  not move them. If any ratchet does complain, run exactly the regen
  command its failure message prints and commit the result — never weaken
  the gate another way.

## Enablement

Core is exhausted before this slice starts, and that is why it is prose.
`patch.reverse` (in `_make/patch.tl`) is the right form and already
exists; `cosmic/searcher_test.tl`'s
`test_the_zip_searcher_outranks_the_file_searcher` already pins the
precedence that makes the wrong form wrong. What no core mechanism can
reach is the wrong turn itself: it happens in a throwaway probe script
under `/tmp`, outside the repo, so no lint reads it, no coverage counts
it, and no test can fail on it. The one core option that WOULD reach it
is a runtime warning in `cosmic/searcher.tl`, and it is closed twice
over — 498/500 lines (measured 2026-08-28) and a behaviour change in
every artifact. So: no blocker items, and `blocked_by` stays empty.

The wrong turns a builder can still take here, each with its wall:

- **Writing the paragraph in their own words.** The `Change` gives the
  seven lines verbatim and Acceptance greps the first line's exact text
  and the block's digest, so a paraphrase fails the check rather than
  landing three near-copies that immediately drift.
- **Putting it in one file and pointing the other two at it.** That is
  the shape that already failed — `_make/patch.tl` is exactly that
  canonical copy, and the item exists because nobody opens it. The
  Acceptance grep demands one occurrence in each of the three.
- **Adding it to `cosmic/teal_narrowing_test.tl` too, "while we're
  here".** Non-goaled. Those files pin an entry's OUTCOME; they do not
  hold the `find`/`replace` text a prober is reading. There are five
  `cosmic/teal_*_test.tl` on `origin/main` today
  (`ls cosmic/teal_*_test.tl` — closure, config, narrowing, nilflow,
  test) and PR #1481 adds a sixth, so the same one-paragraph duplication
  would be six-wide and would collide with a live PR.
- **Adding a lint or a test to police the duplication.** Non-goaled: the
  Acceptance greps are this slice's contract, and a drift-policing lint
  over one three-file directory is its own item if drift is ever
  observed.
- **Adding a warning to `cosmic/searcher.tl` because it looks like the
  real fix.** Non-goaled and measured: 498/500, and it changes runtime
  behaviour in every artifact.
- **Reflowing the header while editing it.** Non-goaled; the digest
  check across the three files catches it.

Composition with the three live siblings, all in `check`:

- **3IWJ2cHm (PR #1481)** modifies `3p/tl/tl_patch/narrow.tl` — the only
  overlap. Its hunk is inside the `return { … }` data (the
  `narrow-metatable-is` entry, `@@ -257,13 +257,36 @@`); this slice's
  hunk is the header immediately above `return {`, which sits at line 17
  today and line 24 after. Different hunks, ~240 lines apart, so git
  merges them cleanly. #1481
  also deletes 167 lines from `cosmic/teal_narrowing_test.tl` and adds
  `cosmic/teal_metatable_test.tl`; this slice touches neither. Whichever
  lands second re-measures the `wc -l` line above and keeps the ≤ 500
  bound.
- **3IVF3HbV (PR #1480)** touches `_perf/**`, `.github/workflows/release.yml`,
  `skills/optimize/SKILL.md` and `.cosmic-coverage` — file-disjoint.
- **3IVHXoDw (PR #1471)** touches `_build/**`, `_cli/**` and
  `.cosmic-coverage` — file-disjoint. Its new `_build/nil_returns.tl`
  ratchet excludes `3p/` from the trees it counts, so this slice cannot
  move its baseline.

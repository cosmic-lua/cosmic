## Goal

G8 — the flow system. Reading a spec through `gitboard` should cost
less than going around the tool, so the skill's rule that board reads
go through `gitboard` survives contact with a 338-line sidecar.

## Evidence

`gitboard show ID` prints fields, role, spec and git history as one
block, and has no option to narrow it (`gitboard help show` lists only
`--dir`). Measured 2026-08-22:

    338 items/3ICDHHW7UiksaaojXJyS6lMKdgp.md    (the spec sidecar)
     12 items/3ICDHHW7UiksaaojXJyS6lMKdgp.tl    (the item record)

Pulling `3ICDHHW7` in the 2026-08-22 scheduled session took three
`show` invocations piped through `head` and `sed` line ranges to page
the spec, plus a fourth for the history at the end; every one
re-printed the fields header. A ready-bar spec is long BY DESIGN, so
this is a read to narrow, not a spec to shorten.

## Change

Three modes on `show`, each printing one thing and nothing else. The
default output does not change.

1. **New module `_work/gitshow.tl`.** Move `show_report` and
   `cmd_show` out of `_work/gitview.tl` — the block
   `sed -n '236,353p' _work/gitview.tl` (118 lines, doc comments
   included) — into it unchanged, drop them from `gitview`'s record
   and table, and require the new module from `_work/gitboard.tl`.
   The move is forced by capacity, not taste: `wc -l < _work/gitview.tl`
   is 495 at board head `46f3f43b`, five lines under the 500-line cap,
   so `show` cannot grow where it stands.

2. **`cmd_show` widens to `cmd_show(s: store.Store, id: string, mode:
   string, section: string): integer`**, where `mode` is one of:
   - `""` — today's report, byte-identical.
   - `"spec"` — the sidecar verbatim, no fields header and no history.
     An item with no sidecar fails: `<id8> has no spec`.
   - `"section"` — the one section `section` names, its heading line
     included. A section the sidecar does not carry fails:
     `<id8> spec has no section: <NAME>`.
   - `"fields"` — today's report minus the `--- spec ---` block and
     minus the history lines.

   The three are mutually exclusive; two or more together fail with
   `REFUSED: --spec, --section and --fields each narrow one read — pass one`.
   Every path still ends in the `gitboard-show:` verdict line
   `gate.verdict_line` already writes.

3. **`_work/spec.tl` gains `section_of(body: string, name: string):
   string`** — the named section including its heading line, `""` when
   absent. It matches headings exactly as `ready_gaps` already does
   (any heading level, case-insensitively on the heading text) and
   ends the section at the next heading or a thematic break, so the
   grammar has one implementation and `--section acceptance` and
   `--section Acceptance` name the same thing. `wc -l < _work/spec.tl`
   is 87, so it has the room.

4. **`_work/gitboard.tl`**: `show`'s flag list gains
   `{long = "spec"}`, `{long = "section", arg = "NAME"}` and
   `{long = "fields"}`, and the dispatch tail passes the mode and the
   section name through. `wc -l < _work/gitboard.tl` is 296.

5. **Tests**: new `_work/gitshow_test.tl` carrying the six
   `show_report` cases that move out of `_work/gitview_test.tl`
   (`grep -c show_report _work/gitview_test.tl` is 6) plus one case
   per new mode and one for the mutual-exclusion refusal;
   `_work/spec_test.tl` gains `test_section_of` covering a present
   section, an absent one, a lowercase spelling, and a section ended
   by a thematic break.

## Non-goals

- The default `show` output does not change — not its line order, not
  its history block, not the `gitboard-show:` verdict line. Whether
  history should move behind its own flag is a separate question and
  stays unanswered here.
- No new verb. This is `show`'s flags; there is no `spec-show`.
- `spec.READY_SECTIONS` and `spec.ready_gaps` keep their current
  behaviour and signatures — `section_of` is added beside them.
- `_work/gitview.tl` keeps `status`, `tree`, `next` and `find` exactly
  where they are; do not reorganize what stays.
- No change to how sidecars are stored or read (`store.read_spec`).

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _work/gitshow_test.tl _work/spec_test.tl`
  ends `test: PASS`.
- The cap the split exists to respect, as commands:
  `wc -l < _work/gitview.tl` ≤ 400, `wc -l < _work/gitshow.tl` ≤ 260,
  `wc -l < _work/gitboard.tl` ≤ 320, `wc -l < _work/spec.tl` ≤ 140.
- `o/bin/gitboard show 3IHLXAaV --spec` ends
  `gitboard-show: 3IHLXAaV is plan` and prints no `parent:` line
  (`o/bin/gitboard show 3IHLXAaV --spec | grep -c '^parent:'` is 0).
- `o/bin/gitboard show 3IHLXAaV --section Acceptance` ends the same
  verdict line and prints a first line of `## Acceptance`.
- `o/bin/gitboard show 3IHLXAaV --section Nonesuch` ends
  `gitboard-show: 3IHLXAaV spec has no section: Nonesuch` and exits 1.
- `o/bin/gitboard show 3IHLXAaV --spec --fields` ends
  `gitboard-show: REFUSED: ...` and exits 1.
- `o/bin/gitboard help show` lists `--spec`, `--section` and
  `--fields`.

## Enablement

none needed — the section grammar this reuses already lives in
`_work/spec.tl` (`ready_gaps`), the verdict-line convention in
`_work/gitgate.tl`, and the report-plus-`cmd_` split the new module
follows is stated in `_work/gitview.tl`'s own module doc. The one
wrong turn a literal-minded session could take is growing
`_work/gitview.tl` past the 500-line cap instead of splitting; the
`wc -l` bounds in Acceptance are the countermeasure, and they are
commands, not prose.

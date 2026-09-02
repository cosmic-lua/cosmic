## Goal

`_build/size.tl`'s `format_compare` — the line release.yml prints
into size-compare.txt and folds into every release's notes — never
surfaces the one number G9's win condition names by itself: AGENTS.md's
doctrine-size delta. The `Report` and `REPORT_SPEC` already carry
`agents_md_lines` every release, but `format_compare`'s one-line
summary reports only `lines`, `files`, `binary`, and `public modules`
— never `agents_md_lines` or its delta. A reader of any release's
`size:` note (or size-compare.txt) cannot tell whether doctrine size
grew or shrank without downloading two size.json assets and diffing
them by hand.

## Evidence

- `_build/size.tl`'s `format_compare` (L165-179) builds its returned
  string from `plines/pfiles, clines/cfiles, pbin/cbin, pmod/cmod`
  only — `rep.agents_md_lines` never appears in the function.
- `_build/size_test.tl`'s two `format_compare` assertions (around
  L108 and L123) check the emitted line's exact text and never
  mention `agents_md_lines`, confirming the omission is by design.
- Every release body since `_build/size.tl` landed
  (`2026-08-17-a3cd318` through `2026-09-01-3c80edc`, checked via the
  GitHub releases API) prints exactly `size: lines N (+d), files N
  (+d), binary N (+d), public modules N (+d)` — never a doctrine or
  agents figure.
- The field exists and moves: downloading `size.json` directly shows
  `2026-08-17-a3cd318` → `agents_md_lines: 498`;
  `2026-09-01-3c80edc` → `agents_md_lines: 384`. The number is
  recorded every release; it is simply never compared or printed.

## Change

Add `agents_md_lines` (and its `%+d` signed delta) to
`format_compare`'s summary line in `_build/size.tl`, following the
exact pattern already used for `lines`/`files`/`binary`/`public
modules` (e.g. append `, doctrine %d (%+d)` to the `string.format`
call and its argument list). Update `_build/size_test.tl`'s two
`format_compare` assertions (the handwritten-report comparison tests
around L78-124) to match the new line text exactly. No change to
`Report`/`REPORT_SPEC` or `report()` — the field already exists and
is already written every release; this only makes the existing
number visible in what actually gets published and diffed release
over release.

## Non-goals

- No change to which trees are tracked, what counts as a line, or
  the JSON schema (`REPORT_SPEC`).
- Not a redesign of the release-notes format beyond appending one
  clause to the existing `size:` line.
- No change to `release.yml` — it already prints whatever
  `format_compare` returns.

## Acceptance

- `format_compare`'s returned line includes a doctrine/agents-md-lines
  figure and its signed delta, in the same `%+d`-always-signed style
  as the other four fields.
- `_build/size_test.tl`'s two `format_compare` tests assert the exact
  new line text (including the doctrine clause) and pass under
  `o/bin/cosmic --make test _build/size_test.tl`.
- `o/bin/cosmic --make ci` passes.

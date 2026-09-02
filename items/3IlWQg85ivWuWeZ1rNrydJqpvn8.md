## Goal

G3 — an honest type layer. The first half of the flat `cosmic/*_test.tl`
cut of the `cosmic/**` `check.must` sweep (3IQfJ1tn), cut by count:
the three `embed_*` tests and `time_parse_test`, 32 sites in 4 files,
two mechanical shapes only.

## Evidence

Census Method re-run 2026-09-02 at `5a36e7c9`:

```text
shape 1 — `zip.open_string(data)` where `data = fs.read(…)` one line above (fs.read: string | nil):
cosmic/embed_test.tl:37 :67 :112 :131 :154 :188 :210 :311 :345 :376 :414   (11; producers at line-1 each)
cosmic/embed_advanced_test.tl:44 :61 :102 :125 :167 :338 :362               (7; producers 43 60 101 124 166 337 361)
cosmic/embed_env_test.tl:47 :97                                             (2; producers 46 96)
shape 2 — time.format_date / format_iso8601 (string | nil) used at '..' or passed to parse_*:
cosmic/time_parse_test.tl rows 70 75 81 130 132 139 144 150 237 239 244 245  (12)
  producers: 69 74 80 (format_date) 129 (format_date) 138 143 149 (format_iso8601) 236 243 (format_iso8601) = 9
```

Headroom: `embed_test.tl` **493** of the 500-line cap — every edit
there is in place, and it already imports `check` (as do
`embed_advanced_test` 411 and `embed_env_test` 112); `time_parse_test`
246 lines, **no** `cosmic.check` import today.

## Change

- The 20 `fs.read` producers → `local data = check.must(fs.read(…))`
  (`orig_data`/`new_data` likewise). Zero net lines in `embed_test.tl`.
- The 9 `time.format_*` producers →
  `local s = check.must(time.format_date(…))` etc.; add
  `local check = require("cosmic.check")` to `time_parse_test.tl`.

## Non-goals

- No file outside these four; no library file.
- No checker change; no census doc edit; no committed strict checker.
- Do not change what a test asserts. Do not add a cast.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- The Method's scan reports **0** rows for
  `cosmic/(embed_test|embed_advanced_test|embed_env_test|time_parse_test)\.tl`.
- Other shares unmoved from the pull-time baseline (2026-09-02:
  library 12; non-`cosmic/**` 0 / 11). Quote before/after.
- `wc -l cosmic/embed_test.tl` ≤ 500.
- `git diff --name-only origin/main` lists only those four files.

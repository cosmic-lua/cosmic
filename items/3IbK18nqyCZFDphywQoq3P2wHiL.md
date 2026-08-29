## Change

The handle's chunk divider becomes an underscore — `«d0x1_37YJ»` —
because `_` is a word character and `-` is not: a double-click
selects the whole 9-character handle body in one gesture instead of
stopping at the hyphen, so the rendered handle is copyable as one
unit. Input stays tolerant of BOTH dividers — hyphenated handles
exist in scrollback, PR comments, and this spec's predecessors, and
tolerance is one character class.

The three lines in `_work/tail.tl` (line numbers measured
2026-08-29, `grep -n`):

1. Line 20, `handle`: the concatenated `"-"` becomes `"_"`.
2. Lines 31-32, `is_tail_shape`: `%-?` becomes `[%-_]?` in both
   patterns (bare and guillemet-wrapped). Note Lua's `%w` does NOT
   match `_`, so the divider must stay its own optional class —
   `^%w%w%w%w[%-_]?%w%w%w%w$` and the `«...»` twin.
3. Line 46, `resolve`: the strip class `[«»%-]` becomes `[«»%-_]`.

Tests, in place: update the expected-render strings (3 `«XX-XX»`
literals in `_work/tail_test.tl` lines 31/38/62, plus whatever
`_work/gitview_test.tl` and `_work/gitshow_test.tl` assert with a
hyphenated handle — measure with `grep -n '«.*-.*»'`). Add one
assertion that a HYPHENATED paste (`«d0x1-37YJ»` form) still
resolves, pinning the backward tolerance.

## Non-goals

Nothing outside `_work/tail.tl` and the render tests changes — the
render sites call `tail.handle` and inherit the divider. Verdict
lines, refusal texts, commit subjects, `flow item=` lines, and item
files untouched (`_work/flowstats_test.tl` proves the grammars).
The handle stays derived, never stored.

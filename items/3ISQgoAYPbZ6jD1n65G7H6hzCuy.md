## Goal

G3 hygiene: the erasure rules in `_types/gentl.tl` say what they do
again. PR #1406 added `FILE` to the `KEEP` pass-through set so the
generated `tl.d.tl` keeps `search_module`'s honest second return
(`string, FILE, {string}`), but the rules comment directly above still
reads "primitives pass through" — a reader auditing the erasure now
finds a non-primitive in the primitive set with no stated reason,
which is exactly the drift the generator's own header warns about.

## Evidence

Measured 2026-08-26 against main `8f34339e`:

- `_types/gentl.tl:14–16` — the rules comment: "Erasure rules:
  primitives pass through; upstream enums/aliases of string become
  string; the records this file re-declares keep their names;
  everything else (internal records, interfaces) becomes any."
- `_types/gentl.tl:17–20` — `KEEP` holds `string, boolean, integer,
  number, any, ["nil"]` and, since #1406, `FILE = true` — the one
  entry the comment does not license.
- The reason, verified when #1406 landed: Teal predeclares `FILE`
  globally (the io handle class), so the generated declaration can
  name it with no re-declaration, and erasing it to `any` was the
  only reason `search_module`'s open-handle return read as `any`.
- `_types/gentl.tl:159` quotes the upstream doc line ("an open FILE
  handle (caller must close") — the generated output's own comment
  already names the type; only the rules prose lags.

## Change

One comment edit in `_types/gentl.tl`: the erasure-rules doc comment
gains the FILE clause — primitives pass through, and so does `FILE`,
because Teal predeclares it globally (the io handle class), so keeping
it costs no declaration and erasing it would lose an honest handle
type (`search_module`'s second return). Reflow within 90 columns. No
code change; `KEEP`'s entries are untouched.

## Non-goals

- No erasure behavior change, no `KEEP`/`TO_STRING`/`NAMED` edits.
- No regeneration concerns: comments do not reach `tl.d.tl`.
- Not a decision record — a generator's local rule prose, not a
  tradeoff.

## Acceptance

Run from the repo root:

- `bin/cosmic --make ci` ends `ci: PASS`.
- `grep -c "FILE" _types/gentl.tl` counts at least one more than
  today's 2 — the rules comment now mentions it (today: the KEEP
  entry and the quoted upstream doc line; nothing in the rules
  prose).
- `grep -n "predeclares" _types/gentl.tl` prints one line (today:
  none).
- `git diff --name-only origin/main` lists exactly `_types/gentl.tl`,
  and `git diff origin/main -- _types/gentl.tl` touches only comment
  lines.

## Enablement

none needed. The reason is established fact from #1406's review (Teal
predeclares FILE globally); the change is prose beside the code it
describes.

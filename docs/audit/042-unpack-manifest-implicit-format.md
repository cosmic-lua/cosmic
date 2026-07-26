# 042 — the `.unpacked` manifest is a line format over names nothing validates

severity: low
type: design / robustness (follow-on to 001's fix)
area: `_make/fetch.tl`, `cosmic/tar.tl`, `cosmic/zip.tl`

## issue

001's fix records unpack products in `<archive>.unpacked`, one path per
line, and `products_present` re-reads it by `gmatch("([^\n]+)")`. the
format's delimiter is a byte the recorded names may legally contain:
archive member names are attacker-shaped input, and neither
`tar.unsafe_path` nor the zip name checks refuse control characters —
they refuse empty/absolute/backslash/`..`/drive-letter, and the
project-side filename gate (validate.tl) does not apply to archive
members at all.

a member named `a\nb.txt` extracts fine, the manifest records it as two
lines `a` and `b.txt`, `products_present` finds neither, and every
subsequent `--make fetch` decides the pin needs repair and re-unpacks —
a permanent "unpack" on every run, with nothing pointing at the cause.
benign in effect (fetch stays correct), but it is the same shape 001
was: state that misdescribes the tree, silently, forever.

the general principle: a persisted format whose delimiter can appear in
its payload needs either payload validation or a delimiter that cannot.

## where

- `_make/fetch.tl` — `manifest_of` write (newline-joined) and
  `products_present` read (`[^\n]+`).
- `cosmic/tar.tl` (`unsafe_path`) and the zip extraction checks — no
  control-character rejection.

## suggested fix

either end works; both is cheapest at the guards that already exist:

1. reject control characters (at least `%c`) in `tar.unsafe_path` and
   the zip name check — a member name with a newline has no legitimate
   use, and refusal-by-name is the codebase's stated posture. this also
   closes the class for every other consumer of extracted names.
2. (belt and braces) make the manifest delimiter unrepresentable: NUL
   separators, since the guards can refuse NUL trivially.

## test to add

a crafted archive with a member name containing `\n`: assert extraction
refuses it (option 1), and that two consecutive fetches of a satisfied
format pin perform zero unpacks (pins the no-repair-loop property
either way).

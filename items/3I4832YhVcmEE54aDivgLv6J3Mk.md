Found while landing item 3HyCSe5U (PR whilp/cosmic#1264, peer table v1).

Item spec sidecars imported from GitHub issues carry raw HTML entities baked
into their stored text (e.g. `&#39;` for an apostrophe, `&#34;` for a double
quote) instead of the real characters — visible today in
`items/3HyCSe5UymQuLd6ZuQr16pklSp9.md` lines 254-255:

    - `ls _perf/peers | grep -o &#39;_bench\.tl&#39; | wc -l` prints `0`.
    - `grep -c &#39;^  peers:&#39; .github/workflows/release.yml` prints `1`.

`move ID check --pr N`'s Acceptance-quoting gate does an exact substring match
of each Acceptance line against the PR body. A PR body written with real
apostrophes (the only reasonable thing for an implementer to write — a
literal `&#39;` in rendered markdown would look broken to a human reviewer)
therefore never matches, and the gate REFUSES a PR that in fact quotes and
ran every Acceptance command correctly. Worked around this time with
`--force --why`; the underlying bug is unrepaired.

Likely reproduces on every item whose spec sidecar came through the same
GitHub-issue import path and whose Acceptance/Change text contains a quote,
apostrophe, or ampersand — same shape as `gitboard show`'s own rendering,
which prints these entities raw rather than decoded (see this session's
transcript: item titles and spec bodies throughout render `&#39;`/`&#34;`
literally).

Fix shape (not investigated further): decode HTML entities once at import
time (or in the store/render layer) so stored spec text carries real
characters throughout, and re-run the decode over already-imported items so
old items don't carry the pollution forward. The quoting gate's substring
match is correct; the data feeding it is not.

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

## Second occurrence (2026-08-18) — confirms the fix shape, raises the stakes

Found again while refining item 3I0L8yuR, and worse than the first sighting:
this time the pollution broke `gitboard check`'s own `facts` execution, not
just the PR-quoting gate. `items/3I0L8yuRpu3qARCS9LGEi5Lo517.md` carried 71
raw entities (42 `&#34;`, 22 `&#39;`, 6 `&amp;`, 1 `&lt;`) including inside
`$`-prefixed fact commands, e.g. `$ wc -l &lt; skills/work/review.md` and
`$ grep -ci &#34;flow review&#34; skills/work/review.md`. `_work/facts.tl`
runs a fact's command verbatim through `/bin/sh -c` — `&lt;` is not a
redirect, it is the literal three characters `&`, `l`, `t`, `;`, and a
bare `&` backgrounds the preceding token — so EVERY fact on this item
reported a false failure (`wc -l` alone, backgrounded, reads empty stdin
and prints `0`; `grep -ci &#34;flow` similarly runs disconnected from its
pattern and prints nothing). `gitboard check` therefore cannot evaluate
ANY fact containing a quote, apostrophe, ampersand, or angle bracket —
which is most facts blocks that grep or redirect, i.e. most items on this
board. Worked around this occurrence by hand: fetched the raw committed
bytes with `git show HEAD:items/<id>.md`, ran them through Python's
`html.unescape`, and replaced the sidecar with `gitboard spec`. Confirmed
by diff that decoding only touched the entity sequences (the two `&amp;`
occurrences were both `&amp;&amp;` → `&&` in shell facts, correctly
recovered — no legitimate literal ampersand exists in this item's text to
false-positive on).

Per `review.md`'s feedback rule ("if the same wrong turn has now appeared
twice, the countermeasure stops being optional"): this is now two
independent items, hit two different ways (a review-time PR-quoting
refusal, and a refine-time fact-verification failure that silently makes
`check`/`move ready` unusable on a whole class of items rather than
erroring loudly). Filing the countermeasure is no longer optional —
whichever planner or implementer next has ready-queue slack should pull
this rather than intake something new. Suggested acceptance for the fix:
after landing it, re-running `gitboard check` on an item with a
known-polluted sidecar (or a synthetic fixture carrying `&#34;`/`&lt;`
inside a facts command) should show the entity decoded and the fact
evaluated against its real command, not silently misexecuted.

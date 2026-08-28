## Evidence

Measured 2026-08-28 against `origin/main` `40776231`.

The `doc-citation` rule scans inline citations with a per-LINE backtick
pairing (`_cli/citations.tl:268`, `for span in line:gmatch("`([^`]+)`")`).
Markdown code spans may wrap a line break, and when one does, the pairing
matches the wrong backticks and the citation on that line is never seen.

`docs/design/casts.md:55-56` is the case in the tree:

```
`cosmic/json.tl:135` declares `decode_object(str): {string: any} | nil,
string` and `cosmic/json.tl:155` declares `decode_array(str): {any} |
```

On line 56 the backticks pair as `` ` and ` `` and `` ` declares ` ``, so
`cosmic/json.tl:155` is not a span at all. It is also WRONG —
`decode_array` is declared at `cosmic/json.tl:157` — and the gate is
green:

    o/bin/cosmic --check lint docs/design/casts.md   # Style check passed

Census of the recognizer's blind spot: the lint sees 8 live inline
citations across the 97 markdown files in `lint_sources`; a line-based
grep for the same shape finds 9. The one it misses is this one.

Found while refining `3IYPq8Sx` (which retires the live inline form and
fixes this site's text, but deliberately does not widen the recognizer —
its Acceptance grep is what covers this site there). After that item
lands the blind spot persists for the FENCED form and for any future
wrapped span, so the recognizer is still the thing to fix.

Candidate shapes, not yet chosen:

- carry an open-span buffer across lines in the non-fenced region, so a
  wrapped code span is paired the way markdown pairs it;
- or normalize the document's non-fenced region into one string before
  scanning, mapping offsets back to line numbers for the diagnostic.

Either needs a test for the wrapped case and one for a span that opens
and never closes.

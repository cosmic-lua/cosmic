Every PR body written through the GitHub MCP tools is HTML-sanitized
in transit. Text shaped like a tag is DELETED; `&`, `'`, `"`, `>` are
entity-escaped. Neither inline backticks nor fenced code blocks
prevent either.

## Measured 2026-08-22

Same session, same sentence, two paths. Via `git commit` (Bash), in
`b855dc66`:

    the rework path merely PRINTED "hand it back with --claim <session>".
    - `verdict` takes `--session`, and refuses when it names the item's

Via `create_pull_request`, the same content in whilp/cosmic#1321, read
back with `pull_request_read`:

    REFUSED:  is 's own build — no session accepts its own work
    verdict   ( -> ) by

`<session>`, `<id8>`, `<kind>`, `<from>`, `<to>` and `<board@cosmic>`
are gone; `'` became `&#39;`. In whilp/cosmic#1322 a FENCED block
stored as `check -&gt; completed`, so fences do not protect against
the escaping half either.

**This predates this session and is not specific to it.**
whilp/cosmic#1284 (2026-08-19, a different session) carries the same
signature: `this session&#39;s 403-walled token` in prose and
`grep -n &#34;merged&#34; _work/review.tl` inside a fenced block.

## Why it matters more than it looks

In PROSE the damage hides: GitHub's markdown renderer decodes `&#39;`
back to `'`, so a sanitized paragraph reads correctly and nobody
notices. Inside code spans and fenced blocks CommonMark does NOT
decode entity references, so a command containing a quote renders
literally as `grep -c &#39;gh\.&#39; file` — not copy-pasteable. Every
acceptance block this repo's agent sessions have shipped with a quoted
command is affected. (The render behaviour is inferred from CommonMark
plus the stored bytes; it has not been confirmed against the rendered
page.)

The placeholder deletion is the louder half: a PR body explaining a
message format or a commit-subject grammar loses exactly the
placeholders that carry its meaning, and the sentence still reads as
prose, so the loss is silent.

## Directions, not a decision

- A gate: `move ID check --pr N` already fetches the PR and runs
  `review.blocks_check` over its body. A sibling check could refuse a
  body carrying `&#NN;` or a bare `&gt;`/`&lt;`/`&amp;`, naming the
  transit sanitizer — the mistake is mechanical and recurring, which
  is what `enable.md` says belongs in core rather than in prose.
- A read-back: any session posting a body re-reads it and diffs
  against what it sent. Catches whatever the sanitizer does next
  rather than the two behaviours measured today.
- Authoring rules that dodge it: no angle-bracket placeholders (use
  `ID8`, `SESSION`, `SHA7`), and quote-free example commands. Weakest
  of the three — it is prose asking every future session to remember.
- Upstream: the sanitizer belongs to the tool path, not to GitHub,
  which stores PR bodies as raw markdown.

## Where the evidence is

whilp/cosmic#1321 and #1322 (bodies via `pull_request_read`), commit
`b855dc66` (same text via git), whilp/cosmic#1284 (the same signature
from a session on 2026-08-19).

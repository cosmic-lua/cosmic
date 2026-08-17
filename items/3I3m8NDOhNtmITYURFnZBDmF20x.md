32 of the board's 49 item spec sidecars (`items/*.tl`'s companion `.md` files) —
856 occurrences total — carry literal HTML-entity sequences (`&#39;`, `&#34;`,
and a handful of bare `&amp;`) in place of real apostrophes and double quotes.
This is not a cosmetic issue: `_work/spec.tl`'s `acceptance_commands` extracts
backtick-quoted spans from an item's "## Acceptance" section VERBATIM, with no
HTML-decoding step, and `_work/review.tl`'s `blocks_check` does a raw
`body:find(c, 1, true)` substring search for each such command against a PR's
body as GitHub actually stores it. Any Acceptance command containing a shell
quote (`grep -c 'exit 0' path`, `-name 'FOO'`, etc.) on a corrupted item
therefore has a required substring of `grep -c &#39;exit 0&#39; path` — a
string a correctly-written PR body will never contain, since GitHub stores
PR bodies with real quote characters (confirmed by fetching PR #1261's body
directly via the REST API with a real token: clean, real apostrophes
throughout, no entities). `gitboard move ID check --pr N` therefore refuses
every such PR with "does not quote N of its Acceptance commands", even when
the author quoted the command exactly as it reads to a human, and there is no
way to satisfy the check without deliberately writing garbled markdown into
the PR body.

This was hit directly landing `3HyCS1Ew`: PR #1261's Acceptance section
quoted `` `grep -c 'exit 0' .github/workflows/release.yml` `` verbatim and
correctly, and `move ... check` refused it every time, because the item's
own spec sidecar stored that command as `` `grep -c &#39;exit 0&#39;
.github/workflows/release.yml` ``. Fixed for that one item by decoding its
`.md` sidecar with `gitboard spec 3HyCS1Ew <html.unescape'd file>` before
retrying the move — a legitimate but narrow workaround, not a systemic fix.

Likely cause: whatever imports a GitHub issue body into an item's spec
sidecar HTML-escapes the text (probably to be safe embedding it somewhere
HTML-ish) and never decodes it back before writing the `.md` file — the same
escaping is visible in every "Imported from whilp/cosmic#N" item this
session touched, so it looks like every import since the board's inception
carries it, not a one-off.

Two independent things are worth someone's attention:

1. A bulk one-time fix: `html.unescape` every `items/*.md` (and `.tl`, if the
   spec text is duplicated into the record's string literal there too) and
   commit the result. Cheap, mechanical, and unblocks every future `move ...
   check` on an item whose Acceptance section quotes anything with an
   apostrophe.
2. The import path itself (wherever "Imported from whilp/cosmic#N" specs are
   generated) needs the HTML-escape step removed or paired with a decode, or
   every future import reintroduces the corruption immediately after the
   bulk fix.

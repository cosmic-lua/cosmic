# 19. url.decode's gsub+match validation replaced with a manual %-scan loop

- status: rejected (2026-07-04)
- layer: cosmic
- scenario: url_decode_query_value

- evidence: `url_decode_query_value` (new): 45.04µs baseline;
  manual-loop fix measured +53.2% then +56.1% on re-measure — a
  confirmed regression, not noise (crossed the ±10% bar both times).
- hypothesis: `decode()` (lib/cosmic/url.tl) validated %XX
  percent-encoding via `str:gsub("%%(%x%x)", "")` (remove every
  valid escape) followed by `check:match("%%")` (anything left over
  is invalid) — two full-string C calls, the first of which builds
  and discards an entire copy of the string. Looked like the same
  "redundant full-string scan" shape as entry 18
  (`codec.decode_base64`).
- fix attempted: replaced the gsub+match pair with a manual loop —
  `str:find("%", pos, true)` to locate each literal `%`, then
  `str:match("^%x%x", pos + 1)` to check the two bytes after it —
  so validation only touches `%` occurrences instead of the whole
  string, with no intermediate copy.
- why it was rejected despite being the "obviously less work"
  approach: unlike base64's grammar, arbitrary percent-encoded text
  isn't expressible as a single anchored Lua pattern (the escape
  sequences can appear anywhere, and Lua patterns can't repeat a
  captured alternation), so the replacement needed a Lua-level loop
  making one `find` and one `match` call *per* `%` character. Each
  of those is a separate Lua-to-C round trip with its own call
  overhead; `QUERY_ENCODED` (the benchmark's realistic value) has
  enough `%XX` sequences that the sum of many small C calls lost to
  two single large-string C calls (`gsub`/`match`, each one call
  doing a tight internal C loop over the whole string). The "avoid
  building an intermediate string" saving was real but smaller than
  the added per-occurrence call overhead. Reverted
  (`git checkout -- lib/cosmic/url.tl`). Kept the new benchmark
  scenario per the "never remove a scenario" rule.
- lesson for future rounds: "fewer bytes touched" doesn't always
  beat "fewer Lua-to-C calls" — a single C-implemented full-string
  operation can outperform a Lua-level loop over a subset of the
  same string once the subset isn't tiny relative to call overhead.
  Entry 18 won because it was still exactly one full-string C call
  on the happy path, not more calls of any kind.
- risk: n/a, rejected on measurement grounds, not correctness (the
  manual loop was verified correct against all existing `decode()`
  tests before being measured and reverted).

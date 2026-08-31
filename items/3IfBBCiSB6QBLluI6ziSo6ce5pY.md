## Change

Move `--docs` search onto FTS5, replacing the substring scan and hand-rolled scoring
in `cosmic/doc/query.tl`.

Search today is `string.find` plus a scoring function:

```teal
local query_lower = query:lower()
local module_contains_query = mod_name:lower():find(query_lower, 1, true) ~= nil
calc_score(simple_lower, mod_doc.module_doc, query_lower, 100, 80, 30)
```

so it matches literal substrings only, in one case-folded pass over every module,
function and record in the embedded index. There is no tokenisation, no stemming, no
phrase or prefix query, no ranking beyond the hand-tuned weights above, and a query
of two words matches nothing unless those exact bytes appear adjacently.

With FTS5 compiled into the library, this becomes an index build plus a `MATCH`
query with `bm25()` ranking — a real retrieval function, and one that already knows
how to weight columns, so `calc_score`'s magic numbers (100, 80, 30 / 95, 75, 25)
either go away or become `bm25()` column weights that mean something.

### What to settle while doing it

- **Where the index lives.** The doc index ships as `.docs/index.lua` inside the
  artifact (`cmd/cosmic/embed_gen.tl` builds it). An FTS5 index is SQLite pages, not
  Lua. Either the artifact carries a prebuilt SQLite file as payload, or `--docs`
  builds an in-memory FTS5 table from the embedded index on first search. The second
  keeps the payload unchanged and costs a build per invocation; measure it before
  choosing, because `--docs` is an interactive command and startup is a promise.
- **Ranking must not regress the searches people actually run.** Capture the current
  results for a set of representative queries first, then compare. `bm25()` on a
  small corpus can rank worse than a hand-tuned exact-substring boost for
  single-token queries that are module names — which is most of what `--docs` gets.
  Keeping an exact-name boost on top of `bm25()` is likely correct and should be a
  deliberate decision, not a discovery.
- **Behaviour when FTS5 is absent.** A build compiled without it must still search.
  Keep the substring path as the fallback, chosen at runtime by asking whether the
  module exists, exactly as `cosmic/sqlite/zipfile_test.tl` asks
  `pragma_module_list`.

### Gate

A test asserting a multi-word query that fails today succeeds after, plus the
representative-query comparison above recorded in the PR. If the in-memory build
path is chosen, a `_perf` scenario for `--docs` search, since it moves an
interactive command's cost.

## Non-goals

- No change to what the doc index contains or to `_tool/doc`'s extraction half.
- No change to `--docs`'s output format.
- No vector or semantic search.

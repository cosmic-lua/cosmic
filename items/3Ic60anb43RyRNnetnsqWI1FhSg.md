## Change

Evidence (review of PR #1542, 2026-08-30): the ETag cache's
`CacheEntry` (`_work/api.tl`) carries no integrity check on `body` — a
cache file corrupted in a way that still parses as a valid literal (a
flip inside the body string, rather than a truncation that breaks
brace/quote balance and already falls back to a miss) is silently
replayed on a 304 match, and the cache is invisible to a human
debugging a stale board fact. The change, in `_work/api.tl` (+
`_work/api_test.tl`): add an integrity field to CacheEntry (a sha256
of the body via the crypto the tree already ships, or the body's
length if no cheap hash is importable from `_work/` — measure what
`cosmic.*` offers and pick the strongest that imports cleanly);
validate on read in `read_cache` (or wherever the entry is loaded —
follow the merged shape); mismatch = cache miss (entry ignored, fresh
fetch path). Tests: a hand-written syntactically-valid entry whose
body disagrees with its integrity field reads as a miss; a valid
entry still hits; mutation-verify the validation (skip the check,
watch the mismatch test go red).

## Non-goals

No change to the 304 protocol, cache keying, or freshness logic. No
cache format migration handling beyond treating old entries (missing
the field) as misses — they repopulate on the next fetch.

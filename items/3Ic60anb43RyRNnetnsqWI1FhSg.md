Evidence (review of PR #1542, 2026-08-30): the ETag cache's
`CacheEntry` (`_work/api.tl`) carries no integrity check on `body` —
a corrupted cache file that still parses as a valid literal (a bit
flip inside the body string, rather than a truncation that breaks
brace/quote balance and falls back to a miss) is silently replayed on
a 304 match, and the cache is invisible to a human debugging a stale
board fact. Narrow, low-probability. The change: add a checksum (or
length) field to CacheEntry, validate on read, treat mismatch as a
miss; one test writing a syntactically-valid-but-mangled entry and
watching it miss.

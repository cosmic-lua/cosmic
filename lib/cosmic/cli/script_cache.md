# script_cache

 Caches compiled Lua output for .tl scripts run directly (`cosmic
 script.tl`), keyed by path + content + cosmic build version, so a
 repeat run of an unchanged script skips Teal compilation entirely.
 Reading the source to hash it is cheap next to a full Teal compile,
 and (unlike an mtime-based key) can't produce a stale hit from
 coarse filesystem mtime granularity. Best-effort: any cache
 read/write failure (missing dir, no write permission, a race with
 another process, etc.) is treated as a cache miss/no-op, never a
 hard error — running the script must still work with no cache at all.

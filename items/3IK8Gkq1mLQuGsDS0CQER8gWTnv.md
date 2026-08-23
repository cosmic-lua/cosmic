Lands in: whilp/cosmopolitan (set the item's repo when it is worked;
no verb sets it at capture time).

Research pass: 2026-08-23, per skills/optimize ("running a research
pass"): four round-1 agents (baseline read, cosmic sweep, C-layer/
startup sweep, literal-vs-json probe) plus a round-2 adversarial
verification. Tree at main 0fb444d6-equivalent. All numbers are
SCOUTING numbers, independently re-measured by the verifier where
stated; accept/reject stays with the _perf harness. C-layer A/Bs
depend on board item 3IHHJcVr (o//depend broken: header edits never
rebuild) landing first, or on clean rebuilds.

## Problem
embed_extract_tree 59.9ms cw1.01 (baseline; verifier reproduced the
scenario shape — 1228 files packed on the cosmic binary — at 31-35ms
on tmpfs, ~50ms disk-backed, so the baseline is consistent with a
disk temp dir). Extraction is: C reader with only read (lzip.c:672)
and save (703, open/write/close per file) verbs; the LOOP lives in
Lua (cosmic/zip.tl extract_entries, line 271) with a per-file
fs.set_mode chmod (332) and per-file path/guard work. Cosmic
self-extracts its build engine through this path.

## Rejected mechanism (recorded so nobody re-tests it)
"Per-member inflateInit2/inflateEnd churn ~40KB and ~3ms": REFUTED.
lzip.c decompresses one-shot with the full output buffer under
Z_FINISH, and vendored zlib skips window allocation entirely in that
mode (third_party/zlib/inflate.c:1323-1325) — per-member churn is one
~10KB inflate_state ZALLOC. Measured full init+inflate+end round trip
0.27µs — 1240 members ≈ 0.3ms, ~1% of the scenario. inflateReset2
stream reuse is valid (zip deflate is always raw -MAX_WBITS) but not
valuable.

## Change (re-scoped hypothesis)
A C-side bulk extract (reader:extract_all(destdir) or an iterating
save that takes the dest dirfd): walk the index once in C, reuse one
scratch buffer, openat against a dest dirfd, create each directory
once, set modes inline — removing per-file Lua dispatch, per-file
chmod calls, and path-string work. Verifier'\''s measured headroom:
save-all minus read-all is 4-5ms per 628 files/7.3MB on tmpfs
(~7µs/file open+write+close, more on disk); estimated 15-30% of the
measured 33ms scenario, larger on disk.

## Constraints
reader:read/save shapes frozen; a new method is its own deliberate
definitions.lua + type-regen change. THE HARD ONE: the zip-slip guard
is fs.is_unsafe_entry_name, deliberately the SINGLE definition shared
by zip/tar/embed (cosmic/zip.tl:267-269) — a C-side extract_all must
not create a second guard implementation (lzip.c'\''s IsUnsafePath at
776 guards the writer, not extraction). Either the C walk returns
names for Lua to vet before extraction (two-phase), or the invariant
is renegotiated at plan — a spec decision, not an implementation one.
Extend tool/lua/test_zip_security.lua either way. Also count the
cosmic-side rider: embed.write'\''s blind per-file appender:remove
(embed/init.tl:389, ~1ms of 24.5ms embed_run_tree) can ride along;
the appender'\''s 19ms close()-time archive rewrite is a separate,
unprobed C question.

## Risk
Medium — new C surface + security-sensitive path. Ambition
medium-high, contingent on the guard-invariant decision.

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
Opening+closing a STORED /zip member costs ~7.2-7.3µs vs 0.84µs for
the identical file on tmpfs through the kernel — 8.7x, adversarially
re-measured (20k iters, 3 runs: 7.329/7.308/7.039 vs ~0.84). A
read-only already-mapped filesystem loses to real syscalls. Boot does
~35 zipos opens (~220µs excess per exec); every /zip asset access in
any cosmic program pays it (embed_run_startup, --docs, --make reading
/zip/cosmic.mk). Verified per-pair kernel cost: 10 syscalls, of which
SIX rt_sigprocmask (2 from __zipos_open'\''s BLOCK_SIGNALS, 2 nested in
cosmo'\''s mmap wrapper, 2 in munmap), plus mmap+fcntl+close+munmap.

## Mechanism (verified at location)
libc/runtime/zipos-open.c: __zipos_alloc (line 56) mmaps a fresh
MAP_PRIVATE|MAP_ANONYMOUS handle per open — for stored members the
map is only the ~64-byte handle, data stays in the image (h->mem =
ZIP_LFILE_CONTENT, line 129); __zipos_drop (49) munmaps on last ref;
__zipos_mkfd (85) does a real fcntl(2, F_DUPFD_CLOEXEC) round-trip;
BLOCK_SIGNALS wraps __zipos_load (243-247).

## Change (hypothesis)
Recycle ZiposHandle allocations: per-zipos freelist bucketed by
mapsize (stored members all hit one fixed bucket), so stored open/
close does zero mmap/munmap — removing 4 syscalls incl. their nested
sigprocmask pairs; optionally narrow the signal-block to the fd-table
mutation. Expected: open+close → ~1-2µs; ~150-250µs off startup_run_
lua (6-10%), more for /zip-asset-heavy work. Surgical diff inside
zipos-open.c for upstream mergeability.

## Constraints and verified risks
No Lua-visible contract. Fork: safe (private anon maps; no zipos fork
handler exists or is needed). Threads: __zipos_alloc runs BEFORE
__fds_lock is taken — the freelist needs its own synchronization.
Signal context: __zipos_close is @asyncsignalsafe and calls
__zipos_drop, so the freelist PUSH must be lock-free (Treiber push);
pop runs under BLOCK_SIGNALS but cross-thread ABA needs care
(exchange-whole-head). Due diligence: struct ZiposHandle still
carries a vestigial '\''next'\'' first member (zipos.internal.h:25) —
upstream once had exactly this freelist and removed it; find out why
before re-adding.

## Risk
Medium (lock-free lifecycle code), high ambition: structural, every
zipos consumer benefits. Related finding, recorded not proposed:
__zipos_load inflates deflated members fully at open() — but cosmic
already ships all .lua members STORED, so lazy inflate is upstream
hygiene with ~zero cosmic startup win today (deflated-vs-stored A/B:
+450-480µs/boot is the cost cosmic already avoided).

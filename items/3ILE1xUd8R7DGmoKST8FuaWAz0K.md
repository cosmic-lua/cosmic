Lands in: whilp/cosmopolitan (C change + tests; one PR).

## Goal

G6 — the defining paths, ratcheted. Startup is a defining path, and a
zipos open/close pair costs 8.7x a kernel open today. cosmic's boot
does ~35 of them, all on the STORED path, for ~220µs of excess per
exec. This slice recycles the one handle allocation that path makes,
which removes an `mmap`/`munmap` pair and the four `rt_sigprocmask`
calls nested inside them, per open.

## Evidence

Measured in the capture on `3IK8GFHj` (the parent), carried here so
this slice does not re-measure what is already adversarially measured:

- a zipos open/close pair is ~7.2µs against ~0.83µs for a kernel
  open/close — 8.7x.
- 10 syscalls per pair: `mmap`, `fcntl`, `close`, `munmap`, and six
  `rt_sigprocmask` — two from `__zipos_open`'s `BLOCK_SIGNALS`, two
  nested in cosmo's mmap wrapper, two in munmap.
- ~35 zipos opens on cosmic's boot path, ~220µs excess per exec.

Recycling removes the `mmap`/`munmap` pair and the four sigprocmasks
nested in them. It does not touch the other four syscalls, so the
predicted win is bounded by those six and not by the whole 7.2µs —
state the measured figure, not the ceiling, when reporting.

The research slice `3IKuRFN5` answered the question that gated this
one, and its `## Findings` are the design rationale for everything
below. Two of its results bind hardest:

- upstream `jart/cosmopolitan` DID ship exactly this freelist, and
  removed it in `464858db` ("Fix bugs with new memory manager",
  2024-06-29) for a NON-correctness reason: the bespoke MAP_FIXED
  allocator it recycled was replaced by ordinary `mmap`, and the
  freelist went with it. There is no removed-because-broken lesson to
  design around. The vestigial `struct ZiposHandle *next` is the link
  that commit left behind when it removed the head from `struct
  Zipos`; it is still unused at upstream HEAD.
- **`refs` is never initialized.** `__zipos_alloc`
  (`libc/runtime/zipos-open.c:56-69`) sets only `size`, `zipos` and
  `mapsize`; `refs` is correct today solely because fresh `mmap`
  memory is zero-filled, and `__zipos_drop` leaves it at `(size_t)-1`
  on the handle it releases. A recycled handle arrives with `refs ==
  SIZE_MAX`, and failing to store 0 into it is a silent
  use-after-free: `__zipos_close` would decrement from SIZE_MAX,
  never reach zero, and never release. The removed upstream allocator
  carried `atomic_store_explicit(&h->refs, 0, ...)` for exactly this
  reason.

**Coverage gap uncovered during review of PR #271
(head `d74bd7db`).** The prior spec's Acceptance asserted that
`TEST(zipos, test)` — 16 threads × 20 open/read/close of
`/zip/libc/testlib/hyperion.txt` — is "the concurrent pop/push
stress this design must survive." That claim is false as measured on
the built test binary:

```
$ unzip -v o//test/libc/runtime/zipos_test | grep hyperion
   22851  Defl:N   10610  54% ... libc/testlib/hyperion.txt
```

`hyperion.txt` is DEFLATED (method 8), not stored, because testlib
assets go through the default `zipobj` rule (compressed; only `-0`
stores). A deflated member takes `__zipos_alloc(zipos, size>0)` →
`mapsize > sizeof(struct ZiposHandle)` → the push guard
`h->mapsize == sizeof(struct ZiposHandle)` is false, so
`__zipos_drop` `munmap`s and the pop's `!size` guard is never
satisfied. **The 16 threads never touch `__zipos_free[]`**; the new
lock-free array is exercised only single-threaded, by the `--strace`
mechanism run. On a lock-free primitive that sits under every `/zip`
open in every cosmo binary, no automated gate covers its concurrency
safety. The steps below deliver the missing coverage in-scope.

## Change

In `whilp/cosmopolitan`. The C change itself (steps 1–4) is unmoved
from the prior spec. Steps 5–6 add the stored-member concurrency
gate the recycle path needs; they are the only additions.

```c
#define ZIPOS_FREE_SLOTS 4
static _Atomic(struct ZiposHandle *) __zipos_free[ZIPOS_FREE_SLOTS];
```

1. **`libc/runtime/zipos.internal.h`** — delete `struct ZiposHandle
   *next;`. The design has nothing to link, and leaving it would
   re-create the vestige this work exists to resolve.
2. **`libc/runtime/zipos-open.c` — `__zipos_alloc` (`:56`), pop.**
   Only when `size == 0` (the stored-member bucket at `:127`, where
   `mapsize == sizeof(struct ZiposHandle)` exactly; this fork does
   not round it). Skip the freelist entirely when `__vforked`.
   Otherwise scan the slots and take the first that yields non-NULL
   from `atomic_exchange(&__zipos_free[i], NULL)` with
   `memory_order_acquire`; fall through to today's `mmap` when none
   does. **On the recycled path, store 0 into `h->refs`** before
   returning it. `size`, `zipos` and `mapsize` are set as they are
   today; `pos`, `cfile` and `mem` are re-set by `__zipos_load`.
3. **`libc/runtime/zipos-open.c` — `__zipos_drop` (`:49`), push.**
   Only when `h->mapsize == sizeof(struct ZiposHandle)`. After the
   existing refcount check and acquire fence, scan for an empty slot
   and claim it with
   `atomic_compare_exchange_strong(&__zipos_free[i], &expect_null, h)`
   using `memory_order_release`; on success return WITHOUT `munmap`.
   No mutex and no unbounded retry — at most `ZIPOS_FREE_SLOTS`
   single-word CASes — because this runs on the `@asyncsignalsafe`
   `__zipos_close` path (`zipos-close.c:30-33`, drop at `:43`), which
   is precisely where the removed upstream code's `pthread_mutex_t`
   was illegal. When no slot is free, `munmap` exactly as today: the
   cap is enforced here and the array never grows.
4. **`fork`/`vfork`** — nothing to add for `fork`: handles are
   `MAP_PRIVATE|MAP_ANONYMOUS` so a child gets its own COW copies, and
   every mutation is a single atomic word operation, so there is no
   half-done publish to inherit and no lock to inherit locked. Do NOT
   add a `pthread_atfork` handler. For `vfork`, the `__vforked` guard
   in step 2 is the whole treatment; push is already skipped by
   `zipos-close.c:40`.
5. **In `test/libc/runtime/BUILD.mk` — ship a stored zip member into
   `zipos_test`.** Add a small text asset (name it
   `test/libc/runtime/prog/stored_smoke.txt`, one line of ASCII is
   enough — the concurrency gate reads it, does not compare content)
   and give its `.zip.o` a private `ZIPOBJ_FLAGS += -0` so the
   packager stores it uncompressed. Model the rule on the existing
   `ftraceasm.txt.zip.o` private-flags block (`test/libc/runtime/
   BUILD.mk:99-102`) — the `-0` flag path is `tool/build/zipobj.c:140`
   (`case '0': nocompress_ = true;`). Add the new `.zip.o` to
   `zipos_test`'s link deps in the same file so it ships inside the
   test binary. This is the only build change; no other target is
   touched.
6. **In `test/libc/runtime/zipos_test.c` — add
   `TEST(zipos, storedRecycleConcurrent)`.** A new test alongside
   `TEST(zipos, test)`, following the same 16-thread × 20-iteration
   shape but opening the STORED member added in step 5 (path
   `/zip/test/libc/runtime/prog/stored_smoke.txt`). The existing
   `TEST(zipos, test)` is unchanged — its Worker still opens
   `hyperion.txt` and gates the untouched deflate path.

Nothing else moves. The `libc/runtime` change and the tests that
gate it ship in the same PR because they cover the same primitive.

## Non-goals

- **Do not restore the removed upstream design.** No `freelist` member
  on `struct Zipos`, no first-fit `mapsize >=` scan, no `StartOver`
  retry, no `__zipos_lock`/`pthread_mutex_t`, and no return of
  `__zipos_mmap_space`/`kMemtrackZiposStart`. Those are what
  `464858db` removed and the reasons are recorded in `3IKuRFN5`.
- **Do not recycle the other two allocation sites.** `:116`
  (synthetic directory, `size + 1`) and `:132` (deflate, full
  uncompressed size) stay on plain `mmap`/`munmap`. Size-bucketing
  them would retain megabyte mappings for the process lifetime to
  speed up opens whose cost is `__inflate`, not `mmap`.
- **Do not raise `ZIPOS_FREE_SLOTS` above 4 in this slice**, and do
  not add reclamation policy, a timer, or high-water logic. The cap is
  structural. Raising it needs a measurement of concurrent depth,
  which is a separate item.
- **Do not touch the other four syscalls in the pair.** `fcntl`,
  `close` and `__zipos_open`'s own two `rt_sigprocmask` are out of
  scope; this slice is the `mmap`/`munmap` pair and the four
  sigprocmasks nested in them.
- **Do not change the binding contract.** No `cosmo.*` return shape,
  error value or constant moves, so no `tool/net/definitions.lua`
  update and no cosmic-side type regen belongs in this PR.
- **Do not modify existing testlib assets or existing tests.** The
  stored asset is a new file whose only consumer is the new
  `TEST(zipos, storedRecycleConcurrent)`; do not switch `hyperion`
  or any other shared asset to stored, and do not extend
  `TEST(zipos, test)`'s Worker to open the new asset — the two tests
  cover the two paths separately so a failure names its own primitive.

## Acceptance

```
make -j$(nproc) o//tool/lua/test
make -j$(nproc) o//test/libc/runtime/zipos_test && o//test/libc/runtime/zipos_test
unzip -v o//test/libc/runtime/zipos_test | grep stored_smoke
git status --porcelain tool/net/definitions.lua
```

- `o//tool/lua/test` passes — the binding tests and the annotation
  ratchet, the standing correctness gate for this repo.
- **`o//test/libc/runtime/zipos_test` passes.** This is the gate that
  matters most and it is not in the lua target, so it is run
  explicitly. The three tests that gate this change:
  - **`TEST(zipos, storedRecycleConcurrent)`** (new, step 6): 16
    threads × 20 open/read/close on the STORED asset from step 5 —
    the concurrent pop/push stress on `__zipos_free[]`, the safety
    property this slice adds. A failure here is a design failure,
    never a flake: do not re-run past it.
  - `TEST(zipos, test)`: unchanged 16-thread × 20-iter gate over
    `hyperion.txt` (deflated), covering the untouched deflate path
    remains free of regressions from the shared allocator changes.
  - `TEST(zipos, closeAfterVfork)` covers the `__vforked` guard in
    step 2; `TEST(zipos, ultraPosixAtomicSeekRead)` covers concurrent
    handle state on a shared fd.
- **`unzip -v o//test/libc/runtime/zipos_test | grep stored_smoke`
  prints a line whose Method column reads `Stored`** — proof that the
  new asset is packaged uncompressed and therefore actually reaches
  the recycle path. This measurement replaces the prior spec's false
  assumption about `hyperion.txt`; do not skip it.
- `git status --porcelain tool/net/definitions.lua` prints nothing —
  the C boundary did not move.
- **The `_perf` compare gate from `skills/optimize`**, run from a
  cosmic checkout against a locally built `lua` per that skill's
  `cosmopolitan.md` chapter, showing `startup_run_lua` improved and
  nothing regressed. `startup_run_lua` is a fixed-overhead scenario,
  so **that skill's cross-session rule applies in full**: a
  release-gating regression seen here needs reproduction across
  separate sessions before it blocks anything, and by the same token a
  single session's improvement figure is reported as this session's
  measurement, not as the settled number.
- **Mechanism evidence — that the recycle actually fired**, rather
  than the win being read off noise. Under `--strace`, opening the
  SAME stored member repeatedly in one process must show `mmap`/
  `munmap` for the first open and neither for later ones. Take this
  against a **cosmic** binary carrying the locally built `lua`, per
  `cosmopolitan.md`: cosmic ships every `.lua` member STORED, which is
  the whole premise of the parent, so its members are the ones that
  reach `zipos-open.c:127`.

  **Do NOT take it against `o//tool/lua/lua`'s own
  `/zip/.lua/definitions.lua`.** Nothing in the tool/lua tree passes
  `zipobj`'s `-0`, and `tool/lua/BUILD.mk:84` passes only `-C4 -P.lua`
  (which is strip-components and prefix, not compression), so that
  member is DEFLATED and reaches `zipos-open.c:132` — the site this
  change deliberately does not touch. Measuring there shows no
  difference and invites exactly the wrong conclusion: that the
  recycle is broken, or that the deflate bucket should be widened
  into, which `## Non-goals` forbids. If a stored member inside a
  plain `lua` build is wanted for a quicker loop, confirm one is
  actually stored before trusting it — do not assume from the
  member's name.

## Enablement

`blocked_by` `3IHHJcVr` — "header edits never rebuild: `o//depend` is
never generated, staling every incremental C measurement". Step 1
edits `zipos.internal.h`, and every A/B in Acceptance is an
incremental C build, so a stale-header rebuild would silently measure
the wrong binary. That item governs how a C-layer A/B is run and must
land first.

Beyond it, none needed: the design is decided down to the memory
orders and the guard conditions in `## Change`, the one non-obvious
hazard (`refs` arriving as SIZE_MAX) is stated with its consequence
in `## Evidence`, every edit site is cited by `file:line`, the newly
required stored-member coverage is decided down to its build rule
(step 5) and its test shape (step 6), and every acceptance measurement
carries its command.

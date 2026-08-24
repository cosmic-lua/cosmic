Lands in: whilp/cosmopolitan (research only — no PR, no C).

**Precondition — read access to `jart/cosmopolitan`.** Question 1 is
answerable only from upstream history, so a session that cannot read
`jart/cosmopolitan` cannot start this slice. A scheduled session's
GitHub access is granted per repository; check the grant BEFORE
claiming, and if the upstream is not in it, leave the item in `plan`
rather than pulling it. That is what happened on 2026-08-24 (see
`## Bounce` below), and it is the only thing standing between this spec
and `ready`.

## Goal

G6 — the defining paths, ratcheted. The parent (`3IK8GFHj`) proposes
recycling `ZiposHandle` allocations to take a zipos open/close pair
from ~7.2µs to ~1-2µs, on the boot path every cosmic exec pays (~35
zipos opens, ~220µs excess). That change is lock-free lifecycle code
inside libc, and the parent's own capture records a question nobody
has answered: `struct ZiposHandle` still carries a vestigial `next`
first member, so upstream once had exactly this freelist and took it
out. Writing the implementation spec before that is answered risks
specifying a bug somebody already found and removed. This slice's
deliverable is the answer, the design it forces, and the sibling
implementation slice written from it. No C.

## Evidence

Measured 2026-08-23 in a `whilp/cosmopolitan` checkout at `8e071ec9`.

**The member is allocated and never touched.**

```
$ grep -n "next" libc/runtime/zipos.internal.h
25:  struct ZiposHandle *next;
$ grep -rn -- "->next" libc/runtime/zipos-open.c libc/runtime/zipos-close.c
                                    # nothing
```

**This repo's history cannot answer why.** The fork is squashed below
the removal:

```
$ git rev-list --count HEAD
50
$ git log --oneline -S 'freelist' -- libc/runtime/
                                    # nothing
$ git log --oneline -S '->next' -- libc/runtime/zipos-open.c
                                    # nothing
$ git log --oneline -- libc/runtime/zipos.internal.h
1c5cfce4 lua: restore the GetCryptoHash contract and SHA-256 speed on Mbed TLS 3.6 (#190)
```

One commit, unrelated. The answer is in `jart/cosmopolitan`, which is
why question 1 below clones it.

**The code any design must satisfy**, all in `libc/runtime/`, read at
the same revision:

- `zipos-open.c:56` — `__zipos_alloc` mmaps `sizeof(struct
  ZiposHandle) + size` as `MAP_PRIVATE|MAP_ANONYMOUS`. Three callers:
  `:116` (synthetic directory, `size + 1`), `:127` (**stored member,
  `size` is 0** — so every stored open maps the same fixed handle and
  nothing else; the data stays in the image, `h->mem =
  ZIP_LFILE_CONTENT`), `:132` (deflate, `size`).
- `zipos-open.c:49` — `__zipos_drop` munmaps on the last ref. Three
  call sites: `zipos-open.c:170`, `zipos-open.c:181`,
  `zipos-close.c:43`.
- `zipos-close.c:30-33` — `__zipos_close` is `@asyncsignalsafe` AND
  `@vforksafe`, and at `:40` it skips the drop entirely when
  `__vforked`.
- `zipos-open.c:201` — `__zipos_open` is `@asyncsignalsafe`; it wraps
  `__zipos_load` in `BLOCK_SIGNALS` at `:243`, while `__fds_lock()` is
  not taken until `:152`, AFTER the alloc at `:127`. So an allocation
  runs with signals blocked on its own thread and no lock held.

**The syscalls the parent measured** (per open/close pair, 10 total):
six `rt_sigprocmask` — two from `__zipos_open`'s `BLOCK_SIGNALS`, two
nested in cosmo's mmap wrapper, two in munmap — plus `mmap`, `fcntl`,
`close`, `munmap`. Recycling removes the mmap/munmap pair and their
four nested sigprocmasks; it does not touch the other four syscalls.

## Change

Answer three questions and record each with the command or `file:line`
that produced it, in a `## Findings` section appended to THIS item's
spec (`o/bin/gitboard spec 3IKuRFN5 FILE`, from the board worktree).

**1. Why the `next` member is vestigial**, from upstream history,
which this fork's log cannot reach:

```
git clone --filter=blob:none --no-checkout \
  https://github.com/jart/cosmopolitan /tmp/upstream-cosmo
git -C /tmp/upstream-cosmo log --oneline -- \
  libc/zipos/ libc/runtime/zipos-open.c libc/runtime/zipos-close.c
git -C /tmp/upstream-cosmo show <candidate sha> -- \
  libc/zipos/zipos-open.c libc/runtime/zipos-open.c
```

The listing is metadata only, so the blobless clone stays cheap;
`show` then fetches just the revisions you name. Do NOT reach for
`git log -S` here — a pickaxe over a blobless clone refetches every
revision of those paths one at a time, and this file's history is
short enough to read by eye. Upstream carried these sources under
`libc/zipos/` before the path moved, which is why both prefixes are
listed. Record the commit that removed the freelist, its message, and
the
removal diff. Then state in ONE sentence whether it came out for a
CORRECTNESS reason — name it — or for another reason (a simplification,
a rewrite that dropped it incidentally, a measurement that found it
worthless). If no such commit exists, record that with the same
commands and their empty output: "the member was speculative and the
freelist never shipped" is a complete answer to this question, and it
is the answer that makes the parent cheap.

**2. Whether that reason still binds here.** For whatever question 1
returns, say against THIS tree whether it applies, walking the four
constraints quoted by `file:line` in Evidence: the async-signal-safe
push out of `__zipos_close`, `__vforked`, no `__fds_lock` held at
alloc time, and the fixed stored-member size.

**3. The design, decided.** Write the decision — not the options —
covering exactly these five points, each carrying its reason from 1
and 2:

- which allocations are recycled: the single fixed
  `sizeof(struct ZiposHandle)` bucket that `zipos-open.c:127` produces,
  or a size-bucketed list that also catches `:116` and `:132`;
- the PUSH side's synchronization, given `__zipos_drop` is reached
  from an `@asyncsignalsafe` `__zipos_close`;
- the POP side's, given `__zipos_load` already runs under
  `BLOCK_SIGNALS` on its own thread but holds no lock at `:127`, and
  given a signal handler on ANOTHER thread may be popping at the same
  moment;
- what BOUNDS the list, so a program that opens and closes many zipos
  members does not retain every handle for the life of the process:
  state the cap and what happens past it;
- what happens across `fork` (a child inheriting the list, and a child
  inheriting it mid-mutation) and across `vfork` (where
  `zipos-close.c:40` already skips the drop).

Then write the sibling implementation slice:
`o/bin/gitboard new "<title>" --parent 3IK8GFHj --repo
whilp/cosmopolitan --spec-file F`, with point 3's design as its
`## Change`, the parent's measured numbers as its `## Evidence`, and an
`## Acceptance` carrying `make -j$(nproc) o//tool/lua/test` plus the
`_perf` compare gate from `skills/optimize` — including that skill's
cross-session rule, because `startup_run_lua` is a fixed-overhead
scenario.

## Non-goals

- **No C.** Do not edit `libc/runtime/zipos-open.c`,
  `libc/runtime/zipos-close.c` or `libc/runtime/zipos.internal.h`, do
  not build, and do not open a pull request against
  whilp/cosmopolitan. A research slice that also writes the code
  cannot say which of the two its findings judged.
- **Do not remove the `next` member either.** It is the evidence this
  slice reads; whether it stays or goes is the sibling slice's
  decision, made with the answer in hand.
- **Do not re-measure the parent's numbers.** The 8.7x, the 10
  syscalls and the ~220µs boot excess were measured adversarially in
  the capture and are carried into Evidence above; this slice spends
  its time on the question they do not answer. A perf re-measure is
  the sibling's `Acceptance`, under the `optimize` skill's gates.
- **Do not settle the C-layer build question.** Board item
  `3IHHJcVr` (`o//depend` broken: header edits never rebuild) governs
  how a C-layer A/B is run; it is the sibling's blocker if it is
  anyone's, not this slice's subject.
- **Do not widen into the deflate finding.** The parent records that
  `__zipos_load` inflates deflated members fully at `open()`; cosmic
  ships every `.lua` member STORED, so it is upstream hygiene with no
  cosmic win. It stays recorded, not proposed, and not researched here.

## Acceptance

The deliverable is recorded findings, so acceptance is that they are
recorded, independently re-runnable, and that they seeded the sibling.
Board commands run from the `board` worktree (`o/board`); the git
commands run anywhere.

```
git clone --filter=blob:none --no-checkout https://github.com/jart/cosmopolitan /tmp/upstream-cosmo
git -C /tmp/upstream-cosmo log --oneline -- libc/zipos/ libc/runtime/zipos-open.c libc/runtime/zipos-close.c
o/bin/gitboard show 3IKuRFN5 | grep -c '^## Findings'
o/bin/gitboard show 3IKuRFN5 | grep -c 'jart/cosmopolitan'
o/bin/gitboard show 3IK8GFHj
git -C <cosmopolitan checkout> status --porcelain libc/
```

- the two `git` commands run clean, and the listing plus whichever
  `git show` revisions the answer rests on are quoted verbatim in
  `## Findings`, so a reviewer re-running them lands on the same
  commits (or the same empty output).
- `grep -c '^## Findings'` on this item is **0 today** and must be 1
  after; the section carries three subsections, one per question, and
  question 3's is five bullets, one per decision point.
- `grep -c 'jart/cosmopolitan'` on this item is **0 today** and must
  be at least 1 after — the answer names where it came from.
- `o/bin/gitboard show 3IK8GFHj` lists exactly one child besides this
  item — the implementation slice this one wrote — and
  `o/bin/gitboard check` on that child's id ends `meets the ready bar`.
- `git status --porcelain libc/` in the cosmopolitan checkout prints
  nothing: no C moved.

## Enablement

none needed for the research itself — the question is answerable by
reading one file's history in a public clone, every constraint it must
be weighed against is quoted here by `file:line`, and the deliverable
is prose on this item.

If the clone cannot be reached at all (no egress, or the proxy refuses
it), that is a bounce, not a workaround: return the item to `plan`
saying the upstream history was unreachable. Do NOT substitute a guess
about why the member is vestigial, and do not answer question 1 from
the code alone — the whole point of this slice is that the code cannot
answer it.

One piece of known friction to expect at hand-over, not to fix here:
board item `3IFUskgH` records that a research slice cannot reach
`check` without a `--pr`, so `move <id> check` needs the `--force`
path that item describes. That is its item, not this one's; do not
change the tool in this slice.

## Bounce, 2026-08-24 (session `claude-sched-2026-08-24T0038`)

Returned to `plan` at claim time, unbuilt. The Enablement clause's
unreachable-clone case fired, for a cause it did not anticipate: not
egress, but **repository scope**.

A scheduled session's GitHub access is granted per repository, and this
one's grant is `whilp/cosmic` + `whilp/cosmopolitan`. `jart/cosmopolitan`
is not in it, and the session's standing instruction is not to read from
a repository outside the grant — so question 1's `git clone
jart/cosmopolitan` was not attempted, rather than attempted and refused.
Per Enablement, no guess was substituted and question 1 was not answered
from the code alone.

Re-measured in scope before bouncing, at `whilp/cosmopolitan` `8e071ec9`
— every Evidence fact this slice can reach holds unchanged:

```
$ git log --oneline -1
8e071ec9 sqlite3: stub the two headers mkdeps cannot resolve, so o//depend builds (#270)
$ grep -n "next" libc/runtime/zipos.internal.h
25:  struct ZiposHandle *next;
$ grep -rn -- "->next" libc/runtime/zipos-open.c libc/runtime/zipos-close.c
                                    # nothing
$ git log --oneline -- libc/runtime/zipos.internal.h
1c5cfce4 lua: restore the GetCryptoHash contract and SHA-256 speed on Mbed TLS 3.6 (#190)
$ git rev-list --count HEAD
50
```

So the spec is not wrong and the question is not answered: the slice is
exactly as specified and simply cannot run from a session with this
grant.

**What the re-refinement must settle**, before this returns to `ready`:

- **Preconditions belong in the spec.** The ready bar checks that a
  session can implement from the spec alone; it does not check that the
  session can REACH the sources the spec names. Any slice whose evidence
  lives outside `whilp/*` needs the required read access stated as a
  precondition, so the mismatch is caught by `check` rather than by a
  claim.
- **Then one of two paths.** Either the grant is widened to include
  `jart/cosmopolitan` (read-only; it is the direct upstream and the
  answer is one file's public history), and the slice runs as written —
  or the slice is re-specified to answer question 1 from a source inside
  the grant. Which of those is right is not this session's call, because
  the second one may have no source: the fork is squashed below the
  removal, which is the premise the Evidence already establishes.

*Resolved 2026-08-24: the owner authorized reading `jart/cosmopolitan`,
the clone succeeded, and the research below was done. The precondition
above stands for anyone re-running it.*

## Findings

Recorded 2026-08-24 from a blobless clone of `jart/cosmopolitan` at
`3293fad0` (2026-07-19), read against `whilp/cosmopolitan` `8e071ec9`.

```
$ git clone --filter=blob:none --no-checkout https://github.com/jart/cosmopolitan /tmp/upstream-cosmo
$ git -C /tmp/upstream-cosmo log --oneline -- \
    libc/zipos/ libc/runtime/zipos-open.c libc/runtime/zipos-close.c | wc -l
123
```

The pickaxe was avoided as the spec directs. Instead the 123 commits
were resolved to the 32 that carry a `zipos-open.c` blob, those blobs
were fetched in one `git cat-file --batch`, and each was grepped for
`->next`/`freelist`. The transition is unambiguous and sits between two
adjacent commits:

```
5 d1d43882 2024-06-22 Delete ASAN                          <- freelist present
0 464858db 2024-06-29 Fix bugs with new memory manager     <- freelist gone
```

### 1. Why the `next` member is vestigial

**The freelist was real, it shipped for years, and it was removed by
`464858db` — "Fix bugs with new memory manager", Justine Tunney,
2024-06-29 — for a NON-correctness reason: it was collateral of the
memory-manager rewrite that made zipos stop carving its handles out of
a fixed reserved address range.**

The commit message, verbatim:

```text
Fix bugs with new memory manager

This fixes a regression in mmap(MAP_FIXED) on Windows caused by a recent
revision. This change also fixes ZipOS so it no longer needs a MAP_FIXED
mapping to open files from the PKZIP store. The memory mapping mutex was
implemented incorrectly earlier which meant that ftrace and strace could
cause cause crashes. This lock and other recursive mutexes are rewritten
so that it should be provable that recursive mutexes in cosmopolitan are
asynchronous signal safe.
```

Its diff over the two files of interest, `-101/+28`:

```text
 libc/runtime/zipos-open.c     | 128 +++++++++---------------------------------
 libc/runtime/zipos.internal.h |   1 -
```

The single header line is the **list head**, removed from `struct
Zipos` — not the link:

```text
-  struct ZiposHandle *freelist;
```

And the removed allocator body is the freelist itself, with its
first-fit scan, its `StartOver` retry, and its mutex:

```text
-void __zipos_drop(struct ZiposHandle *h) {
-  ...
-  __zipos_lock();
-  do
-    h->next = h->zipos->freelist;
-  while (!_cmpxchg(&h->zipos->freelist, h->next, h));
-  __zipos_unlock();
-}
-
-static struct ZiposHandle *__zipos_alloc(struct Zipos *zipos, size_t size) {
-  __zipos_lock();
-  mapsize = ROUNDUP(sizeof(struct ZiposHandle) + size, 4096);
-StartOver:
-  ph = &zipos->freelist;
-  while ((h = *ph)) {
-    if (h->mapsize >= mapsize) {
-      if (!_cmpxchg(ph, h, h->next))
-        goto StartOver;
-      break;
-    }
-    ph = &h->next;
-  }
-  if (!h)
-    h = __zipos_mmap_space(mapsize);      /* _extend() over kMemtrackZiposStart */
-  __zipos_unlock();
-  if (h)
-    atomic_store_explicit(&h->refs, 0, memory_order_relaxed);
```

So the freelist was not deleted because it was wrong. It was deleted
because the thing it recycled stopped existing: handles used to come
from `__zipos_mmap_space`, a bespoke bump allocator that `_extend()`ed a
MAP_FIXED reservation at `kMemtrackZiposStart`, and recycling a slab out
of a hand-managed fixed region is worth real machinery. The same commit
replaced that with an ordinary `__mmap(randaddr(), ...)` and made
`__zipos_drop` an ordinary `__munmap`, at which point the freelist was
machinery attached to an allocator that no longer existed.

**`next` survived because it was simply left behind.** The commit
removed the head from `struct Zipos` and left the link in `struct
ZiposHandle`; nothing has touched it since. It is still declared at
upstream HEAD `3293fad0`, and still unused there:

```
$ git -C /tmp/upstream-cosmo show HEAD:libc/runtime/zipos.internal.h | grep -n 'next'
26:  struct ZiposHandle *next;
$ for f in $(git -C /tmp/upstream-cosmo ls-tree -r --name-only HEAD | grep zipos); do
    git -C /tmp/upstream-cosmo show HEAD:$f | grep -- '->next'; done
                                    # nothing
```

That is the answer the parent needed, and it is the cheap one: **there
is no removed-because-broken lesson to design around.** But the commit
message names two hazards in passing that the new design must not
walk back into, and they are question 2's subject.

### 2. Whether that reason still binds here

The removal reason — "the allocator it recycled is gone" — does not
bind at all: nobody is proposing to bring back `__zipos_mmap_space`.
A freelist over ordinary `mmap`ed handles is a different object from
the one that was removed, and the four constraints the Evidence quotes
are all satisfiable. Walking them:

- **`__zipos_drop` is reached from an `@asyncsignalsafe` `__zipos_close`**
  (`zipos-close.c:30-33`, drop at `:43`). This is the one place the old
  code was genuinely unsafe: its push took `__zipos_lock()`, a
  `pthread_mutex_t`, on that path — and `464858db`'s own message says
  the mapping mutex "was implemented incorrectly earlier which meant
  that ftrace and strace could cause crashes", which is the same class
  of bug. **Binding, and it forbids a mutex on the push side.** It does
  not forbid recycling; it forbids the old implementation of it.
- **`__vforked`** — `zipos-close.c:40` already skips the drop, so
  nothing is ever pushed from a vforked child. Binding on the POP side
  only, and answered in 3.
- **No `__fds_lock` held at alloc time** — `__fds_lock()` is not taken
  until `zipos-open.c:152`, after the alloc at `:127`, and
  `__zipos_load` runs under `BLOCK_SIGNALS` (`:243`). So an allocation
  runs with signals blocked on its own thread and no lock held: there
  is no lock to order against, and no same-thread signal reentry into
  pop. Another thread's handler can still be in pop or push. Binding as
  a concurrency constraint, not as an obstacle.
- **The fixed stored-member size** — `zipos-alloc(zipos, 0)` at `:127`
  makes `mapsize == sizeof(struct ZiposHandle)` exactly, and this fork
  does not round it (`zipos-open.c:59`, no `ROUNDUP`). This is what
  lets the new design drop the old first-fit scan entirely.

**One hazard the history does not name, found by reading this fork.**
`refs` is never initialized. `__zipos_alloc` (`zipos-open.c:56-69`)
sets only `size`, `zipos` and `mapsize`; `refs` is correct solely
because fresh `mmap` memory is zero-filled. `__zipos_drop`'s
`atomic_fetch_sub` leaves it at `(size_t)-1` on the handle it is about
to release. **A recycled handle therefore arrives with `refs ==
SIZE_MAX` and must have 0 stored into it explicitly** — which is
exactly why the removed code carried `atomic_store_explicit(&h->refs,
0, ...)` in its allocator, a line that means nothing until you recycle.
Omitting it is a silent use-after-free: the first `__zipos_close` would
decrement from SIZE_MAX, never reach zero, and never release. This is
the single highest-value thing the slice found.

### 3. The design, decided

An **array of fixed-size slots, not a linked list.** Because only one
size class is recycled (below), the list has no ordering or search to
do, and an array makes ABA structurally impossible without a
double-word CAS. `struct ZiposHandle`'s `next` member is deleted by the
implementing change: the new design has nothing to link.

```c
#define ZIPOS_FREE_SLOTS 4
static _Atomic(struct ZiposHandle *) __zipos_free[ZIPOS_FREE_SLOTS];
```

- **Which allocations are recycled: only the fixed
  `sizeof(struct ZiposHandle)` bucket that `zipos-open.c:127` produces.**
  Pop is attempted only when `size == 0`, push only when `h->mapsize ==
  sizeof(struct ZiposHandle)`. That single bucket is 100% of the
  measured win — cosmic ships every `.lua` member STORED, so all ~35
  boot-path opens land on `:127` — and confining it there deletes the
  old design's entire complexity class: no `mapsize >=` first fit, no
  `StartOver`, no size ordering. A size-bucketed list catching `:116`
  (synthetic directory, `size + 1`) and `:132` (deflate, full
  uncompressed size) would retain megabyte mappings for the life of the
  process to speed up opens whose cost is `__inflate`, not `mmap`.
- **Push side: one wait-free atomic exchange per slot, no lock.**
  `__zipos_drop` scans for an empty slot and claims it with
  `atomic_compare_exchange_strong(&__zipos_free[i], &expect_null, h)`
  using `memory_order_release`; on success it returns without
  `munmap`. This is what makes it legal on the `@asyncsignalsafe`
  `__zipos_close` path where the old `__zipos_lock()` was not: no
  mutex, no unbounded retry, at most `ZIPOS_FREE_SLOTS` single-word
  CASes.
- **Pop side: `atomic_exchange(&__zipos_free[i], NULL)` with
  `memory_order_acquire`**, taking the first slot that yields non-NULL,
  falling through to today's `mmap` when none does. A single exchange
  takes ownership atomically, so there is no read-then-CAS window and
  therefore no ABA — the hazard that would otherwise force a tagged
  pointer and a 16-byte CAS on x86-64 / `casp` on aarch64. It is safe
  against a signal handler popping on another thread for the same
  reason: two exchanges on one slot cannot both return the same
  pointer. Same-thread reentry cannot occur at all, since `:243`'s
  `BLOCK_SIGNALS` covers the alloc. **The popper must then store 0 into
  `h->refs`** before returning it, per question 2's hazard; `pos`,
  `cfile` and `mem` are already re-set by `__zipos_load`, and `size`,
  `zipos`, `mapsize` by `__zipos_alloc` itself.
- **What bounds it: `ZIPOS_FREE_SLOTS` itself, enforced at push.** The
  cap is structural — there is no list to grow. Past it, push finds no
  empty slot and `munmap`s exactly as today, so a program that opens
  and closes many members retains at most 4 handles, never more, with
  no reclamation policy, timer or high-water logic. 4 is chosen because
  the boot path's opens are sequential (open, read, close per module),
  so live depth is ~1; the cost of the cap is one granule of retained
  VM per slot, which is 4 pages on Linux but 4 × 64KB on Windows, where
  the allocation granularity is the reason to keep the number small
  rather than generous. Raise it only against a measurement showing
  concurrent depth above it.
- **`fork` and `vfork`.** Across `fork`: nothing to do, by
  construction. Handles are `MAP_PRIVATE|MAP_ANONYMOUS`, so the child
  gets its own COW copies and recycles them correctly, and every
  mutation of the array is a **single atomic word operation**, so
  there is no multi-step publish for a fork to catch half-done and no
  lock for it to copy in the locked state — the hazard that makes the
  old mutex-based design need `pthread_atfork` care. **No atfork
  handler is required, and that is a designed property of the array,
  not an omission.** Across `vfork`: the child shares the parent's
  address space, so a pop there would take a handle out of the
  parent's array and lose it at `exec`. The decision is to **skip the
  freelist entirely when `__vforked`** — pop falls straight through to
  `mmap` — which is one branch on a global the file already reads, and
  is symmetric with `zipos-close.c:40`, where push is already skipped
  for the same reason.

The sibling implementation slice is `3IL8DJRj`.

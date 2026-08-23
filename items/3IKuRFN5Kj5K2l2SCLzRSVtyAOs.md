Lands in: whilp/cosmopolitan (research only — no PR, no C).

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
$ git log --oneline -S -- '->next' libc/runtime/zipos-open.c
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
spec (`o/bin/gitboard spec <this id> FILE`, from the board worktree).

**1. Why the `next` member is vestigial**, from upstream history,
which this fork's log cannot reach:

```
git clone --filter=blob:none --no-checkout \
  https://github.com/jart/cosmopolitan /tmp/upstream-cosmo
git -C /tmp/upstream-cosmo log --oneline -S '->next' -- \
  libc/runtime/zipos-open.c libc/zipos/
git -C /tmp/upstream-cosmo log --oneline -S 'freelist' -- \
  libc/runtime/ libc/zipos/
```

Record the commit that removed the freelist, its message, and the
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
git -C /tmp/upstream-cosmo log --oneline -S '->next' -- libc/runtime/zipos-open.c libc/zipos/
o/bin/gitboard show <this id> | grep -c '^## Findings'
o/bin/gitboard show <this id> | grep -c 'jart/cosmopolitan'
o/bin/gitboard check <sibling id>
git -C <cosmopolitan checkout> status --porcelain libc/
```

- the two `git` commands run clean, and their output is quoted
  verbatim in `## Findings`, so a reviewer re-running them lands on the
  same commits (or the same empty output).
- `grep -c '^## Findings'` on this item is **0 today** and must be 1
  after; the section carries three subsections, one per question, and
  question 3's is five bullets, one per decision point.
- `grep -c 'jart/cosmopolitan'` on this item is **0 today** and must
  be at least 1 after — the answer names where it came from.
- `o/bin/gitboard check <sibling id>` ends `meets the ready bar`, and
  `o/bin/gitboard show 3IK8GFHj` lists that sibling as a child.
- `git status --porcelain libc/` in the cosmopolitan checkout prints
  nothing: no C moved.

## Enablement

none needed for the research itself — the question is answerable with
`git log -S` against a public clone, every constraint it must be
weighed against is quoted here by `file:line`, and the deliverable is
prose on this item.

One piece of known friction to expect at hand-over, not to fix here:
board item `3IFUskgH` records that a research slice cannot reach
`check` without a `--pr`, so `move <id> check` needs the `--force`
path that item describes. That is its item, not this one's; do not
change the tool in this slice.

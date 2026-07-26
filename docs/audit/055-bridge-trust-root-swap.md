# 055 — bridge removal: the one-pin trust root does not exist yet

severity: blocker for 3i
type: gap (provisioning)
area: `bin/make`, cook.mk bootstrap block, make-plan.md provisioning

## what the plan promises vs what exists

make-plan.md's provisioning section describes the end state: a
committed POSIX-sh `bin/cosmic` whose one job is to fetch the pinned
cosmic (pin in `bootstrap/cosmic.pin.tl`) and exec it — chain =
kernel → fetcher → one pin → everything, "down from two pins." none of
that exists (audit 035 #4): the trust root is `bin/make`, its
bootstrap url+sha live in `cook.mk` (a file scheduled for deletion),
and it provisions *two* artifacts (the bootstrap cosmic and the make
engine from cosmos.zip — the engine half is already obsolete, since
cosmic extracts its embedded make to `o/make` itself).

## the work

1. **`bootstrap/cosmic.pin.tl`** — same grammar as every pin, read by
   the same reader (`cosmic.literal` is already in the sh-reachable
   floor of the pinned binary; `bin/cosmic` itself just needs
   url+sha, extractable by grep the way `bin/make` does today).
2. **`bin/cosmic`**: fetch, verify sha256, cache, exec with argv
   passed through. no make, no second pin.
3. **the cold-start gate moves**: `rm -rf o && bin/cosmic --make ci`
   is the new from-nothing check (the 3g lesson — verify the swap
   from a clean tree, not an incremental one).
4. **small features that die with `bin/make`, named so their loss is
   chosen**: `help` (the `##`-comment catalog → `--make` usage +
   skills docs), `only=` substring filter (→ path selection),
   `bootstrap` target, `TMP=`/`INCLUDE_DIRS` knobs (→ env the verbs
   already read, documented), `o=` alternate outdir (→ 051's
   reproducible-verb question).
5. **workflow rewiring**: pr.yml, docs.yml, release.yml all invoke
   `bin/make` today (with the runuser/HOME dance); each switches to
   `bin/cosmic --make <verb>` as its lane's verbs land (051/053/054),
   not in one big-bang commit.

## exit criteria

a fresh clone with network runs `bin/cosmic --make ci` to green with
nothing else on the host; `bin/make`, `cook.mk`'s bootstrap block, and
the second pin are deleted in the same change that flips the last
workflow.

## Goal

G8 — the flow system. The board claims ALL work state, but that claim
stops at the whilp/cosmic remote: work against whilp/cosmopolitan — the
C core every pin bump carries — has nowhere to live, so it leaks back to
labels or to URLs buried in prose.

## Evidence

2026-08-17 (original filing): whilp/cosmopolitan#265 open with a
`work:ready` label — a fully-shaped spec stranded as an issue, the
pointer to it buried in an ended epic. `_work/item.tl`'s record has no
repo field; `_work/gh.tl`'s `slug` reads the STATE checkout's origin, so
every `pull`/`checks`/`merge` addresses whilp/cosmic by construction.

2026-08-19 (second instance, same shape): the G2 sandbox epic's R6 work
was redirected by the owner to whilp/cosmopolitan#266; the only edge the
board could hold is a URL pasted into 3I1IfJ22's phase-2 prose, because
`blocked_by` is same-repo only. Two stranded pointers in two days is the
class, not an instance.

Direction settled 2026-08-17: ONE board, here. whilp/cosmopolitan gets
no `board` branch — a second board would duplicate machinery, split the
goal trace (a cosmopolitan fix exists to serve a cosmic goal), and hand
a repo with no cosmic toolchain a cosmic project to build.

## Change

An item names the repo its PR lands in; everything GitHub-facing reads
that field; the views surface it. Measured 2026-08-19 on the board
branch:

1. **`_work/item.tl`** (227 lines): add field
   `--- The owner/name the item's PR lands in; "" = the board's origin.`
   `repo: string` to `record Item` (fields at lines 28–58). In
   `problems()` (line 102): when set, it must match
   `^[%w%-%.]+/[%w%-%._]+$`, and — mirroring the existing claim/pr rule
   at line 128 — only a workable item may carry one.
2. **`_work/gh.tl`** (190 lines): `slug(s)` (line 21) becomes
   `slug(s, repo?: string)` — returns `repo` unchanged when non-empty,
   else the origin-derived slug exactly as today. `pull`, `checks`,
   `merge` each gain the same optional trailing `repo` and forward it.
   No message changes needed: `api.error_of` renders the request path
   (`GET /repos/<owner>/<repo>/pulls/N: ...`), so every refusal already
   names the repo it addressed — measured on the 2026-08-19 land 403,
   whose text carried the full path. A token that cannot see the foreign
   repo surfaces as GitHub's 404 through the same strings.
3. **Thread it at the three call sites**: `_work/gitgate.tl`'s
   `handover_refusal` (line 141) gains a `repo` param — its caller
   `cmd_move` (`_work/gitverbs.tl:308`) holds the item and passes
   `it.repo`; `_work/gitland.tl`'s `cmd_land` passes `it.repo` to
   `gh.pull`/`gh.merge` (line 49).
4. **`_work/gitverbs.tl`** (431 lines): `cmd_new` accepts `--repo
   OWNER/NAME`, stored on the item; `gitboard help new` documents it.
   No other verb changes — retrofitting a repo onto an existing item is
   the documented file-edit workaround, until evidence earns a verb.
5. **Views**: `show` prints a `repo:` line when set
   (`_work/gitview.tl`); `status` and `tree` append ` [owner/name]` to
   the line when set, so cross-repo work is visible exactly where it was
   invisible.
6. **Tests**: `_work/item_test.tl` (111 lines) — validate accepts the
   default and `owner/name`, refuses garbage and a repo on a root;
   encode/decode round-trips it sparsely (existing item files carry no
   new key). `_work/gh_test.tl` (37 lines, pure classifiers) — the
   short-circuit `slug(s, "whilp/cosmopolitan")` returns its argument
   without touching git. `_work/gitverbs_test.tl` — `new --repo` lands
   the field; `show` renders it.

Sequencing: blocked by 3I3qas9t (in `ready`), which reshapes the same
`gh.tl`/`gitland.tl` lines — land that first, mirrored in `blocked_by`.

## Non-goals

- no `board` branch on whilp/cosmopolitan; no move of its `perf`/`audit`
  issue queues — issues remain the inbound queue in both repos.
- no cross-repo `blocked_by` ids and no live foreign-issue state
  checking — the repo field scopes an item's PR, not the dependency
  graph; a cross-repo dependency stays a URL in the spec, now beside a
  tracked item instead of instead of one.
- no generalization past the two repos this project spans; no
  multi-token auth story — one GITHUB_TOKEN, and its reach is whatever
  GitHub grants it.
- importing #265 and #266 as items is the follow-up triage act once
  this lands, not part of this diff.

## Acceptance

On the board worktree:

- `bin/cosmic --make test _work/item_test.tl _work/gh_test.tl _work/gitverbs_test.tl`
  ends `test: PASS (3 files)`.
- `o/bin/gitboard help new` output contains `--repo`.
- `bin/cosmic --make ci` ends `ci: PASS`.

## Enablement

blocked by 3I3qas9t (same files, in flight), mirrored in `blocked_by`.
Otherwise none needed — every touched line, caller, and the
already-sufficient error-path behavior are measured above.

# D50 — one branch is the board

- **date:** 2026-09
- **status:** active
- **context:** the work board is a ref layout. read from a clone on
  2026-09-13 it is 3687 refs — 724 `items/*`, 723 `ended/*`, 518
  `claim-batches/*` — and the 14350 commits those item, ended and
  claim-batch refs carry are what one branch would have to hold. three
  costs follow from that shape. a whole-board write is a multi-ref push,
  and this environment cannot make one:
  [D49](d49-board-rewrite-pushes-in-idempotent-batches.md) measured the
  session's egress proxy refusing a `git-receive-pack` somewhere between
  50 and 100 ref updates — 1, 10 and 50 pass, 100 fails — so the
  format-5 cutover ran as 31 batches over 1425 refs. the layout is
  load-bearing in 27 `_work/` modules, each naming a ref path,
  enumerating refs, or knowing about claim batches. and the layout is
  why a second transport exists at all: cosmic-lua/work#167 answered a
  connector-only environment — a GitHub connector that can write a tree
  and advance one branch, with no credential for shell git — by
  archiving the whole ref layout as base64 packs inside one branch,
  which every reader must import and project back
  (`_work/singlehead_hydrate.tl`) and which GitHub can show nothing of.
  two transports for one board, because a multi-ref push cannot be
  expressed as connector calls. the measurements above and the
  mechanisms below are [cosmic-lua/work's
  docs/design/storage.md](https://github.com/cosmic-lua/work/blob/main/docs/design/storage.md);
  this record does not re-derive them.
- **decision:** a board is one branch, and one non-forced push of that
  one ref is the only write a mutation makes.
  - the branch is `refs/heads/state` on the board repository, and its
    tree is the whole of the board's state: every item as files under
    `items/<id>/`, every recorded lease as `claims/<id>`, and the format
    marker `_work/format.tl` reads.
  - a mutation is one commit on that branch, so its first-parent history
    is every mutation in the order it was published and
    `git log -- items/<id>` is one item's history. the item codec is
    reused rather than rewritten: the subtree is the bytes
    `_work/itemtree.tl`'s `build_tree` already produces.
  - the write fence is the object id of every path the mutation READ to
    decide, not only the paths it writes — the item subtree and its
    `claims/<id>` blob, an absent path recorded as the zero id — and a
    bounded mutation, whose gate reads beyond the items it writes,
    fences the whole head instead and has that gate re-run against the
    new head before it lands. the fence is re-checked at publish against
    the fetched head: disjoint writers rebase past each other, and a
    same-path writer loses the race with the `LOST_RACE`
    `_work/publish.tl` already refuses with. the mechanism is
    storage.md's `## The write fence`, named here rather than restated.
  - a publish is one non-forced push of that one ref, and what proves an
    attempt landed is the published commit's CONTENT — every
    transition's changed-path object ids, deletions and message, in
    order, against the frozen attempt `_work/prepared.tl`'s manifest
    holds (storage.md's `## Drafts and prepared transactions`). a
    trailer locates a candidate; it never confirms one.
  - a connector-only environment reproduces exactly that push —
    `create_tree`, `create_commit`, `update_ref(force = false)` — under
    the single-head proof of concept's protocol invariants: one
    immutable attempt rendered from a saved plan bound to one
    destination (`_work/singlehead_calls.tl`), the deadline checked at
    the final call, and publication that is not authority. both
    executors write the same tree on the same branch, so there is one
    transport.
- **rejected:**
  - keeping the ref-per-item layout and batching every large write, as
    D49 has it. batching is a workaround for a cap the layout walks
    into, and it leaves the connector path needing a transport of its
    own.
  - the envelope of base64 packs (cosmic-lua/work#167) as the durable
    format. every reader decodes and unpacks before it can read
    anything, the packs and the whole-blob manifest grow with every
    publication until some compaction exists, GitHub cannot show an
    item's history, and an opaque pack means two writers can never
    merge — so every lost race is a re-executed call sequence instead of
    a local rebase.
  - keeping the proof of concept's receipts manifest. a blob every
    writer rewrites conflicts with every other writer, which is exactly
    what a per-path fence is for.
  - a database file committed on a branch — one SQLite blob. a binary
    blob merges never, so every write conflicts with every other, and
    one item's history is unreadable without the tool.
  - one file per item on a branch, with history only inside the file as
    an append-only log in `meta`. it loses the commit-per-mutation the
    events table and the flow measurements read.
- **consequences:**
  - enables: a one-ref publish under any proxy; a git-level rebase of
    disjoint writers; a fresh reader that is a plain clone; GitHub's own
    UI as an item browser; one transport for shell git and the
    connector.
  - enables also: the connector executor lands in the same release as
    the migration, so a connector-only session is never darkened at the
    cutover.
  - costs: every write serialises on one head — a `_perf` contention
    scenario is a child of the plan, and the retries-per-publish it
    measures is the number that would make us revisit. a full rebuild of
    the read model walks the branch's history, 14350 commits at the
    cutover. the branch is named `state` rather than `board` because
    `board/` is an occupied ref directory until the old refs are
    deleted, and a ref cannot be both a file and a directory. and the
    cutover is a one-way migration whose format marker darkens every
    unpinned clone at once.
  - forbids: a second ref namespace for any board fact, and
    force-pushing `state` — branch protection is the board owner's step.

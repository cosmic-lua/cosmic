# D49 — a whole-board rewrite pushes in idempotent batches, the marker riding the last one

- **date:** 2026-09
- **status:** active
- **context:** the format-5 migration of the work board
  (cosmic-lua/work#163, item «SS6S_2U9z») shipped as one atomic push
  over every item ref plus `refs/heads/board/format` — the shape the
  format-4 migration had used, and the one its spec named as a non-goal
  to violate ("never applied halfway"). run on 2026-09-13 from a claude
  session, the push — every item ref (702 `items/*`, 723 `ended/*`,
  1425 in all) plus the marker, a 4.29 MB body — was refused by the
  session's egress
  proxy: an immediate `403` on the `git-receive-pack` POST with no
  GitHub request id and no body, while the 4-byte probe POST on the
  same connection got a `200` carrying one (the session's
  `GIT_CURL_VERBOSE` trace, quoted on work#163). throwaway pushes measured
  the cap: a 6 MB body passes; a single `ended/*` ref passes; 1, 10 and
  50 ref updates pass, 100 fail; a ref deletion is refused identically.
  so a session credential pushes at most some number between 50 and
  100 ref updates per transaction and cannot delete a ref. the board's
  history does not show this cap before: two earlier rewrites went
  through in one push — 323 refs at 1→2 on 2026-09-05 (work#40,
  authored from a session) and 1244 at 3→4 on 2026-09-09 (work#91) —
  and 2→3 moved only the marker (work#90). git records no push
  identity, so which credential and which proxy carried each is not
  known; work#90 made the caller's own git the transport, and this run
  is the first mass push known to have gone through a session's egress
  proxy since. a second fact made batching unsafe as
  shipped: `_work/gitmigrate.tl` read an already-migrated tip's absent
  `spec.md` as an empty spec and would have rewritten the item with an
  empty Change, so a partial push followed by a rerun destroyed data.
- **decision:** a whole-board rewrite is written to run in batches,
  and the batch is the caller's choice.
  - a tip that already carries the rewrite is recognised by its commit
    subject — `migrate <handle> to format <N>`, the one string the
    writer and the detector share (`migration_subject`) — and skipped.
    a rerun after a partial push rewrites nothing that landed.
  - `--limit N` caps the rewrites in one transaction and `--only
    NAMESPACE` narrows it to one ref namespace; every batch is still
    one `git push --atomic --force-with-lease` over its own refs, and
    an empty selection is refused rather than pushed.
  - the format marker rides only the batch that leaves nothing
    remaining. until then the board keeps refusing the new build, so
    the dark window is one window however many pushes it takes.
  - the tool does not retry or split on its own: the cap belongs to
    the caller's transport, not the board, and a caller whose transport
    allows one push still makes one (`--limit 0`).
  - nothing in a rewrite may depend on deleting a ref — a rule the
    migration's spec already carried (a resolved item stays on
    `refs/heads/ended/<id>`), now measured rather than assumed — and the
    tool creates no scratch refs.
  - a batch derives every field from the whole board's text, migrated
    tips included: for a tip already carrying its migration commit, the
    `spec.md` its parent still holds — the exact text one push would
    have read, dropped Acceptance sections included, which the migrated
    `spec/` blobs and commit body would not reconstruct. so batches and
    the single push write the same trees. the first cut fed only the
    unmigrated blobs to `known_owners`; the fresh-context review of
    work#164 found the order dependence, and the rework pinned it with
    a two-item fixture.
  - [D47](d47-spec-declares-intent-only.md)'s "one cutover over every
    ref" stands as the reader's view: the marker moves once and no
    gitboard reader ever sees two shapes. the number of pushes behind
    it is a transport fact D47 did not address, and this record is the
    one that does.
- **rejected:**
  - one atomic push, as designed. the all-or-nothing property is what
    fenced stale prepared writes at the format-4 cutover, and it is
    still the run shape wherever the transport allows it; it lost only
    as the *sole* shape, to the measurement above.
  - a person runs the push, as format 4 was run. it works, and it
    remains the fallback, but it makes the board's own migration the
    one operation a session cannot perform and leaves the board dark
    until a person is free. that window is the one the migration's
    ordering was reworked to shrink: the code merges first, then the
    pin, then the run in the same sitting, so every clone's
    `bin/gitboard` refuses the board only between the bump and the
    push.
  - splitting automatically inside `--execute` on a `403`. the tool
    cannot tell a policy cap from a transient failure, and a retry loop
    against a policy proxy is what that proxy's own guidance forbids;
    the caller names the batch.
  - recognising a migrated tip by its tree (`spec/` present). an item
    with an empty spec writes no `spec/` subtree at all; the first cut
    of the patch did exactly this and missed that item on the fixture.
  - finding the cap by pushing scratch refs. a session cannot delete
    what it creates — one 6 MB probe ref, `work/probe-1789307748`,
    survives in cosmic-lua/work from the diagnosis; the idempotent
    batches themselves are the probe.
- **consequences:**
  - the format-5 cutover ran as 31 atomic batches over 1425 refs
    (1, 10, 50, then twenty-seven of 50, the last 14 with the marker),
    about twenty minutes dark; `fsck: ok (1425 items)`, zero `spec.md` blobs, every
    tip on a `to format 5` commit. the code is cosmic-lua/work#164; the
    retire item («yXSL_x14T») deletes it with the rest of the
    migration, and the next migration copies from that retire commit's
    parent, batching included, the way #163 copied from `3423bac6^`.
  - a partial state now exists between batches: marker unmoved, some
    tips rewritten. every gitboard reader is refused until the marker
    moves, so only a hand-run `git` sees the two shapes, and a run
    that stops must be resumed with the same tool, never restarted
    under a different design.
  - any future mass ref write — a rank renumbering, a bulk re-parent,
    the next format — inherits the cap and the answer: idempotent,
    batchable, marker last, no deletions.
  - revisit when the proxy's cap is published or lifted (`--limit`
    becomes optional, the one-push shape returns as the default run),
    or when a rewrite needs an ordering across items that independent
    batches cannot honour.

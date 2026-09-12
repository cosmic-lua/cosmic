# D47 — an item depends on zero or more items, as a relation of its own rather than a position in the tree

- **date:** 2026-09
- **status:** active
- **decision supersedes part of** [D45](d45-rank-is-a-list-position-at-every-level.md)
- **context:** [D45](d45-rank-is-a-list-position-at-every-level.md) replaced
  three ordering mechanisms with one — rank is a position in the parent's
  list — and in doing so routed dependency through parentage: *"a
  prerequisite is a child of the item that waits on it, inheriting the
  waiter's rank prefix."* its evidence was that of 26 live `blocked_by`
  edges, 22 sat between siblings, so the edge said nothing parentage did
  not already say about **order**. that reading was right about order and
  wrong about readiness, and the two are different questions. being a
  sibling does not make a dependency expressible: two siblings that both
  wait on a third cannot both re-parent it, because an item has one
  parent. measured across the live board on 2026-09-12, 30 items express
  a dependency in prose naming an item handle or a release, against 31
  distinct things depended on — and **5 of those 31 are waited on by
  more than one item**, a shape parentage cannot hold at all. the cost
  showed up as prose: 142 items (10.6%) say "blocked on «id»" in a spec
  sidecar, and of the 21 distinct `Ready when:` preconditions ever
  written, 16 are "a sibling item is done", several naming the sibling
  and then writing a shell command to detect it because there was no
  relation to point at. re-parenting also has a side effect nobody asked
  for: a waiter with a child is a container, so declaring a dependency
  changed the waiter's role and removed it from the queue rather than
  marking it not-yet-startable.
- **decision:** an item carries `depends_on`, a set of zero or more item
  ids, and it is a relation of its own.
  - it has **no effect on rank.** rank stays D45's list position, which
    stands unchanged. parentage and order answer *where in the queue*;
    dependency answers *whether this may start yet*. one relation for
    each, neither doing the other's job.
  - an item with an unresolved dependency is not pullable: `next` does
    not offer it and `take` refuses it, naming the dependency. it stays
    **workable** — it does not become a container, so it keeps its place
    in the queue and reappears the moment its last dependency resolves.
  - stored as a space-joined `depends_on` line in `meta`, beside `order`,
    `builders` and `speccers`, so readiness costs no read beyond the
    `meta` every whole-board verb already loads. not an `edges/` subtree:
    D45 was right that a whole edge kind with its own namespace was more
    machinery than this relation needs.
  - a cycle is refused by the mutation that would create it and reported
    by `fsck`, bounded by the same depth limit the rank and flow walks
    already share.
  - a precondition that is an external fact — a release carrying a
    merged item, a pin naming that release — is itself work, so it is an
    item, and the several items waiting on it depend on that one item.
    this is the shape parentage could not express and the reason the
    relation is many-to-many rather than one waiter per prerequisite.
- **rejected:**
  - **keeping D45's parentage.** it cannot express a prerequisite shared
    by two waiters, which is 5 of 31 real cases; and it overloads one
    relation with two jobs, so declaring a dependency silently re-ranks
    the prerequisite and turns the waiter into a container.
  - **reviving `blocked_by` as an `edges/<kind>/<id>` subtree**, the
    shape D45 retired. a set of ids on the item is the same information
    with no second namespace, no per-item edge tree to read, and no
    doctrine section of its own — D45's objection to the machinery
    survives even though its objection to the relation does not.
  - **a `ready_when` field naming a command and its expected output.**
    it makes the tool spawn an arbitrary command during `next` and
    `take`, and 16 of the 21 real preconditions are "an item is done",
    which this relation states directly.
  - **letting a dependency lift the prerequisite's rank**, as the
    retired `blocked_by` did. that is the conflation this record
    separates: a prerequisite is worked when its own rank says so, and a
    waiter whose dependency is unresolved is simply skipped rather than
    reordered.
  - **inferring dependencies from the `«handle»` references already in
    spec prose.** a spec cites items for many reasons — provenance, a
    sibling's contrast, a duplicate — and only some of those citations
    are dependencies; guessing would block items nothing was waiting on.
- **consequences:** this restores the shape [D37](d37-two-states-two-gates.md)'s 2026-08 amendment already
  described for the block-first exit — a stuck item records the question and
  the question's `done` frees it — with a set of ids in place of the edge kind
  that amendment named. `next` gains a reason to skip that is not a spec-bar
  gap, so a queue can be legitimately empty while items remain — and a
  session reading that needs to see which dependency holds each one, or
  it looks like a bug. the cycle check is new work that parentage got for
  free, since a tree cannot cycle and this graph can. two relations now
  exist where D45 deliberately left one, which is a real cost in
  explaining the system: `gitboard help order` describes rank, and
  readiness needs its own statement beside it rather than a sentence
  inside that page. what this forbids: any use of parentage to express
  "this must land first", and any verb that reorders a prerequisite
  because something depends on it. what would make us revisit: fan-in
  staying at 2 and shared prerequisites staying under a handful, with
  the cycle check never firing — that would mean the relation is
  carrying less than parentage plus a convention would have.

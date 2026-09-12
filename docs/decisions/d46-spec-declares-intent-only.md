# D46 — an item's spec declares intent only; measurement and outcome live in its own history

- **date:** 2026-09
- **status:** active
- **context:** a gitboard item carried its typed fields in a `meta`
  blob and everything else in a free-markdown `spec.md` sidecar, and
  the system recovered what it needed from that markdown by regex at
  read time. measured across the live board on 2026-09-12: 1342
  sidecars, 7.08 MB, **1149 distinct heading texts of which 1052 appear
  in exactly one item**. only two headings are read by code — `##
  Change` (`_work/spec.tl`'s `READY_SECTIONS`) and `## Access`
  (`_work/gitowner.tl`, `_work/gitready.tl`); `## Non-goals`, `##
  Evidence`, `## Goal` and `## Acceptance` are named in four brief
  templates and parsed by nothing. three failures followed. one heading
  had three incompatible readers — `spec.sections`, `overlap.change_section`
  and `briefmeasure.change_paths` — which disagree on three of four
  representative bodies that all pass the bar. a convention nothing
  reads: 47 items declared readiness as a `## Ready when` heading and
  38 as a `Ready when:` sentence, zero overlap, and only the sentence
  is executed, so 47 declarations were inert. and one file held three
  artifacts: **39.6% of sidecars carried more than one of
  specification, findings and log, and 8.4% held no specification at
  all** — 71% of corpus bytes spec, 21% findings, 8% log, with the
  three largest sidecars (91 KB, 48.5 KB, 39 KB) almost entirely log.
  the mechanism that put findings in the spec was explicit rather than
  accidental: `_work/gittake.tl` refuses a research handover that has
  no sidecar because *"a research handover hands the spec over"*, and
  records `it.result = spec.revision(body)` — the deliverable could
  only ever point at the spec. the vocabulary was meanwhile converging
  on its own (across ten deciles change/non-goals/evidence went
  62/68/35% to 95/91/81% while goal/acceptance/enablement fell to
  29/9/0%), which places the one-off tail squarely in the two artifacts
  that had no schema to converge on. the fuller evidence and the design
  is [cosmic-lua/work's docs/design/schema.md](https://github.com/cosmic-lua/work/blob/main/docs/design/schema.md).
- **decision:** a spec is prospective and is replaced; a measurement is
  retrospective and is appended. the tree holds only the first.
  - an item's spec is `spec/change.md` and `spec/non-goals.md` — prose
    as raw blobs, so `git diff` still reads — and nothing else. there
    is no escape-hatch field: content that is not prospective intent is
    a log entry.
  - the facts code branches on are **declared, not extracted**.
    `touches` (the files the change is expected to touch, advisory) and
    `access` (repositories needed beyond the item's own) join `meta` as
    space-joined lines beside `order`, `builders` and `speccers`, and
    `target` unpacks into `repo` and `base`. ownership is enforced by
    which verb writes a field, as it already is for `verdict` and `pr`.
  - everything retrospective is a commit message body on the item's own
    ref, which already carries date, author and subject. the item's
    **outcome** is the body of the commit that resolved it, making the
    deliverable a commit in both cases — a product commit for a diff, a
    board commit for research.
  - there is no `acceptance` field. done is the repo's gate passing; a
    behaviour worth guaranteeing permanently is a test or ratchet in
    the diff, which outlives the sidecar that asked for it.
  - there is no `kind` field. what an item is follows from what it
    carries and where it sits, as role already follows from the graph.
  - dependencies stay [D45](d45-rank-is-a-list-position-at-every-level.md)'s
    parentage — a prerequisite is a child of its waiter — and a
    precondition that is a release carrying a done item is itself work,
    so the pin bump is an item like any other.
  - `key`, `result` and `verdict_spec` leave the schema, and
    `spec.revision` is deleted with its last caller.
  - format 5, one cutover over every ref, then the migration module is
    retired — the shape the format-3 to format-4 migration already had.
- **rejected:**
  - **one parser and a declared heading vocabulary, keeping the
    markdown.** this closes the three-reader disagreement and nothing
    else: 90% of `## Change` sections carry at least one mechanically
    extracted fact (861 items with backticked paths, 300 with file:line
    citations), so the extraction stays, and the three-artifacts
    problem is untouched.
  - **splitting the markdown into per-section blobs** (`spec/change.md`
    holding what `## Change` held). the same measurement kills it: the
    parsing that hurts is *within* a section, not at its boundary, so
    the move relocates the regexes rather than deleting them. declaring
    `touches` is what removes them.
  - **one serialized blob — `cosmic.literal` or `cosmic.json`.**
    `cosmic.literal` refuses lists on write and on read, and both
    formats write a 60-line Change as a single escaped line, destroying
    the diff these are reviewed through.
  - **a flat typed record with a `notes` escape hatch.** fitted against
    all 1342 sidecars, an eight-field record absorbs 67.8% of items
    fully and leaves **28.3% of corpus bytes** in the hatch, with 195
    items over half. a drawer that large is the sidecar again under
    another name.
  - **an explicit `kind` enum** (`outcome | container | change |
    research | log`). a second source of truth that can disagree with
    the artifacts an item actually carries; deriving it also fixes a
    live misclassification, where 12 `friction:` items sit directly
    under the board and are therefore read as outcomes.
  - **a typed `ready_when` field carrying a command and its expected
    output.** it would still be an arbitrary command the tool spawns
    during `next` and `take`. classifying all 21 distinct preconditions
    ever written: 16 are "a sibling item is done" — several naming the
    sibling and then writing a shell command to detect it anyway — four
    are a release-and-pin chain that is itself work, and one is a
    calendar fact. nothing needs running.
  - **reviving `blocked_by` as an edge.** D45 rejected this and its
    reasoning holds; parentage already expresses the 16 sibling cases.
  - **keeping `evidence` as a spec field** so a builder need not walk
    history for it. a measurement describes a past and belongs on the
    append-only side; 797 items carry one and no code reads any of
    them.
  - **backdating migrated content to the dates inside its own
    headings.** it fabricates a history that did not happen, and only
    about 14% of tail headings carry a usable date.
  - **lazy per-item migration on next write.** it leaves two live
    shapes indefinitely, which is the bifurcation the format marker
    exists to prevent.
- **consequences:** the divergence goes away by construction — four
  path-parsing functions, `spec.revision`, and three `meta` fields are
  deleted rather than reconciled — and collision detection stops
  costing a whole-board spec read, because `touches` is in the `meta`
  that `store.list` already loads. the costs are real. findings become
  **immutable**: a correction is a new entry, not an edit. a reviewer
  wanting the evidence for an item now walks its history rather than
  reading it inline, and 28% of corpus bytes move out of what `show`
  prints as the spec. the cutover is a hard format bump, so **no clone
  can operate the board until its pinned `bin/gitboard` understands
  format 5** — this change stages behind its own release, and is the
  first user of the rule that a pin bump is an item. a schema can force
  a field to be filled but never to be honest: doctrine's rigor rules —
  imperative and concrete, one mechanism not two, measured not inferred
  — remain unenforceable prose, and this decision does not pretend
  otherwise. what would make us revisit: a `notes`-shaped pressure
  reappearing as authors put prospective content somewhere it does not
  belong, or findings-by-reference turning out to matter enough that
  they need addressable identity rather than living in a commit body.

# D26 — a decision record: four sections, a status header, amended in place

- **date:** 2026-08
- **status:** active
- **context:** twenty-five records had accumulated with no record
  governing them, and three inconsistencies showed what that cost.
  first, the README said entries are "append-only" and that a reversal
  "is a new entry that supersedes the old one, and it says so in its own
  file rather than editing the record it replaces" — while D13, D14, D18
  and D19 had all been amended in place. the stated rule and the
  practice disagreed, and nothing said which one was right. second, a
  record's state was invisible: D25 rescoped D7, yet the index still
  advertised D7's original title and its body still ended on an open
  question D25 had answered, so the shortest path into the directory led
  to retired doctrine. third, the only thing enforced was the H1 the
  index derives from — and an unenforced rule drifts, which is the
  finding [D19](d19-toolchain-visibility.md) already acted on when it
  turned the visibility rule into a lint.
- **decision:** the form, the states, and where the method lives.
  1. **the form.** one file per record,
     `docs/decisions/d<NN>-<slug>.md`, taking the next free number,
     never reused and never renumbered. the first line is exactly
     `# D<n> — <title>` and the title states the decision rather than
     the topic. a header block of `date` and `status` opens the body,
     then the four sections: **context** (the forces at the time, with
     the measured facts), **decision** (the call, as a rule someone can
     apply), **rejected** (every serious alternative *with the reason it
     lost*), **consequences** (what it enables, what it costs, what it
     forbids, what would make us revisit).
  2. **three states, in the header.** `active`; `amended <YYYY-MM>`
     (with a short reason in parentheses); `superseded by D<n>`.
  3. **amended in place — the append-only sentence is what changes.** a
     merged record's body is never rewritten to look right in hindsight.
     when a fact under a still-standing decision moves, a final
     `- **amended <YYYY-MM> (<why>):**` bullet says what stopped being
     true and what replaced it. only a *reversal* supersedes, as a new
     numbered record that names the one it replaces. correcting a
     renamed path or a dead link changes no claim and is just a fix; a
     retitle may take the slug with it, and the number never moves.
     context is a snapshot of the decision moment and is not maintained
     as the world moves — the live parts are the decision and its
     consequences.
  4. **the state is derived and gated.** `_docs/derive.tl` reads the H1
     and the status header into the index table, and
     `_build/docs_test.tl` fails the build when the committed table has
     drifted, when a record cannot be parsed, or when a
     `superseded by D<n>` names a record that does not exist.
  5. **the method lives in `skills/decide`** — when to open a record,
     how to write each section, and the audit procedure for converging
     an existing one. this record is the decision; the skill is its
     operating manual, and the split is the same one
     [D12](d12-goals-and-decisions-separate.md) drew between goals and
     tradeoffs.
- **rejected:**
  - **Oxide's RFD lifecycle wholesale** — six states (prediscussion,
    ideation, discussion, published, committed, abandoned), a branch and
    a pull request per document, discussion before the work. its spirit
    is what this format is built on: writing is how an idea gets
    rigorous, the pull request is the forum, the rejected ideas are kept
    rather than deleted, and the process governs itself through its own
    document (which is what this record is). the *states*, though, exist
    to coordinate many people across teams before implementation
    starts. here a record lands in the pull request that implements it
    and is reviewed by the same planner review every change gets
    (`skills/plan/review.md`), so three of the six states are ones no
    record could ever be observed in.
  - **MADR's template** — YAML frontmatter, decision drivers, a
    pros/cons block per option. more ceremony per record than these
    tradeoffs need, and the pros/cons grid makes the short record
    impossible: [D2](d02-quality-not-adoption.md) is twelve lines and
    complete, which is a shape worth being able to write.
  - **supersede-only, never amend** (the README's stated rule) — it was
    tested against the four records that had already been amended, and
    each time it would have promoted a moved fact into a new numbered
    decision. D14's "it is not a second pinned binary" is not a decision
    anyone made; it is a fact that moved under one. numbers would
    inflate with non-decisions, and a reader following D13 would need
    three files to learn what one says.
  - **status as prose in the body** — invisible in the index, which is
    the surface most readers hit first, and underivable, so nothing
    could gate it. the header field is what makes both work.
  - **no records at all, git history as the record** — the part worth
    keeping is the option that lost and why, and that never appears in a
    diff.
- **consequences:** a record now fails the build when its status is
  missing, outside the vocabulary, or points at a record that does not
  exist, and the index carries a status column, so the state a reader
  sees first is the state the gate checks. the costs, stated: a change
  that touches another record is two edits — the amendment and the older
  record's status — and forgetting the second is exactly what the audit
  step in `skills/decide` exists to catch; and the gate can only check
  that the vocabulary parses, never that an amendment's prose is true.
  changing any of this means amending this record, which is the property
  the record exists to have.

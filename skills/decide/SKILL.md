---
name: decide
description: >
  How architecture decisions are recorded in docs/decisions: when a
  tradeoff earns a record, the four-section form and the H1 grammar the
  index derives from, and the amend-versus-supersede rule. Use when
  settling a tradeoff, writing or reviewing a decision record, amending
  one whose facts moved, or checking whether a decision already exists.
---

# Recording decisions

a decision record is one settled tradeoff, written down where the next
reader will find it. the failure it prevents has two shapes: a
newcomer who accepts a constraint blindly because nobody wrote down
why, and a newcomer who reverses it blindly for the same reason. both
are silent bugs in the project's direction, which is why this repo
treats "read the decision, then amend it deliberately" as the only
sanctioned way to change one.

the records live in [docs/decisions/](../../docs/decisions/), one file
per record, indexed by a derived table in that directory's README.
`docs/goals.md` says what cosmic is trying to be; the records say what
was given up to get there
([D12](../../docs/decisions/d12-goals-and-decisions-separate.md)).
the process itself is a record —
[D26](../../docs/decisions/d26-decision-records.md) — and this skill is
its operating manual: D26 is the decision, this file is the method.

## when a tradeoff earns a record

write one when all three hold:

1. **it constrains future work.** someone will hit this later and want
   to do the other thing.
2. **something real was given up.** there is a losing option a
   competent contributor would have chosen. no loser, no record — that
   is a design note, not a decision.
3. **the reason is not visible from the code.** the code shows what;
   the record exists for why, and for what the why cost.

the shapes that recur here: a promise or its ranking
([D3](../../docs/decisions/d03-no-silent-bugs.md),
[D25](../../docs/decisions/d25-outcomes-and-instruments.md)); an
exception to a doctrine everything else follows
([D22](../../docs/decisions/d22-infallible-csprng.md),
[D23](../../docs/decisions/d23-check-throws.md)); a contract frozen at
a public boundary ([D20](../../docs/decisions/d20-naming-charter.md),
[D24](../../docs/decisions/d24-structured-failures.md)); the build's
trust chain and what it excludes
([D13](../../docs/decisions/d13-trust-root.md)); ownership of a
dependency — pin, patch, or fork
([D5](../../docs/decisions/d05-upstream-first-teal.md),
[D21](../../docs/decisions/d21-carried-tl-patch.md)); a scope or
sequencing bet held on purpose
([D9](../../docs/decisions/d09-batteries-include-serving.md),
[D11](../../docs/decisions/d11-harness-first.md)).

**do not** open a record for: which work happens next (that is the
board — `skills/work`), a performance hypothesis (a `perf` issue —
`skills/optimize`), a rule a comment can carry in place
(`skills/docs-style`), or a change with no loser. a record nobody
could have disagreed with dilutes the ones that matter.

**check first.** `ls docs/decisions/` and read the index table before
writing: the decision may exist, in which case the work is an
amendment, not a new number.

## where the argument happens

Oxide's RFDs are the model worth copying, minus the parts that assume
a company: writing is how an idea becomes rigorous, the pull request
is the forum (line-by-line, not a comment thread), timely beats
polished, a rejected idea is kept rather than deleted, and the process
governs itself through its own document.

what does not transfer is the separate lifecycle. an RFD is discussed
before it is built, across teams, so it needs six states and a branch
of its own. here the record lands **in the pull request that makes the
change**, reviewed by the same planner review any change gets
(`skills/work/review.md`), and its state after merge is exactly one of
three: it stands, it was amended, it was superseded. write the record
first — before the diff — when the tradeoff is contested or the
implementation is expensive; the draft is the cheapest place to
discover that the rejected option was better.

## the form

file: `docs/decisions/d<NN>-<slug>.md`, `NN` zero-padded to two
digits, the next free number, **never reused and never renumbered**.

first line, exactly: `# D<n> — <title>`, with an em dash. `_docs/derive.tl`
parses that line into the index and `_build/docs_test.tl` fails the
build when the committed table drifts from it, so a record with a
malformed H1 is a record nobody can find.

the title is the decision, not the topic: "no self-hosting: make stays
the graph executor", not "the build system". lowercase, one claim.

```markdown
# D<n> — <the claim, lowercase>

- **date:** YYYY-MM
- **status:** active
- **context:** the forces at the time of the decision — what collided,
  with the measured facts that made it urgent (numbers, sizes, timings,
  the issue arc that surfaced it). written to stand alone: a reader
  with only this file understands the problem.
- **decision:** the call, in active voice and present tense, stated as
  a rule someone can apply. parts get sub-bullets when the decision has
  parts.
- **rejected:** every serious alternative, each with the reason it
  lost. an option listed without a reason is not rejected, it is
  ignored — and this is the section that stops the relitigation, so it
  is the one to write hardest.
- **consequences:** what this enables, what it costs, what it now
  forbids, and what would make us revisit. the accepted costs are what
  make the record honest; a consequences list with only upside is a
  sales pitch.
```

`status` is one of: `active`; `amended YYYY-MM` (plus a short reason
in parentheses when another record drove it); `superseded by D<n>`.

length follows the tradeoff.
[D2](../../docs/decisions/d02-quality-not-adoption.md) is twelve lines
and complete; [D20](../../docs/decisions/d20-naming-charter.md) is a
charter and earns its size. one record, one decision: when a draft
grows a second claim with its own losing option, it is two records.

**voice.** the surrounding docs are lowercase and terse; match the
file you are next to. name real paths, functions and numbers rather
than gesturing at them. records are the one place in the tree exempt
from `skills/docs-style`'s ban on history and issue references —
narrating how we got here is their job. everywhere else the rule is
restated in place, and only a doc whose job is routing links here.

## amend, supersede, correct

the body of a merged record is not rewritten to look right in
hindsight. three moves, in order of how much of the record survives:

- **correct** — a path the tree renamed, a dead link, a typo. changes
  no claim, so it is just a fix: edit in place, no status change.
- **amend** — the decision stands, but a fact under it moved. append a
  final `- **amended YYYY-MM (<why>):**` bullet saying what stopped
  being true and what replaced it, and set `status`. the original
  body stays exactly as written.
  [D13](../../docs/decisions/d13-trust-root.md) and
  [D14](../../docs/decisions/d14-no-self-hosting.md) are the worked
  examples — including D14's precedent that a **title** advertising
  the retired fact is retitled, because the index is read far more
  often than the record. a retitle may take the slug with it
  (`git mv`, then fix the handful of in-tree links); the number never
  moves.
- **supersede** — the call itself was reversed. the reversal is a
  **new record** with the next number that names the one it replaces
  and says why the earlier reasoning failed; the old record keeps its
  body and gets `status: superseded by D<n>`. never delete a record:
  the dead end is the most useful thing in it.

**context is a snapshot.** it describes the world at decision time and
is not maintained as the world moves — D6 may name a Makefile that no
longer exists. the live parts are the decision and its consequences;
when those stop being true, amend.

## mechanics

```bash
ls docs/decisions/                      # the next free number
$EDITOR docs/decisions/d26-slug.md      # write the record
bin/cosmic _docs/derive.tl              # rewrite the derived index table
bin/cosmic --make test _build/docs_test.tl   # gate: index matches records
bin/cosmic --make ci                    # before the PR, like any change
```

`_docs/derive.tl` owns the table under `| # | decision | status | |` in
`docs/decisions/README.md` — never hand-edit those rows; the prose
around them is prose and is edited by hand. the same run also refuses
a record whose H1 or status header does not parse, which is the check
worth running before opening the PR.

## the bar

before merging a record, every line answers yes:

- the H1 parses (`# D<n> — <title>`), the number is free, the index
  regenerated and the gate green.
- the title states the decision, not the subject area.
- context names the actual forces, with the measurements if any exist.
- every rejected option carries the reason it lost.
- consequences name at least one real cost, and what would make us
  revisit.
- it stands alone: no pointer chase to understand the decision.
- nothing in it relitigates an existing record — if it does, it is an
  amendment or a supersession, and says so.
- the prose elsewhere that this decision governs (AGENTS.md,
  docs/goals.md, module docs) states the rule in place, linking here
  only where the full tradeoff matters to that reader.

## auditing the records

converging an existing record — or the whole directory — is the same
surgical discipline `skills/docs-style` uses on comments: read the
record fully before judging any part of it, and prefer leaving a
compliant record byte-identical over rewording it.

1. **does the H1 parse, and does the index row match?** run
   `bin/cosmic _docs/derive.tl` first; it answers both for every file
   at once.
2. **is the status honest?** a record another record rescoped, or
   whose own body carries an amendment, must not read `active`. a
   `superseded by D<n>` must name a record that exists.
3. **are the live parts still true?** check the decision and
   consequences against the tree — a decision that describes a file or
   mechanism that no longer exists needs an amendment saying so, not a
   quiet rewrite. leave context alone.
4. **do the pointers run both ways?** when D_b changed D_a, D_a says
   so in its status and amendment, and D_b names D_a in its body. a
   forward pointer that exists only in the newer record leaves the
   older one lying to whoever reads it first.
5. **is every rejected option reasoned?** an unreasoned alternative is
   the gap the next relitigation walks through; fill it from the PR
   that landed the record, or drop the option.
6. **is anything here not a decision?** a record that never had a
   losing option is a doc in the wrong directory.

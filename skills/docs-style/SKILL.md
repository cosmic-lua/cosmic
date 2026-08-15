---
name: docs-style
description: >
  The house standard for comments and docs: state what the code is for
  and the implementation details a reader needs, in language that
  stands alone — no history, no commit/issue/decision references. Use
  when writing or reviewing any comment, doc comment, or markdown doc,
  and when auditing existing files to converge them on the standard.
---

# Concise, specific, concrete docs

A comment or doc has one job: tell the reader what the code is for,
plus any implementation detail the code itself cannot show — an
invariant, a unit, a constraint, a non-obvious consequence. Everything
else is noise. This file is the standard; the audit procedure at the
bottom is how to converge an existing file onto it.

## The standard

A good comment:

1. **states the goal** — what this code is for, in present tense, as a
   fact about the code as it is today.
2. **adds only notable implementation details** — the invariant the
   code relies on, the unit an integer is in, the edge case a branch
   exists for, the reason a simpler approach is wrong. If the code
   already says it, the comment goes.
3. **stands alone** — a reader with only this file open understands it
   completely. No pointer chases.
4. **is concise and concrete** — name actual values, shapes, units, and
   functions. One sentence that says the thing beats three that gesture
   at it.

## Banned moves

**No history.** How the code got here is the version control system's
job, not the comment's. Delete narration of renames, removals, and
past shapes: "was `X`", "previously", "formerly", "retired",
"since ...", "no longer", "used to". If the old name matters to nobody
reading today's code, nothing replaces it; if the current behavior
needs explaining, explain the current behavior.

```teal
-- before
--- Compile a Teal file to Lua code (#1001: was `compile`).
-- after
--- Compile a Teal file to Lua code.
```

**No commit, issue, PR, or decision references.** `#989`, `D20 rule
11`, commit hashes, and "see the decision record" all make the reader
leave the file to learn something the comment should have said. If the
referenced rationale matters, state the rationale itself in a clause;
if it doesn't, drop the reference.

```teal
-- before
--- return may carry the value and nothing else (D20 rule 11).
-- after
--- A fallible return has exactly two slots: the value and the error.
```

```teal
-- before
-- cosmic.poll owns the absolute-deadline retry (#980), so repeated
-- EINTR cannot extend the timeout.
-- after
-- cosmic.poll owns the absolute-deadline retry, so repeated EINTR
-- cannot extend the timeout.
```

**No self-justification.** A comment never argues that the code is
correct, describes the change that introduced it, or addresses a
reviewer. It describes the code.

**No restating the code.** `-- close the file` above `f:close()` is
deleted, not improved.

## What survives, and what a rewrite must preserve

- **Rationale is welcome — inline.** "so repeated EINTR cannot extend
  the timeout" is exactly what a comment is for. The banned thing is
  the pointer to where the rationale lives; the rationale itself,
  stated in place, is the point.
- **Code cross-references are fine.** Naming a real function, module,
  or file the reader would go to next (`see escapehtml.c`,
  "`cosmic.poll` owns the retry") is standalone: it points at code,
  not at history.
- **Doc-comment structure is load-bearing.** `---` doc comments and
  their `@param`/`@return` tags feed type generation, the doc index,
  and coverage ratchets. Rewrite the prose; never remove or reshape
  the tags or the comment's position.
- **Code is untouched.** An audit edits comments and markdown prose
  only — never identifiers, string literals (even ones containing
  stale references; they may be asserted on by tests), behavior, or
  formatting of surrounding code. `-- cast: <reason>` justification
  comments are code to the linter: keep them, and keep the reason
  concrete.
- **House style holds**: 90 columns, the file's existing comment
  density and voice, `--` vs `---` as the file already uses them.

## Exemptions

- **Decision records** (`docs/decisions/**`) are the narrative of how
  we got here *by design* — leave them alone.
- **Operational references**: where a reference IS the content — a
  backlog that lives in issues ("open hypotheses are issues labeled
  `perf`"), a changelog, a release note — the reference stays.
- **Rationale indexes**: a doc whose job is to route readers to full
  rationale (a decisions README, a contributing guide's "where
  decisions live" section) may link decision records. Any other doc
  states the rule in place; it may *additionally* link the record only
  when the full tradeoff genuinely matters to its reader.

## Audit procedure (converging a file)

1. Read the whole file first; understand what the code does before
   judging any comment.
2. For each comment or doc paragraph, ask: does it state the goal or a
   needed detail, as a standalone fact about today's code?
   - History or reference clause → rewrite to state the fact (or the
     rationale) directly; drop what no longer informs.
   - Restates the code → delete.
   - Vague → make it concrete, or delete.
   - Already good → leave it byte-identical. An audit is surgical:
     no reflowing, no drive-by rewording of compliant comments.
3. Never let a rewrite change meaning. When a comment asserts
   something you cannot verify from the file and nearby code, keep the
   assertion and strip only the history/reference framing.
4. Re-read each edited comment with fresh eyes: would a reader with no
   repo history understand it completely? Is every remaining word
   earning its place?

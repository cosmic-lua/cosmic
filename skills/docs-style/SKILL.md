---
name: docs-style
description: >
  The house standard for comments and docs: state what the code is for
  and the implementation details a reader needs, in language that
  stands alone — no history, no commit/issue/decision references. A
  markdown page is one of four kinds (tutorial, how-to, reference,
  explanation), written in short plain sentences, with code the gates
  check. Use when writing or reviewing any comment, doc comment, or
  markdown doc, and when auditing existing files to converge them on
  the standard.
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

## Which page: the four kinds

A markdown page under `docs/` is exactly one kind, and its directory
says which. The four answer four different reader needs, and a page
that serves two needs serves neither well.

| kind | directory | the reader wants | the page does | the page never does |
|---|---|---|---|---|
| tutorial | `docs/tutorial/` | to learn by doing | walks one path to a working result; every step is concrete and runs | offers choices, explains design, covers edge cases |
| how-to | `docs/howto/` | to get one task done | numbered or ordered steps for a reader who knows the basics; names the commands and files | teaches concepts, lists every option, justifies itself |
| reference | `docs/reference/` | a fact | states the facts completely, in the structure of the thing described (one section per rule, verb, column) | instructs, advises, tells stories |
| explanation | `docs/explanation/` | to understand why | discusses design, tradeoffs, and consequences in prose | gives steps to follow |

Contributor pages mirror the four under `docs/dev/<kind>/` and do not
ship. `docs/goals.md` and `docs/decisions/` stay where they are and
are linked from explanation pages.

The shipped kinds are what the binary serves: `docs/howto/test.md` is
`cosmic --docs howto.test`, and `cosmic --docs howto` lists the kind.
Refer to a page by that address in prose and in error messages.

Two rules follow from the table:

- **when a sentence wants to be on another kind of page, move it and
  link.** a how-to that starts explaining links the explanation; a
  reference that starts advising links the how-to. the link is one
  line: `cosmic --docs explanation.build` says why.
- **the module reference is generated.** `cosmic --docs <module>`
  renders the doc comments, so no prose page restates a signature.
  Prose reference is for what has no source to derive from: the lint
  rules, `--make`'s tables, the platform matrix, the conventions.

Tutorials get two more: the reader must not need to make a decision
(name the file, name the command, show the output), and the page must
be RUN, not read, to be reviewed — the runner below does that in CI,
and the author does it first.

## Sentences: the writing rules

Prose follows the Simplified Technical English writing rules. They are
guidance a reviewer applies, not a lint, and the house lowercase voice
stays. Apply them sentence by sentence:

1. **one instruction per sentence** in a procedure; one idea per
   sentence elsewhere.
2. **length**: about 20 words in a step, 25 in a description. a
   sentence past that is two sentences.
3. **active voice.** "the gate refuses the file", not "the file is
   refused by the gate". name the actor: the checker, the formatter,
   `--make`, the reader.
4. **the imperative for steps**: "run `cosmic --make ci`", not "you
   should run" or "one runs".
5. **one topic per paragraph**, and the topic in its first sentence.
   six sentences is a long paragraph.
6. **one meaning per term, one term per meaning.** it is an
   `artifact`, not sometimes a `binary` and sometimes an `executable`;
   it is `narrow`, not `refine`; the project's words are the words on
   `cosmic --help` and in the module names.
7. **no noun stacks past three words.** "the test sandbox grant
   derivation rule" is "the rule that derives a test's grants".
8. **present tense, statements of fact.** "the formatter rewrites the
   file" — never "will", "should", "might", "could" about what the
   code does.
9. **articles stay in.** "the checker reads the source", not "checker
   reads source".
10. **no em-dash chains.** a clause that hung off a dash is its own
    sentence. a parenthesis holds a name or a value, not a thought.
11. **warnings before the step they guard**, as their own sentence:
    "work on a copy. the artifact you run is the one you would edit."

The banned moves above still hold on top of these: no history, no
issue or decision references, no self-justification.

## Code in a page

Every fence claims something, and the gates hold it to the claim:

- **```` ```teal ```` and ```` ```lua ```` compile.** at full
  strictness, warnings included, and as a formatter fixpoint
  (`_build/snippets_test.tl`). a fence about a compile error, a
  deliberate mis-format, or a skeleton with `...` in it is prose:
  tag it ```` ```text ````.
- **a fence that shows output is derived.** name the `Example_*`
  function in the info string and let the tool fill it:

  ````markdown
  ```teal example=cosmic/json_example.tl#Example_decode
  ```
  ````

  `bin/cosmic _docs/derive.tl` writes that function's body into the
  fence, `-- Output:` block included; `_build/docs_test.tl` fails when
  the committed fence differs from the source. never type an output
  claim by hand. if no example exists for what the page shows, write
  one in the module's `*_example.tl` first.
- **a tutorial's files and commands run.** a file the reader creates is
  a fence whose info string names it (```` ```teal file=greet/text.tl ````);
  a command is a line in a ```` ```bash ```` fence, and each `# ` line
  under it is an assertion — a substring the command's output must
  contain. `_build/tutorials_test.tl` writes the files and runs the
  commands in a scratch project, in page order, with `cosmic` resolving
  to the binary under test. `# ...` is a skip.
- **a `path:line` citation is checked** by the `doc-citation` lint;
  quote it fenced, or name the symbol instead of the line.

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
5. For a markdown page, ask first which kind it is; every section that
   serves another kind moves to that page. Then apply the sentence
   rules paragraph by paragraph, and replace every hand-typed output
   with a derived fence.

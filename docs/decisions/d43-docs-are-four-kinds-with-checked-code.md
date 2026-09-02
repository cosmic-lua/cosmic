# D43 — docs are four kinds by reader need, in plain sentences, with code that is checked

- **date:** 2026-09
- **status:** active
- **context:** the prose docs grew as one directory of "guides", each
  written for whatever question was pressing when it was opened.
  `docs/guides/make.md` reached 498 lines and carried a verb table, the
  rationale for convergence, the project-model table, validator
  messages, an environment-variable reference and a coverage essay in
  one scroll; `checking.md` mixed a Teal type primer, the narrowing
  rules, a doctrine essay on where the checker enforces a guard, and a
  contributor recipe for swapping the checker. a reader with one need
  — a task, a fact, a lesson, a why — got all four at once, and the
  three agent-eval rounds (`docs/dev/explanation/agent-usability-study.md`)
  show agents front-loading whole pages to find the one paragraph that
  applied. contributor pages (`architecture.md`, `build.md`,
  `contributing.md`) sat beside them at the top of `docs/` with no
  marker saying who they were for. the sentences were long: measured
  over the guides and the four contributor pages on 2026-09-02, 36% of
  546 sentences ran past 25 words, the mean was 24.7, the longest 186,
  and the pages held 304 em-dash clauses. code in the docs was gated
  for compile and format (`_build/snippets_test.tl`) but not for what it
  claimed to print: the quickstart's `# ci: PASS (4 stages)`, the
  recipes' output lines, and every `-- Output:` shown in prose were
  typed by hand and checked by nobody, while `--make example` already
  ran and verified the same shapes in `*_example.tl` files that no page
  pointed at. goals.md's first promise says a documented claim that is
  not CI-verified is a bug.
- **decision:**
  - a page is exactly one of four kinds, and position declares it:
    `docs/tutorial/` (a lesson the reader follows to a working result),
    `docs/howto/` (steps for one task, for a reader who knows the
    basics), `docs/reference/` (the facts and nothing else), and
    `docs/explanation/` (why things are the way they are). those four
    directories ship in the binary, and `cosmic --docs <kind>.<topic>`
    is `docs/<kind>/<topic>.md`; `cosmic --docs <kind>` lists that
    kind. contributor docs mirror the shape under `docs/dev/<kind>/`
    and do not ship. `docs/goals.md` and `docs/decisions/` stay where
    they are: they are the governance layer, addressed by path from
    the board tooling and the `decide` skill, and explanation pages
    link to them.
  - the generated module pages (`cosmic --docs <module>`, from doc
    comments) are the library's reference. prose reference exists only
    for what has no source to derive it from: the lint rules, `--make`'s
    tables, the platform matrix, the conventions.
  - a page mixes no kinds. a how-to does not explain, a reference does
    not instruct, a tutorial does not offer choices; the sentence that
    wants to belongs on the page of the other kind, linked.
  - prose follows the Simplified Technical English writing rules,
    carried as guidance in `skills/docs-style`: one instruction per
    sentence, about 20 words in a procedure and 25 in a description,
    active voice, the imperative for steps, one topic per paragraph,
    one meaning per term, no noun stacks past three words. the house
    lowercase voice stays. no lint enforces the rules; the review gate
    does.
  - code in a page is real. every `teal`/`lua` fence compiles at full
    strictness and is a formatter fixpoint (unchanged). a fence that
    shows what code prints is DERIVED: its info string names an
    `Example_*` function (```` ```teal example=cosmic/json_example.tl#Example_decode ````),
    `bin/cosmic _docs/derive.tl` writes that function's body into the
    fence, `-- Output:` block included, and `_build/docs_test.tl` fails
    when the committed fence differs from the source. a tutorial's
    files are fences whose info string names the file
    (```` ```teal file=greet/text.tl ````) and its `bash` fences are
    commands; `_build/tutorials_test.tl` writes the files and runs the
    commands in a scratch project, in page order, and asserts every
    `# ` line under a command is a substring of that command's output.
  - `cosmic --docs guide.<topic>` is retired without an alias.
- **rejected:**
  - one flat directory with a kind label in each page's front matter.
    the label is the thing that drifts, and every other classification
    in this repo is positional (`*_test.tl`, `cmd/<name>/main.tl`,
    `_<dir>/`); a directory per kind is the same rule applied to prose.
  - keeping `guide.<topic>` as an alias for a release. two names for
    one page is the drift the structure exists to remove, D10 reserves
    the right to break, and every in-tree pointer is rewritten in the
    same change.
  - the full ASD-STE100 dictionary and a prose lint enforcing it. the
    dictionary is licensed, sized for maintenance manuals, and refuses
    the words this domain runs on (`record`, `closure`, `ratchet`,
    `narrow`). a sentence-length lint over markdown misfires on table
    rows, code-bearing sentences and lists; the rules are cheap to
    apply by hand and the fresh-context review already reads every
    page.
  - a doctest that executes every `teal` fence in place and compares
    against a following `text` fence. that is a second output-checking
    runner beside `--make example`, with the same `-- Output:` protocol
    respelled, and the examples would then live in two places. deriving
    the fence from the example reuses the runner and keeps one copy.
  - generating whole pages from code. the sentences that say why
    cannot be generated; the decisions index already set the shape —
    derive a REGION of a committed file, keep the prose around it.
  - moving `docs/goals.md` and `docs/decisions/` into `explanation/`.
    they are reached by path from the board (`G<n>` items), the
    `decide` skill, `_docs/derive.tl` and forty-two records' relative
    links; the move buys a tidier tree and costs every one of those.
- **consequences:**
  - a reader asks by need: `--docs howto` for a task, `--docs
    reference` for a fact, `--docs tutorial` to learn, `--docs
    explanation` for why. an agent's first read is one page of one
    kind.
  - a stale output claim in a page is now a gate failure, not a lie
    delivered by the tool. the cost: editing an `Example_*` body edits
    every page that derives from it, so the diff has two files, and
    `derive.tl` is a step to remember (the gate reminds).
  - tutorials build a project inside the test run, which costs a
    `--make ci` of a hello-world per tutorial per test run, and means
    a tutorial can only teach what a fenced test may do.
  - contributor docs are not in the binary; a builder with only the
    artifact never sees them, which is what `docs/dev/` says.
  - `--docs guide.*` breaks for anyone who scripted it.
  - revisit when a prose check over the STE rules becomes cheap to
    write and stays quiet on tables and code, or when an eval round
    shows agents still reading the wrong kind of page first.

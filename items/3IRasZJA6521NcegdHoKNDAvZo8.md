## Goal

G3 — an honest type layer, no escape hatches. D23 says "no other
`cosmic.*` module may throw or exit", and its own amendment already
concedes the doctrine is enforced against no census: 19 `error(` /
`os.exit(` sites in seven modules outside `cosmic.check` (D23) and
`cosmic.rand` (D22) are correct where they sit and recorded nowhere.
This slice writes the record that licenses their shapes and marks every
site with a checkable justification, the way `-- cast:` and
`-- assert:` already work.

## Evidence

Measured 2026-08-26 at main `b4ad036b`, from the repo root.

- **The census.**
  `git ls-files 'cosmic/*.tl' 'cosmic/**/*.tl' | grep -v '_test\.tl$\|_example\.tl$\|_benchmark\.tl$' | xargs grep -nE '(^|[^_[:alnum:]])error\(|os\.exit\(' | grep -v ':\s*---' | grep -v ':\s*--[^-]'`
  finds, outside `cosmic/check.tl` (14 sites, D23's module) and
  `cosmic/rand.tl` (6 sites, D22's module), exactly 19 sites in 7 files:
  `cosmic/searcher.tl:91,103,280,312,316,325` (6),
  `cosmic/hash.tl:100,105,133` (3),
  `cosmic/coverage/init.tl:129` (1), `cosmic/teal.tl:21` (1),
  `cosmic/quicksand/box/run.tl:152,165,235,242,287` (5),
  `cosmic/child/init.tl:386,402` (2), `cosmic/init.tl:41` (1). The
  word-boundary in the pattern matters: a plain `error(` also matches
  `cosmic/_teal_engine.tl`'s `process_error(...)` calls, which return a
  value and throw nothing.

- **Every site falls into one of three shapes**, read from the code:
  1. **Protocol throws** — the module implements a Lua protocol whose
     error channel IS the throw. `cosmic/searcher.tl`'s six sites are
     package-searcher loaders: `require`'s contract is that a loader
     that finds a module but cannot load it raises, and returning
     `nil, string` from a loader silently means "not found here".
     `cosmic/teal.tl:21` raises at require time when the Teal compiler
     is absent — a failed `require("cosmic.teal")` IS the reporting
     channel. `cosmic/coverage/init.tl:129` is the `coroutine.wrap`
     shim re-raising a failed `resume` with `error(results[2], 0)` —
     byte-for-byte what stock `coroutine.wrap` does; swallowing it
     would change coroutine semantics under coverage.
  2. **Process-boundary exits** — code running where no caller can
     receive a return. `cosmic/child/init.tl:386,402` and
     `cosmic/quicksand/box/run.tl:152,165,235,242,287` are post-`fork`
     child paths: a child whose `chdir`/`exec`/setup failed writes the
     error to the parent's pipe and MUST exit — returning would run
     the parent's continuation in two processes. (`run.tl:242` exits
     with the workload's code from `become_init`, and `:287` is the
     unreachable belt after `supervisor()`, which never returns.)
     `cosmic/init.tl:41` is `cosmic.main()`, whose documented job is
     turning the main function's return into the process's exit
     status; its caller is the OS — the same argument
     `cosmic/embed/init.tl`'s generated wrapper won in the 3IQfhI33
     review.
  3. **Infallible-by-type contract violations** — `cosmic/hash.tl:100`
     and `:133` throw on an algorithm smuggled past the typed `Algo`
     enum through a cast, and `:105` on a `GetCryptoHash` failure that
     is unreachable for a valid enum member; `digest`'s doc comment
     (`cosmic/hash.tl:92-94`) already calls this a deliberate
     caller-contract violation. D23's amendment says this shape "still
     needs its own record"; there is none.

- **The record number is free.** `ls docs/decisions/` ends at
  `d29-tests-run-because-defined.md`, so the new record is D30. The H1
  grammar (`# D30 — <claim>`) is parsed by `_docs/derive.tl` into
  `docs/decisions/README.md`, and `_build/docs_test.tl` fails ci when
  the committed table drifts; its failure message prints the regen
  command `bin/cosmic _docs/derive.tl`.

- **Headroom for the comments.** `wc -l cosmic/searcher.tl` → **492**,
  8 lines under the 500 cap, and its six `error(` lines run 63–80
  columns (`awk 'NR==91||NR==103||...{print length($0)}'`), so several
  need the line-above comment form; worst case all six do, landing the
  file at 498. Every other annotated file is ≤474 lines.

- **AGENTS.md's doctrine line points only at D23.** `grep -n 'three
  shapes' AGENTS.md` → line 237: "never throw from library code —
  three shapes are exempt (D23) …". The three new shapes need the
  pointer or the rule reads as forbidding what D30 licenses.

- **Precedent for grammar-then-lint sequencing.** The `-- assert:`
  convention landed in D23's amendment first and its lint came later
  as its own slice (3IRTkNx1, PR #1401, accepted). The enforcement
  lint for this slice's grammar is filed the same way (Enablement
  below), not folded in here.

## Change

Ten files: one new record, two derived/doc updates, and trailing
justification comments at 19 sites in 7 modules. **No executable line
changes anywhere** — every site keeps its exact behavior, message, and
error level; the diff outside `docs/` and `AGENTS.md` is comments only.

### `docs/decisions/d30-*.md` — new record

Written by the `decide` skill's form (H1 `# D30 — <claim, lowercase>`,
then date/status/context/decision/rejected/consequences). The decision,
stated as a rule with three sub-bullets: **a `cosmic.*` module may
throw or exit only where no caller could receive the value**, which is
exactly three shapes —

1. a Lua protocol whose error channel is the throw (a package
   searcher/loader, a `coroutine.wrap` re-raise);
2. a process boundary: a post-`fork` child that cannot return, or an
   entry helper (`cosmic.main`) whose caller is the OS;
3. an infallible-by-type function whose typed contract was violated
   through a cast, or whose binding failure is unreachable for the
   arguments it passes — `cosmic.hash`'s shape, the per-module record
   D23's amendment demanded.

Each site carries a trailing justification: `-- throws: <why>` on an
`error(` line, `-- exits: <why>` on an `os.exit(` line, or either as a
comment on the line directly above when the 90-column width won't fit
it — the same grammar contract as `-- cast:` (AGENTS.md) and
`-- assert:` (D23). `cosmic/check.tl` and `cosmic/rand.tl` carry no
comments: their exemptions are module-level, recorded in D23 and D22.

Rejected alternatives to write hardest: returning `nil, string` from a
loader (breaks `require`'s found-but-broken channel), a module
allowlist without per-site comments (D23's amendment already rejected
the seat-on-a-list shape for `-- assert:`), and folding this into a
second D23 amendment (D23 is check's record; these shapes are not
about check).

Cite paths and functions in prose; do NOT quote source lines in
citation-headed code blocks (`-- file.tl:NNN`) — the doc-citation lint
verifies those against the tree and every annotated line moves in this
same diff.

### The 19 site comments

Add the `-- throws:`/`-- exits:` comment at every census site, with
the shape's reason in that site's own words (e.g. searcher:
`-- throws: package-searcher protocol; require reports load failures by raising`;
child: `-- exits: forked child, exec failed; error already on the parent's pipe`;
hash: `-- throws: Algo contract violated through a cast; digest is infallible by type`;
init: `-- exits: entry helper; the caller is the OS`). Trailing where
the line stays ≤90 columns, line-above otherwise.
`cosmic/quicksand/box/run.tl:287`'s existing `-- unreachable` trailing
comment is subsumed into its `-- exits:` comment rather than kept
beside it.

### `AGENTS.md` — one bullet

The "never throw from library code" bullet (line 237) extends its
parenthetical: the three D23 shapes stay, and the sentence gains "and
D30's three: a protocol whose error channel is the throw, a process
boundary with no caller, and an infallible-by-type contract violation
— each site carrying a trailing `-- throws:`/`-- exits:` reason".
Keep it to the one bullet; no other AGENTS.md prose moves.

### `docs/decisions/README.md` — regenerate

`bin/cosmic _docs/derive.tl` rewrites the derived index table with
D30's row; commit the result. Never hand-edit it. If any other ratchet
complains, run exactly the regen command its failure message prints
and commit the result.

## Non-goals

- **No behavior change at any site.** Messages, error levels, exit
  codes (126/127 are the parent's contract in `child` and
  `quicksand`), and control flow are all frozen; this diff outside
  docs is comments only.
- **No lint.** Enforcement of the `-- throws:`/`-- exits:` grammar is
  the follow-up item named under Enablement, sequenced the way
  `-- assert:` (D23 amendment) preceded its lint (3IRTkNx1).
- **`cosmic/check.tl` and `cosmic/rand.tl` untouched** — their
  exemptions are D23's and D22's, module-level, already recorded.
- **No D23 or D22 edit.** D30 references them; their bodies and
  statuses do not move.
- **No conversion of `hash.tl`'s `error(` sites to `assert`** or any
  other respelling — recording, not refactoring.
- **Frozen:** the `-- cast:` and `-- assert:` grammars and their
  lints; `_docs/derive.tl` and the H1 index grammar; the census
  pattern above is the follow-up lint's spec input, not something this
  slice commits as code.

## Acceptance

Run from the repo root.

1. `bin/cosmic --make ci` ends `ci: PASS` — this carries the
   docs-index drift gate and the doc-citation lint over the new
   record.
2. `grep -c -- '-- throws:' cosmic/searcher.tl cosmic/hash.tl cosmic/coverage/init.tl cosmic/teal.tl`
   prints `6`, `3`, `1`, `1` (all print `0` today).
3. `grep -c -- '-- exits:' cosmic/child/init.tl cosmic/quicksand/box/run.tl cosmic/init.tl`
   prints `2`, `5`, `1` (all print `0` today).
4. `head -1 docs/decisions/d30-*.md` prints a line beginning `# D30 — `,
   and `grep -c 'D30' docs/decisions/README.md` prints at least `1`
   (`0` today).
5. `wc -l < cosmic/searcher.tl` prints at most `500` (it is `492`
   today and gains at most 6 line-above comments).
6. `git diff --name-only origin/main` prints exactly, in any order:

   ```text
   AGENTS.md
   cosmic/child/init.tl
   cosmic/coverage/init.tl
   cosmic/hash.tl
   cosmic/init.tl
   cosmic/quicksand/box/run.tl
   cosmic/searcher.tl
   cosmic/teal.tl
   docs/decisions/README.md
   docs/decisions/d30-<slug>.md
   ```

## Enablement

none needed to pull this: the record's form is the `decide` skill, the
regen command comes from the gate's own failure message, and every
site and its shape is enumerated above with the census command that
found it. The enforcement lint — refuse an `error(`/`os.exit(` call
line in `cosmic/**` (outside `cosmic/check.tl` and `cosmic/rand.tl`,
and outside tests/examples) with no `-- throws:`/`-- exits:`
justification, by the same token-walk `check_assert_justification`
uses — is filed as its own item, blocked on this one, so the grammar
exists before anything enforces it.

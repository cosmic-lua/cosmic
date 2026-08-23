## Goal

G3 — an honest type layer, no escape hatches. Two shipped sentences promise
that "the checker forces callers to narrow" a `T | nil`. It does not: it
refuses an unnarrowed union at an INDEX and admits it everywhere else. Make
the doctrine say what the checker enforces, and pin the enforcement boundary
with a test so the sentences cannot drift back.

## Evidence this stands on

**Re-measured 2026-08-23** against a binary built from main `e534b127`
(`bin/cosmic --make build`, then `o/bin/cosmic --check types <probe>` on three
throwaway files outside the tree). Teal admits `T | nil` into every position
except an index:

| probe file | contents | verdict |
|---|---|---|
| `p1.tl` | `local n = gi(); print(n + 1)`, `local m: integer = gi()`, `f(gi())` with `f(x: integer)`, `("abc"):sub(1, gi())` | `Type check passed: p1.tl` |
| `p2.tl` | `local t: string = gs()`, `print(gs() .. "x")` | `Type check passed: p2.tl` |
| `p3.tl` | `local s = gs(); print(s:upper())` | `error: cannot index key 'upper' in variable 's' of type string \| nil` |

(`gi(): integer | nil` and `gs(): string | nil` are one-line stubs.) Arithmetic,
concatenation, assignment to a declared non-nil local, and a non-nil parameter
position all pass the nil straight through. Only the index refuses.

This is the same finding recorded on this item on 2026-08-22 at `aaf4af95`,
re-run at `e534b127` — unchanged across two pins.

## Change

Four files. Nothing else moves.

**1. `AGENTS.md` — the false claim, and the missing half of the narrowing
note.** Measured: `grep -rn 'forces callers to narrow' --include='*.md' . |
grep -v '^./o/'` prints exactly two lines, `AGENTS.md:152` and
`docs/stdlib.md:38`, and nothing else. `wc -l < AGENTS.md` prints **454**.

Line 152 today reads

```text
- **Fallible value**: `T | nil, string` — the checker forces callers to narrow.
```

Replace it with a line that says where the force actually is:

```text
- **Fallible value**: `T | nil, string` — callers must narrow, and the checker
  only makes them at an index (`cosmic --docs guide.checking`).
```

Then, in the `**Narrowing nil unions.**` paragraph, lines 178–180 today read
`... What / still does NOT narrow: record FIELDS (copy the field to a local and
guard the / local). The other tools:`. Append one sentence to that same
paragraph, between `local).` and `The other tools:`:

```text
And what the checker never DEMANDS: an unnarrowed `T | nil` passes into a
non-nil parameter, a declared non-nil local, arithmetic and concatenation —
only an index refuses it, so an unguarded union becomes a runtime nil
downstream (pinned in `cosmic/teal_narrowing_test.tl`).
```

**2. `docs/stdlib.md` — the same false claim.** `wc -l < docs/stdlib.md` prints
**57**. Lines 37–38 today read

```text
- **fallible value**: `value | nil, string` — the primary pattern; the
  checker forces callers to narrow before use
```

Replace with

```text
- **fallible value**: `value | nil, string` — the primary pattern; callers
  must narrow before use, which the checker makes them do at an index and
  nowhere else
```

**3. `docs/guides/checking.md` — one new subsection.** `wc -l <
docs/guides/checking.md` prints **337**; its subsection headings are
`grep -n '^#\{1,3\} ' docs/guides/checking.md`, and `### Narrowing and
Casting` starts at line 64 and runs to `### Record Types` at line 198. Add a
new `### Where Narrowing Is Required` immediately before `### Record Types`,
carrying:

- the boundary in prose — an index (`s:upper()`, `t.field`, `a[i]`) is the only
  position that refuses an unnarrowed `T | nil`; assignment to a declared
  non-nil type, a non-nil parameter, arithmetic and concatenation all admit it;
- one `teal` fence showing the admitting positions (it compiles, which is the
  point);
- the index refusal shown in a `text` fence, with the checker's message
  (`cannot index key 'upper' in variable 's' of type string | nil`);
- one sentence saying what this means for a reader: a `| nil` annotation is a
  contract with the reader that the checker only half enforces, so guard at the
  boundary rather than trusting the annotation to force it downstream.

This guide SHIPS in the binary (`cosmic --docs guide.checking`), which is why
the acceptance below reads it back out of a built binary and not off disk.

**4. `cosmic/teal_narrowing_test.tl` — pin the boundary.** `wc -l <
cosmic/teal_narrowing_test.tl` prints **212** (288 lines of headroom under the
500-line cap); this addition is ~45 lines. The file's stated job is "teal_test.tl's
canary pins what must narrow; this file pins what must not", and the admission
boundary is exactly that. Add two functions at the end, each called on the line
after its `end` per AGENTS.md, following the file's existing shape (write a
snippet to `fs.join(tmpdir, "<name>.tl")`, run `teal.check_file(path)`, assert
on `result.ok`):

- `test_nil_union_is_admitted_outside_an_index` — one snippet carrying all four
  admitting positions from the probe table above, asserting `result.ok` and
  concatenating `result.errors`' messages into the failure message, modelled on
  `test_early_exit_is_guard_narrows` (declared at line 81, called at line 121 in
  the file today).
- `test_nil_union_is_refused_at_an_index` — the negative twin, modelled on
  `test_error_terminated_guard_does_not_narrow` (declared at line 196): the same
  `gs(): string | nil` stub, indexed without a guard, asserting `not result.ok`.
  Without it the positive test would pass under a tl bump that made the checker
  strict and would pin nothing.

If either test ever fails, the checker's boundary moved and the three prose
sites above are the thing to update — that coupling is the whole point of the
pin.

## Non-goals

- **No checker change, and no carried-patch entry.** Extending
  `3p/tl/tl_patch.tl` to REFUSE `T | nil` in non-index positions is the other
  candidate this item recorded, it needs a blast-radius measurement nobody has
  taken, and it is separate work. `3p/tl/tl_patch.tl` (395 lines) and
  `_make/patch.tl` (190 lines) must be byte-unchanged by this slice.
- **No upstream report filed from here.** Asking teal whether the admission is
  intended is D5 (upstream-first) work with its own item; this slice records the
  behaviour, it does not negotiate it.
- **No new fenced snippet that fails to type-check.** `_build/snippets_test.tl`
  compiles every ` ```teal ` fence in `AGENTS.md`, `README.md`, `docs/**` and
  `skills/**` at full strictness AND requires it to be a formatter fixpoint. Its
  own header states the escape: prose showing a compile error is not Teal and
  says so by tagging the fence ` ```text `. Use `text` for the refusal example;
  do not tag it `teal`, and do not add an opt-out word — there is none.
- **No rewrite of the surrounding doctrine.** D24's structured-failure rules,
  the fallible-return two-slot rule, `check.must`, and the `is`/cast guidance
  are correct and stay exactly as written. Only the "forces callers to narrow"
  claim and the one appended sentence move in `AGENTS.md`; only lines 37–38 move
  in `docs/stdlib.md`.
- **No cast sites move**, so `_build/casts_baseline.tl` must not change. If any
  ratchet gate does complain, run exactly the regen command its failure message
  prints and commit the result — never a gate weakened any other way.
- **No change to `docs/guides/make.md`**, which `_build/guides_test.tl` ratchets
  against `_make/`; this slice touches `docs/guides/checking.md` only.

## Acceptance

```
bin/cosmic --make ci
grep -rn 'forces callers to narrow' --include='*.md' . | grep -v '^./o/' | wc -l
grep -c '^### Where Narrowing Is Required$' docs/guides/checking.md
o/bin/cosmic --docs guide.checking | grep -c 'Where Narrowing Is Required'
bin/cosmic --make test cosmic/teal_narrowing_test.tl
wc -l < cosmic/teal_narrowing_test.tl
git diff --stat -- 3p/tl/tl_patch.tl _make/patch.tl _build/casts_baseline.tl
git status --short
```

- `bin/cosmic --make ci` ends `ci: PASS (5 stages)`, quoted in the PR
  description. (It converges and builds first, so `o/bin/cosmic` below is the
  binary carrying the edited guide.)
- the first command prints **0** (2 today: `AGENTS.md:152` and
  `docs/stdlib.md:38`).
- the second prints **1** (0 today).
- the third prints **1** (0 today) — the new subsection reaches the reader
  through the binary, not only through the file.
- `bin/cosmic --make test cosmic/teal_narrowing_test.tl` ends `test: PASS (1
  file)` and reports **9 test functions** (7 today).
- `wc -l < cosmic/teal_narrowing_test.tl` prints a number ≤ 500 (212 today,
  ~257 expected).
- `git diff --stat` over the three walled files prints nothing.
- `git status --short` lists exactly four modified files and no others:
  `AGENTS.md`, `docs/stdlib.md`, `docs/guides/checking.md`,
  `cosmic/teal_narrowing_test.tl`.

## Enablement

none needed — the two false-claim sites are located by a grep whose output is
quoted here with both `file:line`s, their current text and their replacement are
given verbatim, the guide's insertion point is fixed by two heading line numbers
read with the command that prints them, the test file's shape and its two model
functions are named by line, and the probe verdicts the whole change asserts were
re-run in this pass against a binary built from `e534b127` rather than carried
over from the 2026-08-22 capture.

The one wrong turn a literal session could take — writing the index refusal as a
` ```teal ` fence, so a snippet that is SUPPOSED not to compile is fed to a gate
that compiles every fence — is walled in `Non-goals` with the escape
`_build/snippets_test.tl`'s own header states, and would otherwise be discovered
as a red `--make ci` after the prose was written. The second — treating this as
the checker fix — is walled by the first two Non-goals and by the
`git diff --stat` acceptance over `3p/tl/tl_patch.tl`.

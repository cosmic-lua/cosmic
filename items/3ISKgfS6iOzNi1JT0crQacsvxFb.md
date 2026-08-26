## Goal

G3, under the tl-patch gaps container: the smallest of the four
narrowing gaps — mixed-arity `table.pack` erasing `.n` to `any` —
closed with a one-line patch entry and pinned by a narrowing test.
(The title's "one cast retired" half moved to 3ISPGV8z: a first
implementation attempt proved the cast cannot come out until the
PINNED checker carries the patch — see Evidence — and the board has
no rename verb.)

## Wrong turn, recorded

The 2026-08-26 bounce from `do`: the spec prescribed removing
`cosmic/coverage/init.tl:133`'s cast in the same slice as the patch,
and its "proven end to end" evidence was measured on a WARM tree whose
binary already embedded the patched tl. Cold, it fails:
`bin/cosmic --make build` generation 1 compiles the tree with the
running binary's embedded (unpatched) tl —
`cosmic/coverage/init.tl:131:46: error: argument 3: got <any type>,
expected number` — and CI's `build`/`repro` lanes start from the
pinned release the same way. Same failure family as PR #1405's
`filter_of` and board item 3IIm7ZyN (the standing countermeasure
capture): `--make ci`'s convergence hides what the fixpoint build
refuses. The rule this spec now encodes: every `cosmic/**` source in
a tl-patch slice must type-check under BOTH the pinned checker and
the patched one.

## Evidence

Measured 2026-08-26 at main `b4ad036b`, from the repo root.

- tl's embedded stdlib declares `table.pack` twice (`o/3p/tl/tl.lua`,
  lines 384–385 of the stdlib text; identically in `o/3p/tl/tl.tl`):

  ```
  pack: function<T>(T...): PackTable<T> --[[needs_compat]]
  pack: function(any...): {any:any} --[[needs_compat]]
  ```

  `PackTable<A> is {A}` carries `n: integer` (lines 371–376). Uniform
  arguments resolve the generic overload; MIXED returns
  (`table.pack(coroutine.resume(t))`) fall to the second overload's
  bare `{any:any}` and `.n` erases to `any`. Probed: a file with
  `local n: integer = results.n` over a mixed pack fails
  `--check types` today with `got <any type>, expected integer`, and
  passes with the patch applied — both directions observed.

- **The patch is proven through the real mechanism.** With the entry
  below in `3p/tl/tl_patch.tl`, `bin/cosmic --make fetch` re-applies
  the patch set and `grep -n 'PackTable<any>' o/3p/tl/tl.lua` shows
  line 385 patched. The probe file then type-checks.

- **The anchor is unique and its indentation is six spaces.**
  `grep -nF '      pack: function(any...): {any:any} --[[needs_compat]]' o/3p/tl/tl.lua`
  → exactly line 385; `grep -cF 'pack: function(any...): {any:any}'`
  reports 1 in each of `o/3p/tl/tl.lua` and `o/3p/tl/tl.tl`.

- **`tl.lua` alone is the right target — settled.** `_make/patch.tl`
  applies each entry to the file its `file` field names, and entries
  for both files exist (`ast-cache-envoptions-tl-tl` carries
  `file = "tl.tl"`). That twin exists because `_types/gentl.tl`
  verifies the `EnvOptions` record against the Teal source
  (`_types/gentl.tl:189`); gentl reads nothing of the Lua-stdlib text
  where `pack` is declared, and the checker the tree runs loads the
  patched `tl.lua`. `tl.tl`'s copy staying upstream is correct.

- **The 500-line cap binds — the file must shed lines first.**
  `wc -l 3p/tl/tl_patch.tl` → **499**, the cap is enforced by
  `file-length` in `_tool/lint.tl:31-44` with only `.d.tl` exempt
  (`_cli/lint.tl:335`), and the entry below is 6 lines. The header
  comment is lines 1–28; the compressed 22-line version below
  preserves every claim and frees 6 lines, landing the file at 499.

- `cosmic/teal_narrowing_test.tl` is 415 lines (85 of headroom). Its
  probes are runtime strings checked through `teal.check_file`, so the
  test file itself compiles identically under both checkers — the
  property the Wrong turn above demands.

## Change

Two files. `cosmic/coverage/init.tl`, its cast, and the casts
baseline are NOT touched — that is 3ISPGV8z, blocked on this landing
and reaching the pin.

1. **`3p/tl/tl_patch.tl`, header**: replace the header comment
   (lines 1–28) with exactly these 22 lines — same content, 6 lines
   freed for the entry:

   ```
   -- The carried patch riding 3p/tl/tl_pin.tl; _make/patch.tl is the
   -- mechanism. Each entry's `note` says what it does; a multi-line
   -- replacement also carries its reasoning at the lines it changes.
   --
   -- The ast-cache-* group (whilp/cosmic#967) lets an embedder skip tl's
   -- parse of its embedded prelude/stdlib d.tl sources — ~11 of the ~16 ms
   -- a fresh process pays in its first tl.new_env(). `ast-cache-hooks-*`
   -- exposes the node/type metatables and the typeid allocator a thawed AST
   -- needs; `ast-cache-new-env` (plus the -tl-tl twin for gentl's ground
   -- truth) accepts pre-parsed programs in EnvOptions, byte-identical when
   -- absent — generated in _types/tlast_gen.tl, thawed in cosmic/_teal_ast.tl.
   --
   -- The narrow-* group teaches the checker that a nil union narrows
   -- through the guards Lua programmers actually write — truthiness,
   -- `assert`, `x and x.field`, `== nil`, exiting branches, disjunctive
   -- guards, `x or fallback` with a non-nil fallback — each strictly
   -- better: more correct programs check, none stop. `narrow-nil-union`
   -- installs the shared helpers; the census is docs/design/nil-flow.md.
   --
   -- Carried, not forked: each anchor must match the pinned source exactly
   -- once, so a tl pin bump that moves this code fails the fetch loudly
   -- until the patch is re-audited (or dropped, once upstream lands it).
   ```

2. **`3p/tl/tl_patch.tl`, entry**: add one 6-line entry to the
   `narrow-*` group (directly above `narrow-nil-union`, today line
   377 after the header change), the reasoning carried by `note`
   since the replacement is a one-line type-declaration swap:

   ```
     ["narrow-pack-n"] = {
       file = "tl.lua",
       note = "mixed-arity table.pack fallback returns PackTable<any>: .n stays integer",
       find = [=====[      pack: function(any...): {any:any} --[[needs_compat]]]=====],
       replace = [=====[      pack: function(any...): PackTable<any> --[[needs_compat]]]=====],
     },
   ```

   Copy the six-space indentation inside the brackets byte-exactly —
   the find must match once.

3. **`cosmic/teal_narrowing_test.tl`**: one appended test,
   `test_mixed_pack_keeps_n_integer`, called after its `end`: write a
   probe file whose mixed `table.pack(coroutine.resume(t))` result
   assigns `.n` into a declared `integer` AND passes it as
   `table.unpack`'s third argument, and assert `teal.check_file`
   reports ok, quoting the errors in the failure message. Follow the
   file's existing probe pattern (`fs.write` into `TEST_TMPDIR`,
   `teal.check_file`, message with `table.concat(msgs, "; ")`).

4. **Ratchet**: none expected — no cast moves, no file joins or
   leaves coverage. If one complains anyway, run exactly the regen
   command its failure message prints and commit the result.

## Non-goals

- **`cosmic/coverage/init.tl` and `_build/casts_baseline.tl` are
  untouched.** The cast retire is 3ISPGV8z, blocked on the pin
  catching up; removing it here fails the cold build (Wrong turn
  above).
- The other three gaps (or-fallback shapes, closure carry-through,
  metatable<any>) are the research sibling's (3ISKgwfn).
- No other tl_patch entry moves; no pin bump; no `tl.tl` entry (the
  Evidence settles why).
- No behaviour change: the patch edits a TYPE declaration only; the
  compat-generated Lua for pack is untouched (`needs_compat` stays),
  so the fixpoint's byte-compare is unaffected.
- No header content is dropped — the compression rewords, it does not
  delete claims; the entry-form contract (`find` matches exactly
  once) and `_make/patch.tl` are untouched.

## Acceptance

Run from the repo root.

- `bin/cosmic --make ci` ends `ci: PASS`.
- `grep -c "narrow-pack-n" 3p/tl/tl_patch.tl` reports 1 (today 0).
- `wc -l < 3p/tl/tl_patch.tl` prints at most `500` (today 499; 22-line
  header plus 6-line entry lands it at 499).
- `grep -c "narrow_pack_n" cosmic/teal_narrowing_test.tl` reports at
  least 1 (today 0).
- `bin/cosmic --make test cosmic/teal_narrowing_test.tl` ends
  `test: PASS (1 file)` — this is the patched-checker proof, since the
  probe fails without the patch.
- `git diff --name-only origin/main` prints exactly, in any order:

  ```text
  3p/tl/tl_patch.tl
  cosmic/teal_narrowing_test.tl
  ```

## Enablement

none needed. The bounce's countermeasure is encoded in this spec's own
shape (no `cosmic/**` source changes that need the new checker), the
standing capture for the underlying convergence blind spot is
3IIm7ZyN, and the deferred half is filed and blocked: 3ISPGV8z. The
mechanics — anchor, indentation, header text, entry text, test
pattern — are all given verbatim above with the commands that
verified them.

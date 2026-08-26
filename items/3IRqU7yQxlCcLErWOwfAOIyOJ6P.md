## Goal

G6 — the defining paths, ratcheted. The cosmic half of the parent
container's one-pass fix: `cosmo.EncodeLua` now refuses the literal
reader's domain itself, so the Teal pre-walk that duplicates it can go.

## Evidence

The performance figure is the parent container's, measured 2026-08-26 at
cosmic main `14ff1d1d`: `format_compact` costs 2.58x the
`cosmo.EncodeLua` call it wraps (332 KB fixture: 14.52 ms against
5.64 ms), and 61% of that is the walk (8.89 ms). The parent carries the
harness and both tables. Everything below was measured 2026-08-26 at
cosmic main `7e8e1170`, from the repo root, and against the released
cosmos binary this slice pins.

- **The blocker is clear and released.** `3IRqQvST` merged as
  whilp/cosmopolitan PR #278, and release `2026.08.26-fe7c36c4c`
  carries it — `third_party/lua/cosmo.h` at
  `refs/tags/2026.08.26-fe7c36c4c` declares `bool literal` on
  `struct EncoderConfig`. The pin target:

  ```text
  curl -sSL -o cosmos.zip \
    https://github.com/whilp/cosmopolitan/releases/download/2026.08.26-fe7c36c4c/cosmos.zip
  sha256sum cosmos.zip
  # 1b54fceb616831aa155da03b5f26865a1d180f02908a82e56dd022fcd87c5d17
  ```

  The pin on main (`3p/cosmos/cosmos_pin.tl`) is `2026.08.26-1e1658153`,
  which is exactly PR #278's base — so this is a one-commit bump.

- **The option name is `literal`, a boolean.** `tool/lua/lcosmo.c` reads
  `lua_getfield(L, 2, "literal")` into `conf.literal` beside
  `sparsenull`, and the shipped `definitions.lua` annotates it
  (`@field literal boolean?`). Confirmed against the release binary:

  ```text
  unzip -q cosmos.zip -d cosmos
  ./cosmos/lua -e 'local c=require("cosmo")
    print(c.EncodeLua({["end"]=1},{sorted=true,literal=true,maxdepth=32}))'
  # nil     reserved word as key
  ```

- **`maxdepth` must be passed, and it must be 32.** The binding's
  default is `maxdepth = 64` (`tool/lua/lcosmo.c`, the `conf`
  initializer in `LuaEncodeSmth`). Left at the default the encoder would
  admit values nested up to 64 tables, which `literal.parse` — whose
  `MAX_DEPTH` is 32, mirrored by `cosmic/_literal_format.tl:20` — cannot
  read back: exactly the silent corruption the walk exists to prevent.

  The two sides also count depth differently. The walk calls
  `is_compact_writable(value, 1)`, so a table nested L levels deep is
  seen at `depth = L` and refused when `L > 32`; the C serializer starts
  the top value at `depth = 0` and refuses at `depth >= maxdepth`, and a
  table's keys and scalar values are serialized one level deeper than
  the table itself. Probed against the release binary over
  `maxdepth ∈ {32, 33}` and `L ∈ {30..34}`, with and without a scalar
  leaf in the innermost table:

  ```text
  M=32 L=31 leaf=true  -> OK          M=33 L=32 leaf=true  -> OK
  M=32 L=32 leaf=true  -> REFUSED     M=33 L=33 leaf=false -> OK      <-- unsafe
  M=32 L=32 leaf=false -> OK          M=33 L=33 leaf=true  -> REFUSED
  M=32 L=33 leaf=false -> REFUSED     M=33 L=34 leaf=false -> REFUSED
  ```

  `maxdepth = 33` admits an empty table nested 33 deep, which both the
  walk and `format` refuse and `literal.parse` cannot read — the
  corrupting direction. `maxdepth = 32` never admits anything either
  refuses. It is the only safe value.

- **The domains then agree on 35 of 36 cases, and the one divergence is
  in the safe direction.** The walk was re-implemented verbatim in plain
  Lua (same `MAX_DEPTH`, `RESERVED`, byte-27 and `math.mininteger`
  tests) and run against
  `cosmo.EncodeLua(v, {sorted=true, literal=true, maxdepth=32})` over a
  36-value corpus — arrays, mixed and non-string keys, reserved and
  near-reserved keys (`ending`, `en`, `endx`), NaN/±inf, `mininteger`
  and the float of the same magnitude, byte 27 in a key and in a value,
  embedded NULs, high bytes, UTF-8, empty key and value, functions,
  threads, a cycle, a shared-but-acyclic table, and the depth ladder
  above. Result: **1 divergence of 36.**

  ```text
  DIFFER deep-32-leaf   walk=true  c=false (too deep)
  ```

  A table nested exactly 32 levels deep whose innermost table has any
  content: the walk admits it, the C option refuses it. The refusal
  reasons matched the walk's verdict on every other case, including the
  three the module deliberately hands off (`reserved word as key`,
  `mininteger is written as arithmetic`, `byte 27 in string`).

- **That divergence costs a layout, never a value.** The refused value
  goes to `format(value)`, whose own guard is the same
  `render_table(out, value, 1, "")` / `depth > MAX_DEPTH` boundary
  (`cosmic/_literal_format.tl:288`, `:222-224`), so it renders. The
  module's own doc comment already states this as the contract: *"A
  value inside the grammar that the encoder cannot spell gets the pin
  layout, which can spell anything the grammar admits: the compact
  layout is a request for smaller output, never a narrower domain."*
  No test pins the depth boundary today — the compact cases in
  `cosmic/_literal_format_test.tl` are nan/inf/-inf/array/mixed
  keys/boolean key/function/cycle (`test_compact_refuses_what_pin_refuses`,
  `:106-126`) and reserved key/mininteger/nested reserved key
  (`test_compact_falls_back_to_pin_when_it_cannot_spell`, `:179-198`).
  This slice adds one.

- **The code to delete, with every caller enumerated.**
  `git grep -n '<name>' -- '*.tl'` over the whole tree, per name:

  ```text
  is_compact_writable  cosmic/_literal_format.tl:339 (def), :354, :397
  is_compact_scalar    cosmic/_literal_format.tl:81  (def), :357
  is_compact_string    cosmic/_literal_format.tl:61  (def), :83, :350
  RESERVED             cosmic/_literal_format.tl:307 (def), :347
  is_finite            cosmic/_literal_format.tl:46  (def), :89, :113
  ```

  No caller of any of the four lives outside this file (the `RESERVED`
  hits in `_make/validate.tl` and `_types/tlast.tl` are unrelated locals
  of the same name). Every remaining use of the first four is inside the
  walk or inside each other, so all four go together. `is_finite`
  stays: `:113` is the non-compact renderer's use, and only `:89`
  (inside `is_compact_scalar`) goes.

- **Headroom.** `wc -l < cosmic/_literal_format.tl` is `440`;
  `wc -l < cosmic/_literal_format_test.tl` is `239`. The deletions below
  remove roughly 107 lines from the module, so both stay far under the
  500-line cap.

- **The regression gate exists.** `_perf/bench/literal_bench.tl:138`
  defines the `literal_format_floor_compact` scenario, landed in #1400
  for this hypothesis. It runs a 100-row `FLOOR` fixture, far smaller
  than the 332 KB payload above, so the win shows as a ratio rather
  than a large absolute number on that row.

## Change

Three files.

1. **`3p/cosmos/cosmos_pin.tl`** — `version` to
   `"2026.08.26-fe7c36c4c"` and the `["*"]` `sha` to
   `"1b54fceb616831aa155da03b5f26865a1d180f02908a82e56dd022fcd87c5d17"`.
   Nothing else in the file moves. Then `bin/cosmic --make fetch`.

2. **`cosmic/_literal_format.tl`** — delete the walk, ask the encoder.

   Rewrite `format_compact`'s body (currently `:395-411`) to:

   ```text
   local function format_compact(value: any): string | nil, string
     if value is {any: any} then
       local encoded = cosmo.EncodeLua(value,
         {sorted = true, literal = true, maxdepth = MAX_DEPTH})
       if not encoded then
         return format(value)
       end
       return "return " .. encoded .. "\n"
     end
     return nil, "a " .. type(value) .. " is not a literal table"
   end
   ```

   Take only the FIRST return. The refusal reason is deliberately
   discarded: the handoff to `format(value)` is what produces the
   message, and `test_compact_refuses_what_pin_refuses` pins that the
   two layouts give the same one. Binding the second return would be an
   unused local, which `--check types` fails.

   Then delete, by line range at `7e8e1170` (top-down, so the earlier
   ranges stay valid):

   - `:316-363` — `is_compact_writable` and its doc comment.
   - `:301-315` — `RESERVED` and its doc comment.
   - `:65-93` — `is_compact_scalar` and its doc comment.
   - `:50-64` — `is_compact_string` and its doc comment.

   Keep `is_finite` (`:39-48`) and everything else.

   Rewrite `format_compact`'s doc comment (`:364-394`). Two paragraphs
   in it describe the deleted walk and must go or change: *"The check is
   not optional. `cosmo.EncodeLua` never refuses…"* — it does now, and
   that is the point — and *"Whatever the walk turns down goes to the
   renderer…"*, which must name the encoder's refusal instead. Keep the
   paragraph on `sorted` and the paragraph explaining why the handoff
   covers both reasons; state that `maxdepth` is pinned to `MAX_DEPTH`
   for the reason in Evidence. Follow the `docs-style` skill: describe
   what the code is for, not what it used to be — no reference to the
   walk having existed.

3. **`cosmic/_literal_format_test.tl`** — pin the depth boundary, which
   nothing pins today. Add one test beside
   `test_compact_falls_back_to_pin_when_it_cannot_spell`, calling itself
   on the line after its `end` per AGENTS.md:

   - a value nested exactly 32 tables deep with a scalar in the
     innermost table round-trips through `written(v, {layout =
     "compact"})` and `literal.parse`, and equals `written(v)` — it now
     takes the pin-layout handoff;
   - a value nested 31 deep with a scalar leaf does NOT fall back
     (`compact ~= written(v)`, and the compact output is one line);
   - a value nested 33 deep is refused, with `refused(v, {layout =
     "compact"}) == refused(v)`.

   Build the nesting with a loop, not 32 literal braces.

   Also fix the file's header comment (`:2-9`), which opens *"The
   compact layout hands the value to a C encoder that never refuses"* —
   no longer true, and it is the sentence that explains why the rest of
   the file exists. Say instead that the encoder is asked to refuse the
   reader's domain itself, and that these tests state the property that
   makes the layout usable: it admits exactly the values the default
   layout admits, hands the rest to that layout, and what it writes is
   what `parse` reads back.

`_types` regenerates from the new `definitions.lua` as a consequence of
the build — no regen step, per AGENTS.md.

## Non-goals

- **No residual Teal check.** The one measured divergence
  (`deep-32-leaf`) is absorbed by the module's existing, documented
  handoff to the pin layout, not by a leftover guard. Do not reintroduce
  a depth test, a key test, or any other predicate to close it.
- **The refusal SET does not narrow.** Every value the walk refused
  today must still take the pin-layout handoff and produce the pin
  layout's message, and `cosmic/_literal_format_test.tl` is where that
  is pinned. If the encoder ADMITS anything the walk refused — the
  corrupting direction — stop and fix the sibling; that is measured as
  zero cases above and any recurrence is a real defect. Over-refusal is
  bounded to the `deep-32-leaf` shape and is the accepted cost stated in
  Evidence; if a NEW over-refusal appears, stop and report it rather
  than widening the handoff to cover it.
- **`maxdepth` is not a knob.** Pass `MAX_DEPTH`, the module's own
  constant. Do not add an option, a parameter, or a second constant.
- **No change to `format`, `format_file`, `render_table`,
  `render_inline`, `scalar`, `quoted`, or the pin layout.** Their bytes
  are a `cosmic --check fmt` fixpoint and committed files depend on
  them.
- **No change to the `cosmo.*` C boundary from this side.** This slice
  consumes the contract; it does not move it. No edit to
  `whilp/cosmopolitan`, and no other pin moves.
- **No unrelated micro-optimization of the module.** The parent ruled
  out option (b); do not land any part of it here.
- **`cosmic/literal.tl` is not touched.** Its own `MAX_DEPTH` is the
  reader's, mirrored here deliberately (`:16-20`); leave the
  duplication alone.

## Acceptance

Run from the repo root. Baseline BEFORE any edit, on a clean tree.

- `bin/cosmic --make fetch` succeeds against the new pin, then
  `bin/cosmic --make build` ends `build: PASS`.
- `bin/cosmic --make ci` ends `ci: PASS`.
- `o/bin/cosmic --make test cosmic/_literal_format_test.tl` passes,
  including the new depth test.
- `grep -c 'is_compact_writable\|is_compact_scalar\|is_compact_string' cosmic/_literal_format.tl`
  prints `0` (today `8`).
- `grep -c 'RESERVED' cosmic/_literal_format.tl` prints `0` (today `2`).
- `grep -c 'is_finite' cosmic/_literal_format.tl` prints `2` (today `3`)
  — the definition and the renderer's one use.
- `grep -c 'literal = true' cosmic/_literal_format.tl` prints `1`
  (today `0`), and `grep -c 'maxdepth = MAX_DEPTH' cosmic/_literal_format.tl`
  prints `1` (today `0`).
- `wc -l < cosmic/_literal_format.tl` prints a number ≤ `360`
  (today `440`).
- `grep -c '2026.08.26-fe7c36c4c' 3p/cosmos/cosmos_pin.tl` prints `1`.
- `git diff --name-only origin/main` prints exactly these three, and
  nothing else:

  ```text
  3p/cosmos/cosmos_pin.tl
  cosmic/_literal_format.tl
  cosmic/_literal_format_test.tl
  ```

- Performance, per the `optimize` skill: with the tree clean and the
  PREVIOUS pin in place,
  `bin/cosmic --make run _perf/run.tl --out o/perf/baseline.json`;
  after the change,
  `o/bin/cosmic --make run _perf/run.tl --out o/perf/current.json`;
  then
  `o/bin/cosmic --make run _perf/gate.tl compare o/perf/baseline.json o/perf/current.json o/perf/selfb.json`
  ends `perf-compare: PASS`, and the `literal_format_floor_compact` row
  shows an improvement rather than a regression. Quote both rows'
  µs/op in the PR. Never commit `o/perf/*.json`.

## Enablement

none needed. The blocker (`3IRqQvST`) has landed and shipped in
`2026.08.26-fe7c36c4c`, the option's contract is annotated in the fork's
`definitions.lua` and flows into the generated Teal types by the build,
and the domain equivalence is measured above rather than assumed. The
conventions that bind are AGENTS.md's (Teal, `--check types` warnings as
errors, the test self-call line, ≤500-line files) and the `docs-style`
skill's for the rewritten doc comment.

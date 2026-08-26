## Goal

G6 — the defining paths, ratcheted. The parent container measured
cosmic's compact literal encode paying 2.58x the C encode it wraps, 61%
of it a Teal pre-walk that re-decides what the C encoder is about to
decide anyway. This is the C half: give `cosmo.EncodeLua` an option
that makes it refuse the literal reader's domain itself, so the caller
needs no pre-walk. The cosmic half is the sibling slice, blocked on
this one.

## Evidence

Measured 2026-08-26 against whilp/cosmopolitan master `1e165815`, and
against cosmic main `5ba85817` for the domain.

- **File sizes.** `wc -l`: `third_party/lua/luaencodeluadata.c` `444`,
  `tool/lua/lcosmo.c` `369`, `third_party/lua/cosmo.h` `46`,
  `tool/net/definitions.lua` `8274`.
- **The option table already exists.** `LuaEncodeSmth`
  (`tool/lua/lcosmo.c:104-156`) reads `maxdepth`, `sorted`, `nan`,
  `sparsenull`, `pretty` and `indent` off argument 2, so a new boolean
  key is the shape the function already has.
- **The config struct already carries per-encoder flags.**
  `struct EncoderConfig` (`third_party/lua/cosmo.h:9-16`) has six
  fields; `nannull` and `sparsenull` are commented `json:` — precedent
  for a flag scoped to one of the two encoders.
- **The refusal path already exists.** `struct Serializer`
  (`third_party/lua/cosmo.h:18-28`) carries `const char *reason`;
  `LuaEncodeLuaData` (`:424-444`) pushes it on a `-1` return
  (`:435-439`), so the binding already answers `nil, reason`. There
  are eleven existing `return -1` sites in the file.
- **Depth is already an option.** `LuaEncodeSmth` defaults
  `maxdepth` to 64 and clamps to `SHRT_MAX`
  (`tool/lua/lcosmo.c:107,114-119`); `Serialize`
  (`third_party/lua/luaencodeluadata.c:378-406`) checks
  `depth < z->conf.maxdepth`. So the caller sets its own depth and
  this slice only has to make the over-depth case FAIL instead of
  stringify.
- **`definitions.lua` is where the annotation goes.**
  `---@class cosmo.EncoderOptions` is at `:93-101`, one `@field` per
  option, with the per-encoder ones opening "``EncodeJson`` only:".
  The `EncodeLua` prose block listing the options is `:2469-2530`,
  ending at `function cosmo.EncodeLua(value, options) end` (`:2530`).

## The domain to refuse, and what the encoder does today

cosmic's literal reader's exclusions, as `cosmic/_literal_format.tl`
spells them at cosmic `5ba85817`, each probed against the current
encoder (probe: `cosmo.EncodeLua(v, {sorted = true})`, then `load` on
`"return " .. s`):

| excluded value | encoder today | site to change |
|---|---|---|
| a key that is not a string | `{[1.5]="x"}` — loads | `SerializeObject` `:268-304` / `SerializeSorted` `:306-348`, at the `Serialize(..., -2, ...)` key call |
| a key that is a Lua keyword | `{end=1}` — **does not load** | `IsLuaIdentifier` `:41-50` |
| byte 27 in a key or string | `{a="x\ey"}` — loads | `SerializeString` `:188-220` |
| NaN, `math.huge`, `-math.huge` | `{a=0/0}`, `{a=math.huge}` — load, but are arithmetic and a global read | `SerializeNumber` `:114-131` |
| `math.mininteger` | `{a=-9223372036854775807 - 1}` — loads, but is arithmetic | `SerializeNumber` `:118-119`, the branch already special-casing it |
| a function, thread, userdata, light userdata | `{a="func@0x4344820"}` — loads, as a LIE: a pointer string in place of the value | `Serialize` `:392-402`, the `SerializeOpaque` cases |
| nesting past the caller's depth | `"greatdepth@0x..."` — same lie | `Serialize` `:403-405` |

The keyword-key row is a defect in its own right — the encoder emits
source that does not parse — and is board item `3IRryfNl`, to be fixed
separately and unconditionally. **This slice does not fix it**; under
the new option it refuses that key like any other exclusion, which is
correct whether or not the bare-key bug is fixed first.

## Change

Add a boolean encoder option, `literal`, that makes `LuaEncodeLuaData`
refuse every row of the table above with a `reason`, instead of
emitting text. Four files, plus tests:

1. **`third_party/lua/cosmo.h`** — one `bool literal;` on
   `struct EncoderConfig`, commented the way `nannull` and
   `sparsenull` are (`EncodeLua only: ...`).
2. **`third_party/lua/luaencodeluadata.c`** — at each site named in the
   table's third column, when `z->conf.literal` is set, assign
   `z->reason` and `return -1` rather than appending. Reuse the
   existing `OnError` idiom; add no new traversal — the encoder already
   visits every key and value exactly once, which is the whole point of
   the option. Each `reason` names the exclusion in words a caller can
   log (`"keyword key"`, `"byte 27 in string"`, `"non-finite number"`,
   `"mininteger"`, `"non-string key"`, `"unsupported value"`,
   `"too deep"`); no format is promised beyond "a non-empty string".
3. **`tool/lua/lcosmo.c`** — read `literal` off the option table in
   `LuaEncodeSmth`, beside `sorted` (`:121-124` is the model), defaulting
   to false in the `conf` initializer at `:107-112`.
4. **`tool/net/definitions.lua`** — add the `@field` to
   `---@class cosmo.EncoderOptions` at `:93-101`, worded
   "``EncodeLua`` only: ..." like the two `EncodeJson` ones, and add the
   option to the `EncodeLua` prose list at `:2469-2530`. Same commit,
   per this repo's AGENTS.md.
5. **`tool/lua/test_data_formats.lua`** — the encoder's existing test
   home. One case per row of the table: with `literal = true` the value
   returns `nil` and a non-empty string; with the option absent the SAME
   value encodes to the SAME bytes it does today.

**Additive only.** With `literal` absent or false, `EncodeLua` must
produce byte-identical output to today and refuse exactly what it
refuses today. That is what the second half of each test case pins.

## Non-goals

- **Do not fix the keyword-key bug here.** `IsLuaIdentifier` emitting
  `{end=1}` unconditionally is board item `3IRryfNl` and a separate
  change; this slice only makes that key refuse under the new option.
  Do not change what the encoder emits with the option off.
- **No change to `EncodeJson`**, to `LuaEncodeJsonData`, or to
  `nannull`/`sparsenull`.
- **No change to any existing return shape, error value or constant.**
  cosmic's generated types and wrappers depend on them; this is an
  addition. In particular `LuaEncodeLuaData` keeps returning `0`/`-1`
  and the binding keeps returning `string` or `nil, reason`.
- **No new option beyond the one.** Do not add a "strict" mode, a
  refusal-list parameter, or a way to select individual exclusions.
- **No reformatting or restructuring** beyond the diff: keep the fork
  mergeable with upstream jart/cosmopolitan.
- **Nothing on the cosmic side.** No pin bump, no wrapper change, no
  `_literal_format.tl` edit — that is the sibling slice, and it cannot
  start until this is released.
- **Do not make the refusal unconditional.** Every exclusion above is
  currently legal output for some caller; the option is what keeps this
  additive.

## Acceptance

Run from the whilp/cosmopolitan repo root:

- `make -j$(nproc) o//tool/lua/test` passes — the binding tests and the
  `definitions.lua` annotation-coverage ratchet.
- `make -j$(nproc) o//tool/lua/lua` builds.
- `grep -c 'literal' third_party/lua/cosmo.h` prints `1` or more
  (today `0`).
- `grep -c 'literal' tool/lua/lcosmo.c` prints `1` or more (today `0`).
- `grep -c 'literal' tool/net/definitions.lua` prints `2` or more
  (today `0`) — the `@field` and the prose entry.
- `wc -l third_party/lua/luaencodeluadata.c` prints a number ≤ `560`
  (today `444`).
- With the built `o//tool/lua/lua`, each of these prints `nil` plus a
  non-empty reason, and the same call without the option prints the
  bytes named in the Evidence table:

  ```text
  o//tool/lua/lua -e 'print(EncodeLua({["end"]=1}, {literal=true}))'
  o//tool/lua/lua -e 'print(EncodeLua({[1.5]="x"}, {literal=true}))'
  o//tool/lua/lua -e 'print(EncodeLua({a="x\27y"}, {literal=true}))'
  o//tool/lua/lua -e 'print(EncodeLua({a=0/0}, {literal=true}))'
  o//tool/lua/lua -e 'print(EncodeLua({a=math.huge}, {literal=true}))'
  o//tool/lua/lua -e 'print(EncodeLua({a=math.mininteger}, {literal=true}))'
  o//tool/lua/lua -e 'print(EncodeLua({a=print}, {literal=true}))'
  o//tool/lua/lua -e 'print(EncodeLua({a={b={c=1}}}, {literal=true, maxdepth=2}))'
  ```

  (`EncodeLua` is global in this binary's REPL surface; adjust to
  `require("cosmo").EncodeLua` if the test harness needs it.)

## Enablement

none needed. Every mechanism is in the tree: the option table is read
at `tool/lua/lcosmo.c:104-156`, the config struct is
`third_party/lua/cosmo.h:9-16`, the `reason`/`-1` refusal path is
already what `LuaEncodeLuaData:435-439` surfaces, and
`tool/lua/test_data_formats.lua` is the encoder's test home. The
conventions that bind are this repo's AGENTS.md — surgical diffs, the
`definitions.lua` update in the same commit, `o//tool/lua/test` before
any PR.

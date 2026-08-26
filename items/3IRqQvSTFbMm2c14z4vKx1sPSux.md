## Goal

G6 — the defining paths, ratcheted. The parent container measured the
compact literal encode paying 2.58x the C encode it wraps, 61% of it a
Teal pre-walk that duplicates work the C encoder already does. This
slice is the C half: give `cosmo.EncodeLua` an option that makes it
refuse the literal reader's domain itself, so the caller never has to
pre-walk.

## Evidence

Measured 2026-08-26 against whilp/cosmopolitan master. The parent
item's timing tables are the demand side; these are the supply side.

- `LuaEncodeSmth` — `tool/lua/lcosmo.c:105-156` — already reads a
  boolean option table (`sorted`, `sparsenull`, `pretty`, and the
  string-valued `nan`/`indent`), so a new boolean key is the shape the
  function already has.
- `struct EncoderConfig` — `third_party/lua/cosmo.h:9-16` — six
  fields, three of them already `bool` flags scoped to one encoder
  (`nannull` and `sparsenull` are commented `json:`), so a
  lua-encoder-scoped flag has precedent in the same struct.
- `struct Serializer` — `third_party/lua/cosmo.h:18-28` — carries
  `const char *reason`.
- `LuaEncodeLuaData` — `third_party/lua/luaencodeluadata.c:424-444`,
  `wc -l` on that file is `444`. Its refusal path is already built:
  eleven `return -1` sites (`:95,103,111,129,219,248,265,303,347,356,
  375`), and `:437` pushes `z.reason` so the binding returns
  `nil, reason`.
- `tool/net/definitions.lua` is the annotation source of truth and the
  ratchet test reads it; `make -j$(nproc) o//tool/lua/test` is the
  correctness gate this repo names in AGENTS.md.

## The domain to refuse

The literal reader's exclusions, as `cosmic/_literal_format.tl` spells
them today (read at cosmic main `14ff1d1d`):

- a key that is not a string (`:344`)
- a key that is one of the 22 Lua keywords (`RESERVED`, `:307-314`)
- byte 27 (`\27`) anywhere in a key or in a string value (`:61-63`)
- a non-finite number: NaN, `math.huge`, `-math.huge` (`:46-48`)
- `math.mininteger` specifically, which the encoder spells as
  `-9223372036854775807 - 1` — arithmetic, which a literal may not
  contain (`:88-90`)
- a value that is not a string, boolean, number or table (`:92`)
- nesting deeper than 32 tables (`MAX_DEPTH`, `:340`)

## Change

Add an option — name it in the slice, `literal` is the obvious one —
that makes `LuaEncodeLuaData` refuse each of the above with a `reason`
naming which exclusion and, where it can, the key path. Three files:

1. `third_party/lua/cosmo.h` — one `bool` on `struct EncoderConfig`,
   commented the way `nannull`/`sparsenull` are.
2. `third_party/lua/luaencodeluadata.c` — the checks, on the existing
   `return -1` + `z.reason` path. No new traversal: the encoder
   already visits every key and value.
3. `tool/lua/lcosmo.c` — read the key in `LuaEncodeSmth`, beside
   `sorted`.
4. `tool/net/definitions.lua` — the annotation, in the same commit
   (AGENTS.md makes this non-optional).
5. `tool/lua/test/` — tests for each refusal and for a value inside
   the domain encoding unchanged.

**Additive only.** With the option absent or false, `EncodeLua` must
produce byte-identical output to today and refuse exactly what it
refuses today.

## Non-goals

- No change to `EncodeJson` or its config fields.
- No change to any existing return shape, error string or constant —
  cosmic's generated types and wrappers depend on them, and this is an
  addition, not a contract change.
- No reformatting or restructuring beyond the diff: keep the fork
  mergeable with upstream jart/cosmopolitan.
- Nothing on the cosmic side: consuming this is the sibling slice.

## Acceptance

To be written at refinement, from this repo's AGENTS.md: at minimum
`make -j$(nproc) o//tool/lua/test` passing, the annotation-coverage
ratchet green over the new option, and a test showing the same value
encoding byte-identically with the option off.

## Enablement

Not yet checked — this item is in `plan`, one rung above the bar.

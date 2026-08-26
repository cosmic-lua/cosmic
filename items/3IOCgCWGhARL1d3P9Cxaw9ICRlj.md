## What this container is

`test/tool/net/**` in whilp/cosmopolitan holds 40 checks that run in no
workflow. The parent container (`3INxo51I`) settled that the
redbean-contract half is retired and the rest is salvaged into
`tool/lua/`, where the gate actually runs. This container is the salvage
half, and it carries the children that do it.

It stopped being a slice because its own `Change` had two independent
steps with the word "and" between them: an inventory nobody has, and a
port whose file list IS that inventory's output. `decompose.md` names
that shape — *"if a slice cannot be sized without research, the research
IS the slice: an enablement item whose deliverable is recorded evidence
and the follow-up slices, not code"* — and the parent already anticipated
it (*"The inventory is research the salvage cannot be sized without, so
it is that child's first deliverable"*). So the inventory is now a child
in its own right, and the port slices it names are filed as its
siblings, each sized from a list that exists.

## Goal

G5 — adversarial verification. Coverage that exists only in a lane
nothing runs is not coverage. When this container ends, everything
`test/tool/net/**` covers that `tool/lua/test_*.lua` does not is running
inside `o//tool/lua/test`, which both `pr.yml` and `release.yml` already
invoke — and the retirement sibling (`3IOCgtWA`, blocked on this) can
delete the directory without losing a check.

## Evidence

Measured 2026-08-26 against whilp/cosmopolitan `fe7c36c4` (master; the
release cosmic pins as `2026.08.26-fe7c36c4c`), from the repo root.

**The two sets, and the gate's shape.**

```text
ls test/tool/net/*.lua | wc -l                                  # 38
ls tool/lua/test_*.lua | wc -l                                  # 31
grep -c '^\to/$(MODE)/tool/lua/test_.*\.ok' tool/lua/BUILD.mk    # 29
```

`tool/lua/BUILD.mk:222-251` is `TOOL_LUA_TESTS`, a hand-written list of
29 `o/$(MODE)/tool/lua/test_<name>.ok` stamps, and `:259-260` is the
`.PHONY o/$(MODE)/tool/lua/test` target that depends on it. Each stamp
has its own three-line rule (`o/$(MODE)/tool/lua/test_cosmo.ok:
o/$(MODE)/tool/lua/lua.dbg tool/lua/test_cosmo.lua`, run, `touch`).
Wiring a ported file is: one such rule plus one line in
`TOOL_LUA_TESTS`. That is the mechanism to follow; there is no second
one.

**The port is not a copy — 34 of the 38 files call redbean globals.**

```text
for f in test/tool/net/*.lua; do grep -q require "$f" || echo "$f"; done | wc -l   # 34
```

redbean exposes `DecodeJson`, `EncodeJson`, `Slurp`, `UnescapeParam` and
friends as bare globals; this fork namespaces every one of them under
`cosmo.*` and registers the module from `tool/lua/lcosmo.c`, which
redbean does not link. So each ported file needs a prelude that binds
the names it uses — the corpus BODY still moves verbatim, which is the
point of aliasing rather than rewriting call sites.

The json corpus makes the size of that prelude concrete:

```text
grep -ohE '\b(DecodeJson|EncodeJson|EncodeLua|unix\.[a-zA-Z_]+)\b' \
  test/tool/net/json*.lua test/tool/net/ljson_test.lua | sort | uniq -c | sort -rn
#  439 DecodeJson
#   31 EncodeJson
#   15 EncodeLua
#    9 unix.pledge
```

Four names across 9 files and 7,542 lines. A six-line prelude per file
covers all of it and leaves 485 corpus call sites untouched.

**The json corpus is the clear `none` row and has no counterpart.**

```text
wc -l test/tool/net/json*.lua test/tool/net/ljson_test.lua   # 7542 total, 9 files
wc -l tool/lua/test_data_formats.lua                          # 288
```

`test_data_formats.lua` is a CONTRACT test — array metatables,
`NaN`/`Infinity` rejection, empty-collection round-tripping — not a
corpus one. It adversarially exercises nothing.

**The redbean-contract failures are identifiable by grep, not by
running the lane.** The parent recorded why each of the twelve fails;
the tells are in the source. `grep -ln 'errno()' test/tool/net/*.lua`
names six files, four of which (`futex`, `mapshared`, `spinlock`,
`sysconf`) the parent identified as failing on exactly that call. This
matters because it means the inventory child does not have to build and
run a lane that is in no workflow to do its job.

## The children

1. **The inventory** (`3IS8...`, filed with this decomposition) — one
   row per `test/tool/net/*.lua`: what binding surface it exercises,
   which `tool/lua/test_*.lua` already covers that ground or `none`, and
   whether it is a redbean-contract file the parent already retires.
   Its second deliverable is the port slices themselves, filed as
   children of this container, one per coherent group of `none` rows,
   each sized from the row list.
2. **The port slices** — filed by (1), each blocked on it. Not written
   ahead of the inventory, because their `Change` sections are exactly
   its output.

## Outcome test for this container

From the whilp/cosmopolitan repo root, after every child has ended:

- `make -j$(nproc) o//tool/lua/test` passes.
- `ls tool/lua/test_*.lua | wc -l` is strictly greater than `31`, by the
  number of rows the inventory marked `none` and the port slices moved.
- `grep -c '^\to/$(MODE)/tool/lua/test_.*\.ok' tool/lua/BUILD.mk` rose by
  the same number, and every new stamp appears in `TOOL_LUA_TESTS`.
- Every `none` row in the inventory names the `tool/lua/test_*.lua` that
  now carries it.
- `git diff --stat master -- test/tool/net .github` is empty across all
  of them — deletion is `3IOCgtWA`'s, not this container's.

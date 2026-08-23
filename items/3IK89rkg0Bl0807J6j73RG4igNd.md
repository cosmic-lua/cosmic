## Goal

G6 — the defining paths, ratcheted. `cosmic.literal` is the codec behind every
`*_pin.tl`, every committed ratchet floor, and any project that wants a config
file which cannot do anything. Its writer is pure Teal and ~4-6x slower than the
C serializer this fork already ships, on identical output semantics.

## Evidence

Measured 2026-08-23 on `main` at `b76d657f`, with `o/bin/cosmic` built from that
tree (`bin/cosmic --make fetch && bin/cosmic --make build`). All numbers below
are `os.clock` medians over the iteration counts named, run through
`o/bin/cosmic <script>` — SCOUTING numbers, not the `_perf` gate. The payload is
a map of N entries, each a 4-field record of string/integer/boolean:

| payload | `literal.format` | `cosmo.EncodeLua{sorted=true}` | a bare key/value walk |
|---|---|---|---|
| 10 entries (940 B formatted) | 60.3 µs | 9.0 µs | 5.9 µs |
| 4000 entries (413,583 B formatted) | 28.10 ms | 5.07 ms | 2.42 ms |

The third column is the shape of the strict pre-walk this slice adds — one
`pairs` visit per key and value — so encoder-plus-guard lands near 14.9 µs and
7.49 ms, about **4x and 3.8x** faster than `format` today. Output is also
smaller: 285,582 bytes against 413,583 for the large payload.

**The C encoder is present and its output already round-trips.**
`cosmo.EncodeLua` is `tool/lua/lcosmo.c:230` in the pinned cosmos, declared in
the generated `o/_types/types_gen/cosmo.d.tl:441`. Its `sorted` output is a
single line of bare-identifier keys, which `literal.parse` accepts:

```
literal.format:   return {\n  ["alpha"] = {["count"] = 1, …},\n  ["beta"] = "x",\n}\n
EncodeLua sorted: {alpha={count=1, flag=true, name="a b"}, beta="x", gamma=42}
```

`literal.parse("return " .. EncodeLua(v, {sorted = true}) .. "\n")` returned a
table for both payloads above.

**But it never refuses, and two of its answers are silently wrong.** Probed
value by value against `literal.format`'s refusal for the same input:

| input | `EncodeLua` emits | does `literal.parse` read it back? |
|---|---|---|
| `{x = 0/0}` | `{x=0/0}` | no — refused by the parser |
| `{x = math.huge}` | `{x=math.huge}` | no — refused |
| `{x = -math.huge}` | `{x=-math.huge}` | no — refused |
| `{1, 2, 3}` | `{1, 2, 3}` | no — refused |
| `{[1] = "a", b = "c"}` | `{[1]="a", b="c"}` | no — refused |
| `{[true] = "a"}` | `{[true]="a"}` | no — refused |
| `{x = print}` | `{x="func@0x43414c0"}` | **yes — as a plain string** |
| a self-referential table | `{self="cyclic@0x7f30…"}` | **yes — as a plain string** |

`literal.format` refuses all eight by name and key path. The last two are the
dangerous pair: they produce output that parses, so nothing downstream notices
that a function or a cycle became a hex-address string. A guard is therefore not
optional — it is what makes the C encoder usable under literal's founding
promise (`cosmic/literal.tl:1-17`): values only, refuse everything else, with
the line or key path that was refused.

**Capacity and callers, measured:**

```
$ wc -l cosmic/literal.tl cosmic/_literal_format.tl cosmic/literal_test.tl
  402 cosmic/literal.tl              (98 lines under the 500-line cap)
  273 cosmic/_literal_format.tl      (227 under)
  421 cosmic/literal_test.tl         (79 under)
```

The only production caller of `literal.format` outside the module and its own
tests is `_tool/floor.tl:78`, which writes committed ratchet floors and must
keep today's layout byte for byte. Neither `cosmic/literal.tl` nor
`cosmic/_literal_format.tl` requires `cosmo` today; adding the require in
`_literal_format.tl` is the expected place for it (AGENTS.md: library internals
are where `cosmo.*` belongs).

## Change

**1. `cosmic/_literal_format.tl` — a strict pre-walk and a compact writer.**
Add two internal functions and export the second:

- a walk that visits every key and value of the value once, capped by the
  module's own `MAX_DEPTH` (`cosmic/_literal_format.tl:18`, already 32 and
  already deliberately duplicated from `cosmic/literal.tl:48` so the writer
  refuses exactly the depth the reader refuses), and returns `nil, msg` on the first
  offender, where `msg` is built by the module's existing `refusal(path, what)`
  so the message wording and key paths match what `format` already produces for
  the same input. It refuses: a non-string key, a number that is NaN or
  infinite, any value that is not string/number/boolean/table, and a table
  reached twice on the current path (a cycle).
- `format_compact(value: any): string | nil, string` — runs that walk, and on
  success returns `"return " .. cosmo.EncodeLua(value, {sorted = true}) .. "\n"`.

**2. `cosmic/literal.tl` — an options argument on `format`.** Widen the export
to `format(value: any, opts?: FormatOptions): string | nil, string`, with
`record FormatOptions layout: string end` taking `"pin"` (the default, dispatching
to today's `lformat.format`, unchanged) or `"compact"` (dispatching to
`format_compact`). Any other value is refused with a message naming the two
accepted ones. Declare the record and the widened signature on `LiteralModule`,
and document on `format` that `"pin"` is a fmt fixpoint suitable for a committed
file while `"compact"` is the bulk path: same domain, same refusals, smaller and
faster output, no fixpoint promise.

**3. Tests.** `cosmic/literal_test.tl` has 79 lines of headroom, which is tight;
put the new tests in a new `cosmic/_literal_format_test.tl` instead, following
the house pattern (each `test_*` called on the line after its `end`). Cover: the
default and explicit `"pin"` layouts are byte-identical to today's output for a
nested payload; `parse(format(v, {layout = "compact"}))` deep-equals `v`; each
of the eight rows in the refusal table above is refused under `"compact"` with
the same key path `"pin"` refuses it with; and an unknown `layout` value is
refused.

## Non-goals

- **Do not change `format`'s default output by one byte.** `_tool/floor.tl:78`
  writes committed ratchet floors through it and every `*_pin.tl` in the tree is
  read back by `literal.parse`; the fmt-fixpoint property is the reason the
  layout is what it is. The compact layout is opt-in and nothing in the tree
  opts in as part of this slice.
- **Do not modify `whilp/cosmopolitan`.** Variant (b) of the original hypothesis
  — a `strict` option on `EncodeLua` in C — touches a frozen binding contract
  and needs its own `definitions.lua` change and type regen, as its own item.
  This slice adds no C-side change and no cosmos pin bump.
- **Do not touch `parse`, `parse_file`, `format_file`, or
  `cosmic/_literal_lex.tl`.** The reader half is out of scope; the decode-side
  hypothesis (`cosmo.DecodeLua`) is a separate capture.
- **Do not convert any existing caller to the compact layout.** Adding the
  option and switching a caller are two changes; this is the first.
- **Do not skip the sort.** `{sorted = true}` is what makes the output
  deterministic, which every committed-data use depends on, and it is already
  inside the measured numbers above.
- **Do not weaken a refusal to make the fast path win.** If the pre-walk cannot
  refuse something `format` refuses, the answer is to keep `format` for that
  input, never to let the compact path through.

## Acceptance

```
bin/cosmic --make ci
bin/cosmic --make test cosmic/_literal_format_test.tl cosmic/literal_test.tl
bin/cosmic --make example cosmic/literal_example.tl
wc -l cosmic/literal.tl cosmic/_literal_format.tl cosmic/_literal_format_test.tl
git diff --stat -- cosmic/_literal_lex.tl _tool/floor.tl 3p/cosmos
```

- `bin/cosmic --make ci` ends `ci: PASS`. If the coverage ratchet fails, run
  exactly the regen command its failure message prints and commit the result.
- the narrow test run passes, including a test asserting the default layout is
  byte-identical to the `"pin"` layout and a test asserting
  `literal.parse(literal.format(v, {layout = "compact"}))` deep-equals `v`.
- `bin/cosmic --make example cosmic/literal_example.tl` passes — the example
  file exists today and exercises the public surface.
- `wc -l` shows every touched file at or under 500 lines. `cosmic/literal.tl` is
  402 today and `cosmic/_literal_format.tl` is 273.
- `git diff --stat` over `cosmic/_literal_lex.tl`, `_tool/floor.tl` and
  `3p/cosmos` prints nothing.

## Enablement

none needed. The C entry point is named with its `file:line` in both the fork
and the generated declarations, its output layout and round-trip behaviour are
shown side by side with `format`'s, every refusal the guard must reproduce is
measured one input at a time against what `format` says today, the two files to
touch are quoted with their measured headroom, and the single production caller
that constrains the default is cited by `file:line`.

The one decision this refinement settled, so the implementer does not re-open
it: the fast path is an OPTION on `format`, not a new public function. `parse`
and `format` are the module's pair, and adding an `encode` beside a `parse` that
already decodes would leave the surface with two writers and an asymmetric name.
An optional `opts` argument is backward-compatible for every existing caller and
keeps the public surface at the same two verbs.

What the reviewer should press on, stated plainly: **no caller in this tree is
latency-bound on `literal.format` today.** The payloads it writes — pins, board
items, ratchet floors — are kilobytes, where the win is 45 µs. The case for the
slice is the public codec and the guard, not a measured end-to-end gain in this
repo, and the `_perf` harness has no literal scenario to show one. A reviewer
who judges that insufficient should say so against the parent outcome rather
than against the diff; the honest alternative is to reject this and file the
`_perf` scenario first.

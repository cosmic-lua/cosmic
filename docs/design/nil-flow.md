# unguarded nil flow

A `T | nil` return says the value can be nil. The checker enforces that
claim in exactly one position — an index — and admits it everywhere
else, so an unguarded union becomes a runtime nil downstream. This
document measures how far that gap actually reaches: **359 sites across
125 files**, found by running a strict prototype checker over every
tracked source, and classified below by the mechanism that would close
each one.

The headline is not the total. It is the split. **100 of the 359 (28%)
are sites where the author DID write a guard and the checker does not
credit it** — an early exit by `break` instead of `return`, an `or`
fallback, a compound condition, an `and`-guarded argument. Those are
not debt in the tree; they are missing narrowing rules, and closing
them is one patch group rather than 100 edits. 254 are real: 209 with
no guard anywhere, 45 reading a union out of a record field or an
inline call. The last 5 carry a guard in a shape this classification
could not name, and are listed individually.

Measured against `e7ac1580` on 2026-08-25, over 579 tracked `.tl`
files. `testdata/` is excluded throughout — those trees have their own
roots, so a checker run from this root reports module-not-found for
them rather than anything about nil.

## Method

The census is produced by a THROWAWAY strict checker built inside `o/`
and deleted before the gate runs. Nothing in this document depends on
a committed checker change, and re-deriving it means re-applying the
edit below.

Two hinges in the pinned `tl` (0.24.8) admit a nil union, and the
prototype closes both:

1. `subtype_relations["union"]["*"]` is `forall_are_subtype_of`, and
   `subtype_relations["nil"]["*"]` is `compare_true` — nil is a
   subtype of everything, so `integer | nil` satisfies an `integer`
   sink. The prototype rejects a nil-carrying union against any sink
   that does not itself admit nil, leaving bare `nil` a subtype of
   everything so that `local x: string = nil` and every `x == nil`
   comparison stay legal. Both `["union"]["*"]` and
   `["union"]["nominal"]` need the rule.
2. `unite()` sets `types_seen["nil"] = true` before it starts, so
   uniting a union always drops nil — which is what the binary-operator
   path does to both operands before looking up `binop_types`. The
   prototype reports an operand that carries nil, for the arithmetic,
   bitwise, concatenation and relational operators, before that unite.

Rebuild and run:

```text
bin/cosmic --make fetch && bin/cosmic --make build   # a LAX binary first
# apply the two edits above to o/3p/tl/tl.lua
bin/cosmic --make build                              # compiles with the lax
                                                     # binary, embeds strict tl
git ls-files '*.tl' | xargs o/bin/cosmic --check types
```

The lax-first order matters: once `o/bin/cosmic` is strict it cannot
compile this tree, so a strict binary must be built by a lax one. That
is the census result stated as a build step.

Proof of life for the prototype is the test that pins today's
boundary. `cosmic/teal_narrowing_test.tl:222`,
`test_nil_union_is_admitted_outside_an_index`, asserts that five sinks
in one program raise NO error. Under the prototype it fails, reporting
all four admitting positions, and every other test in that file still
passes:

```text
TEST_TMPDIR=$T o/bin/cosmic cosmic/teal_narrowing_test.tl
cosmic/teal_narrowing_test.tl:245: arithmetic, concatenation, a declared
non-nil local and a non-nil parameter must all admit an unnarrowed T | nil:
in local declaration: m: unguarded nil: integer | nil reaches a integer sink;
in local declaration: t: unguarded nil: string | nil reaches a string sink;
unguarded nil: integer | nil is an operand of '+'; argument 1: unguarded nil:
integer | nil reaches a integer sink; argument 2: unguarded nil: integer | nil
reaches a integer sink; unguarded nil: string | nil is an operand of '..'
```

Of the 359 sites, 355 carry the prototype's own `unguarded nil:`
message. The other 4 are the same cause reported by tl's existing
diagnostics — 3 `wrong index type` (a `string | nil` used as a map key)
and 1 `cannot use operator 'or'` — and they are counted because the
cause is identical, not the wording.

The class of each site is read from the source at that `file:line`: the
expression the column points at, and a backward scan for a guard on
that variable. The counts below come from that scan; the shapes it
names were each confirmed against a hand-written probe, quoted in the
class, so a mis-scan can shift a site between classes but cannot invent
a class that does not exist.

## Sinks

Where the nil arrives, before any judgment about why:

| sink position | sites |
| --- | --- |
| argument to a non-nil parameter | 176 |
| operand of `..` | 75 |
| return value against a non-nil return type | 44 |
| assignment to a declared non-nil target | 31 |
| record field in a table constructor | 10 |
| operand of an arithmetic/bitwise/relational operator | 15 |
| map key at an index | 3 |
| declared non-nil local | 2 |
| other | 3 |

`string | nil` is 229 of the unions and `integer | nil` 65; the rest are
records — `child.Result | nil` 28, `Response | nil` 11.

## Classes

| class | library | test/example | all | files |
| --- | --- | --- | --- | --- |
| unguarded latent nil | 109 | 100 | 209 | 79 |
| guard not credited: `or` fallback | 19 | 36 | 55 | 29 |
| record field or inline call result | 26 | 19 | 45 | 27 |
| guard not credited: non-`return` exit | 12 | 13 | 25 | 17 |
| guard not credited: compound condition | 6 | 6 | 12 | 11 |
| guard not credited: `and`-operand argument | 4 | 4 | 8 | 7 |
| guard present, other shape | 4 | 1 | 5 | 5 |
| **total** | **180** | **179** | **359** | **125** |

The library/test split is almost exactly even, and it matters: a test
site's mechanism is `check.must`, which already exists and needs no
checker change, while a library site needs a guard or a narrower
signature.

### Guard not credited: the exit is not a `return`

25 sites, 17 files. Top: `_docs/publish.tl` 4, `cosmic/fs/tree.tl` 2,
`cosmic/stream_test.tl` 2, `cosmic/surface_test.tl` 2.

The carried `narrow-truthiness` patch narrows after `if not x then
return end`. It does not narrow after `if not x then break end`, nor
after `goto`, `error()` or `os.exit()` — and `break` is how every
directory walk in this tree is written:

```text
-- cosmic/fs/tree.tl:24
local entry = h:read()
if not entry then break end
if entry ~= "." and entry ~= ".." then
  local s = cosmo_path.join(src, entry)   -- flagged: argument 2
```

Confirmed against a probe: with the guard's body changed from `break`
to `return`, the same use narrows and is not flagged; `goto continue`,
`error("nope")` and `os.exit(1)` all behave like `break`.

**Mechanism.** A narrowing rule that treats any branch that cannot fall
through as terminating, not just `return`. This is a checker change, in
the same patch group as `narrow-truthiness`, and it is the highest-
leverage single edit in this census: it also removes the reason
`cosmic/fs/tree.tl` looks like the tree's worst file.

### Guard not credited: `or` fallback

55 sites, 29 files. Top: `_tool/testrun_test.tl` 8,
`cosmic/codec_test.tl` 6, `_make/graph_test.tl` 3.

`x or default` — the single most common way a Lua programmer disposes
of a nil — does not produce a non-nil type:

```text
-- _docs/derive.tl:87
local text = fs.read(path) or ""
local n, title = string.match(text, "^#%s*D(%d+)...") -- flagged: argument 1
```

`text` is `string | nil` on the second line, after `or ""`. A probe
pins the same shape three ways: `take(gs() or "")`, `local b: string =
gs() or "fallback"` and `(gs() or "") .. "x"` are all flagged.

**Mechanism.** A rule for `a or b`: when `b` cannot be nil, the result
cannot be nil. A sub-case needs its own answer — `out or qerr` at
`_cli/main_handlers.tl:276`, where BOTH operands are unions and the
non-nil-ness is a runtime invariant the types do not carry. That one is
a signature problem, not a narrowing problem, and belongs to the class
below.

### Guard not credited: compound condition

12 sites, 11 files. Top: `_make/stage.tl` 2.

A guard joined by `or`/`and` narrows nothing, even when every arm of it
excludes nil:

```text
-- _cli/driver.tl:63
local home = env.get("HOME")
if home == nil or home == "" then
  return
end
local found = fs.glob(home, ".ape-*") -- flagged: argument 1
```

`if home == nil then return end` alone narrows; adding `or home == ""`
loses it. Probed both ways, including `if not b or b == "" then return
end`.

**Mechanism.** Distribute the narrowing fact across a disjunctive
guard: in the fall-through branch, every arm of an `or` guard is false,
so a `== nil` arm strips nil there. Same patch group.

### Guard not credited: `and`-operand argument

8 sites, 7 files.

The `narrow-and-operand` patch narrows `x and x.field` and `x and #x`,
but not `x and f(x)`:

```text
-- _build/casts.tl:66
local text = fs.read(path)
local n = text and #lint.cast_lines(text, path) or 0 -- flagged: argument 1
```

`#text` on the same line would narrow; `text` as an argument does not.

**Mechanism.** Extend `narrow-and-operand` from index and length
positions to the whole right operand. Same patch group.

### Record field or inline call result

45 sites, 27 files. Top: `cosmic/fetch/verbs_test.tl` 10,
`_cli/main_handlers.tl` 3, `_perf/peers/peers.tl` 3.

The union is never bound to a local, so there is nothing a guard could
narrow. Two shapes, and they close differently.

A record field, which AGENTS.md already documents as un-narrowable —
here guarded by a SIBLING field, which no field rule would fix either:

```text
-- _cli/main_handlers.tl:110
if result.ok then
  exit_code, err_msg = write_output(result.code, output, write_if_changed)
```

Or a call result consumed inline, which in a test is `check.must`'s job:

```text
-- cosmic/fetch/verbs_test.tl:78
local res = fetch.head(base .. "/x", {allow_private = true})
```

**Mechanism.** Two, split by file kind. In tests and examples, wrap the
call in `check.must` — 19 of the 45. In library code, copy the field to
a local and guard the local, or narrow the producing signature — 26.
Neither needs a checker change.

### Unguarded latent nil

209 sites, 79 files — the largest class, and evenly split between
library (109) and test (100). Top: `cosmic/time_parse_test.tl` 12,
`cosmic/fs/tree.tl` 10, `cosmic/embed_test.tl` 9,
`_eval/checks/json-cli.tl` 8, `cosmic/fs/find.tl` 8.

No guard exists anywhere on the value. These are the census's real
finds, and the worst of them are in the published API, where a fallible
binding's failure is passed straight through a signature that promises
it cannot happen:

```text
-- cosmic/time.tl:32
--- @return integer Seconds since epoch
--- @return integer Nanoseconds
local function now(): integer, integer
  local secs, nanos = unix.clock_gettime(unix.CLOCK_REALTIME)
  return secs, nanos -- flagged twice: in return value
end
```

`unix.clock_gettime` returns `integer | nil` in both slots. `now()`
declares `integer, integer`. A clock failure is therefore a nil handed
to a caller that the type says cannot receive one — and `cosmic/time.tl`
does the same at `:44` and multiplies one of them at `:53`.

The plainer shape is a `%d` format argument:

```text
-- _build/size.tl:160
return string.format(
  "size: lines %d (%+d), files %d (%+d), binary %d (%+d), ...",
  clines, clines - plines,
  cfiles, cfiles - pfiles,
  cbin, cbin - pbin,          -- flagged: cbin is integer | nil
```

**Mechanism.** Split by which of the two things is wrong, which is the
distinction the parent outcome needs and no command can draw:

- **Latent nil** — the value really can be nil and the code has no
  answer for it. Fix: a guard at the site, or `check.must` if it is a
  test. `_build/size.tl` and `cosmic/fs/tree.tl` are here.
- **Signature over-declares nil** — the producer cannot fail in the way
  its type admits, or the consumer should not have accepted a union.
  Fix: narrow the signature, not the call site, so every downstream
  caller stops paying. `cosmic/time.tl`'s `now()` is the reverse case
  and the more serious one: the signature under-declares, promising
  `integer` over a binding that returns `integer | nil`, so the fix is
  a decision about what `now()` does when the clock fails — not a
  guard, and not a wider return type chosen by reflex.

The 109 library sites need reading one at a time to make that split;
the 100 test sites do not — `check.must` closes them mechanically.

### Guard present, other shape

5 sites, 5 files: `cosmic/rand.tl:34`, `cosmic/re.tl:288`,
`cosmic/child/io.tl:200`, `cosmic/quicksand/box/run.tl:241`,
`_tool/testrun_test.tl:129`. A guard exists on the variable but the
backward scan could not match it to one of the shapes above. Small
enough to read individually; listed so the total reconciles.

## The doctrine dividend

G3's win condition counts the doctrine this gap makes necessary. The
narrowing block is `AGENTS.md:172-211` (40 of the 92 lines that
`awk '/^### Error Handling Patterns/,/^## Build System/' AGENTS.md`
returns), and a strict mode retires the half of it that exists only to
warn about what the checker does not demand:

- `AGENTS.md:180-184` — "what the checker never DEMANDS: an unnarrowed
  `T | nil` passes into a non-nil parameter, a declared non-nil local,
  arithmetic and concatenation — only an index refuses it". Deleted
  outright by a strict mode; it is a description of the gap.
- `AGENTS.md:179-180` — "What still does NOT narrow: record FIELDS".
  Survives; no class above closes it.
- `AGENTS.md:185-193` — the `check.must` paragraph. Survives, and gets
  MORE load-bearing: 179 of the 359 sites are in tests and examples.

In `docs/guides/checking.md`, the whole of `### Where Narrowing Is
Required` (`198-240`, 43 lines) is an explanation of the gap, built
around a snippet whose stated point is that "that snippet compiles at
full strictness". Under a strict mode the snippet does not compile and
the section becomes wrong rather than merely long. Its replacement is
one sentence: a guard is required wherever a union reaches a non-union
sink.

That is 48 lines of prose retired and one section rewritten — the
measurable half of what G3 asks for, and the reason the checker change
is worth more than 359 site fixes would be.

## Upstream or carried patch

**Both, in that order, and the census says why.** Four of the seven
classes — non-`return` exits, compound conditions, `or` fallback,
`and`-operand arguments — are not cosmic-specific policy. They are
narrowing rules any Teal program would want, they match what a Lua
programmer already believes the code says, and each of them makes the
checker accept MORE correct programs rather than fewer. That is the
shape of a change upstream takes: a strictly-better inference, with no
new error for any program that compiles today.

The strict mode itself is the opposite shape. It rejects programs that
compile today — 259 of them in this tree alone, after the four
narrowing rules land — so it is a mode, a flag, or a fork's policy, and
proposing it to teal-language/tl in the same breath as the narrowing
rules would sink both.

So: propose the four narrowing rules upstream as separate changes, each
with the probe that pins it. Carry the strict mode as a sixth group in
`3p/tl/tl_patch.tl` — the file already carries 11 anchored edits across
five narrowing behaviours, and `_make/patch.tl` re-anchors them against
the pinned `tl` on every fetch, so the mechanism exists and its cost is
known. Land the narrowing rules FIRST, whichever way they arrive: they
remove 100 sites from the census, and the strict mode's real cost is
whatever is left after them.

## What this is not

Not a plan. Every class above names a mechanism, but which of them is
worth a slice, and in what order, is the parent outcome's decision.

Not a list of bugs. A flagged site is a site where the TYPES do not
prove the value is non-nil; most of them are correct programs whose
proof lives in a comment or an invariant. `cosmic/time.tl`'s `now()` is
the exception that shows the difference: there the types do not merely
fail to prove it — they assert something the binding does not support.

Not stable. The totals are a snapshot of `e7ac1580`. Re-derive them
with the Method above before quoting them; a slice that lands any of
these classes moves every number in this document.

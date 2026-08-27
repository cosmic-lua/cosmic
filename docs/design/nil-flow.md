# unguarded nil flow

Teal demands a guard on a `T | nil` in exactly one position: an index.
Every other position takes the union without complaint — a non-nil
parameter, a declared non-nil variable, an arithmetic or concatenation
operand, a return slot. **358 sites in 125 files** of this tree put a
possible nil somewhere a nil cannot go, and the checker says nothing
about any of them.

That number is what G3 — an honest type layer, no escape hatches — has
been missing. It is the cost of adopting a strict nil-flow mode, and it
is also the size of the doctrine that exists only because the mode does
not: 92 lines of AGENTS.md and a 43-line section of
`docs/guides/checking.md` whose entire job is to warn a reader that the
annotation is a contract the checker half-enforces.

Measured against `e7ac1580` on 2026-08-25, over the 527 tracked `.tl`
files outside `**/testdata/**`. The site list this document is built
from is committed beside it as `nil-flow-sites.tsv`; where the two
disagree, the file is right.

## Method

The census comes from a throwaway strict checker, built inside `o/` and
deleted before this change was gated. It is not committed and no edit
to `3p/tl/tl_patch.tl` rides with it.

**The two hinges.** In pinned `tl` 0.24.8 (`3p/tl/tl_pin.tl`), two
places let a nil-carrying union reach a sink that cannot hold nil.

1. `TypeChecker.subtype_relations` declares `["nil"]["*"] =
   compare_true` — nil is a subtype of everything. A union is compared
   member by member by `TypeChecker:forall_are_subtype_of`, so the nil
   member always passes. The prototype replaces that function: a `nil`
   member is accepted only when the target itself admits nil (it is
   `any`, `nil`, a union carrying nil, or a type the checker cannot
   resolve), and is otherwise reported as `STRICTNIL`. Bare `nil` stays
   a subtype of everything, so `local x: string = nil` and every
   `x == nil` comparison still compile.

2. `unite()` sets `types_seen["nil"] = true` before it starts, so
   uniting a union always drops nil — and the binary-operator path
   unites both operands before consulting `binop_types`. The prototype
   reports an operand that carries nil *before* that unite, for the
   arithmetic, bitwise, concatenation and relational operators. `and`,
   `or`, `==` and `~=` are excluded: they are how a nil is disposed of,
   not a place it leaks to.

Both edits are applied to `o/3p/tl/tl.lua` — the checker that runs and
the file the binary embeds. `o/3p/tl/tl.tl` beside it is the Teal
source carried for `_types/gentl.tl`; editing that one alone changes no
behaviour.

**The build order is itself a result.** A strict `o/bin/cosmic` cannot
compile this tree, so the strict binary has to be built by a lax one:
build once from the pin, keep that binary aside, restore it before each
strict rebuild, and let it compile the tree while the patched `tl.lua`
is linked into the artifact.

**Proof of life.** `cosmic/teal_narrowing_test.tl` pins today's
boundary: `test_nil_union_is_admitted_outside_an_index` asserts that the
checker does *not* complain about five sinks in one program. Run the
file directly under the prototype (`--make test` re-execs into the
strict binary and dies at the build instead) and that test fails,
naming all four admitting positions at once (the assertion prints them
`; `-joined on one line; wrapped here):

```text
in local declaration: m: STRICTNIL: value may be nil;
in local declaration: t: STRICTNIL: value may be nil;
STRICTNIL: operand of '+' may be nil;
argument 1: STRICTNIL: value may be nil;
argument 2: STRICTNIL: value may be nil;
STRICTNIL: operand of '..' may be nil
```

Neutralising that one call in a scratch copy of the file — never the
tracked one — leaves every other test in it passing.

**Two sink shapes decide whether the total means anything.**

- **A parameter typed `any` is not flagged.** `errno.format(err: any,
  prefix?: string): string` (`cosmic/errno.tl:127`) is the repo's
  error-wrapping idiom, reached 203 times across `cosmic/ _cli/ _make/
  _tool/ _build/ _docs/` (`grep -rn --include='*.tl' -E
  '\b(errstr|errno\.format)\(' … | wc -l`). Flagging `any` would bury
  the census under one idiom. Confirmed with a probe: `anysink(gi())`
  where `gi(): integer | nil` reports nothing.
- **`string.format` is split by its verb.** tl declares it
  `function(string, any...): string` and *also* registers it as a
  special function whose `%d`/`%s` argument check runs independently of
  the vararg's `any`. The prototype therefore flags a `T | nil` at a
  `%d` and not at a `%s` — verified on a probe with both in one call —
  which is why `_build/size.tl`'s `%d` arguments appear below.

**The scan.** With the strict binary in place:

```text
git ls-files '*.tl' | grep -v '/testdata/' | xargs o/bin/cosmic --check types
```

reports 358 errors and zero warnings. `_eval/testdata/**` and
`_make/testdata/**` are excluded because those fixture projects have
their own roots: checked from here their imports do not resolve, and
their types are unknown rather than nil-carrying. Outside them, **every
error the strict binary reports is a nil-flow site** — there is no
other diagnostic to filter out, which is what makes the total
re-derivable from that one command.

**A row is a diagnostic.** `nil-flow-sites.tsv` carries one row per
error the scan reports — path, line, class — sorted by path then line,
so `wc -l` is the total. A line that reaches two sinks appears twice
(`cosmic/fs/walk.tl:82` sets two record fields from one union), and a
row's class is the *innermost* sink named by the diagnostic, because
that is the shape that decides the fix.

**What the prototype does not flag**, stated so the total is read
correctly: unary operators (`#x`, `-x`), `and`/`or`/`==`/`~=` operands,
and anything inside `**/testdata/**`. Each of those would only raise the
number.

## Classes

Nine sink shapes, disjoint. Reproduce the table with:

```text
cut -f3 docs/design/nil-flow-sites.tsv | sort | uniq -c | sort -rn
```

| class | sites | the sink |
| --- | --- | --- |
| `argument` | 175 | a parameter whose type cannot hold nil |
| `operand` | 90 | an arithmetic, bitwise, concatenation or relational operand |
| `return` | 44 | a return slot declared non-nil |
| `assignment` | 31 | assignment to an already-declared non-nil target |
| `table-field` | 11 | a record field in a table constructor |
| `index-key` | 3 | a map key |
| `table-item` | 2 | an item in an array literal |
| `declaration` | 1 | the initialiser of a declared non-nil local |
| `or-expected` | 1 | the expected type of an `or` expression |

The split by kind of file is even: **179 sites in `*_test.tl`,
`*_example.tl` and `*_benchmark.tl`, 179 everywhere else**
(`awk -F'\t' '{print ($1 ~ /_test\.tl$|_example\.tl$|_benchmark\.tl$/)}'`).
That matters for sizing: the test half has a one-line fix that already
exists — `check.must` — while the other half needs a guard or a
signature change, one site at a time.

### argument (175)

Top: `cosmic/embed_test.tl` 10, `cosmic/embed_advanced_test.tl` 9,
`cosmic/tty_pty_test.tl` 8, `cosmic/fs/tree.tl` 8,
`_eval/checks/json-cli.tl` 8, `_docs/publish.tl` 7.

The plain shape is a union read once and then spent as an argument
several times over:

```text
-- cosmic/fs/tree.tl:28
      local s = cosmo_path.join(src, entry)
      local d = cosmo_path.join(dst, entry)
```

`entry` is `h:read()` two lines up, guarded by `if not entry then break
end` — a guard the checker does not credit, because `break` is not
`return`. Then `s` and `d` are themselves `string | nil`, because
`cosmo.path.join` is declared to return one, and the file's remaining
eight sites are those two locals being spent.

**Closes with**: a guard the author usually already wrote (see
*Mechanisms* below), or `check.must` in the test half.

### operand (90)

Top: `cosmic/time_parse_test.tl` 9, `_tool/testrun_test.tl` 8,
`cosmic/codec_test.tl` 6, `cosmic/time.tl` 5,
`cosmic/fs/path_test.tl` 5, `cosmic/fs/tree.tl` 4.

Concatenation into an assertion message is the single most common
instance, and it is written with the nil already disposed of:

```text
-- _tool/testrun_test.tl:21
  assert(out == "hello from script\n", "expected script output, got '" .. (out or "nil") .. "'")
```

`(out or "nil")` cannot be nil at runtime. tl types it `string | nil`
anyway: in the `or` path, when the right operand is a subtype of the
left union, the result takes the left type whole. That is a checker
behaviour, not an author mistake — see *Mechanisms*.

The arithmetic instances are the ones with a real nil behind them:

```text
-- cosmic/time.tl:53
  return secs * 1000 + math.floor(nanos / 1000000)
```

**Closes with**: teaching `or` to drop nil (69 of the 358, below), and
a guard for the rest.

### return (44)

Top: `cosmic/fetch/verbs_test.tl` 11, `cosmic/fs/find.tl` 4,
`cosmic/fs/path.tl` 3, `cosmic/fs/dir.tl` 3, `cosmic/time.tl` 2.

The worst of the whole census is here, and it is in the published API:

```text
-- cosmic/time.tl:35
  return secs, nanos
```

`now()` is declared `function(): integer, integer` and its body is
`local secs, nanos = unix.clock_gettime(unix.CLOCK_REALTIME)`. The
binding is honest — `o/_types/types_gen/cosmo/unix.d.tl:1938` declares
`clock_gettime: function(clock?: integer): integer | nil, integer,
string, Errno`, so slot 1 admits nil and slot 2 does not — and the
wrapper under-declares over it. A clock failure hands a caller a nil
the type says it cannot receive. One site, one slot: `secs`.

The test-side instances are the honest-nil shape written for brevity:

```text
-- cosmic/fetch/verbs_test.tl:78
      return fetch.get(base .. "/x", {allow_private = true})
```

inside a `function(base: string): (fetch.Response, fetch.Error)` whose
declared first slot cannot hold the nil `fetch.get` can return.

**Closes with**: widening the declared return to admit the nil, or
guarding at the call that produces it — never a cast.

### assignment (31)

Top: `cosmic/fd_test.tl` 4, `cosmic/zip.tl` 2, `cosmic/json.tl` 2,
`cosmic/fs/path.tl` 2.

```text
-- cosmic/zip.tl:257
    handle, err = zip.from(data, raw_opts)
```

`handle` was declared non-nil at an earlier branch; the re-assignment
puts the union back into it.

**Closes with**: declaring the target `T | nil` and guarding after, or
restructuring so each branch returns.

### table-field (11)

Top: `cosmic/fs/walk.tl` 2, `_perf/peers/measure.tl` 2.

```text
-- cosmic/fs/walk.tl:82
        local e: Entry = {path = full_path, name = entry, stat = wst, depth = depth}
```

Two fields on one line take a union each, which is why this line
contributes two rows.

**Closes with**: a guard before the constructor, or a record field that
admits nil.

### index-key (3)

```text
-- cosmic/fs/dir_test.tl:218
      entries[entry] = true
```

Worth naming precisely, because it is the one class the *current*
checker very nearly catches. An index into a record or an array refuses
a `T | nil` today; a MAP KEY does not, because the key is compared with
the same subtype relation that lets nil pass. All three instances are
the directory-walk shape with a `break` guard.

**Closes with**: hinge 1 alone — no separate rule needed.

### the tail (4)

```text
-- cosmic/log.tl:122
  local parts: {string} = {ts, tag[level], message}
```

```text
-- cosmic/quicksand/proxy/serve.tl:151
  local bind_ip: integer = opts.bind_ip or cosmo.ParseIp("127.0.0.1")
```

```text
-- cosmic/sys.tl:56
  return normalize_host_os(cosmo.GetHostOs() or "unknown")
```

The last one is the only site the prototype reports without a
`STRICTNIL` marker: it fails earlier, at tl's own message `cannot use
operator 'or' for types HostOs | nil and string "unknown"`. tl infers
the type of an `or` by asking whether both operands fit the expected
type; once the union stops fitting `string`, the expression has no type
at all. It is counted, and it is the same `or` behaviour as everywhere
else in this document.

## Where the unions come from

Each flagged union carries the declaration that produced it. **96
distinct declarations** account for the 354 marked sites; 64 of those
sites come from generated `cosmo.*` declarations and the rest from
cosmic's own module interface records.

| producer | sites |
| --- | --- |
| `cosmic/fs/init.tl:122` `read` | 39 |
| `_eval/checks/support.tl:221` (a `child.Result \| nil` return) | 28 |
| `cosmic/proc/init.tl:322` `fork` | 27 |
| `o/_types/types_gen/cosmo/path.d.tl:40` `join` | 26 |
| `cosmic/env.tl:179` `get` | 15 |
| `o/_types/types_gen/cosmo/unix.d.tl:1938` `clock_gettime` | 10 |
| `cosmic/fs/types.tl:129` `Dir:read` | 10 |
| `cosmic/net/socket.tl:95` `recv` | 9 |
| `cosmic/time.tl:397` `format_iso8601` | 8 |
| `cosmic/fs/init.tl:164` `temp_dir` | 8 |

This is what separates a **latent nil** from a declaration that should
never have been a union — the split the follow-ups turn on.

**Latent.** The overwhelming majority. `fs.read`, `proc.fork`,
`env.get`, `fetch.get`, `Dir:read`, `socket:recv`, `json.encode`,
`unix.clock_gettime`: every one performs I/O, a syscall or a parse that
really can fail, or is an iterator whose exhaustion *is* the nil. Their
declarations are correct and the sites are the bug.

**Over-wide.** One producer stands out at 26 sites:
`cosmo.path.join(str?: string, ...: string): string | nil`. Its own doc
comment says nil is returned only "if exclusively `nil` arguments are
passed". No call site in this tree does that — every one passes at
least one non-nil path — so the nil is unreachable and the union is a
declaration Teal cannot make precise. It is the single largest
mechanical win available, and it is a `definitions.lua` question in
whilp/cosmopolitan, not a cosmic one.

**Optional record fields**, 30 sites across `cosmic/format/init.tl:22`,
`cosmic/_teal_engine.tl:50`, `_tool/example.tl`, `_tool/benchmark.tl`,
`_make/types.tl:133`, `_build/size.tl:44` and `_perf/peers/peers.tl:28`.
The union is honest (the field may be absent) and the author knows it is
present in that branch. AGENTS.md already names this as the case that
does not narrow — "record FIELDS (copy the field to a local and guard
the local)" — so these sites are the existing doctrine going unapplied
rather than a new problem.

## Mechanisms

Two of the nine classes close on a checker rule; the rest close one
site at a time.

**Teach `or` to drop nil: 69 sites, 19% of the census.** When the left
operand of `or` is a union carrying nil and the right operand is not
nil, the result cannot be nil — but tl types it as the left union
whole, because the right operand is a subtype of it. Measured by
re-running the same scan with one further prototype edit (drop the nil
member from the left operand's union at the top of the `or` branch,
before the type of the expression is inferred): **289 errors instead of
358**, and the 289 are a strict subset of the 358 — the rule closes
sites and creates none.

```text
comm -23 <(sort A.tsv) <(sort B.tsv) | wc -l      →  69
comm -13 <(sort A.tsv) <(sort B.tsv) | wc -l      →   0
```

By class those 69 are: 29 `operand`, 23 `argument`, 8 `return`, 5
`assignment`, 2 `table-field`, 1 `table-item`, 1 `or-expected`. The
shape they share is the one every Lua programmer writes:

```text
-- _build/size.tl:162
    cbin, cbin - pbin,
```

where `local cbin = cur.binary_bytes or 0` eight lines up has already
disposed of the nil. This is a sixth narrowing edit for
`3p/tl/tl_patch.tl`, in the same family as the five it carries, and it
should land *before* any site-fixing slice: 69 of the sites are not
work, they are a missing rule.

**Exits other than `return`.** `if not x then break end` does not
narrow, though `if not x then return end` does. Every directory walk in
the tree is written that way, which is why `cosmic/fs/tree.tl`,
`cosmic/fs/dir_test.tl` and their siblings cluster. This is a second
candidate patch edit and it is not measured here — the prototype
reports the sink, not the guard the author wrote — so sizing it is a
slice of its own.

**Everything else is a site.** A guard, a narrowed signature, or
`check.must` in the test half. There is no rule that closes them and no
cast that should.

## The doctrine dividend

A strict mode retires the prose that exists to warn about its absence.

- **AGENTS.md 181–184** (the sentence starts mid-line at 181) —
  "And what the checker never DEMANDS: an
  unnarrowed `T | nil` passes into a non-nil parameter, a declared
  non-nil local, arithmetic and concatenation — only an index refuses
  it, so an unguarded union becomes a runtime nil downstream (pinned in
  `cosmic/teal_narrowing_test.tl`)." Four lines out of the 92-line
  Error Handling Patterns block (145–236). The rest of the block —
  return shapes, `check.must`, `is` dispatch, the two-slot rule — is
  unaffected.
- **`docs/guides/checking.md` 198–240**, the whole `### Where Narrowing
  Is Required` section: 43 lines whose entire content is a worked
  example of a program that "compiles at full strictness, which is the
  point", plus the advice to "guard where the union is produced …
  rather than trusting the annotation". Under a strict mode the section
  becomes two sentences: narrowing is required wherever nil cannot go.
- **`docs/stdlib.md`** is unaffected. Its 58 lines describe the return
  *shapes*, which a strict mode does not change.

Nothing here is edited by this change. The lines are quoted so the
slice that moves the boundary knows what it is paying for.

## Upstream or carried

**Both, in that order — and the `or` rule first.**

The `or` rule is a strong upstream candidate: it is a soundness-neutral
precision improvement (`x or fallback` genuinely cannot be nil), it
needs no new syntax or option, and it would benefit every Teal user. It
belongs as a proposal to teal-language/tl, with the 69-site measurement
as its evidence.

Strict nil flow itself is not. It is a breaking change to every
existing Teal program — 358 errors in one repository that type-checks
clean today — so upstream would have to gate it behind an option, which
is a much larger conversation than a narrowing fix. Carrying it as a
sixth edit group in `3p/tl/tl_patch.tl` is the shape that fits: the
mechanism (`_make/patch.tl`, 190 lines) already anchors 11 edits against
the pinned `tl`, five of them narrowing rules, and the two hinges above
are two more anchors in files the patch already touches.

The order matters because the 69 `or` sites would otherwise be fixed by
hand, one guard at a time, and then have to be unwound when the rule
lands.

## What this is not

This document changes no checker, fixes no site, and edits no doctrine.
The prototype it describes was built inside `o/`, used, and deleted; the
gate that admitted this change ran against an unmodified pinned `tl`.
The one source line it touches is a comment word in
`3p/tl/tl_patch.tl` that said "Four edits" over five bullets.

The counts are a snapshot of `e7ac1580`. They will drift, and
`nil-flow-sites.tsv` is what a later pass re-derives and diffs against.

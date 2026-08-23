## Goal

G3 — an honest type layer, no escape hatches. `cosmic/quicksand/proxy/rules.tl`
declares a non-nilable port in five places and deliberately, documentedly puts
`nil` in it, in both directions, inside the proxy's allowlist enforcement path.
This makes the five declarations say what the code already does.

## Change

Widen five declarations in `cosmic/quicksand/proxy/rules.tl` to `integer | nil`,
and add one test in `cosmic/quicksand/proxy/rules_test.tl` that pins the runtime
behaviour a nil port already has. Nothing else moves — no function body changes,
no caller changes.

**Measured 2026-08-23 at main `daf8bd52`.** `wc -l < cosmic/quicksand/proxy/rules.tl`
prints **231** (269 lines of headroom under the 500-line cap);
`wc -l < cosmic/quicksand/proxy/rules_test.tl` prints **133** (367 of headroom).
Each line below was read with
`grep -n 'port: integer)\|port: integer$\|: string, integer$' cosmic/quicksand/proxy/rules.tl`,
which prints exactly these five lines and nothing else:

```
 31:  port: integer
 47:local function parse_rule(key: string): string, integer
174:local function match(idx: Index, host: string, port: integer): ProxyRule | nil
212:  parse_rule: function(key: string): string, integer
217:  match: function(idx: Index, host: string, port: integer): ProxyRule | nil
```

The five edits, each a pure widening of the port slot:

| line | from | to |
|------|------|----|
| 31 (`SuffixEntry.port`) | `  port: integer` | `  port: integer \| nil` |
| 47 (`parse_rule`) | `: string, integer` | `: string, integer \| nil` |
| 174 (`match`) | `port: integer)` | `port: integer \| nil)` |
| 212 (`RulesModule.parse_rule`) | `: string, integer` | `: string, integer \| nil` |
| 217 (`RulesModule.match`) | `port: integer)` | `port: integer \| nil)` |

This is a tuple whose second element is genuinely optional, not a fallible
return, so D20 rule 11 (a fallible return has TWO slots) does not apply and no
error shape changes. `parse_rule` returns nil in slot 2 on three of its four
paths and says so at `:43-45`; `SuffixEntry`'s own doc comment at `:28` already
reads "`port` nil = any port"; `match` reads a nil port as "no port constraint"
(`entry[port] or entry["*"]`, and `s.port == nil or s.port == port`).

**No caller needs touching, measured rather than assumed.** All five edits were
applied together in this refinement pass and the whole tree gated:
`bin/cosmic --make check` ends `check: PASS (514 files)` and
`bin/cosmic --make lint` ends `lint: PASS (606 files)`, with
`cosmic/quicksand/proxy/rules.tl` the only modified file. The complete caller
set, from
`grep -rn 'parse_rule\|rules\.match' --include='*.tl' . | grep -v '^./o/'`:
`parse_rule` is called only inside `rules.tl` itself (`:155`, `:158`) and from
`rules_test.tl` (`:5`, `:8`, `:10`); `match` is called from
`cosmic/quicksand/proxy/serve.tl:182` and `:235` and from `rules_test.tl`.

**The test to add.** Append `test_nil_port_query` to
`cosmic/quicksand/proxy/rules_test.tl`, called on the line after its `end` per
AGENTS.md, following the file's existing shape (build an index with
`rules.index`, assert on `rules.match`):

- `rules.match(idx, "any.example.com", nil)` on an index built from
  `{["any.example.com"] = {}, ["db.internal:5432"] = {}}` is non-nil — a nil
  port query hits the any-port entry;
- `rules.match(idx, "db.internal", nil)` is nil — a nil port query does not
  widen past a rule that names a port;
- `rules.parse_rule("example.com")` returns `("example.com", nil)`.

Both `match` assertions were run in this pass against the widened signatures and
hold. Note what this test does and does not pin, so it is not mistaken for the
whole change: **the `nil` literal at that call site type-checks TODAY, under the
un-widened `port: integer`** (measured: `bin/cosmic --check types
cosmic/quicksand/proxy/rules_test.tl` prints `Type check passed` with the test
added and `rules.tl` reverted), because Teal admits `nil` into every non-index
position. So the test pins runtime behaviour; the declarations are pinned by the
Acceptance grep below, which is why that grep is not optional.

## Non-goals

- No body changes. `parse_rule`, `validate_key`, `validate_rule`, `validate`,
  `index`, `match` and `auth_header` keep their current logic exactly —
  in particular `validate_key`'s fail-open guard (a malformed port must stay a
  validation error, never a silent widening to "any port") is untouched.
- No new nil handling in `cosmic/quicksand/proxy/serve.tl`. Its two `rules.match`
  calls compile unchanged; do not add guards around them.
- `cosmic/quicksand/proxy/http.tl` belongs to item `3I9Tko2h` (PR #1306), which
  walls this file off in turn. The two are file-disjoint and land in either order.
- `cosmic/url.tl` carries the same declaration shape and is NOT in scope:
  `port: integer` at `:113` and `:233`, and `local port: integer = nil` at `:132`.
  Leave all three alone; that is separate work, not this slice's.
- No cast sites move, so `_build/casts_baseline.tl` must not change — if a
  ratchet gate does complain, run exactly the regen command its failure message
  prints and commit the result, never a gate weakened any other way.
- No doc-comment rewrites beyond leaving the existing ones alone: `:28` and
  `:43-45` already state the nil contract correctly.

## Acceptance

```
bin/cosmic --make ci
bin/cosmic --make test cosmic/quicksand/proxy/rules_test.tl
grep -c 'port: integer)\|port: integer$\|: string, integer$' cosmic/quicksand/proxy/rules.tl
grep -c 'integer | nil' cosmic/quicksand/proxy/rules.tl
wc -l < cosmic/quicksand/proxy/rules.tl
wc -l < cosmic/quicksand/proxy/rules_test.tl
git status --short
```

- `bin/cosmic --make ci` ends `ci: PASS (5 stages)`, quoted in the PR description.
- `bin/cosmic --make test cosmic/quicksand/proxy/rules_test.tl` ends
  `test: PASS (1 file)` and reports **8 test functions** (7 today).
- the first grep prints **0** (5 today): no un-widened port declaration survives.
- the second grep prints **5** (0 today): each of the five is widened exactly once.
- `wc -l < cosmic/quicksand/proxy/rules.tl` prints a number ≤ 500 (231 today,
  unchanged expected).
- `wc -l < cosmic/quicksand/proxy/rules_test.tl` prints a number ≤ 500
  (133 today, ~142 expected).
- `git status --short` lists exactly two modified files and no others:
  `cosmic/quicksand/proxy/rules.tl` and `cosmic/quicksand/proxy/rules_test.tl`.

## Enablement

none needed — the five sites are enumerated by `file:line` with their exact
current text and the exact replacement, the grep that relocates them is in
Acceptance, the whole set was applied and gated green (`check: PASS (514 files)`,
`lint: PASS (606 files)`) during this refinement pass with no caller touched, the
complete caller set is enumerated, and the new test's three assertions were run
against the widened signatures rather than reasoned about.

The one wrong turn a literal session could take — adding the test and believing
it proves the widening, because the `nil` literal type-checks under the current
signature too — is measured and stated in `Change`, and walled by the first
Acceptance grep, which fails if any of the five declarations is left alone.

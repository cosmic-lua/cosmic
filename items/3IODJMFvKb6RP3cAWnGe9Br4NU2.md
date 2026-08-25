## Goal

G3 — an honest type layer, no escape hatches. `number to integer` is a
whole cast bucket, and this slice deletes all of it: 13 sites across 6
files, leaving the reason unused in the tree.

## Evidence

Measured 2026-08-25 against `whilp/cosmic` `5f227969` (`main`), with
`o/bin/cosmic` built from that tree.

**The bucket is 13 sites in 6 files** — not the 30 this item asserted
before it was refined:

```
$ git ls-files '*.tl' | xargs grep -c -- "-- cast: number to integer" \
    | awk -F: '$2>0' | sort -t: -k2 -rn
cosmic/instrument.tl:7
_tool/coverage/lines.tl:2
cosmic/quicksand/proxy/serve.tl:1
cosmic/quicksand/box/run.tl:1
cosmic/errno.tl:1
_tool/testrun.tl:1
$ git ls-files '*.tl' | xargs grep -h -- "-- cast: number to integer" | wc -l
13
```

**The `math.type` narrowing this item was opened around is not what
closes them.** Each site was probed by deleting its ` as integer` and
running `o/bin/cosmic --check types <file>`. Three outcomes, all
verified:

- **5 sites are already stale** — the cast is unnecessary against the
  pinned tl (0.24.8) and the current generated declarations. Deleting
  it type-checks with no other edit. `o/3p/tl/tl.tl:252` declares
  `floor: function(number): integer`, so the three `math.floor(...) as
  integer` sites in `cosmic/instrument.tl` need nothing; `(128 +
  r.signal)` in `_tool/testrun.tl:112` is integer arithmetic; and
  `cosmo.ParseIp` in `cosmic/quicksand/box/run.tl:198` is already
  declared returning `integer`.
- **6 sites close with `math.tointeger`**, which `o/3p/tl/tl.tl:291`
  declares `function(any): integer`. The checker itself prints this
  route: deleting the cast at `cosmic/instrument.tl:162` reports
  `got number, expected integer` with `hint: … convert with
  math.tointeger`.
- **2 sites close by correcting a curated declaration.**
  `_types/gentl.tl:199-200` hand-writes `tl.Error.y: number` and `x:
  number`, while upstream `o/3p/tl/tl.tl:614-615` declares both
  `integer`. The file's own header says records are "curated field
  subsets verified against upstream", so `number` there is drift. With
  `integer` in its place, both `_tool/coverage/lines.tl` sites
  type-check with the cast simply deleted.

**Every closure below was compiled before being written here.** Each
was applied in a scratch checkout of `5f227969` and passed
`o/bin/cosmic --check types <file>`; the `gentl.tl` edit additionally
passed `o/bin/cosmic --make build` and
`o/bin/cosmic --make test _types/tl_conformance_test.tl` (`test: PASS`).

**The two files that hold `tl.Error`** are `_tool/coverage/lines.tl`
and `cosmic/format/init.tl` (`git ls-files '*.tl' | xargs grep -ln
'tl\.Error'`); both type-check under the corrected declaration.

**Baseline rows that move.** `_build/casts_baseline.tl` today:

```
$ grep -nE 'instrument\.tl|testrun\.tl|errno\.tl|box/run\.tl|proxy/serve\.tl|coverage/lines\.tl' _build/casts_baseline.tl
32:  ["_tool/coverage/lines.tl"] = 11,
35:  ["_tool/testrun.tl"] = 1,
56:  ["cosmic/errno.tl"] = 3,
77:  ["cosmic/instrument.tl"] = 7,
89:  ["cosmic/quicksand/box/run.tl"] = 3,
98:  ["cosmic/quicksand/proxy/serve.tl"] = 1,
```

and the tree's total justified casts are 402
(`git ls-files '*.tl' | xargs grep -h -- "-- cast: " | wc -l`).

## Change

Delete all 13 `number to integer` casts, in six files plus one
generated-declaration correction. No other cast reason is touched.

**1. `cosmic/instrument.tl` — 7 sites, 7 → 0.** At `:111`, `:117` and
`:124-125` delete the ` as integer` and the `-- cast:` comment; the
`math.floor(...)` calls already return `integer`. At `:162-165` wrap
each with `math.tointeger`, keeping the existing zero default:

```text
exit = (math.tointeger(tonumber(exit_str) or 0) or 0),
```

and the same for `wall_ms`, `cpu_ms`, `maxrss_kb`. The trailing `or 0`
is the honest half — `math.tointeger` returns nil at runtime for a
non-integral value even though tl declares it `integer` — and it
preserves today's behaviour, which is that an unparseable field reads
as 0.

**2. `_tool/testrun.tl:112` — 1 site, 1 → 0.** Delete the cast and its
comment; leave `exit_code = (128 + r.signal)`.

**3. `cosmic/quicksand/box/run.tl:198` — 1 site, 3 → 2.** Delete the
cast and its comment; leave `bind_ip = cosmo.ParseIp("127.0.0.1"),`.

**4. `cosmic/errno.tl:119-122` — 1 site, 3 → 2.** Replace the
`is number` guard and its cast with a `math.tointeger` guard:

```text
local n = v is number and math.tointeger(v) or nil
if n then
  codes[name] = n
end
```

The `-- cast: dynamic E* lookup` on the line above stays; only the
`number to integer` cast goes.

**5. `cosmic/quicksand/proxy/serve.tl:111-116` — 1 site, 1 → 0.**
Replace the `v is number` guard with a `math.tointeger` guard so the
`%d` argument is typed:

```text
local iv = v is number and math.tointeger(v) or nil
if iv then
  table.insert(parts, string.format(',%q:%d', k, iv))
else
  table.insert(parts, string.format(',%q:%q', k, tostring(v)))
end
```

This is a deliberate behaviour change and the only one in this slice: a
non-integral number field previously reached `string.format("%d", v)`,
which raises `number has no integer representation` in Lua 5.4, and now
falls to the existing `else` branch and logs as a quoted string.

No current caller can reach that branch — every `logger.*` call in
`serve.tl` passes ports, status codes and byte counts, all integers
(`grep -n 'logger\.' cosmic/quicksand/proxy/serve.tl` lists 15 calls
at `:184`–`:392`) — so the float case gets no test and the integer
case gets a regression guard. Add one test to
`cosmic/quicksand/proxy/serve_test.tl` (206 lines today, 294 of
headroom under the 500-line cap) named
`test_json_log_writes_an_unquoted_integer_port`: start a proxy with
`log_format = "json"`, `log_level = "info"` and `log_file` pointing
into `TEST_TMPDIR`, then read that file and assert its `listen` line
matches `"port":%d+` and does NOT match `"port":"`. The `listen` event
at `serve.tl:359` is what emits it.

**6. `_types/gentl.tl:199-200` — closes 2 sites, `_tool/coverage/lines.tl`
11 → 9.** Change the curated `tl.Error` record's `y: number` and
`x: number` to `y: integer` and `x: integer`, matching upstream
`tl.tl:614-615`. Then delete both casts and their `-- cast:` comment
lines at `_tool/coverage/lines.tl:113-114` and `:120-121`, leaving
`(e.y or 0)` as the `%d` argument.

**7. Regenerate the baseline.** After the edits run
`bin/cosmic --make run _build/casts.tl --baseline` and commit the
result — that is the exact command the ratchet's failure message
prints, and it is in scope here.

## Non-goals

- **No tl patch and no upstream proposal.** `3p/tl/tl_patch.tl` and
  `_make/patch.tl` are not touched: the probe above showed no site here
  needs a checker change, so the `math.type` narrowing this item was
  opened around is not built, not proposed, and not filed. If a future
  site does need it, that is a new item.
- **No other cast reason moves.** `git ls-files '*.tl' | xargs grep -h
  -- "-- cast: " | grep -vc "number to integer"` is 389 before and 389
  after (the total falls 402 -> 389 because only this bucket leaves). In particular the `-- cast: dynamic E* lookup` in
  `cosmic/errno.tl` and the `from any` sites in `cosmic/instrument.tl`
  stay exactly as they are.
- **No behaviour change outside `serve.tl`'s log line.** The five
  stale-cast deletions and the six `math.tointeger` wraps compile to
  the same or equivalent Lua; `instrument.tl`'s `or 0` defaults are
  preserved deliberately so a malformed record still reads as 0.
- **Do not touch `_types/types_gen.tl` or anything else under
  `_types/`** beyond the two field types on `_types/gentl.tl:199-200`.
  The generated `.d.tl` files are build output and are not committed.
- **Do not touch `whilp/cosmopolitan`.** No `definitions.lua` change is
  implicated; `cosmo.ParseIp` is already annotated correctly.
- **Do not lower any other baseline row.** Only the six rows named
  above move, and they move because casts were removed — never by
  hand-editing `_build/casts_baseline.tl`.
- **Do not widen `AGENTS.md` or write a decision record.** Deleting a
  cast bucket settles no tradeoff.

## Acceptance

All commands run verbatim from the `whilp/cosmic` repo root. Nothing
here writes into the committed tree.

- `bin/cosmic --make ci` ends `ci: PASS`.
- **The bucket is gone.**

  ```
  git ls-files '*.tl' | xargs grep -c -- "-- cast: number to integer" | awk -F: '$2>0'
  ```

  prints nothing and the summed count is 0:

  ```
  git ls-files '*.tl' | xargs grep -h -- "-- cast: number to integer" | wc -l
  ```

  prints `0` (was `13`).

- **Nothing else moved.**

  ```
  git ls-files '*.tl' | xargs grep -h -- "-- cast: " | wc -l
  ```

  prints `389` (was `402`), and

  ```
  git ls-files '*.tl' | xargs grep -h -- "-- cast: " | grep -c "from any"
  ```

  still prints `192` — the `from any` sites are untouched. (The 189 in
  `docs/design/casts.md` counts the sites whose reason is EXACTLY
  `from any`; this grep also catches the three that say more.)

- **The baseline records the win.**

  ```
  grep -nE 'instrument\.tl|testrun\.tl|errno\.tl|box/run\.tl|proxy/serve\.tl|coverage/lines\.tl' _build/casts_baseline.tl
  ```

  shows `_tool/coverage/lines.tl` = 9, `cosmic/errno.tl` = 2,
  `cosmic/quicksand/box/run.tl` = 2, and no row at all for
  `_tool/testrun.tl`, `cosmic/instrument.tl` or
  `cosmic/quicksand/proxy/serve.tl` — each reached 0 and the regen
  drops the row.

- **The declaration correction holds.**
  `bin/cosmic --make test _types/tl_conformance_test.tl` ends
  `test: PASS`, and

  ```
  grep -n 'y: integer' _types/gentl.tl
  ```

  reports line 199.

- **The new test runs.**
  `bin/cosmic --make test cosmic/quicksand/proxy/serve_test.tl` ends
  `test: PASS`, and
  `grep -c 'test_json_log_writes_an_unquoted_integer_port'
  cosmic/quicksand/proxy/serve_test.tl` is `2` (the definition and the
  call-after-define line AGENTS.md requires).

- `git diff --name-only main` names exactly these nine paths and no
  others: `_build/casts_baseline.tl`, `_tool/coverage/lines.tl`,
  `_tool/testrun.tl`, `_types/gentl.tl`, `cosmic/errno.tl`,
  `cosmic/instrument.tl`, `cosmic/quicksand/box/run.tl`,
  `cosmic/quicksand/proxy/serve.tl`,
  `cosmic/quicksand/proxy/serve_test.tl`. `.cosmic-coverage` may join
  them if — and only if — the coverage ratchet demanded a regen; no
  other path may.

If the coverage ratchet complains, run exactly the regen command its
failure message prints and commit the result — in scope. The casts
ratchet is expected to complain until step 7 is run; its message names
`bin/cosmic --make run _build/casts.tl --baseline`.

## Enablement

none needed. Every closure in `## Change` was compiled against
`5f227969` during this refinement pass with the command that verified
it recorded beside it, so no mechanism has to be invented and no
decision is left open. Conventions are AGENTS.md — in particular that
a fallible return has two slots and that every remaining `as` keeps its
`-- cast:` justification; the comment-and-prose standard is
`skills/docs-style/SKILL.md`.

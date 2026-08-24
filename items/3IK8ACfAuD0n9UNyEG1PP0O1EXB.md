## Goal

G9 — the least thing: `re.gsub` and `re.split` do measurable work
nobody reads. Parent `3HyRcd9F`. `all_matches` materializes a full
`{Span}` list — one Span table plus one `text:sub` copy of the matched
substring per match — and gsub/split then walk that list a second time,
though split never reads the copy and literal-string gsub never reads
either the copy or the captures.

## Change

In `cosmic/re.tl` only. Factor the single non-overlapping find loop out
of `all_matches` into a private helper, and have `gsub` and `split`
consume it directly instead of building and re-walking a `{Span}` list.
`find_all` and `gmatch` keep using `all_matches` — Spans ARE their
product (`gmatch`'s iterator reads `sp.m`/`sp.caps` at re.tl:362).

Measured now: `wc -l < cosmic/re.tl` is **473** (27 lines of headroom
under the 500-line cap); `grep -n 'sp.m\|sp.caps' cosmic/re.tl` returns
only lines 362 (gmatch), 424 and 428 (gsub's function-repl path);
`split` (re.tl:387-389) reads only `sp.s`/`sp.e`.

1. **Add `scan_matches`** beside `all_matches`, carrying the loop body
   verbatim from `all_matches` (re.tl:268-290) so the `NOT_BOL` resume
   semantics (re.tl:273-277) and the engine-error propagation
   (`if e is string then return … end`) live in exactly one place:

   ```teal
   -- Run the single non-overlapping find loop, invoking emit(s, e, caps)
   -- per match in order. Returns true on clean completion, or false, err
   -- on engine failure. NOT_BOL resume matches all_matches; the
   -- empty-match guard stays in compile_for_iter.
   local function scan_matches(regex: Regex, text: string,
       emit: function(integer, integer, {string})): boolean, string
     local pos = 1
     while pos <= #text do
       local sflags: integer = 0
       if pos > 1 then
         sflags = NOT_BOL
       end
       local s, e, caps = regex:find(text, sflags, pos)
       if s == nil then
         if e is string then
           return false, e
         end
         break
       end
       local ei = e as integer -- cast: tuple element (integer whenever start is non-nil)
       emit(s, ei, caps)
       pos = ei + 1
     end
     return true
   end
   ```

2. **Rewrite `all_matches`** (re.tl:268-290) to build its `{Span}` list
   through `scan_matches`, preserving its exact return contract
   (`{Span} | nil, string`), so `find_all`/`gmatch` are byte-for-byte
   unaffected:

   ```teal
   local function all_matches(regex: Regex, text: string): {Span} | nil, string
     local spans: {Span} = {}
     local ok, err = scan_matches(regex, text,
       function(s: integer, e: integer, caps: {string})
         spans[#spans + 1] = {s = s, e = e, m = text:sub(s, e), caps = caps}
       end)
     if not ok then
       return nil, err
     end
     return spans
   end
   ```

3. **Rewrite `gsub`** (re.tl:408-435) to emit into `out` from inside
   `scan_matches`, building the matched substring (`text:sub(s, e)`)
   only on the function-repl and keep-match branches — never for a
   literal `repl`:

   ```teal
   local out: {string} = {}
   local pos = 1
   local ok, err = scan_matches(regex, text,
     function(s: integer, e: integer, caps: {string})
       out[#out + 1] = text:sub(pos, s - 1)
       if repl is string then
         out[#out + 1] = repl
       else
         local r = repl(text:sub(s, e), caps)
         if r is string then
           out[#out + 1] = r
         else
           out[#out + 1] = text:sub(s, e)
         end
       end
       pos = e + 1
     end)
   if not ok then
     return nil, err
   end
   out[#out + 1] = text:sub(pos)
   return table.concat(out)
   ```

4. **Rewrite `split`** (re.tl:376-393) the same way, reading only the
   offsets — no `m`, no `caps` — from inside `scan_matches`:

   ```teal
   local out: {string} = {}
   local pos = 1
   local ok, err = scan_matches(regex, text,
     function(s: integer, e: integer, _caps: {string})
       out[#out + 1] = text:sub(pos, s - 1)
       pos = e + 1
     end)
   if not ok then
     return nil, err
   end
   out[#out + 1] = text:sub(pos)
   return out
   ```

The `compile_for_iter` call and the `if not regex then return nil, cerr
end` guard at the head of `gsub`/`split` are unchanged; only the body
after the `all_matches` call is replaced.

## Non-goals

- **The public contract is frozen.** Return shapes (`gsub` →
  `string | nil, string`; `split` → `{string} | nil, string`),
  no-match behavior (split yields one field; gsub returns text
  unchanged), the empty-match rejection, and the `nil`-from-function-repl
  "keep the match" rule all stay byte-identical. This is the Acceptance
  equality check's whole subject.
- **Do not touch `find`, `find_all`, `gmatch`, or `match`.** They keep
  `all_matches`/their own loop; `gmatch` reads `sp.m`/`sp.caps`, so its
  Spans are not surplus.
- **Do not delete `all_matches` or the `Span` record.** `find_all` and
  `gmatch` still return them, and `Span` is exported (re.tl:441).
- **No `cosmo.*`/engine change**, no new public function, no signature
  change on any exported name.
- **Do not widen the file past the cap.** Keep the change inside the
  measured headroom rather than reformatting neighbours to make room.

## Acceptance

```
bin/cosmic --make ci
bin/cosmic --make test cosmic/re_test.tl
wc -l cosmic/re.tl
```

- `bin/cosmic --make ci` ends `ci: PASS` — fmt, check (no new warning
  from the added closures/casts), example, lint (the one `as integer`
  cast carries its `-- cast:` justification), coverage.
- `bin/cosmic --make test cosmic/re_test.tl` passes all 35 `test_*`
  functions — this is the output-equality gate for the frozen contract
  (gsub literal + function repl, split with leading/trailing/adjacent
  matches, engine-error propagation, empty-match rejection).
- `wc -l cosmic/re.tl` prints a number **≤ 500** (today 473).
- **Performance — the `optimize` skill's compare gate.** Per
  `skills/optimize/SKILL.md`: baseline `o/bin/cosmic` before the change,
  build after, and
  `bin/cosmic --make run _perf/gate.tl compare BASE.json CUR.json SELFB.json`
  shows `re_gsub_redact_numbers` and `re_split_colon_list` improved past
  their noise bars and **no scenario regressed**. The scenarios and
  their functional `check()`s already exist (`_perf/bench/re_bench.tl`:
  `re_split_colon_list` at :88, `re_gsub_redact_numbers` at :107); do
  not weaken either. The hypothesis probed −38% on gsub via a direct
  `regex:find` loop producing byte-identical output (bare finds = 53µs
  is the C floor); report the harness figure as this session's
  measurement, not the probe's.

## Enablement

none needed — the change is contained to one file whose relevant
functions are cited by line, the loop body to lift is quoted from the
source, every constraint that must survive is named in Non-goals with
its enforcing gate, and the perf acceptance is the `optimize` skill's
standing gate. The `as integer` cast is copied verbatim with its
existing justification, so lint stays green.

## Goal

G6 — the defining paths, ratcheted. `literal.format(..., {layout =
"compact"})` writes every committed floor and every machine-read literal
file cosmic produces (D27),
and since `3IOFN9bn` deleted the Teal guard walk, all of that writer's
remaining overhead is one C function: the reserved-word scan
`cosmo.EncodeLua` runs for every identifier-shaped key when
`literal = true`. This slice makes that scan cheap.

## Evidence

Measured 2026-08-26. Timings from cosmic main `b4ad036b` with
`o/bin/cosmic` built from that tree (which carries cosmos
`2026.08.26-fe7c36c4c`); source line numbers from whilp/cosmopolitan
`fe7c36c4` (master).

**The tax exists and is stable.** `3IOFN9bn`'s harness recipe — N
string-keyed entries of mixed scalars plus one nested table each, best of
five runs of 20 iterations, `os.clock`, script kept outside the tree:

| entries | size   | `{sorted}` | `{sorted, literal, maxdepth=32}` | tax   |
|---------|--------|------------|----------------------------------|-------|
| 400     | 37 KB  | 0.73 ms    | 1.11 ms                          | 1.52x |
| 2500    | 245 KB | 5.03 ms    | 7.08 ms                          | 1.41x |

**The cost is attributed, not guessed.** `IsLuaKeyword` runs only behind
`IsLuaIdentifier`
(`third_party/lua/luaencodeluadata.c:84` — `if (IsLuaIdentifier(L, idx)
&& IsLuaKeyword(L, idx))`), so identifier-shaped keys pay it and
hyphenated keys skip it. Two fixtures of the same shape, differing only
in whether their keys are identifiers, comparing the literal/sorted ratio
WITHIN each fixture so the different baseline cost of bracketed keys
cancels — three independent runs of the same script:

```text
identifier keys   203 KB  sorted=3.65 ms  literal=5.27 ms  tax=1.44x
hyphenated keys   286 KB  sorted=4.52 ms  literal=5.14 ms  tax=1.14x
identifier keys   203 KB  sorted=3.52 ms  literal=5.33 ms  tax=1.52x
hyphenated keys   286 KB  sorted=4.56 ms  literal=5.16 ms  tax=1.13x
identifier keys   203 KB  sorted=3.33 ms  literal=4.91 ms  tax=1.47x
hyphenated keys   286 KB  sorted=4.25 ms  literal=4.81 ms  tax=1.13x
```

The keyword scan is **~68% of the literal tax** — `(1.47 − 1.13) /
(1.47 − 1.00)` at the middle run, and the two groups do not overlap
across three runs. The residual 1.13x is the rest of literal mode: the
`memchr(s, 27, n)` scan of every string value, the per-scalar
type/finiteness tests, and `IsLuaIdentifier` itself.

**The function, and why it is slow.**
`third_party/lua/luaencodeluadata.c:63-73`:

```c
static bool IsLuaKeyword(lua_State *L, int idx) {
  size_t i, n;
  const char *p;
  p = lua_tolstring(L, idx, &n);
  for (i = 0; i < sizeof(kLuaKeywords) / sizeof(*kLuaKeywords); ++i) {
    if (!strncmp(p, kLuaKeywords[i], n) && !kLuaKeywords[i][n]) {
      return true;
    }
  }
  return false;
}
```

A linear scan of all 22 entries of `kLuaKeywords`
(`:52-56`) with a `strncmp` call each, for every identifier-shaped key,
and it runs to completion on every key that is NOT a keyword — which is
every key in practice. `IsLuaKeyword` has exactly one caller
(`grep -rn IsLuaKeyword --include=*.c --include=*.h .` → the definition
at `:63` and the call at `:84`), so its shape is free to change.

**The keywords bucket by length, and no bucket holds more than five.**
Counted from `kLuaKeywords` at `:52-56`:

| length | keywords                                | count |
|--------|-----------------------------------------|-------|
| 2      | `do` `if` `in` `or`                     | 4     |
| 3      | `and` `end` `for` `nil` `not`           | 5     |
| 4      | `else` `goto` `then` `true`             | 4     |
| 5      | `break` `false` `local` `until` `while` | 5     |
| 6      | `elseif` `repeat` `return`              | 3     |
| 8      | `function`                              | 1     |

4+5+4+5+3+1 = 22, the full table. Lengths 1, 7 and ≥9 hold none, so a
length test alone rejects those keys in O(1), and no surviving key
compares against more than five candidates.

## Change

One file: `third_party/lua/luaencodeluadata.c`, in whilp/cosmopolitan.

Replace `IsLuaKeyword`'s body (`:63-73`) with a length-bucketed lookup.
Keep the function's name, signature, and its single call site at `:84`
unchanged. Keep `kLuaKeywords` (`:52-56`) exactly as it is — it is the
readable statement of the set and other readers may rely on it; add the
buckets beside it rather than replacing it.

The shape:

- return `false` immediately when `n < 2 || n > 8`, and when `n == 7`;
- otherwise compare `p` against only the keywords of length `n`, with
  `memcmp(p, kw, n)` — equal lengths make `strncmp`'s trailing
  `!kw[n]` check unnecessary, and `memcmp` needs no NUL scan;
- express the buckets as static const tables in the file, one per
  length, sized by the table above. Do not compute them at runtime and
  do not add a hash.

The result must be exactly equivalent: the same 22 strings return
`true`, everything else returns `false`. This is a pure lookup
rewrite — no behaviour, no contract, and no annotation moves.

Follow the fork's convention (AGENTS.md): a surgical diff, no drive-by
reformatting of the surrounding file.

## Non-goals

- **No contract change.** The `cosmo.*` C boundary,
  `tool/net/definitions.lua`, and every return shape, error string and
  constant are frozen. `LiteralKeyRefusal` still returns the literal
  string `"reserved word as key"` for exactly the same inputs. The
  domain `literal = true` refuses is consumed by
  `cosmic/_literal_format.tl` and pinned by
  `cosmic/_literal_format_test.tl`; a faster check that admits or
  refuses one value differently is a correctness regression in the
  corrupting direction, not an optimization.
- **Only `IsLuaKeyword`.** `IsLuaIdentifier` (`:41-50`),
  `LiteralKeyRefusal` (`:80-88`), `LiteralScalarRefusal` (`:97-115`),
  the `memchr(s, 27, n)` string scan and every `z->conf.literal` branch
  in the serializer stay as they are.
- **Do not merge the two `IsLuaIdentifier` calls.** In literal mode it
  runs twice per string key — once at `:84` inside `LiteralKeyRefusal`
  and again at `:362`/`:398` where the serializer picks bare against
  bracketed spelling. That is a real second finding, recorded here so
  it is not lost, but it changes control flow through the serializer
  and belongs to its own slice, measured after this one lands. Do not
  take it here.
- **No cosmic-side change.** No pin bump, no type regen, no wrapper
  edit, and nothing in whilp/cosmic. The win reaches cosmic on the next
  ordinary pin bump; `_perf/bench/literal_bench.tl`'s
  `literal_format_floor_compact` row is where it will show.
- **No new test file and no new CI lane.** The equivalence check below
  goes into the existing `tool/lua/test_cosmo.lua`, wired already.
- **Do not touch `test/tool/net/**`.** That lane is `3IOCgCWG`'s and
  `3IOCgtWA`'s.

## Acceptance

Run from the whilp/cosmopolitan repo root. Steps 3 and 4 need the
harness script; write it outside the tree and do not commit it.

1. `make -j$(nproc) o//tool/lua/test` passes — the fork's stated
   pre-PR gate (AGENTS.md), which carries the binding tests and the
   annotation-coverage ratchet.

2. **Equivalence, all 22 and their near misses.** Add to
   `tool/lua/test_cosmo.lua` a block asserting, for each of the 22
   strings in `kLuaKeywords`, that

   ```lua
   local ok, why = cosmo.EncodeLua({[kw] = 1},
     {sorted = true, literal = true, maxdepth = 32})
   ```

   returns `ok == nil` and `why == "reserved word as key"`; and for the
   near misses `ending`, `en`, `endx`, `And`, `NIL`, `function1`,
   `_end`, `end_` that `ok` is a string. Then
   `o//tool/lua/lua tool/lua/test_cosmo.lua` prints its existing PASS
   line and `make -j$(nproc) o//tool/lua/test` still passes.

3. **The tax drops, measured on the built binary.** With the identical
   two-fixture script whose three runs are quoted in Evidence — 2500
   entries, five sub-keys each, identifier keys against hyphenated
   keys, best of five runs of 20 iterations — run it on
   `o//tool/lua/lua` built from `master` and again on the same binary
   built from this branch, at least twice per side. Quote all four
   figures in the PR. The identifier-key tax must fall to **≤ 1.30x**
   (today 1.44–1.52x across three runs; the hyphenated floor is
   1.13x, and 1.30x is a little over half the gap).

4. **The hyphenated fixture does not regress.** Its tax stays within
   `1.13x ± 0.05` on the same runs — it skips `IsLuaKeyword` entirely,
   so a move there means something else changed and the measurement is
   not attributable.

5. `git diff --name-only master` prints exactly:

   ```text
   third_party/lua/luaencodeluadata.c
   tool/lua/test_cosmo.lua
   ```

6. `git diff master -- tool/net/definitions.lua third_party/lua/cosmo.h`
   is empty — the contract did not move.

### The harness script

Write this verbatim outside the tree and run it as
`o//tool/lua/lua /path/to/tax.lua`. It is the script whose three runs
are quoted in Evidence; a different fixture produces different numbers
and the bound above does not apply to it.

```lua
-- literal-mode tax, attributed by key shape.  IsLuaKeyword runs only
-- behind IsLuaIdentifier, so identifier keys pay it and hyphenated keys
-- skip it.  Comparing the literal/sorted ratio WITHIN each fixture makes
-- the different baseline cost of bracketed keys cancel.
local cosmo = require("cosmo")

local function fixture(n, keyfmt, subkeys)
  local t = {}
  for i = 1, n do
    local e = {}
    for j, k in ipairs(subkeys) do
      if j % 2 == 0 then
        e[k] = "value_" .. i
      else
        e[k] = i * j
      end
    end
    t[string.format(keyfmt, i)] = e
  end
  return t
end

local function best(f, iters, runs)
  local b = math.huge
  for _ = 1, runs do
    local t0 = os.clock()
    for _ = 1, iters do f() end
    local dt = (os.clock() - t0) / iters
    if dt < b then b = dt end
  end
  return b * 1000
end

local function measure(label, t)
  local encoded = assert(cosmo.EncodeLua(t, {sorted = true}))
  local a = best(function() return cosmo.EncodeLua(t, {sorted = true}) end, 20, 5)
  local b = best(function()
    return cosmo.EncodeLua(t, {sorted = true, literal = true, maxdepth = 32})
  end, 20, 5)
  print(string.format("%-22s %6.0f KB  sorted=%6.2f ms  literal=%6.2f ms  tax=%5.2fx",
    label, #encoded / 1024, a, b, b / a))
end

local ident = {"name", "count", "ratio", "flag", "extra"}
local nonident = {"a-name", "a-count", "a-ratio", "a-flag", "a-extra"}

measure("identifier keys", fixture(2500, "key_%d", ident))
measure("hyphenated keys", fixture(2500, "key-%d", nonident))
```

## Enablement

none needed. The function, its single call site, and the keyword table
are read above at real line numbers; the bucket table is computed from
`kLuaKeywords` itself and stated in full, so the implementer picks
nothing. The build and gate commands are whilp/cosmopolitan's AGENTS.md
(`make -j$(nproc) o//tool/lua/lua`, `make -j$(nproc) o//tool/lua/test`;
the first build downloads the cosmocc toolchain into `.cosmocc/` and
needs a network once, after which builds are hermetic and an incremental
rebuild after a one-file C edit is ~2 seconds). The measurement
discipline is the `optimize` skill's `measurement.md`; this scenario is
not one of the fixed-overhead microbenches that chapter names, and the
two-fixture ratio design controls for machine noise by construction.

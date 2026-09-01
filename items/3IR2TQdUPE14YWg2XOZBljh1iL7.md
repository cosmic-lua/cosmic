## Goal

G3, via the cosmo-contracts container: the inventory that turns "two
bindings fixed" into "the boundary is exact", for one slice of it —
the top-level `cosmo` surface — codecs, hashes, fetch and the stream reader. A research slice: its deliverable is recorded evidence and the
follow-up captures, not code.

## Evidence

Measured 2026-08-26 against whilp/cosmopolitan master `1e165815` (the
commit carrying both settled sibling contracts, #276 and #277).

The universe is one walk of `tool/net/definitions.lua`: for each
`^function` declaration, classify the FIRST `@return` line of the
contiguous `---` doc run directly above it — **NIL** when that line
contains `|nil` or its type token ends in `?`, **EXACT** otherwise,
**NONE** when the run declares no `@return` at all. Save this as
`census.awk` and run it from the cosmopolitan repo root:

```awk
/^---/ { run[n++] = $0; next }
/^function / {
  name = $2; sub(/\(.*/, "", name)
  cls = "NONE"
  for (i = 0; i < n; i++) {
    if (run[i] ~ /^---@return /) {
      split(run[i], f, " ")
      cls = (index(run[i], "|nil") > 0 || f[2] ~ /\?$/) ? "NIL" : "EXACT"
      break
    }
  }
  print cls "\t" name
  n = 0; next
}
{ n = 0 }
```

```text
$ awk -f census.awk tool/net/definitions.lua | cut -f1 | sort | uniq -c
    209 EXACT
    192 NIL
     38 NONE
$ grep -c '^function ' tool/net/definitions.lua
439
```

209 + 192 + 38 = 439, so the walk classifies every declaration and
nothing is silently dropped. By module, the 192 NIL rows
(`awk -F'\t' '$1=="NIL"{print $2}' … | sed 's/[:.].*//' | sort | uniq -c`):

| module | nil-admitting |
|---|---|
| `unix` | 127 |
| `lsqlite3` | 22 |
| `cosmo` | 22 |
| `zip` | 14 |
| `re` | 5 |
| `getopt` | 1 |
| `argon2` | 1 |
| `path`, `cov`, `repl` | 0 |

`path` is exact in all 7 of its bindings — sibling 3IQtfuCx (#276)
closed the last one — and `cov` and `repl` contribute no rows, so
neither module gets a census slice.

**This measurement supersedes the per-module figures in the parent's
bounce note**, which reported `unix` 128 (its walk predates #277's
`clock_gettime`), `lsqlite3` 30 and "`cov` and `repl` declare 2
bindings between them". Re-derived here at `1e165815`, `lsqlite3`
carries 22 NIL rows of 108 declarations, and `cov`/`repl` declare 7
between them, all EXACT. The command above is the one to re-run; the
parent's is not reproducible from its note.

**This slice's scope: the 22 nil-admitting bindings below.**

```text
cosmo.Barf cosmo.DecodeBase32 cosmo.DecodeHex cosmo.DecodeJson 
cosmo.DecodeLua cosmo.Deflate cosmo.EncodeBase32 cosmo.EncodeJson 
cosmo.EncodeLua cosmo.Fetch cosmo.FetchStream cosmo.GetCryptoHash 
cosmo.GetHostOs cosmo.GetRandomBytes cosmo.Inflate cosmo.ParseHost 
cosmo.ParseIp cosmo.ResolveIp cosmo.Slurp cosmo.Strftime 
cosmo.StreamReader:read cosmo.StreamReader:read_until
```

## Change

Classify every binding in this slice's scope into exactly one class,
with evidence:

1. **degenerate-input-only** — nil reachable only for an argument shape
   no correct caller passes (the `path.join(nil)` class, closed by
   #276). Each is a raise-candidate: file one capture per binding,
   unparented, then `attach` it under this item's parent container
   with `--repo whilp/cosmopolitan`.
2. **environmental or data-dependent** — a correct caller can meet the
   failure (ENOENT, EINTR, bad input data). The union stays; verify the
   tuple is exactly `T|nil, err string, errno?` with nothing else
   sharing a slot. Each deviation gets its own capture — `unix.nanosleep`
   is the archetype, its slot 2 declared `integer|string remnanos` so
   the success remainder shares a slot with the error string.
3. **exact already** — no action; one summary row.

The evidence standard, per row:

- the C source cite, as `file:line`
- the `tool/net/definitions.lua` line
- one probe transcript against the built binary
  (`o//tool/lua/lua -e '...'`) demonstrating the reachability class
- the cosmic-side spend: `grep -rn '<binding>' cosmic/` in a cosmic
  checkout, listing the wrapper sites that guard or assert it today

Record the summary table (binding, class, probe command, capture id or
"exact") back onto THIS item with `gitboard spec`, then finish per
review.md's research-slice clause — the deliverable is board state, and
there is no product PR.

## Non-goals

- No code change in either repo — captures and evidence only.
- No bindings outside this slice's scope list above. A binding that
  turns out to belong to a sibling slice's family stays that slice's
  row; say so in this item's summary rather than adopting it.
- No re-litigating `path.join` (#276) or `unix.clock_gettime` (#277).
- No captures for class-3 rows.
- No promotion of the filed captures — ordering them is the goal
  owner's `compare`, after this slice reports.

## Acceptance

- This item's spec carries the summary table, with exactly one row per
  binding in the scope list above and no others. State the row count
  beside the scope count so a reader can see they match.
- Every class-1 row and every class-2 tuple-deviation row names a filed
  capture id, and `gitboard tree` under the parent container lists it.
- Every row's probe command is literally runnable from the
  cosmopolitan repo root against `o//tool/lua/lua`, built by
  `make -j$(nproc) o//tool/lua/lua`.
- The scope list is re-derived, not trusted: re-running the `census.awk`
  command above at the commit the slice is worked at yields this
  slice's binding set. A binding that has moved class since
  `1e165815` is a re-measured row, not a bounce.

## Enablement

none needed. The classes, the evidence standard and the capture rule
are stated in full above, so this slice is workable without reading the
parent. It writes no repo files, so it is parallel-safe with every
sibling census slice and with any contract slice they seed.

## Result — re-measured 2026-09-01, whilp/cosmopolitan `2faa3113`

Re-derived again at `2faa3113` (four commits past `1e165815`; only one
touches this slice's scope, `fe7c36c4` adding `EncodeLua`'s `literal`
option — additive, does not change its nil-admitting status).
Re-running the exact `census.awk` command from `## Evidence` at this
commit yields the same totals (209/192/38, 439 declarations) and the
same per-module breakdown (`cosmo` 22, `unix` 127, `lsqlite3` 22, `zip`
14, `re` 5, `getopt` 1, `argon2` 1). The `cosmo` NIL set is
byte-identical to the 22-binding scope list below — nothing has moved
class, nothing has entered or left the set.

All builds/probes below ran against `o//tool/lua/lua` built by
`make -j$(nproc) o//tool/lua/lua` at the cosmopolitan repo root;
cosmic-side spend was grepped against a `cosmic-lua/cosmic` checkout
(`grep -rn '<binding>' cosmic/`).

Row count: **22**. Scope count: **22**. Match.

None of the 22 bindings are class-1 (degenerate-input-only): every one
of them has at least one nil-producing path a correct caller can meet
at runtime (ENOENT-class filesystem/network failures, malformed or
adversarial input data, or C-heap/allocator exhaustion), so the union
rule in `## Change` puts all 22 in class 2. Two distinct tuple-shape
deviations were found within that set, each filed as its own capture
below; every other row's tuple already matches the canonical
`T|nil, err string, errno?` shape (with `errno?` legitimately absent
where the failure isn't a syscall). Two rows (`ParseHost`, `GetHostOs`)
carry a single-value optional return with **no** error slot at all —
verified as the *correct* shape for them (nil there is a valid,
non-error answer — "no port present" / "host OS not in the known set"
— not a failure with a cause to report), so they are not tuple
deviations and get no capture.

| binding | class | C source | definitions.lua | probe | cosmic spend | capture |
|---|---|---|---|---|---|---|
| `cosmo.Barf` | 2 (environmental) | `tool/net/lfuncs.c:420` (`LuaBarf`), fails via `LuaFileError` (`lfuncs.c:334`) on open/write/close; degenerate arg-shape (`offset<1`, `append+offset`) already raises via `luaL_error` at `lfuncs.c:453,461` | `2158` | `o//tool/lua/lua -e 'local cosmo=require("cosmo"); print(cosmo.Barf("/no/such/dir/x.txt","a"))'` → `nil  open /no/such/dir/x.txt: ENOENT: No such file or directory  2` | `cosmic/fs/file.tl:58` | exact |
| `cosmo.DecodeBase32` | 2 (environmental: bad alphabet shape + OOM) | `tool/net/lfuncs.c:706` (`LuaDecodeBase32` → `LuaBase32Impl` at `lfuncs.c:677`) | `2191` | `o//tool/lua/lua -e 'local cosmo=require("cosmo"); print(cosmo.DecodeBase32("AB","xyz"))'` → `nil  alphabet length is not a power of 2 in range 2..128` | `cosmic/codec.tl:145` | exact |
| `cosmo.DecodeHex` | 2 (data-dependent; source comment: "not a programmer error") | `tool/net/lfuncs.c:722` | `2210` | `o//tool/lua/lua -e 'local cosmo=require("cosmo"); print(cosmo.DecodeHex("abc"))'` → `nil  hex string length uneven` | `cosmic/codec.tl:25` | exact |
| `cosmo.DecodeJson` | 2 (malformed/truncated JSON) | `tool/lua/lcosmo.c:45` | `2267` | `o//tool/lua/lua -e 'local cosmo=require("cosmo"); print(cosmo.DecodeJson("{bad json"))'` → `nil  illegal character` | `cosmic/json.tl:68,70,138,158` | exact |
| `cosmo.DecodeLua` | 2 (malformed literal data) | `tool/lua/lcosmo.c:87` | `2293` | `o//tool/lua/lua -e 'local cosmo=require("cosmo"); print(cosmo.DecodeLua("return {x=}"))'` → `nil  holds literals only  11` | `cosmic/literal.tl:29,277` — the wrapper discards BOTH the message and the offset and re-lexes with its own reader on any C refusal (`literal.tl:270-281`: "A C refusal is discarded, message and byte offset both...") | **3IiG0ga5** (tuple deviation: 3rd slot is `integer? offset`, not `errno`) |
| `cosmo.Deflate` | 2 (option-shape nil + zlib-internal/OOM) | `tool/net/lfuncs.c:1189`; level/format checks at `1202-1210`, `GetZlibFormat` at `1161` | `2322` | `o//tool/lua/lua -e 'local cosmo=require("cosmo"); print(cosmo.Deflate("x",{level=99}))'` → `nil  level must be in range -1..9` | `cosmic/compress.tl:48` | exact (note: the level/format-shape nil looks raise-worthy in isolation, similar to the `path.join(nil)` precedent, but the union rule keeps the whole binding class 2 because zlib-internal/OOM failures are genuinely environmental — not filed as a partial capture per the classification scheme's per-binding grain) |
| `cosmo.EncodeBase32` | 2 (mirrors DecodeBase32) | `tool/net/lfuncs.c:702` | `2334` | `o//tool/lua/lua -e 'local cosmo=require("cosmo"); print(cosmo.EncodeBase32("AB","xyz"))'` → `nil  alphabet length is not a power of 2 in range 2..128` | `cosmic/codec.tl:128` — wrapped in `assert(...)`, i.e. cosmic already treats this path as effectively impossible at its one call site | exact |
| `cosmo.EncodeJson` | 2 (cyclic tables, blended keys, NaN/Infinity, sparse arrays, OOM) | `tool/lua/lcosmo.c:163` (shared `LuaEncodeSmth` at `lcosmo.c:104`) | `2442` | `o//tool/lua/lua -e 'local cosmo=require("cosmo"); local t={}; t.self=t; print(cosmo.EncodeJson(t))'` → `nil  won't serialize cyclic lua table` | `cosmic/json.tl:91,100` | exact |
| `cosmo.EncodeLua` | 2 (OOM always; literal-mode refusals since #278 are data-dependent) | `tool/lua/lcosmo.c:181` (shared `LuaEncodeSmth`) | `2544` | `o//tool/lua/lua -e 'local cosmo=require("cosmo"); print(cosmo.EncodeLua(print, {literal=true}))'` → `nil  value is not literal data` | `cosmic/check.tl:25`, `cosmic/coverage/init.tl:231`, `cosmic/_literal_format.tl:301` (none pass `literal=true` today) | exact |
| `cosmo.Fetch` | 2 (dns/connect/tls/timeout/proxy/protocol/too_large/blocked) | `tool/net/lfetch.c:301` includes `tool/net/fetch.inc`; `LuaFetch` at `fetch.inc:74`; `LuaFetchError` helper at `fetch.inc:16` | `2708-2714` | `o//tool/lua/lua -e 'local cosmo=require("cosmo"); local a,b,c,d = cosmo.Fetch("http://this.host.invalid.tld.example/", {timeout=2}); print(a,b,c,d)'` → `nil  <dns error>  dns  nil`; success case returns 4 populated values (`status,headers,body,url`) | `cosmic/fetch/init.tl:233` — `local status, headers_or_err, body_or_kind, final_url = cosmo.Fetch(...)` followed by two explicit workaround casts, `-- cast: dual-shape binding return` and `-- cast: from any` (`init.tl:239-244`) | **3IiG0LQr** (tuple deviation: arity 4 on success vs 3 on failure; slot 2 is `headers` or `error`, slot 3 is `body` or `kind`, depending on branch) |
| `cosmo.FetchStream` | 2, identical root cause to `Fetch` | `tool/net/lfetch.c:705` (`LuaFetchStream`), same `LuaFetchError` helper | `2734-2738` | same DNS-failure probe as `Fetch`, substituting `cosmo.FetchStream`, returns the identical 3-value nil/error/kind shape | `cosmic/fetch/init.tl:362` — `local status, headers_or_err, reader_or_kind, final_url = cosmo.FetchStream(...)`, same cast pattern, plus `init.tl:365`: "the raw union isn't narrowed statically as StreamReader (it carries the kind string on failure)" | **3IiG0LQr** (same capture as `Fetch` — identical shape and mechanism) |
| `cosmo.GetCryptoHash` | 2 (unknown/data-driven hash name; internal mbedtls failure path, in practice unreachable given non-null Lua strings) | `tool/net/lfuncs.c:838` | `2754-2760` | `o//tool/lua/lua -e 'local cosmo=require("cosmo"); print(cosmo.GetCryptoHash("bogus-hash","payload"))'` → `nil  unknown hash type: bogus-hash` | `cosmic/hash.tl:103,140` | exact |
| `cosmo.GetHostOs` | 2 (host-platform data: nil only if compiled/run on a platform outside the seven `Is*()` checks) | `tool/net/lfuncs.c:103` | `2774-2776` | `o//tool/lua/lua -e 'local cosmo=require("cosmo"); print(cosmo.GetHostOs())'` → `LINUX` (nil branch unreachable on any of cosmopolitan's own supported hosts — the seven `Is*()` checks are exhaustive for its target matrix) | `cosmic/sys.tl:49-61` explicitly documents and handles the nil branch — "unreachable on shipped fat-binary targets, but the type admits it honestly" — plus unguarded call sites at `cosmic/quicksand/init.tl:145`, `cosmic/sandbox/unveil.tl:81`, `cosmic/sandbox/init.tl:143` | exact — not a tuple deviation: the single-value, no-error-slot return is the correct shape here (nil denotes "unrecognized category," not a failure with a cause), same family as `ParseHost` |
| `cosmo.GetRandomBytes` | 2 (arg-range degenerate case already raises; remaining nil path is a genuine `getrandom()` syscall failure) | `tool/net/lfuncs.c:753` | `2792-2796` | `o//tool/lua/lua -e 'local cosmo=require("cosmo"); print(pcall(cosmo.GetRandomBytes, 0))'` → `false  bad argument #1 to 'cosmo.GetRandomBytes' (not in range 1..4194304)` (degenerate case already raises, not nil) | `cosmic/rand.tl:27` | exact |
| `cosmo.Inflate` | 2 (corrupt/truncated compressed data, size cap, zlib-internal/OOM) | `tool/net/lfuncs.c:1248` | `2833` | `o//tool/lua/lua -e 'local cosmo=require("cosmo"); print(cosmo.Inflate("not compressed data"))'` → `nil  inflate failed: invalid block type` | `cosmic/compress.tl:67` | exact |
| `cosmo.ParseHost` | 2, but nil here is a valid non-error answer ("no port present"), not a failure | `tool/net/lfuncs.c:274` — note: builds an unused two-field table (`lua_newtable` + two `LuaPushUrlView` pushes) before `return 1`; per the Lua C-function calling convention this returns only the last-pushed value (`port`), matching the doc, and the table/host value are computed then discarded (an out-of-scope dead-allocation cleanup, not a contract issue) | `2964-2975` | `o//tool/lua/lua -e 'local cosmo=require("cosmo"); print(cosmo.ParseHost("example.com"))'` → `nil`; `print(cosmo.ParseHost("example.com:8080"))` → `8080` | **zero** — `grep -rn 'cosmo\.ParseHost' cosmic/` returns nothing; the binding is currently unused/unwrapped in cosmic | exact — single-value optional return is the correct shape for a non-error absence |
| `cosmo.ParseIp` | 2 (malformed IPv4 string from external/user data) | `tool/net/lfuncs.c:154` | `2977-2984` | `o//tool/lua/lua -e 'local cosmo=require("cosmo"); print(cosmo.ParseIp("999.999.999.999"))'` → `nil  invalid IP address: 999.999.999.999` | `cosmic/quicksand/proxy/dial.tl:33`, `serve.tl:52,153`, `box/run.tl:198` (`-- assert: literal IP always parses`) | exact |
| `cosmo.ResolveIp` | 2 (DNS failure, timeout, worker-thread create failure, OOM) | `tool/net/lfuncs.c:615` (`LuaResolveIp`), worker/timeout helpers at `lfuncs.c:518-613` | `3074-3079` | `o//tool/lua/lua -e 'local cosmo=require("cosmo"); print(cosmo.ResolveIp("this.host.does.not.exist.invalid", 500))'` → `nil  this.host.does.not.exist.invalid: DNS lookup failed: EAI_Name does not resolve` | `cosmic/quicksand/proxy/dial.tl:40`, `cosmic/ip.tl:149` | exact |
| `cosmo.Slurp` | 2 (ENOENT/EACCES/etc reading real files; mirrors `Barf`) | `tool/net/lfuncs.c:350` | `3102-3109` | `o//tool/lua/lua -e 'local cosmo=require("cosmo"); print(cosmo.Slurp("/no/such/file"))'` → `nil  open /no/such/file: ENOENT: No such file or directory  2` | `cosmic/fs/file.tl:15`, `cosmic/env.tl:334`, `cosmic/script_test.tl:119`, `cosmic/compile_test.tl:127` | exact |
| `cosmo.Strftime` | 2 (pathological/oversized format strings; OOM growing the buffer) | `tool/net/lfuncs.c:199` | `3132-3138` | `o//tool/lua/lua -e 'local cosmo=require("cosmo"); local r,e = cosmo.Strftime(string.rep("%A",100000)); print(r==nil, e)'` → `true  strftime: format "%A%A...` (nil reached) | `cosmic/time.tl:281,307` (fixed literal formats — the nil path isn't reachable from cosmic's own call sites today, only from a caller passing a user-supplied format string) | exact |
| `cosmo.StreamReader:read` | 2 (closed reader, connection failure/reset, truncated response); a second, non-error nil (clean EOF) shares slot 1 but is disambiguated by slot 2's absence, mirroring Lua's own `file:read()` idiom | `tool/net/lfetch.c:550` (`LuaFetchReaderRead`) | `3164-3174` | EOF: `chunk=nil, err=nil`; after `reader:close()`: `chunk=nil, err="reader closed"` (both probed against a live `http://example.com/` fetch, `timeout=8`) | `cosmic/fetch/stream_test.tl` (extensive), `cosmic/fetch/body.tl`, `cosmic/stream.tl:111,284`, `cosmic/stream_example.tl` | exact |
| `cosmo.StreamReader:read_until` | 2, same shape/reasoning as `:read` | `tool/net/lfetch.c:594` (`LuaFetchReaderReadUntil`) | `3189-3192` | same pattern as `:read`, probed together (see `cosmic/fetch/stream_test.tl:150-185` for both EOF and post-close cases) | `cosmic/stream.tl:214`, `cosmic/fetch/stream_test.tl:150,153,175,179,182,185` | exact |

Filed captures: **3IiG0LQr** (`cosmo.Fetch`/`cosmo.FetchStream` dual-shape
return), **3IiG0ga5** (`cosmo.DecodeLua`'s offset-not-errno third slot)
— both attached under this item's parent container,
`--repo whilp/cosmopolitan`.

### Out-of-scope findings (not filed, reported per instructions)

- `cosmo.ParseHost` (`tool/net/lfuncs.c:274`) builds a table via
  `lua_newtable` plus two `LuaPushUrlView` pushes (host, then port)
  before `return 1`. Per the Lua C-function calling convention,
  `return 1` returns only the topmost pushed value (`port`), so the
  table and the host value are computed and then silently discarded on
  every call — a wasted allocation, not a contract or correctness bug
  (the returned value matches the documented `@return string? port`
  exactly). Small cleanup opportunity, unrelated to this census.
- `cosmo.Deflate`'s `level`/`format` option-shape checks
  (`tool/net/lfuncs.c:1202-1210`, `1161`) and
  `cosmo.DecodeBase32`/`EncodeBase32`'s alphabet-length check
  (`tool/net/lfuncs.c:677`) return `nil, err` for what looks like a
  hardcoded-argument mistake (similar in spirit to the `path.join(nil)`
  precedent from #276) — but each binding also has a genuinely
  environmental nil path (zlib-internal/OOM failure, or malloc
  failure) that keeps the whole binding class 2 under this slice's
  classification scheme, so no partial capture was filed. Worth a
  future, finer-grained look if the goal owner wants to split "shape
  errors that should raise" out of otherwise-legitimate class-2
  bindings — but that's a scheme change, not something this slice's
  literal rules authorize.

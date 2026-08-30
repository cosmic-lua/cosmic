## Goal

G5 — adversarial verification. The salvage container's (`3IOCgCWG`)
first child, and the one the port slices cannot be sized without: which
of `test/tool/net/**`'s 38 Lua checks cover ground `tool/lua/test_*.lua`
does not. This is a RESEARCH slice — its deliverables are a recorded
table and the port slices that table makes writable. **No code, and no
pull request.**

## Evidence

Measured 2026-08-26 against cosmic-lua/cosmopolitan `fe7c36c4` (master; the
release cosmic pins as `2026.08.26-fe7c36c4c`), from the repo root.

- **The two sets.**

  ```text
  ls test/tool/net/*.lua | wc -l   # 38
  ls tool/lua/test_*.lua  | wc -l   # 31
  ```

  38 rows to write, 31 files to compare each against. `test/tool/net`
  also holds `redbean_test.c` and `sqlite_test.c`; they are not Lua
  checks and are not rows.

- **The comparison is by reading, not by running.** The lane is in no
  workflow and did not compile until `3c36bc35`; nothing here requires
  building or running `o//test/tool/net`, and this slice does not. The
  redbean-contract files the parent (`3INxo51I`) already retires are
  identifiable from source: `grep -ln 'errno()' test/tool/net/*.lua`
  names six, four of which (`futex_test`, `mapshared_test`,
  `spinlock_test`, `sysconf_test`) the parent recorded as failing on
  exactly that call — `:errno()` is redbean's error object, where this
  fork returns `nil, err:string, errno:integer`.

- **34 of the 38 use bare redbean globals.**

  ```text
  for f in test/tool/net/*.lua; do grep -q require "$f" || echo "$f"; done | wc -l   # 34
  ```

  A file calling `DecodeJson` bare is not automatically a
  redbean-contract file: the fork has the same function at
  `cosmo.DecodeJson`, so the body ports under a prelude. A file
  asserting a shape the fork deliberately replaced (`:errno()`,
  redbean's `UnescapeParam` global, `argon2`'s `variants` field) is the
  genuine `retired` case. The verdict column below is where that call
  gets made, once, per file.

- **The json corpus is the known `none` row.**

  ```text
  wc -l test/tool/net/json*.lua test/tool/net/ljson_test.lua   # 7542 total, 9 files
  wc -l tool/lua/test_data_formats.lua                          # 288
  ```

  `test_data_formats.lua` is the fork's only json test and it is a
  CONTRACT test — array metatables, `NaN`/`Infinity` rejection,
  empty-collection round-tripping (`grep -n json
  tool/lua/test_data_formats.lua`). It is not a corpus test. The 9
  files above are the JSONTestSuite and json.org bodies vendored inline.
  Expect these 9 rows to read `none`; the inventory's job is the other
  29.

- **The wiring mechanism the port slices will name.**
  `tool/lua/BUILD.mk:222-251` is `TOOL_LUA_TESTS`, a hand-written list
  of 29 `o/$(MODE)/tool/lua/test_<name>.ok` stamps; `:259-260` is the
  `.PHONY o/$(MODE)/tool/lua/test` target depending on it; and each
  stamp has its own three-line rule above the list. One rule plus one
  list line per ported file. Read it, do not invent a second mechanism.

## Change

Two deliverables, in order. Neither is code.

**1. Write the inventory table into this item's own spec sidecar.**

Read all 38 `test/tool/net/*.lua` and all 31 `tool/lua/test_*.lua`, then
append one new `## Inventory` section to this spec — after
`## Enablement`, so the five ready-bar sections stay as they are —
holding a markdown table of **exactly 38 rows**, one per Lua file, in
`ls` order, with exactly these four columns and this header:

```markdown
| file | surface | covered by | verdict |
|------|---------|-----------|---------|
| test/tool/net/argon2_test.lua | cosmo.argon2 hash/verify | tool/lua/test_argon2.lua | covered |
```

- **file** — the path, verbatim, starting `test/tool/net/`.
- **surface** — the binding surface it exercises, in a few words
  (`cosmo.DecodeJson conformance corpus`, `cosmo.unix.futex`,
  `cosmo.path.join`). Name the binding, not the test.
- **covered by** — the `tool/lua/test_*.lua` path that already covers
  the same ground, or `—` when none does. When two cover parts of it,
  name both, space-separated.
- **verdict** — exactly one of three literal words:
  - `covered` — `tool/lua/` already exercises this ground. Nothing to
    port.
  - `none` — real coverage that exists nowhere else in the fork. Goes
    on a port slice.
  - `retired` — the file asserts a contract this fork deliberately
    replaced (redbean's `:errno()` object, redbean globals the fork
    namespaces under `cosmo.*` with no equivalent, a `cosmo` module
    redbean does not link). The parent settled that these are dropped,
    not repaired; a row is `retired` only when porting it would
    reproduce a `tool/lua/test_*.lua` that already exists, and the
    `covered by` cell must then name that file.

  A file that merely calls a redbean global the fork has under `cosmo.*`
  is NOT `retired` — the body ports under a prelude that binds the
  names. Judge by the contract asserted, not by the spelling of the
  call.

Write it back with `gitboard spec 3ISCk9jy FILE` from the board
worktree. That commit is the first deliverable and must land before the
second.

**2. File one port slice per coherent group of `none` rows**, as
children of `3IOCgCWG`, each blocked on this item:

```text
gitboard new "<title>" --parent 3IOCgCWG --repo cosmic-lua/cosmopolitan --spec-file F
gitboard block <new id> 3ISCk9jy
```

Group by binding surface, not by file count — the 9 json files are one
slice because they are one corpus and one prelude. Each slice's spec
carries the full five sections, and its `Change` names, per file: the
source path, the destination `tool/lua/test_<name>.lua`, the prelude
lines that bind the redbean globals it uses to their `cosmo.*`
equivalents, and the two `tool/lua/BUILD.mk` edits (the `.ok` rule and
the `TOOL_LUA_TESTS` line). Its `Acceptance` carries
`make -j$(nproc) o//tool/lua/test` plus the stamp-count delta for that
slice. Size each for one session: if a group's `Change` needs the word
"and" between two independent surfaces, cut it in two.

If the inventory finds **zero** `none` rows outside the json corpus,
that is a real result — file the one json slice and say so in the
report. Do not manufacture slices to fill a quota.

## Non-goals

- **No code, and no PR.** Nothing under `tool/lua/`, `test/tool/net/`,
  `tool/net/`, `.github/workflows/**` or any `BUILD.mk` is edited by
  this slice. Its entire output is board state. A diff in
  cosmic-lua/cosmopolitan means the slice was misread.
- **Do not build or run `o//test/tool/net`.** The comparison is a read.
  The lane's pass/fail split is the parent's recorded evidence and is
  not re-measured here.
- **Do not repair, rewrite, or port anything now.** Writing one ported
  file "to prove it works" is the port slice's work, done under its own
  review.
- **Do not delete anything, and do not touch `test/tool/BUILD.mk`.**
  Retirement is `3IOCgtWA`, blocked on the whole container.
- **Do not change any binding.** The `cosmo.*` C boundary,
  `tool/net/definitions.lua`, and every return shape and error string
  are frozen. A test that will not port because a binding differs from
  redbean is a `retired` row and evidence for the table — never a
  reason to move the binding.
- **Do not touch anything in cosmic-lua/cosmic.** No pin bump, no type
  regen, no wrapper change.
- **Do not re-decide the parent's split.** Which checks are
  redbean-contract failures is settled in `3INxo51I`; this table records
  them, it does not relitigate them.

## Acceptance

Every command below runs **from the cosmic-lua/cosmopolitan repo root**,
after setting two variables once — `ID` is this item's full ksuid and
`BOARD` is the board worktree of the cosmic checkout:

```text
ID=3ISCk9jyvgHUio3gPwQuZkSURUB
BOARD=<cosmic checkout>/o/board
SPEC="$BOARD/items/$ID.md"
```

- `git status --porcelain` prints nothing — this slice writes no file in
  cosmic-lua/cosmopolitan.
- `grep -c '^| test/tool/net/' "$SPEC"` prints `38`.
- Every row's file exists and every file has a row — no output:

  ```text
  diff <(grep -oE '^\| test/tool/net/[a-z0-9_]+\.lua' "$SPEC" | sed 's/^| //' | sort) \
       <(ls test/tool/net/*.lua | sort)
  ```

- Every verdict is one of the three words, and they sum to 38:

  ```text
  grep -cE '\| (covered|none|retired) \|$' "$SPEC"   # 38
  ```

- Every `tool/lua/test_*.lua` named in a `covered by` cell exists — no
  output:

  ```text
  grep -oE 'tool/lua/test_[a-z0-9_]+\.lua' "$SPEC" | sort -u \
    | while read -r f; do test -f "$f" || echo "MISSING $f"; done
  ```

- Every `covered` and `retired` row names a file in `covered by` (only
  `none` rows may hold `—`):

  ```text
  grep -E '\| (covered|retired) \|$' "$SPEC" | grep -c '| — |'   # 0
  ```

- The 9 json rows read `none`:

  ```text
  grep -E '^\| test/tool/net/(json|ljson)' "$SPEC" | grep -c '| none |'   # 9
  ```

- **The port children exist, one per group, each blocked on this
  item** — this corrects a spec bug found 2026-08-30: `gitboard tree`
  and `gitboard check` are not real verbs (`gitboard help` lists only
  `init, new, attach, compare, block, unblock, set, spec, next, take,
  drop, verdict, done, show, sync`), so the two bullets that named them
  could never be satisfied as written. The board is a git checkout of
  committed item files, so both facts are readable directly, from the
  board worktree (`$BOARD`):

  ```text
  grep -l '\["parent"\] = "3IOCgCWG"' "$BOARD"/items/*.tl
  ```

  lists one file per port-child group filed here, and each listed
  child's `.tl` file carries a `["blocked_by"]` entry naming this
  item's id (`3ISCk9jyvgHUio3gPwQuZkSURUB`):

  ```text
  grep -l '3ISCk9jyvgHUio3gPwQuZkSURUB' "$BOARD"/items/*.tl
  ```

  — the intersection of the two listings is every port child, and each
  passes its own ready bar when `"$BOARD"/o/bin/gitboard show <id>`
  prints no `bar:` line (a `bar:` line is exactly how `show` reports a
  spec-bar problem — its absence is the pass).
- The port children's `Change` sections collectively name every `none`
  row exactly once. Quote that count in the report beside
  `grep -c '| none |' "$SPEC"` and show they agree.

## Enablement

none needed. Both comparison sets are in the tree and readable
(`ls test/tool/net/*.lua`, `ls tool/lua/test_*.lua`); the wiring
mechanism the port slices must name is `tool/lua/BUILD.mk:222-260`,
read there, not invented; the three-verdict vocabulary and the
`retired` test are defined in `## Change` above rather than left to
judgment; and the parent (`3INxo51I`) carries the decision this table
records. Conventions are cosmic-lua/cosmopolitan's AGENTS.md. The
ready-bar form for the port slices this one files is `decompose.md`.

## Inventory

| file | surface | covered by | verdict |
|------|---------|-----------|---------|
| test/tool/net/argon2_test.lua | cosmo.argon2 hash_encoded/verify via the removed numeric `variants` table | tool/lua/test_argon2.lua | retired |
| test/tool/net/base64_test.lua | cosmo.EncodeBase64/DecodeBase64 RFC 4648 padding vectors | — | none |
| test/tool/net/clearenv_test.lua | cosmo.unix.clearenv / cosmo.unix.environ | — | none |
| test/tool/net/daemon_test.lua | cosmo.unix.daemon | — | none |
| test/tool/net/encodejson_test.lua | cosmo.EncodeJson pretty-print, indent, maxdepth, cyclic-table refusal | tool/lua/test_data_formats.lua | none |
| test/tool/net/encodelua_test.lua | cosmo.EncodeLua default-mode number/table spelling, pretty-print, cyclic/maxdepth placeholders | tool/lua/test_data_formats.lua | none |
| test/tool/net/execvp_test.lua | cosmo.unix.execvp / execvpe / fexecve success paths | tool/lua/test_unix_proc.lua | none |
| test/tool/net/futex_test.lua | cosmo.unix.mapshared futex-based mutex (wait/wake); reap loop calls `:errno()` | tool/lua/test_unix_errno.lua | retired |
| test/tool/net/getlogin_test.lua | cosmo.unix.getlogin | — | none |
| test/tool/net/jsonorg_fail_test.lua | cosmo.DecodeJson conformance corpus (json.org fail cases) | — | none |
| test/tool/net/jsonorg_pass_test.lua | cosmo.DecodeJson conformance corpus (json.org pass cases) | — | none |
| test/tool/net/jsontestsuite_fail1_test.lua | cosmo.DecodeJson conformance corpus (JSONTestSuite n_ group 1) | — | none |
| test/tool/net/jsontestsuite_fail2_test.lua | cosmo.DecodeJson conformance corpus (JSONTestSuite n_ group 2) | — | none |
| test/tool/net/jsontestsuite_fail3_test.lua | cosmo.DecodeJson conformance corpus (JSONTestSuite n_ group 3, deep-nesting stress) | — | none |
| test/tool/net/jsontestsuite_fail4_test.lua | cosmo.DecodeJson conformance corpus (JSONTestSuite n_ group 4) | — | none |
| test/tool/net/jsontestsuite_okay_test.lua | cosmo.DecodeJson conformance corpus (JSONTestSuite i_ implementation-defined cases) | — | none |
| test/tool/net/jsontestsuite_pass_test.lua | cosmo.DecodeJson conformance corpus (JSONTestSuite y_ cases) | — | none |
| test/tool/net/lfetch_test.lua | cosmo.Fetch HTTP proxy (CONNECT tunneling, Proxy-Authorization, http_proxy env) plus extended redirect/SSRF/status/timeout coverage | tool/lua/test_fetch_local.lua tool/lua/test_fetch_unix_proxy.lua | none |
| test/tool/net/lfetchstream_test.lua | cosmo.FetchStream malformed-chunked-encoding edge cases and SSE-style event parsing | tool/lua/test_fetch_local.lua | none |
| test/tool/net/lfuncs_test.lua | cosmo Encode*/Decode*/Escape*/ParseUrl/GetMonospaceWidth/IP-classify/Crc32/Deflate value-correctness against known vectors | tool/lua/test_definitions_conformance.lua | none |
| test/tool/net/ljson_test.lua | cosmo.DecodeJson error-message vocabulary, integer/float overflow spelling, UTF-16 surrogate handling, depth cap | tool/lua/test_data_formats.lua | none |
| test/tool/net/lre_test.lua | cosmo.re compile/search via the removed `re.Errno` userdata error object | tool/lua/test_re.lua | retired |
| test/tool/net/lua_test.lua | Lua VM syntax extensions (binary/octal numeral literals, `*` string-repeat, `%` string-format operators) plus the redbean-only `ProgramContentType` global | — | none |
| test/tool/net/lunix_test.lua | cosmo.unix pledge sandbox enforcement, dup/dup2, gmtime, ranged open/fstat/ftruncate/lseek/read/write, copy_file_range, opendir/getdents | tool/lua/test_signal.lua tool/lua/test_unix_proc.lua | none |
| test/tool/net/mapshared_test.lua | cosmo.unix.mapshared cross-process atomics (xchg/cmpxchg/fetch_add/fetch_xor/fetch_and/fetch_or); reap loop calls `:errno()` | tool/lua/test_unix_errno.lua | retired |
| test/tool/net/path_test.lua | cosmo.path.dirname/basename/join value-correctness across edge cases | tool/lua/test_definitions_conformance.lua | none |
| test/tool/net/readlink_test.lua | cosmo.unix.readlink relative-path resolution and bufsiz clamping | — | none |
| test/tool/net/setenv_test.lua | cosmo.unix.setenv overwrite semantics | — | none |
| test/tool/net/sha_test.lua | cosmo.Sha256 / cosmo.GetCryptoHash sha256 known-answer vectors (RFC 6234) | tool/lua/test_crypto_hash.lua | covered |
| test/tool/net/slurp_test.lua | cosmo.Slurp start/end substring-range reads | tool/lua/test_slurp_barf.lua | none |
| test/tool/net/spinlock_test.lua | cosmo.unix.mapshared xchg-based spinlock, cross-process counter contention; reap loop calls `:errno()` | tool/lua/test_unix_errno.lua | retired |
| test/tool/net/sqlite_test.lua | cosmo.lsqlite3 Database:readonly() / Statement:readonly() | — | none |
| test/tool/net/sysconf_test.lua | cosmo.unix.sysconf SC_* queries; failure path calls `:errno()` | tool/lua/test_unix_errno.lua | retired |
| test/tool/net/tcattr_test.lua | cosmo.unix.tcgetattr / tcsetattr termios | — | none |
| test/tool/net/uname_test.lua | cosmo.unix.uname | — | none |
| test/tool/net/unsetenv_test.lua | cosmo.unix.unsetenv | — | none |
| test/tool/net/uuidv4_test.lua | cosmo.UuidV4 format/version/variant | tool/lua/test_uuid.lua | covered |
| test/tool/net/uuidv7_test.lua | cosmo.UuidV7 format/version/variant | tool/lua/test_uuid.lua | covered |

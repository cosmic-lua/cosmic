# API review, 2026-08: the whole surface, after the charter

- **scope:** every public `cosmic.*` module and the markdown docs, reviewed against
  D20 (naming charter), the honest-nil doctrine, and the brief "remove docs by
  improving the code." Backwards compatibility deliberately ignored (D10).
- **method:** eight parallel full-text audits (fs/streams, network, system, data,
  containment, CLI/observability, dev-tooling, docs), findings verified against
  call sites. Everything below carries file:line evidence in the section it names.
- **relationship to prior waves:** D20 landed the mechanical renames and the
  `api-review-N` semantic redesigns landed for `url`, `zip`, `net`, `tty`, `syslog`,
  `time`, `shm`, `check`. This review's headline is what those waves reveal in
  aggregate: **every wave stopped mid-family**, and the eleven data modules
  (`json`, `codec`, `hash`, `rand`, `re`, `string`, `table`, `fuzzy`, `html`,
  `sqlite`, `uuid`) carry zero `api-review-N` markers — they have never been
  through review at all.

## The six findings that organize everything else

### F1 — the type system still lies in ~15 places (D3 violations)

The anchor promise is "types never lie." Live counterexamples, worst first:

1. `fetch.Result` declares `status`/`headers`/`body` non-nil; all three are nil on
   every failure (`fetch/init.tl:32-50`, `:186-192`) — its own test asserts the nils
   (`fetch/init_test.tl:76-82`). `net/init.tl:218-229` records fixing this exact bug
   in `listen_tcp`; `fetch` never got the fix.
2. `re.gmatch` is declared `MatchIterator, string` but returns `nil, err` on a bad
   pattern (`re.tl:292-296`) — `for m in re.gmatch(t, p) do` type-checks and crashes.
3. `net.Socket.fd: integer` is set to nil on close (`net/socket.tl:57`, `:147`);
   ~15 internal guards and a six-line doc in `poll.tl:4-9` exist to manage it.
4. `child.Handle:try_wait` returns `nil, nil` for "still running"
   (`child/init.tl:53`) — the tuple-with-a-hole shape the tree already retired in
   `proc.WaitResult`, `rusage.Rlimit`, `signal.PrevAction`, `shm.Cmpxchg`.
5. `child.run` is declared infallible with the error folded into
   `Result.spawn_error` — and **72 call sites wrap it in `check.must`**, a no-op,
   including the module's own example (`child/init_example.tl:10`). The tree does
   not believe the signature.
6. `errno.name_of(msg): string` returns nil on no match (`errno.tl:84-86`);
   its own `@return` tag says `string?`. `getopt.Parser.next: string, string`
   returns nil when done (`getopt.tl:52`, `:179`).
7. `time.clock_gettime(clock?): integer, integer` returns `nil, err` on a bad
   clock id (`time.tl:34-37`) — the same bug `proc/rusage.tl:25-26` documents fixing.
8. `hash.verify_password` and `re.test` both return `false` for two different
   things (mismatch vs malformed input / bad pattern) — `boolean, string` used
   where the doctrine's `boolean | nil, string` is exact (`hash.tl:206`,
   `re.tl:161`).
9. `sqlite`: `query_value(): any, string` folds no-row / SQL NULL / error into
   two slots (`sqlite/extras.tl:41-43` documents the ambiguity); `changes()` and
   `last_insert_rowid()` return 0 when the db is closed (`init.tl:398-410`);
   `Statement:values()` silently drops any row whose first column is NULL —
   documented as unfixable (`init.tl:55-62`) while `extras.tl:55-59` routes around
   it internally.
10. `records.parse_counts` uses a `-1` sentinel (`records.tl:180`); `records.row`
    uses 0 and negative as two different "absent" markers (`records.tl:133-134`).
11. `rand` is fallible end to end (`rand.float(): number | nil, string` cannot
    fail) while `uuid.v4()` draws from the same CSPRNG and returns bare `string` —
    one of the two modules is wrong about the same operation.
12. `fs.Dir:read` on a closed dir returns bare nil = clean EOF (`fs/init.tl:29-33`);
    `fd.Handle:read` returns `nil, "handle closed"`. Same family, opposite answers.
13. `flags.Dispatched.command`/`.parsed` are documented nil on help/version and
    typed non-nil (`flags/types.tl:77-88`).
14. `json.decode("null")` returns `nil, nil` — success indistinguishable from
    failure by the doctrine's own guard; the module teaches `if err` instead
    (`json_example.tl:48-51`).

**Charter amendment that prevents recurrence (proposed rule 11):** *a multi-value
return whose last slot is an error returns a record, never a tuple with holes; the
error must be reachable from `local v, err = ...` and from `check.must`.* The four
modules that already fixed this each recorded the reason in a local doc comment;
one rule replaces four archaeologies.

### F2 — one concept, many spellings

The failure D20 was written to end — "every call site a guess" — still holds
wherever a concept crosses a module boundary:

- **Installing a containment policy** is `sandbox.apply(policy)`,
  `pledge.apply(promises, opts)`, `landlock.restrict(opts)`,
  `unveil.allow(path, perm) + unveil.commit(opts)` — four verbs, four permission
  vocabularies (`ro/rw/exec` lists vs a 15-member string enum vs OR'd integers vs
  a 23-member promise enum). In `sandbox.Policy`, `fs.exec` is a list of paths and
  `sys.exec` is a promise string, on adjacent lines (`sandbox.tl:48,57`).
- **"Is it available"** is `available(): boolean` in three modules,
  `available(): Availability` (a record, always truthy) in the facade,
  `capabilities()`, `is_supported()`, and `supported()` in quicksand —
  `if not X.available()` is correct four times and silently wrong once.
- **Walking the filesystem** is `walk`/`find`/`find_iter`/`find_info`/`glob` —
  five contracts differing in path convention, result shape, sorting, options,
  and error channel (`fs/walk.tl:126,201,238,287,382`), plus a "partial error in
  slot 2" convention that makes the universal `if err then return nil, err end`
  idiom wrong for four functions.
- **Emitting a structured line** is four grammars: `log` (`%q`-quoted key=value),
  `instrument` (percent-escaped key=value), `syslog` (no fields at all), `records`
  (icons). `log` says `warn`; `syslog` says `warning`; both export a type named
  `Level`.
- **The fd variant of a function** is spelled `fstat`, `fdopendir`, and
  `set_times_fd` — three schemes in one module (`fs/init.tl:267,276,306`) — and all
  take raw integers while `cosmic.fd` exists to wrap them.
- **(source, destination)** is `copy(src, dst)`, `rename(oldpath, newpath)`,
  `link(existingpath, newpath)`, `symlink(target, linkpath)` in one file, with
  `link` and `symlink` printing their error arrows in opposite directions
  (`fs/ops.tl:152,165`).
- **Splitting a string**: `str.split("", sep)` yields zero fields, `re.split("", p)`
  yields one; `str.contains(s, "")` is true while `str.count(s, "")` is 0.

### F3 — every rename wave stopped mid-family

The transition protocol works; what is missing is a completeness check per family:

- `fs`: `make_dirs`/`remove_all`/`temp_dir` (English) landed beside `mkdir`,
  `rmdir`, `chdir`, `unlink`, `chmod`, `opendir`, `realpath`, `lstat` — ~20 POSIX
  spellings in a battery module the charter names as the exemplar (rule 4).
- `zip` renamed `Reader`/`Writer` to `Archive`/`Builder`; `fetch.Reader` — the only
  remaining rule-10 violation on the reserved names — was missed
  (`fetch/init.tl:108`).
- `listen_tcp` folded its positional into `ListenOptions` (api-review-6);
  `listen_unix(path, backlog?)` kept it (`net/init.tl:81`). `connect_unix` got no
  options at all.
- `fetch.timeout` became `timeout_ms`; `maxresponse` sits beside it un-renamed
  (`fetch/init.tl:81`).
- `child.spawn` was retired (D20); the module doc, `Options` doc, error strings,
  and `child/fast.tl:1` still say "spawn" seven times, and rule 9's `start` has no
  `stop` partner (the verb is `kill`).
- `net.dial` is the documented stable contract with **zero** in-tree callers;
  everything calls `connect_tcp`, which `dial` subsumes (`net/init.tl:167-191`).
- `check.eq`/`ne`/`ok` — rule 1's headline case in the single most-imported test
  module.
- `shm` (`mapshared`, `xchg`, `cmpxchg`) and `tty` (`getattr`, `winsize`,
  `noecho`, `getpass`, `openpty`) were never anglicized despite being outside
  rule 4's syscall-shaped allowlist.
- `errno` — required by 35 modules — uses `wrap` to mean *format* (colliding with
  rule 5's reserved `wrap`), bare `is` (a Teal keyword), and `code`/`name_of` as
  false inverses (one maps name→int, the other searches a message).

### F4 — the public surface is inflated by the visibility lint, not user need

D19's stated premise — "the strip floor forces `teal`, `format` and `doc` under
`cosmic/`" — is factually wrong for two of the three. The stripped boot chain is
`embed/init.tl:183-188` → `searcher.tl:60-66` → (optional) `teal.tl` and touches
nothing else; meanwhile `format/init.tl:6`, `example.tl:4`, and
`coverage/lines.tl:8` hard-`require("tl")` at load, so they **cannot run in a
stripped artifact at all** — they are dead payload shipped by the floor. What
actually forces ~7 tooling modules public is the D19 lint (`_cli`/`_make` may not
require internal shards). Amend D19 to grant the toolchain an internal tree, and
`testrun`, `records`, `style`, `example`, `benchmark`, coverage's ratchet half,
and `doc`'s extraction half leave the public API — ~7 module names and ~40
functions — with zero user-visible change, because every one is reached through
`--make`/`--check`/`--docs`.

Whole-module questions, decided by call-site evidence:

- `cosmic.flags` has **zero in-tree callers**; every internal parser hand-rolls
  `getopt` (24 `LongOpt` records in `_cli/args.tl`). Two public arg parsers, the
  higher-level one unproven — port the dispatcher onto `flags` and internalize
  `getopt`, or delete `flags`. Shipping both is the worst option.
- `cosmic.envd` is four exports: a constant-argument alias, a parser missing its
  rule-6 `format` half, and two zero-caller helpers — fold into `env`.
- `cosmic.syslog` is one function with no fields, no lifecycle, and a conflicting
  `Level` — fold into `log` as an output sink (log's own header already frames it
  as a destination).
- `cosmic.table` has zero in-tree callers, reserves five names for a battery
  nobody asked for, and documents its own name collision as the caller's problem —
  keep `deep_copy`/`deep_equal`/`deep_merge` somewhere, drop `map`/`filter`/`reduce`.
- `cosmic.style` is one function whose name collides with `ansi`'s job and whose
  header advertises two checks that no longer exist — rename to `cosmic.lint` or
  fold into `_cli/lint.tl`.
- Containment: internalize `pledge`/`unveil`/`landlock` behind `sandbox` (with
  `handled`/`no_new_privs` escape hatches so no capability is lost); `quicksand`
  stays as the out-of-process axis. G2 wants one boundary, not four declinable
  libraries. On Linux, `unveil` is already unreachable through the facade.
- ~25 zero-caller exports (verified): `proc.posix_spawn`/`posix_spawnp`,
  `time.clock_gettime`/`is_leap_year`/`days_in_month`, `env.clear`,
  `sys.normalize_host_os`/`sysconf`+7 `SC_*`/`nproc_configured`, `user.setfsuid`,
  `tar.unsafe_path`, `fs.major`/`minor`/`ext`, `coverage.reset`, `doc.load_index`,
  `style.DEFAULT_COLUMN_WIDTH`, `searcher.searcher`/`tree`, `getopt.new`+`Parser`,
  `hash.hmac_sha256`, `check.enforcing`/`enforce_skip`/`enforced` (the doc says
  "NOTHING SETS IT YET"), `url.escape_literal`/`escape_ip`/`escape_user`/
  `escape_pass`, `net`'s 12 `POLL*` re-exports. D19 §3's own rule: an export with
  no callers is deleted, not documented.

### F5 — docs that a code fix deletes

The project already has the policy (issue #949: a gotcha entry is a stopgap; the
fix is code). Applying it to the whole doc surface:

- The two hand-maintained 58-row module tables (`AGENTS.md`, `docs/stdlib.md`)
  restate what `--docs` generates from module headers, and have drifted (`codec`,
  `hash`, `rand`, `env` descriptions are stale). `_docs/derive.tl` already has the
  derived-region + gate machinery; add `modules_table()` — or delete `stdlib.md`'s
  copy outright (it is unpublished, unembedded, and ungated; its `child.run`
  example doesn't type-check against the current API).
- `skills/cosmic/checking.md` and `gotchas.md` — which SHIP in the binary — cite a
  cast-ratchet file (`_build/casts.txt`) that does not exist, and contradict
  AGENTS.md on `fs.Stat` narrowing. The gotchas guide is 47% "retired" tombstones.
- Warning docs that are signature bugs: the walk visitor's "do NOT join path and
  name" appears **four times** (`fs/walk.tl:106,477`, `fs/init.tl:328`,
  `walk_example.tl`) — pass an `Entry` record instead; `find_iter`'s five-line
  error-retrieval recipe (`walk.tl:366-375`) — fix the error channel;
  `poll`'s `err()` sidecar and its explanation (`poll.tl:56-62`) — return the
  ready set; `temp_fd`'s matched pair of "how to wrap this raw int" notes
  (`fs/init.tl:230`, `fd.tl:257`) — return a Handle; sse's identical six-line
  narrowing workaround printed twice (`sse.tl:22-33`, `:68-80`) — fix the yield
  shape; `compress`'s "rejects auto at runtime" paragraph — split the enum.
- Dead-API docs: `zip.tl:3-7` module header documents four deleted functions
  (`reader`/`writer`/`appender`/`from`) and a `@param` names the retired `Reader`
  type; `walk_example.tl` demonstrates retired `collect()`/`files()`;
  `shm.tl:259-261` argues against a signature the code no longer has;
  `box/merge.tl:9` lists a field that now raises a migration error.
- ~50 `api-review-N` / "the old shape did X" archaeology notes in shipped doc
  comments (`net`, `zip`, `fs`, `stream`, `compress`, `url`, `ip`, `tty`,
  `testrun`, `check`, `literal`, `embed`, `doc`). History belongs in decisions,
  not in `@return` tags.
- Five copies of the IPv6 status, five of the error-doctrine table, three of the
  find-needle rule, two hand-typed verb/vocabulary lists in `sys/help.md` that
  drift from the registries that already render them.

### F6 — bugs found incidentally (fix regardless of any rename)

1. `fs.write`'s `mode` silently does nothing when the file exists (`Barf`
   semantics). `zip.extract` works around it with a chmod whose error is
   discarded (`zip.tl:220-221`); `tar.extract` doesn't — the two extractors
   disagree on the permissions of the same input. Fix in `fs.write`; both docs
   and the workaround delete.
2. `quicksand.Box.merge` merges `proc.keep_caps` **by index** (missing from the
   list schema, `box/merge.tl:25-36`): merging `{CAP_A,CAP_B}` with `{CAP_C}`
   yields `{CAP_C,CAP_B}` — silently retaining a capability nobody granted. No
   test covers it.
3. **The example gate's output verification is dead — confirmed by running it.**
   The gate feeds the runner the *compiled* Lua (`embed/cosmic.mk:190`:
   `--check example $<` where `$<` is `o/%.lua`), and the Teal compiler strips
   comments, so `example.tl:117-121`'s "no expected output specified → skip"
   branch fires for every example: all 102 `-- Output:` blocks across 33 example
   files are silently skipped ("SKIP (no output check)"), and the stage reports
   PASS. The smoking gun that exposed it: `shm_example.tl:44-50` destructures
   `cmpxchg`'s record return as the retired tuple and expects `true 7 8`; the
   real call returns a table (verified: prints `table: 0x…  nil`), yet
   `--make example cosmic/shm_example.tl` passes. Fix: point the example stage at
   the `.tl` source (the runner already compiles bodies itself), then fix
   `shm_example.tl` and whatever else the revived gate catches.
4. Requiring `cosmic.child` sets SIGPIPE to SIG_IGN process-wide at module load
   (`child/io.tl:19`) — a global side effect of an import, documented rather than
   scoped.
5. `poll` retries EINTR by reissuing the full `timeout_ms` — the effective wait
   is unbounded under signals; documented three times instead of computing a
   deadline once (`child/io.tl` and `shm.tl` already do it right).
6. `sqlite.transaction`'s callback is `function(Database): any...` — returning
   `0`, `""`, a table, or bare `nil` **commits**; only literal `false` or
   `nil, err` rolls back (`extras.tl:86`). The most consequential return value in
   the module is unchecked.
7. `fetch`'s retry table is declared total over `ErrorKind`, but wrapper-side
   validation failures carry a nil kind that indexes past the totality guarantee
   (`fetch/init.tl:226,247`).
8. `zip.open` can fail with an error string containing no path; `zip.tl:167`
   ignores `list()` failure, extracting an empty archive "successfully";
   `fs.copy` discards both close errors (ENOSPC surfaces at close).
9. `child`/`benchmark`/`_perf` each re-derive monotonic ms/ns privately —
   `child`'s copy runs deadlines in floats. Add `time.monotonic_ns()`; delete
   three private clocks.
10. `shm.tl:135-140` and `signal.tl:263-266` document upstream binding bugs
    (write's argument-order annotation; sigaction's nil-slot handling) — fix in
    whilp/cosmopolitan `definitions.lua` per D5, then delete the workarounds.

## Ranked plan

Phase 1 — honest types (F1): fetch.Result reshape; child.run/try_wait; re.gmatch;
Socket.fd method; errno.name_of/getopt nils; verify_password/re.test to
`boolean | nil, string`; sqlite query_one/query_value/changes; rand↓ or uuid↑.
Phase 2 — incidental bugs (F6), each small and testable.
Phase 3 — one-concept-one-spelling (F2): containment consolidation; fs find
family; structured-line grammar; errno renames (35 dependents, do early);
`is_available()` everywhere.
Phase 4 — finish the stopped waves (F3): fs anglicization; zip constructors;
dial absorbs connect_tcp; check.equal/not_equal/truthy; shm/tty renames;
child spawn→start sweep.
Phase 5 — surface reduction (F4): D19 amendment + internalization; flags-vs-getopt
decision; envd/syslog/table/style folds; zero-caller deletions.
Phase 6 — docs (F5): generated module tables; skills corrections; archaeology
sweep; delete every warning the phases above made unnecessary.

Charter amendments to record: rule 11 (record-not-tuple, F1); rule 3 carve-out
(`starts_with`/`ends_with`/`contains`); rule 6 discriminator (encode/decode for
named wire formats, parse/format for structured text — so `json` is sanctioned
and `codec.encode_lua` is not); rule 4 clarification (a syscall-shaped module
marks its non-syscall members; `net` picks one convention); D19 §1 correction;
a D22 recording that `cosmic.check` alone may throw and `os.exit`.

## Postscript: the finding to act on first

F6.3 is the one item here that was verified by execution, not just by reading:
the example gate — the flagship mechanism of "documented behavior is verified
behavior" — has not been checking any documented output. Every drifted example
this review found (shm's tuple destructure, walk_example's retired
`collect()`/`files()`, the doc examples in stdlib.md) survived because the gate
that owns them went quiet. Reviving it (run examples from `.tl` source, not
compiled Lua) is small, independent of every rename above, and re-arms the gate
that would have caught much of this review automatically.

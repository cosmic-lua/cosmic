# D20 — the naming charter, and the renames that applied it

- **date:** 2026-08
- **context:** the API review found five or six *competing
  internally-consistent* naming conventions on the public surface, not
  random names: POSIX spellings beside English ones (`makedirs` /
  `write_atomic`), three spellings of milliseconds, `is*` predicates
  in two shapes, PascalCase constructors that collide with type
  exports. Each was locally defensible; together they made every call
  site a guess. The pre-1.0 window (D10) is the one time renames are
  cheap.
- **decision:** the rules below (ten at first writing; rule 11 added
  2026-08, #1006). New code follows them; a deviation is a bug.
  1. `snake_case`, words spelled out; no new abbreviations.
     `PascalCase` is for record TYPES only — no PascalCase functions;
     constructors are lowercase (`signal.sigset()`; `Sigset()` is
     retired).
  2. Units live in the identifier: `_ms`, `_kb`, `_bytes`. Durations
     are integer milliseconds.
  3. Predicates are `is_*` (`fs.is_file`, `poll:is_empty`);
     object-state getters are bare participles (`h:closed()`). Named
     carve-out (#1006): `starts_with`/`ends_with`/`contains` on
     `cosmic.string` keep their cross-language spellings — every
     mainstream string API spells them so — and predicates are `is_*`
     everywhere else, which is why `re.is_match` and
     `hash.is_equal_constant_time` sit correctly beside them.
  4. Getters are bare nouns (`sys.nproc()`, `fs.cwd()`); `get*/set*`
     prefixes survive only in syscall-shaped modules (`proc`, `user`,
     `signal`), which keep POSIX names wholesale. Battery modules use
     English: `fs.make_dirs`, `fs.remove_all`, `fs.temp_dir`.
     Additions (#1006): a syscall-shaped module marks its non-syscall
     members with a section header (`proc.which`/`interpreter`/
     `is_main` sit under one), so the wholesale-POSIX license visibly
     stops where the battery half starts; `net` is declared NOT
     syscall-shaped — its verbs follow the battery rules. The fs
     kept-POSIX set is the amended section below.
  5. Constructors: `open` = acquires a closeable resource; `new` =
     pure in-memory object; `wrap` = adopts an existing raw resource.
  6. `parse`/`format` for text↔value; `encode`/`decode` for
     representation change; `escape`/`unescape` for syntax safety.
     Every pair ships both halves or documents why not. The file
     variant is `<verb>_file` (`literal.parse`/`parse_file`).
     The discriminator (#1006): `encode`/`decode` when the target is a
     named wire format the world already calls encoding — JSON,
     base64, hex — so `json.encode`/`json.decode` are sanctioned;
     `parse`/`format` when reading a structure out of text — URL,
     time, literal, IP. `re.gmatch`/`re.gsub` are deliberate Lua
     mirrors, recorded as such, not rule-9 verbs.
  7. Options records are named `Options` (or `<Thing>Options` when a
     module has several); the argument is named `opts`. Named
     exemption (#991): `flags.Spec` — a CLI interface declaration is
     genuinely not a kwargs bag, and its flag list is `Spec.flags`
     ({Flag}), not an Options record.
  8. `verb_noun` order: `hash.hash_password`, `hash.verify_password`.
  9. Reserved verbs, one meaning tree-wide: `run` = execute a
     program/callback; `match` = pattern match; `query` = index/db
     lookup. Lifecycle: `start`/`stop` for toggleable state
     (`child.start`), `begin`/`finish` for spans (`instrument`).
  10. Every type in a public signature is exported (`type X = X`);
      `Reader`/`Writer` are reserved for the `cosmic.stream` contract.
  11. (added 2026-08, #1006) A multi-value return whose last slot
      would be an error returns a RECORD instead: the error must be
      reachable from `local v, err = ...` and from `check.must`, so a
      tuple never carries it in slot 3 or beyond. `proc.WaitResult`,
      `proc.Rlimit`, `signal.PrevAction`, and `shm`'s `Exchange` are
      the shape; this rule replaces the four per-site justifications
      they carried. **Enforced since #1063**, as the `fallible-returns`
      lint: a function whose FIRST declared return admits nil (`T |
      nil`, or `any`) declares at most two slots. That is the
      mechanical stand-in for "the last slot would be an error" — nil
      in slot 1 is what makes `local v, err = f()` the calling
      convention, and an infallible tuple like `string.partition`
      keeps its three slots because no slot of it could be an error.
      A foreign shape — a `cosmo.*` binding's tuple, decided in C, or
      a Teal record describing one — carries a `-- returns: <reason>`
      marker instead. Because the rule lives in the linter rather than
      in a ratchet over this repo's surface, it holds for every project
      cosmic builds, which is the point: a caller who has learned the
      two-slot call shape may write it at every cosmic call site,
      including the ones in their own code.
- **the transition:** the pinned cosmic that cold-starts a build
  EXECUTES tree tooling (`_cli`/`_make`/…) against its own embedded,
  pre-rename `cosmic.*` modules, so a rename cannot be atomic: renamed
  modules carry typed DEPRECATED aliases under the old names, and
  tooling keeps calling the old names, until a release carrying the
  new names becomes `bin/cosmic.pin`. Then a cleanup change flips
  tooling to the new names and deletes the aliases. That cleanup
  landed with the 2026-08-05 pin advance: the aliased set —
  `fs.isfile/isdir/islink/makedirs/rmrf/copytree/getcwd/mkdtemp/
  tmpfile/tmpfd/collect/collect_all/files`, `tty.isatty` and the three
  per-stream wrappers, `zip.reader/writer/appender/from` and the
  `Reader`/`Writer` type aliases, `child.spawn`, `embed.run`,
  `doc.run`, `literal.of_source/of_file`, `proc.commandv` — is gone,
  and tooling calls the charter names everywhere. The protocol above
  remains the template for any future public rename, with one
  amendment (#1006): a rename wave's PR lists, explicitly, the family
  members it does NOT rename. Every wave so far missed a sibling the
  next review had to catch — `listen_unix` beside `listen_tcp`, zip's
  reader beside `fetch.Reader`, `maxresponse` beside `timeout_ms` —
  and the omission was invisible precisely because nothing required
  naming it.
- **the kept-POSIX set (amended 2026-08, #988):** operations are named
  in English, and the POSIX names that survive are the
  effectively-English concepts — a closed, recorded carve-out, not a
  per-call-site judgment: `stat` (and its `stat_link`/`stat_fd`
  variants, which spell HOW they stat), `statfs`, `symlink`,
  `readlink`, `truncate`, `dirname`, `basename`. Everything else on
  `cosmic.fs` spells the operation out: `make_dir`, `remove_dir`,
  `remove`, `open_dir`, `open_dir_fd`, `set_cwd`, `set_mode`,
  `set_owner`, `resolve`, `sync_all`; fd variants standardize on the
  `_fd` suffix. `access` folded into `is_present`/`is_accessible`
  (rule 3). Rule 4's syscall-shaped exemption (`proc`, `user`,
  `signal`) is unchanged.
- **consequences:** the rename wave landed in two parts — the
  mechanical applications of rules 1–4 and 8–9 (this record), with the
  semantic redesigns (re subject-first argument order and match/find
  family, zip `Archive`/`Builder`, url escape family, syslog `Level`
  enum, tty `is_tty` consolidation, net dial options, fs find/find_iter)
  following separately. Renames not yet applied are tracked there, not
  relitigated per-file. Two error-shape carve-outs recorded in their
  own files bound rule 11 and the never-throw doctrine:
  [D22](d22-infallible-csprng.md) (the CSPRNG's deliberate
  crash-on-failure) and [D23](d23-check-throws.md) (`cosmic.check`
  alone may throw).
- **applying rule 11 (2026-08, #1063):** enforcing it cost seven public
  signatures, each of which had put something real past slot 2. The
  find family (`fs.find`/`find_info`/`glob`) and `fs.visit` carried
  their subtree-error list in slot 3; it moved onto the result as
  `.errors`, and `Found` keeps the path list as the record's ARRAY
  part so `ipairs`/`#`/`table.sort` still work on it. `fs.find_iter`
  carried a to-be-closed guard in slot 4; the iterator became the
  closeable handle instead (`__close`, `iter:close()`), the shape
  `sqlite.Rows` already had — so a loop that exits EARLY now says so,
  where the generic for used to adopt the guard for it. The alternative
  was measured and rejected for now: reading each directory in full and
  closing its handle before yielding makes an abandoned iterator hold
  nothing at all, but it cost +16% and 2.77 -> 15.69 KB/op on the
  `fs_files_tree` scenario, and it belongs to the walker rather than to
  this rule. It is the right fix at the point the two traversal engines
  (`walk`'s recursive one and `find_iter`'s stack) are consolidated,
  where the property is written once instead of into a walker that is
  about to be replaced. `fetch` carried
  a structured `Error` in slot 3; the kind moved into the message as a
  `"<kind>: <detail>"` prefix, and the record stayed as `should_retry`'s
  parameter, which was always its documented consumer.
  `sqlite.query_value` carried a `found` boolean in slot 2 and its
  error in slot 3, and is GONE. Two slots can hold its value and its
  error but not the `found` flag, and without that flag a NULL first
  column is indistinguishable from no row — so the convenience would
  have had to ship a semantic wart to survive the rule. `query_one`
  answers the same question without one (the row is there; the column
  is NULL), the module header already recommended it over
  `query_value`, and no caller outside sqlite's own tests used the
  convenience. Removing a function the rule made worse beat keeping a
  documented defect: worth recording as the second general shape of
  the fix, beside find_iter's "remove the thing the slot carried". `fs.visit` also stopped
  echoing the caller's own context back, which is what the record it
  now returns would otherwise have had to carry generically.

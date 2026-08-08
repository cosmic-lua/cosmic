# D20 — the naming charter: ten rules, and the renames that applied them

- **date:** 2026-08
- **context:** the API review found five or six *competing
  internally-consistent* naming conventions on the public surface, not
  random names: POSIX spellings beside English ones (`makedirs` /
  `write_atomic`), three spellings of milliseconds, `is*` predicates
  in two shapes, PascalCase constructors that collide with type
  exports. Each was locally defensible; together they made every call
  site a guess. The pre-1.0 window (D10) is the one time renames are
  cheap.
- **decision:** ten rules. New code follows them; a deviation is a bug.
  1. `snake_case`, words spelled out; no new abbreviations.
     `PascalCase` is for record TYPES only — no PascalCase functions;
     constructors are lowercase (`signal.sigset()`; `Sigset()` is
     retired).
  2. Units live in the identifier: `_ms`, `_kb`, `_bytes`. Durations
     are integer milliseconds.
  3. Predicates are `is_*` (`fs.is_file`, `poll:is_empty`);
     object-state getters are bare participles (`h:closed()`).
  4. Getters are bare nouns (`sys.nproc()`, `fs.cwd()`); `get*/set*`
     prefixes survive only in syscall-shaped modules (`proc`, `user`,
     `signal`), which keep POSIX names wholesale. Battery modules use
     English: `fs.make_dirs`, `fs.remove_all`, `fs.temp_dir`.
  5. Constructors: `open` = acquires a closeable resource; `new` =
     pure in-memory object; `wrap` = adopts an existing raw resource.
  6. `parse`/`format` for text↔value; `encode`/`decode` for
     representation change; `escape`/`unescape` for syntax safety.
     Every pair ships both halves or documents why not. The file
     variant is `<verb>_file` (`literal.parse`/`parse_file`).
  7. Options records are named `Options` (or `<Thing>Options` when a
     module has several); the argument is named `opts`.
  8. `verb_noun` order: `hash.hash_password`, `hash.verify_password`.
  9. Reserved verbs, one meaning tree-wide: `run` = execute a
     program/callback; `match` = pattern match; `query` = index/db
     lookup. Lifecycle: `start`/`stop` for toggleable state
     (`child.start`), `begin`/`finish` for spans (`instrument`).
  10. Every type in a public signature is exported (`type X = X`);
      `Reader`/`Writer` are reserved for the `cosmic.stream` contract.
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
  remains the template for any future public rename.
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
  relitigated per-file.

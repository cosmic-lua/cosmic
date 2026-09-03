## Change

#373 removed every session/changeset/rebaser binding from
`tool/net/lsqlite3.c`, and nothing else in the tree ever called that
API, but the amalgamation is still compiled with it enabled. Remove:

- `third_party/sqlite3/BUILD.mk:166-167`: the two lines
  `-DSQLITE_ENABLE_PREUPDATE_HOOK` and `-DSQLITE_ENABLE_SESSION` from
  `THIRD_PARTY_SQLITE3_FLAGS`. Both go together: the session extension
  is the only consumer of the preupdate hook (41 `#ifdef
  SQLITE_ENABLE_PREUPDATE_HOOK` sites in sqlite3.c, all session or
  pre-update plumbing).
- `tool/net/definitions.lua:523`: the comment line
  `-- Session / Changeset Constants` that heads nothing (the `SC()`
  rows under it left with #373); delete it and the blank line above so
  `CHECKPOINT_TRUNCATE = nil,` is followed directly by `}`.
- `tool/lua/test_cosmo.lua:104-106`: the comment now says the flag
  "was never defined for lsqlite3.o"; make it say the library flag is
  gone too, and keep the `db.create_session == nil` assertion at `:113`
  as the gate that the surface stays absent.

`shell.c` is in `THIRD_PARTY_SQLITE3_A_SRCS` (`BUILD.mk:59-60`) and
guards its `.session` command with `#if defined(SQLITE_ENABLE_SESSION)`
(7 sites); it compiles either way. Run `make -j o//tool/lua/test` and
`make -j o//third_party/sqlite3` (the shell package) before opening the PR.

## Evidence

The flags (`git show origin/master:third_party/sqlite3/BUILD.mk | sed -n 166,167p`):

    	-DSQLITE_ENABLE_PREUPDATE_HOOK				\
    	-DSQLITE_ENABLE_SESSION					\

No consumer of the API outside the vendored sources
(`git grep -n -E 'sqlite3session_|sqlite3changeset_|sqlite3changegroup_|sqlite3rebaser_|sqlite3_preupdate_' origin/master -- . ':!third_party/sqlite3/sqlite3.c' ':!third_party/sqlite3/sqlite3.h' ':!third_party/sqlite3/shell.c'`):

    (no output)

and none inside shell.c either
(`git grep -c 'sqlite3_preupdate' origin/master -- third_party/sqlite3/shell.c` → no output);
its session uses are all under the guard
(`git grep -n 'SQLITE_ENABLE_SESSION' origin/master -- third_party/sqlite3/shell.c`):

    23661 23757 27237 27671 27691 27708 34270  (#if defined(SQLITE_ENABLE_SESSION))

Every other mention of either macro outside the amalgamation
(`git grep -n -E 'SQLITE_ENABLE_SESSION|SQLITE_ENABLE_PREUPDATE_HOOK' origin/master -- . ':!third_party/sqlite3/sqlite3.c' ':!third_party/sqlite3/sqlite3.h' ':!third_party/sqlite3/shell.c'`):

    third_party/sqlite3/BUILD.mk:166 / :167   (the two flag lines)
    tool/lua/test_cosmo.lua:105               (the comment above)

Nothing in `tool/net/lsqlite3.c` references the surface
(`grep -n -i -E 'changeset|session|rebaser|liter_' tool/net/lsqlite3.c` → no output),
and `third_party/sqlite3/update.sh` carries no flag list
(`git grep -n -E 'ENABLE_SESSION|PREUPDATE' origin/master -- third_party/sqlite3/update.sh` → no output),
so a future amalgamation bump does not reintroduce them.

The stale header (`sed -n 521,525p tool/net/definitions.lua`):

        CHECKPOINT_TRUNCATE = nil,

        -- Session / Changeset Constants

    }

## Non-goals

`-DSQLITE_ENABLE_DESERIALIZE` on `lsqlite3.o` (`tool/net/BUILD.mk`) and
the extension registry stay. This is a flag removal, not a bump of the
vendored sqlite3.c.

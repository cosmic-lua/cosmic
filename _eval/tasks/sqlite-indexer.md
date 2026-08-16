Build a file indexer backed by SQLite. First create this fixture tree with exactly these files and byte contents (note `a.txt` and `sub/deep/c.txt` are identical): `testdata/tree/a.txt` containing `alpha` plus a trailing newline (6 bytes); `testdata/tree/sub/b.txt` containing `beta` plus a trailing newline (5 bytes); `testdata/tree/sub/deep/c.txt` containing `alpha` plus a trailing newline (6 bytes). The tool is a compiled binary `o/bin/findex` (source `cmd/findex/main.tl`) with three subcommands. `findex index <dir> <db>` walks the directory tree recursively and records every regular file in a SQLite table `files(path, size, hash)`, where `path` is the file's path relative to `<dir>` (forward slashes, no leading `./`), `size` is its byte size, and `hash` is its SHA-256 digest as lowercase hex. `findex lookup <db> <path>` prints one line `<size> <hash>` for the stored relative path, or prints an error to stderr and exits non-zero if the path is not in the index. `findex dupes <db>` finds hashes stored more than once and prints, for each, one line of the matching paths sorted ascending and joined by single spaces (groups sorted by hash). Errors (missing directory, missing db) exit non-zero with a message on stderr. Ship tests and take the project to a green `ci` gate.

## Acceptance facts

- `./cosmic --make build` produces an executable `o/bin/findex`, and `./o/bin/findex index testdata/tree o/index.db` exits 0 and creates `o/index.db`.
- The index holds exactly 3 rows: `./o/bin/findex lookup o/index.db a.txt`, `... sub/b.txt`, and `... sub/deep/c.txt` all exit 0.
- `./o/bin/findex lookup o/index.db sub/b.txt` prints exactly `5 f2c82decdd7181cf98945929a62598db7e6b477e11f6e0eb0ae97020eff151ad`.
- `./o/bin/findex lookup o/index.db a.txt` prints exactly `6 b6a98d9ce9a2d9149288fa3df42d377c3e42737afdcdaf714e33c0a100b51060`.
- `./o/bin/findex lookup o/index.db sub/b.txt/b.txt` exits non-zero — this doubled path is exactly what a wrong join of the walk visitor's full-path argument with the basename produces (S-trap: the historically observed path-doubling bug).
- `./o/bin/findex dupes o/index.db` exits 0 with stdout exactly one line: `a.txt sub/deep/c.txt`.
- `./o/bin/findex lookup o/index.db nope.txt` exits non-zero with empty stdout and non-empty stderr.
- The workspace contains at least one `*_test.tl`, and `./cosmic --make ci` ends with `ci: PASS`.

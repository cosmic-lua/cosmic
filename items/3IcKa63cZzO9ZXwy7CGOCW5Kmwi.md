## Change

`cosmic/fs/glob_test.tl` was excluded from runner-mode batch 3
(3IU6AsZC, merged as #1558) because it tears its fixture down at top
level. This item migrates it. Measured against origin/main 45f56e81,
2026-08-30.

**The form is settled: delete the teardown, keep the fixture build.**
The top-level SETUP is not the problem — it runs at module load, before
any case, which is the correct order. Only the top-level TEARDOWN is
wrong: line 129, `assert(fs.remove_all(root))`, runs at load too, so
under runner mode it removes the fixture before the generated tail
calls a single case.

Nothing needs to own the cleanup, because the harness already does:
each test file gets its own `TEST_TMPDIR` (AGENTS.md, "Testing"), and
`root` is `fs.join(TEST_TMPDIR, "glob_root")`. The precedent this item
was told to follow, `_cli/citations_test.tl` (a972ab5a, #1508), does
exactly this — it builds its fixture at top level and has no
`remove_all` at all.

**The deletion is 13 lines, not 12 — this corrects a bounce measured on
this item 2026-08-30.** The teardown (line 129) is the file's literal
last line, preceded by a blank separator (line 128) between the final
self-call (line 127) and the teardown:

```
$ sed -n '126,129p' cosmic/fs/glob_test.tl
end
test_walk_unlimited_by_default()

assert(fs.remove_all(root))
```

Deleting only the 11 self-call lines and line 129 (the original 12-line
plan) strands line 128 as a trailing blank line at EOF, which
`bin/cosmic --make fmt` refuses:

```
$ bin/cosmic --format cosmic/fs/glob_test.tl
cosmic/fs/glob_test.tl:118: format mismatch
        end
        
  have: 
  want: <eof>
```

So, in `cosmic/fs/glob_test.tl` and nowhere else, delete:

1. every line matching exactly `^test_[A-Za-z0-9_]*()$` (11 of them —
   the same shape batch 3 deleted from its 27 files),
2. line 129, `assert(fs.remove_all(root))`, and
3. the now-stranded trailing blank line immediately before it (line
   128) — deleted only because deletions 1 and 2 leave it as a
   trailing blank line at EOF, which `--check fmt` rejects; it is not
   itself semantically meaningful.

13 lines deleted, zero insertions. The fixture build (lines 11-15) and
every case body stay byte-identical.

**This was trialled and passes.** With exactly those 13 lines deleted:

```
$ bin/cosmic --make test cosmic/fs/glob_test.tl
✓ cosmic/fs/glob_test.tl (11 test functions)  6ms
1 checks: 1 passed
11 tests: 11 passed
test: PASS (1 file)
$ bin/cosmic --check fmt cosmic/fs/glob_test.tl
fmt: PASS (1 file)
```

Mutation-verify before opening the PR: break one assertion in a case,
confirm the narrow test goes red through the generated tail, restore
it.

**No other file in the tree has this shape**, so this item closes the
class rather than the instance. Swept 2026-08-30 at 45f56e81:

```
$ grep -rn --include='*_test.tl' -E '^(assert\()?fs\.remove_all\(|^os\.remove\(|^assert\(fs\.remove\(' . | grep -v '^./o/'
./cosmic/fs/glob_test.tl:129:assert(fs.remove_all(root))
```

one hit, this one. (The sweep matches a destructive call at column 1;
it would not catch a teardown hidden inside a top-level `do ... end`,
and none of the remaining batches' scopes contain one — batch 3's
review re-derived that with a Lua-aware lexer over all 29 files in its
scope.)

## Non-goals

No fixture restructuring: no per-case root, no setup/teardown helper
pair, no `temp_dir` call. The cases keep their shared `root` and the
case count stays 11. No assertion changes, renames, reflow or comment
rewrites beyond the one stranded blank line named above. No change to
any other file — `cosmic/fs/glob_test.tl` is the whole diff. No change
to `cosmic/test.tl`, `_tool/seam.tl`, `_tool/discover.tl`, or the
`call-after-define` lint.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test cosmic/fs/glob_test.tl` reports 11 test
  functions and 11 passing tests.
- `git diff origin/main --numstat -- cosmic/fs/glob_test.tl` → `0` insertions,
  `13` deletions, and the diff touches no other file.
- `grep -c '^test_[A-Za-z0-9_]*()$' cosmic/fs/glob_test.tl` → `0`, and
  `grep -c 'remove_all' cosmic/fs/glob_test.tl` → `0`.
- `bin/cosmic --check fmt cosmic/fs/glob_test.tl` → `fmt: PASS (1 file)`.

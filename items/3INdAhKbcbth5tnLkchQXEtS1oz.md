## Change

Measured 2026-08-30: `_make/clean.tl` removes every direct child of
`o/` except the `KEEP` set (`{bootstrap = true}`) — no worktree
protection of any kind — while `skills/work/SKILL.md` and the board
branch's README both instruct `git worktree add o/board board`, so
`cosmic --make clean` deletes a live board worktree (and strands its
admin entry in `.git/worktrees`). The change, in `_make/clean.tl`:
clean skips any direct child of `o/` that is a git worktree root —
detected by the presence of a `.git` entry (file or directory) directly
inside it — and prints one `clean: kept <name> (git worktree)` line per
skip. Test in `_make/clean_test.tl`: a fixture `o/` whose child
directory contains a `.git` file survives clean while ordinary children
are removed; mutation-verify the skip (drop the `.git` check, watch the
fixture get deleted, restore).

## Non-goals

No doc changes (the worktree location stays documented as `o/board`).
No worktree registration, pruning, or `git` invocation from clean —
detection is the filesystem `.git` marker only.

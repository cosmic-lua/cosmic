## Evidence

Reported by the builder of cosmic-lua/cosmic#1622 (item 3IkxXhOb, the
doc path-reference gate). That gate verifies every backtick repo path
in `docs/**/*.md` and `skills/**/*.md` exists in the tree, and has to
excuse the `_work/` prefix wholesale: `docs/decisions/d26-decision-
records.md`, `d37`, `d38`, `d42` and `skills/work/decompose.md` cite
`_work/*.tl` modules (`_work/doctrine.tl`, `_work/priority.tl`,
`_work/item.tl`, ...) that exist only on the orphan `board` branch, so
a rename there strands these pointers with no gate on either branch
noticing. Re-measure at pull time on `origin/main`: `grep -ohE
'`_work/[A-Za-z0-9_./-]+`' docs/**/*.md skills/**/*.md | sort -u`
and, for each, `git cat-file -e origin/board:<path>`.

## Change

`_build/doc_paths_test.tl`: replace the `_work/` prefix excuse with a
cross-branch check — a `_work/...` span must exist on `origin/board`
(`git ls-tree`/`cat-file` against the fetched ref, read once per run),
and when the ref is not fetched the case is skipped with a printed
reason rather than passing silently (CI fetches `board`? measure
`pr.yml`; if it does not, add `origin/board` to the checkout's fetch
in the `ci` lane, one line). Fail naming file:line and the missing
board path. The first run's report is the fix list.

## Non-goals

- No change to the board branch.
- No widening beyond the `_work/` prefix.

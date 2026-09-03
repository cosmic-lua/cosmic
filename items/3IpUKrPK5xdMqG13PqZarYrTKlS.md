## Evidence

`ls -l /home/user/cosmic/CLAUDE.md` → `CLAUDE.md -> AGENTS.md`. The
builder of PR #1657, told by its spec to amend "CLAUDE.md, the
cold-build rule paragraph", had its edit refused by the harness
("Refusing to write .../CLAUDE.md: it is a symbolic link. Write to the
link's target path instead"), recovered by editing AGENTS.md, and had
to explain the substitution in the PR body; the fresh-context reviewer
then flagged "no CLAUDE.md file is touched directly" as a scope
question to verify. Board specs, the builder brief and this file all
say "CLAUDE.md"; nothing in the tree says which of the two names is
the file. `grep -n 'symlink\|AGENTS.md' AGENTS.md | head` → no
self-reference.

## Change

`AGENTS.md`, immediately under the `# AGENTS.md` heading: one sentence
— "`CLAUDE.md` at the root is a symlink to this file; edit `AGENTS.md`,
and read any instruction naming `CLAUDE.md` as naming this file." No
other prose moves. `_build/docs_test.tl` already gates the paths this
sentence names.

## Non-goals

No rename, no second copy, no change to which name tools read.

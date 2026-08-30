## Change

Evidence (2026-08-30): whilp/cosmopolitan transferred to the
cosmic-lua organization along with whilp/cosmic — checkouts' remotes
name https://github.com/cosmic-lua/cosmopolitan, and the pinned
release (tag 2026.08.27-13977f2ef) serves under cosmic-lua with
unchanged digests. That repo's own tree still names the old owners:
its AGENTS.md opens with "whilp/cosmopolitan is a fork of
jart/cosmopolitan" and names whilp/cosmic as the downstream consumer.
One PR carrying cosmic-lua/cosmopolitan (base master): sweep the tree
(`git grep -n 'whilp/'`), apply the mechanical owner substitution
whilp/cosmopolitan → cosmic-lua/cosmopolitan and whilp/cosmic →
cosmic-lua/cosmic in prose, URLs and comments. Walls:
jart/cosmopolitan upstream references are CORRECT and stay; leave
issue-number citations of the form `whilp/<repo>#<digits>` as
historical provenance if any exist (state the count); do not touch
vendored third_party/** or generated files — if a hit lands in one,
leave it and report it. After the edit, `git grep -n 'whilp/'` must
match only the deliberately-kept citations/vendored hits you report.
The gate for that repo is its own: `make -j$(nproc) o//tool/lua/test`
is the correctness gate per its AGENTS.md, but a prose-only diff
does not require it — CI's `build` check on the PR is the acceptance.
Landing goes through that repo's merge queue (the orchestrator
enqueues after review).

## Non-goals

No code, build, or definitions.lua changes; no keeping the fork
"mergeable with upstream" concerns triggered (prose/comments only —
if the sweep hits a file where upstream-mergeability makes the edit
churn (e.g. a vendored README), leave it and report).

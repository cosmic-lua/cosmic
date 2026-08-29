Evidence (2026-08-29): whilp/cosmopolitan transferred to the cosmic-lua
organization along with whilp/cosmic — session checkouts' `git remote
-v` name https://github.com/cosmic-lua/cosmopolitan, and the GitHub API
serves its pinned release (tag 2026.08.27-13977f2ef) under cosmic-lua
with unchanged asset digests. That repo's own tree still names the old
owners: its AGENTS.md opens with "whilp/cosmopolitan is a fork of
jart/cosmopolitan" and names whilp/cosmic as the downstream consumer.
Sweep that tree (`git grep -n 'whilp/'`) and update the stale
self-references and cross-references to cosmic-lua/{cosmopolitan,cosmic}
in one small PR carrying that repo; jart/cosmopolitan upstream
references are correct and stay.

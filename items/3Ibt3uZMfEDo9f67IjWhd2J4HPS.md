## Change

Evidence: whilp/cosmic and whilp/cosmopolitan both transferred to the
cosmic-lua organization on 2026-08-29 — every session checkout's
`git remote -v` now names https://github.com/cosmic-lua/{cosmic,cosmopolitan},
and the GitHub API serves both pinned releases under cosmic-lua with
byte-identical asset digests (measured 2026-08-29 via the releases API:
cosmic-lua/cosmic tag `2026-08-27-555873e` asset `cosmic-lua` digest
`sha256:145057b9fe905bb866fa3c03818265e4284a3bcd8367b76d9d5254f3c32a0900`
= bin/cosmic.pin's sha256; cosmic-lua/cosmopolitan tag
`2026.08.27-13977f2ef` asset `cosmos.zip` digest
`sha256:7d2a03524c176857c710f16113b38db9ea07505f72d9d5f5f280d26c8d98be72`
= 3p/cosmos/cosmos_pin.tl's sha). The old whilp URLs still serve via
GitHub's transfer redirect (this session's cold builds fetched and
sha-verified both through them), but the tree should name the canonical
owner. Sweep command:
`git grep -n 'whilp/' origin/main` (run it fresh; counts below are
2026-08-29's).

One PR, mechanical owner substitution — sha256 fields UNCHANGED
everywhere (verified identical above; a changed sha is a wrong build,
not a rename):

1. `bin/cosmic.pin` line 7: url owner whilp/cosmic → cosmic-lua/cosmic.
2. `3p/cosmos/cosmos_pin.tl` url: whilp/cosmopolitan →
   cosmic-lua/cosmopolitan.
3. `README.md` lines 20, 29 (release download URLs, whilp/cosmic) and
   its one whilp/cosmopolitan prose ref.
4. `docs/contributing.md` line 6 (clone URL).
5. The remaining whilp/cosmopolitan owner references in prose and code
   comments: AGENTS.md (2), _perf/bench/startup_bench.tl (1),
   _types/gentype.tl (1), cosmic/sqlite/zipfile_test.tl (1),
   docs/decisions/d14-no-self-hosting.md (1),
   docs/decisions/d31-gate-noise-from-every-control-pair.md (1),
   docs/design/casts.md (3), docs/design/make/log/phase1-2.md (1),
   docs/design/nil-flow.md (1), skills/optimize/SKILL.md (6),
   skills/optimize/cosmopolitan.md (5), skills/optimize/finding.md (1).

After the edit, `git grep -n 'whilp/'` over the tree must match ONLY
issue-number citations of the form `whilp/cosmic#<digits>` (see
Non-goals) — anything else remaining is a miss.

## Non-goals

Issue-number citations (`whilp/cosmic#967`, `#942`, `#1065` in
3p/tl/tl_patch/*.tl and docs/decisions/d21-carried-tl-patch.md) stay:
they are provenance naming where the issue lived when filed, and
GitHub's transfer redirect keeps them clickable. skills/work/SKILL.md
is already fixed by PR #1534 (item 3IbpI2YD) — not this diff.
jart/cosmopolitan references are upstream and correct. The
cosmopolitan repo's own tree (its AGENTS.md names whilp/cosmopolitan
and whilp/cosmic) is a separate item carrying that repo.

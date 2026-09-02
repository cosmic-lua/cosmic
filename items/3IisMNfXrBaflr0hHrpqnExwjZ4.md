## Finding

An item's own `repo:` field — the repo `gitboard set --repo` and `new
--repo` write, "the repo its PR lands in" — can name a repository the
claiming (or reviewing) session cannot reach, and nothing on the ready
bar catches it, even after `3IL7mlxc` (handle «LGb4_tdJj», PR #1603)
taught `_work/spec.tl`/`_work/gitgate.tl` to refuse a spec whose TEXT
reaches an undeclared `github.com` URL.

## Symptom

Orchestrating this session's wave (2026-09-01), five items under the
cosmo-contracts census container (`3IQtgMjycyFrxa8xT2ZqwOHfdJl`) —
`3IR2U42t` («YloP_x1CX»), `3IiFbuoO` («Kjua_j899»), `3IR2TE1O`
(«YAQq_Fsja»), `3IR2SQaC` («aPvf_Gezb»), `3IR2SvRb» («7Gbq_90xl») —
all carried `repo: whilp/cosmopolitan`, inherited from their parent
container (`3IQtgMjycyFrxa8xT2ZqwOHfdJl`, also `repo: whilp/cosmopolitan`).
This session's GitHub grant is `cosmic-lua/cosmic` +
`cosmic-lua/cosmopolitan` only; confirmed unreachable directly:

```
mcp__github__get_file_contents(owner=whilp, repo=cosmopolitan, path=README.md)
→ Access denied: repository "whilp/cosmopolitan" is not configured for
  this session. Allowed repositories: cosmic-lua/cosmic, cosmic-lua/cosmopolitan
```

Sibling items under the SAME parent and same census effort —
`3IiFXFCS` («TLb0_ldVZ»), `3IiFXXGK` («UiTB_vfQ2»), `3IiFcAtW`
(«RKRd_xj6S»), and the already-`doing` `3IK…` («kPjH_SBKS», "census:
zip") — correctly carry `repo: cosmic-lua/cosmopolitan` and built and
merged there without incident, confirming `whilp/cosmopolitan` on the
other five is stale data (a personal-fork name used while the evidence
for the whole container was first gathered), not a deliberate distinct
target. A repo-wide scan (`grep -rl 'repo"\] = "whilp/cosmopolitan"'
items/*.tl` on the `board` branch) turns up 37 `.tl` item files still
carrying it as of this writing — most likely stale the same way,
though this item does not audit each one.

## Provenance

Discovered live while filling a build wave under `/work 9`
(2026-09-01), immediately after `3IL7mlxc`/PR #1603 landed the
spec-text half of this exact class of gap. `3IL7mlxc`'s own spec
explicitly named an item's own `repo` field as the ONE case its
`declared_repos`/`reached_repos` check deliberately exempts from
needing a `## Access` declaration — reasonable for a repo the claiming
session genuinely owns, but that exemption is also the blind spot a
stale `repo:` field hides behind: nothing re-checks that the exempted
field is itself reachable.

Worked around this time by hand: `gitboard set ID --repo
cosmic-lua/cosmopolitan` on each of the five before claiming, cross-
checked against the working siblings' `repo:` field. That repair is
per-item and manual; it does not generalize to the other 32+ affected
items still on the board, nor prevent a future container from being
seeded the same way.

## Where the tool stands (board `146e6a5f`, 2026-09-02)

- `_work/gitgate.tl:379-399` `undeclared_repos`: the spec-text check
  deliberately exempts the item's own `repo` ("it is where the diff
  lands, not a source read on the side"); `ready_problems` (409-443)
  has no check on that field at all.
- `_work/gh.tl:23` `slug(s, repo)` already resolves a repo argument
  or the board's own `origin` remote to an `owner/name` slug, so the
  board's own owner is one call away; on a board with no GitHub
  origin it returns `nil, "no origin remote"` / `"origin is not a
  github remote"`.
- `new` lives in `_work/gitgraph.tl` (`cmd_new`, 54-55, `repo = repo
  or ""`), dispatched from `_work/gitboard.tl:351` with `--repo`
  verbatim; `set --repo` is beside it. Neither reads a parent's
  field: the board has NEVER inherited `repo` parent→child (measured
  by the builder, 2026-09-02: `git log -S"inherit"`/`-S".repo"` over
  `_work/gitgraph.tl`, `_work/gitverbs.tl` shows only #1286, #1500,
  #1529, none adding inheritance). The five items in Symptom got
  `whilp/cosmopolitan` by an explicit `--repo` at `new` (3IR2U42t,
  3IR2TE1O, 3IR2SQaC, 3IR2SvRb) or by `set --repo` (3IiFbuoO), so the
  propagation to stop is the WRITE, not an inheritance.
- Measured on the board: 27 item files still carry
  `repo = whilp/…`, 7 open: 3IOESI2v, 3IOIfiqQ, 3IQtgMjy (the census
  container), 3ISJHQ2M, 3ISJHfNY, 3IVL9YxP, 3IVLCTbq.
- `_work/fixture.tl`: `init_state_repo` has no origin and
  `init_shared` uses a local bare path, so `gh.slug(s, nil)` fails
  on every fixture board today.

## Change

Board-tooling change on the `board` branch of cosmic-lua/cosmic, as a
PR against base `board`, plus one data repair:

1. `_work/gitgate.tl` `ready_problems`: an item's own `repo`, when
   set, must share the board's origin owner (`gh.slug(s, nil)`'s
   owner half) — a foreign owner is refused with a problem naming
   the field, the value, and the repair (`gitboard set ID --repo
   <owner>/<name>`), unless the spec's `## Access` section names that
   exact slug (the deliberate cross-owner case). A board whose origin
   does not resolve to a GitHub slug skips the rule (the local-only
   waiver `handover_refusal` already uses). `take` and `check` report
   it through the existing problem list; no new verb.
2. `_work/gitgraph.tl` (`cmd_new` with `--repo`, and `set --repo`):
   refuse a foreign-owner slug at write time with the same rule and
   the same escape — the spec being written (`--spec-file`) or the
   item's current spec names the slug under `## Access` — so stale
   data stops entering the board. The verdict line names the value
   and the repair.
3. Tests in `_work/gitgate_test.tl` (foreign owner refused; same owner
   accepted; foreign owner declared under `## Access` accepted;
   no-origin board skips) and `_work/gitgraph_test.tl` (`new --repo`
   and `set --repo` refuse a foreign owner, accept with `## Access`).
   Fixture: give the fixture board `remote.origin.url =
   https://github.com/cosmic-lua/cosmic` with `remote.origin.pushurl`
   the local bare path, so `gh.slug` resolves while `publish` keeps
   pushing locally; add it to `_work/fixture.tl` as an opt-in helper
   so existing fixtures are unchanged. Runner mode; file caps
   (overflow goes in a sibling module).
4. Data repair, separate commit on the board, by the orchestrator
   after the PR lands: `gitboard set ID --repo cosmic-lua/cosmopolitan`
   on the 7 open items above; closed items keep their history.

## Non-goals

- Not verifying reachability against a session's actual GitHub grant
  (the board cannot see it); the owner rule is the proxy, the
  `## Access` declaration the escape hatch.
- No change to `undeclared_repos` (the spec-text check) or to
  `spec.reached_repos`.
- No parent→child `repo` inheritance: the board has none and this
  item adds none.

## Acceptance

- On a fixture board whose origin url is `cosmic-lua/cosmic`: `new
  --repo whilp/cosmopolitan` is refused naming the repair; with a
  `--spec-file` whose `## Access` names `whilp/cosmopolitan` it is
  accepted, and `take` on it passes the ready bar; an item whose
  `repo` was written foreign before the rule is refused by `take`
  naming `gitboard set ID --repo`.
- `bin/cosmic --make ci` on the board branch ends `ci: PASS`.

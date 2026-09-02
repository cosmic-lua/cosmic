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

## Where the tool stands (board `037a394c`, 2026-09-02)

- `_work/gitgate.tl:379-400` `undeclared_repos`: the spec-text check
  deliberately exempts the item's own `repo` ("it is where the diff
  lands, not a source read on the side"); `ready_problems` (409-445)
  has no check on that field at all.
- `_work/gh.tl:23` `slug(s, repo)` already resolves a repo argument
  or the board's own `origin` remote to an `owner/name` slug, so the
  board's own owner is one call away.
- Measured on the board: 116 items carry `repo = cosmic-lua/cosmopolitan`,
  7 `cosmic-lua/cosmic`, and 27 still `whilp/cosmopolitan`, of which 7
  are open (`grep -l 'repo"\] = "whilp/' items/*.tl`, filtered by no
  `resolution`): 3IOESI2v, 3IOIfiqQ, 3IQtgMjy (the census container),
  3ISJHQ2M, 3ISJHfNY, 3IVL9YxP, 3IVLCTbq. A `new --parent` under the
  container inherits its `repo`, which is how the five items in
  Symptom got theirs.

## Change

Board-tooling change on the `board` branch of cosmic-lua/cosmic, as a
PR against base `board`, plus one data repair:

1. `_work/gitgate.tl` `ready_problems`: an item's own `repo`, when
   set, must share the board's origin owner (`gh.slug(s, nil)`'s
   owner half) — a foreign owner is refused with a problem naming
   the field, the value, and the repair (`gitboard set ID --repo
   <owner>/<name>`), unless the spec's `## Access` section names that
   exact slug (the deliberate cross-owner case). `take` and `check`
   report it through the existing problem list; no new verb.
2. `_work/gitverbs.tl` (`new`): a child inherits its parent's `repo`
   only when that repo passes the same owner rule; otherwise the child
   is created with no `repo` and the verdict line says why, so stale
   data stops propagating.
3. Tests in `_work/gitgate_test.tl` (foreign owner refused; same owner
   accepted; foreign owner declared under `## Access` accepted) and
   `_work/gitverbs_test.tl` (inheritance stops at a foreign repo).
   Runner mode; file caps (`gitverbs.tl` was split at 500 once —
   place overflow in a sibling module).
4. Data repair, separate commit on the board, by the orchestrator
   after the PR lands: `gitboard set ID --repo cosmic-lua/cosmopolitan`
   on the 7 open items above; closed items keep their history.

## Non-goals

- Not verifying reachability against a session's actual GitHub grant
  (the board cannot see it); the owner rule is the proxy, the
  `## Access` declaration the escape hatch.
- No change to `undeclared_repos` (the spec-text check) or to
  `spec.reached_repos`.

## Acceptance

- On a fixture board whose origin is `cosmic-lua/cosmic`: `new` with
  `--repo whilp/cosmopolitan` then `take` is refused naming the repair;
  with `## Access` naming `whilp/cosmopolitan` it is accepted; `new
  --parent P` under a `whilp/…` parent creates a child with no repo
  and says so.
- `bin/cosmic --make ci` on the board branch ends `ci: PASS`.

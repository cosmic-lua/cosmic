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

## Change

Extend `_work/gitgate.tl`'s `ready_problems` (the same check `3IL7mlxc`
extended for spec-text URLs) to also refuse `ready` for an item whose
own `repo` field the claiming/reviewing session cannot demonstrate
access to — using whatever reachability signal the board already has
available at claim/check time (this project's GitHub MCP tooling
reports access denial by exact allowed-repo list, per the transcript
above; the refinement should confirm whether that signal is available
to `gitgate.tl` at check time or only surfaces through a session's tool
calls, which would change how this half is actually implementable).

This is NOT the same code path as `3IL7mlxc`'s `reached_repos` (which
scans spec TEXT for `github.com` URLs and deliberately skips the
item's own `repo` field) — that skip is correct given the field
usually IS the session's own target; this item adds a second,
independent check for exactly the field the first one skips.

## Non-goals

- Do not mass-repair the 37 currently-affected `.tl` files as part of
  this item — that is either a one-time data-cleanup script (if the
  refinement judges a bulk fix worthwhile) or left to repair-on-claim,
  a separate call from adding the gate.
- Do not touch `3IL7mlxc`'s `reached_repos`/`declared_repos` spec-text
  logic — it is correct and unrelated to this gap.
- Do not attempt to verify arbitrary repository access in general
  (e.g. push rights, branch protection) — only that the configured
  session's read/write grant covers the item's own declared `repo`
  field, mirroring `3IL7mlxc`'s existing scope discipline.

## Acceptance

To be written at refinement, against `_work/gitgate.tl` and whatever
fixture reproduces this session's exact denial (a synthetic item whose
`repo` field names a repo outside a stubbed/fake grant) — with one of
the five items named above, or the container itself, as a real-world
fixture if the refinement can construct one without depending on this
session's specific credentials.

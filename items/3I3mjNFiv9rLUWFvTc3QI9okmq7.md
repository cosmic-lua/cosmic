AGENTS.md sits exactly at the repo's hard 500-line file-length cap (enforced
by `cosmic --check lint`) with zero slack. Landing PR #1262 (item 3HyEla9L,
the deep-fuzz workflow) needed two small prose additions to AGENTS.md — a
workflow-list row and a CI-section bullet for the new `fuzz.yml` lane — and
the only way to fit them under the cap was to tighten the line-wrap (not the
wording) of the two neighboring `docs.yml`/`release.yml` bullets to free up
lines. That worked here, but it is a one-time trick: the file is back at
exactly 500 lines afterward, so the next required AGENTS.md addition hits the
same wall immediately, with no more wrapping slack to reclaim.

## Direction from the goal owner, 2026-08-18

The question this item opened — exempt prose, split the file, or hold the
line — is settled at the top: **no carve-out.** A prose file is not exempt
from the 500-line cap, and `.cosmicignore` is not the answer here. The cap
applies **per file**, so splitting is permitted and each resulting file gets
its own 500 lines.

The per-file cap is the floor, not the target. The standing preference,
which governs how the split is done and what goes in it:

- **Prefer short docs, and few of them.** Per-file headroom is not a licence
  to grow doctrine. A split that turns one 500-line file into three
  half-full ones has spent the budget without paying for it — the win is
  fewer words, not more places to put them.
- **Prefer making the code explicit over describing it in prose.** Doctrine
  a gate can enforce should live in the gate, not in a paragraph asking
  people to remember it. The prose that survives is what a gate cannot say.

## Where the lines actually are (measured 2026-08-18, AGENTS.md at 500)

| section | lines |
|---|---:|
| Language and Conventions | 149 |
| Build System | 63 |
| Repository Layout | 61 |
| Standard Library Modules | 55 |
| Type Generation | 34 |
| Testing | 32 |
| remaining 7 sections | 106 |

Two sections are where the preference above bites hardest:

- **Language and Conventions (149 lines, 30% of the file)** is mostly
  error-handling and narrowing doctrine. G3's win condition already schedules
  its death: "zero casts; the scaffolding deleted; the doctrine reduced to a
  footnote." Much of it describes rules that `--make lint` already enforces
  mechanically (cast justification, `fallible-returns`, `find-needle`) — the
  prose restates a gate rather than replacing one, which is exactly the case
  the preference says to resolve toward the code.
- **Standard Library Modules (55 lines)** is a module/description table that
  restates what `cosmic --docs` already serves from the binary. It is
  derivable, not authored.

Roughly 200 lines — 40% of the file — is therefore reclaimable without
losing anything an agent needs, which is why holding the cap is cheaper than
it looked when re-wrapping bullets was the only known tool.

## Open for refinement (planner's)

- Does this warrant a decision record via the `decide` skill? The rule being
  settled ("no prose exemption; per-file; prefer fewer, shorter docs and
  explicit code") is a tradeoff with a rejected alternative, which is the
  shape D26 says earns a record.
- Which reclamation lands first, and as how many items: deriving the module
  table, shrinking the conventions block toward the gates that already
  enforce it, or a structural split. The preference argues for reclamation
  before any split — a split that carries the current text unchanged is the
  outcome this direction rejects.
- Whether anything mechanical should check "few and short" once a split
  exists, or whether the per-file cap plus review is enough. Note that a
  total-doctrine-size measure is already named by G9 ("AGENTS.md doctrine
  size" in its measured-by), so the instrument may belong there rather than
  in lint.

## Non-goals

- Not a `.cosmicignore` entry for AGENTS.md, and not an exemption clause in
  the cap. Both were considered and rejected.

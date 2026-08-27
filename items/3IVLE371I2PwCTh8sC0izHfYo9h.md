# Problem

G1's win condition requires peer baselines — the same eval tasks run
in Python/Node/Go sandboxes — and G6's win condition requires "the
peer table current" per release. Neither exists anywhere in the tree
(measured 2026-08-27: `grep -rln "CPython|peer table" _perf/ docs/
_build/` matches nothing), and the one G1 board item (3IOESaPQ)
scopes cadence + history + the zero-silent-bugs gate, explicitly
leaving peers out of its shape. Two outcomes above G1 in the derived
order read this instrument to complete: G6's table and G4's "agents
adopt it unprompted" are unmeasurable while it is down.

# Change

The peer half of the instrument: for each eval task in the versioned
suite, an equivalent sandbox with only CPython / Node / Go (one
container image per peer, pinned versions), the same task prompts,
the same scoring (silent bugs, checker-caught, cycles), and a
published table — cosmic beside the three peers per task — emitted
with the suite's history assets (the release-asset pattern G6's perf
history already uses). The `agent-eval` skill holds round mechanics;
this item extends its harness to non-cosmic runtimes rather than
inventing a second harness.

# Non-goals

- Gating anything on the peer numbers: goals.md is explicit that the
  table reports and never gates.
- The cadence/history/gate half — that is 3IOESaPQ.

# Acceptance

- one suite run produces the peer table artifact with all four
  columns populated on at least the project-scaffold task.
- the table generation is invoked by the same entry point that will
  run on the cadence (so 3IOESaPQ picks it up when it lands).

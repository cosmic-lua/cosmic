## Goal

One ratchet (parent 3I1IoF4k): beyond a shared format, reader, regen verb
and failure contract, every gate must also share a liveness contract — it
reports how many things it checked, and that count can only be moved
deliberately. A gate that silently measures less than it did yesterday is
the anchor promise inverted: its PASS is a lie with provenance nobody reads.

## Evidence

The week of 2026-08-16..22 fixed five independent instances of one class —
a gate or instrument that kept passing while measuring nothing — and every
multi-week defect latency in the repo belongs to it:

- d592567: coverage normalize() handed the raw /zip chunk as the parse
  target; static line analysis silently failed and totals collapsed to
  hits-only for >= 22 days. Found by reading, not by a gate.
- 9569d3f (#1261): the release perf verdict was laundered through
  `| tee` + `exit 0` since the step's inception — regressions "reported"
  into a void for weeks. Fixed with a workflows-shape ratchet.
- b66f887 (#1241): a multi-token `reads:` declaration parsed as a silent
  no-op — declared trees never joined the dep closure (issue #1178).
- #1227: a 52-second cached test PASS replayed over 51 rewritten cast
  sites; the lint (2a66266) exists because a gate result was stale, not
  wrong.
- 0fbe600 (#1276): the cast ratchet's hardcoded TREES list had silently
  excluded `_eval/` and `_fuzz/` — casts there were unbounded from the day
  those trees appeared. Same shape upstream: whilp/cosmopolitan #250's
  arity scanner had silently skipped 51 bindings whose prose contained
  the word `return`; its fix ratcheted the checked-count (262 -> 322)
  and that ratchet is the proof this contract works.

Still open in the same family: #1245 (a concurrent --make yields a
payload-less o/bin/cosmic that exits 0 — a build whose "PASS" checked
nothing), and every remaining hand-maintained enumeration inside a gate
(TREES-style lists, allowlists), which in a repo whose creed is "position
is the manifest" are the one place the manifest is still a list.

## Direction

Two halves, likely separate children on refinement:

1. every ratchet/gate emits its denominator — N files/sites/bindings
   checked — beside its verdict, and a floor on N is committed like any
   other floor: a denominator that drops fails the gate until the drop is
   spent deliberately (the regen verb), exactly as the cast floor moves.
2. gate scopes are derived from the tree, not enumerated: a TREES-style
   list inside a gate either becomes a derivation (walk the root, apply
   `.cosmicignore`-style exclusion) or gains a completeness check that
   fails when the tree grows a top-level entry the list does not name.

# D3 — "no silent bugs" is the anchor promise, at full depth

- **date:** 2026-07
- **status:** active
- **context:** candidate core promises: no silent bugs, agent
  efficiency, self-sufficiency, best tool-building tool. and "no silent
  bugs" itself has depths: honest types only; plus verified docs; plus
  adversarial testing; plus transfer to user code.
- **decision:** no-silent-bugs ranks first, at full depth (types never
  lie + documented behavior is verified + adversarially verified + the
  promise transfers to user code). efficiency second (observed through
  agent evals), self-sufficiency third, tool-building as the payoff.
- **rejected:** stopping at type-layer honesty; treating correctness
  and efficiency as co-equal.
- **consequences:** the eval win condition gates on zero silent bugs
  before it targets cycle counts (D8). G4 and G5 exist.


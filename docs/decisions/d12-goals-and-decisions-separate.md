# D12 — goals and decisions are separate documents

- **date:** 2026-07
- **context:** the goals content divides into aspirations (mission,
  promises, measurable goals) and settled tradeoffs. tradeoffs are the
  part most at risk of accidental relitigation.
- **decision:** `docs/goals.md` for mission/promises/goals with win
  conditions; this file for ADR-style decisions, append-only, one entry
  per future decision.
- **rejected:** one combined file; root-level GOALS.md; folding into
  AGENTS.md.
- **consequences:** the decision log can grow without bloating the
  goals statement; goals stay short enough to actually be read.


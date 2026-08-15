# D12 — goals and decisions are separate documents

- **date:** 2026-07
- **status:** amended 2026-08 (one record per file; the process is D26)
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

- **amended 2026-08 (one record per file; the process is
  [D26](d26-decision-records.md)):** "this file" above was a single
  `decisions.md` holding every entry. it is now a directory holding one
  file per record, with `docs/decisions/README.md` carrying the prose
  and a derived index table — a growing log made the one-file shape a
  merge conflict per decision and a document nobody could link into
  precisely. the separation this record decided is unchanged; only the
  storage moved. how a record is written, amended, and superseded is
  itself recorded, in D26.


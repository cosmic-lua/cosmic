whilp/cosmopolitan has no `board` branch (confirmed: `refs/heads/board` 404s via the
GitHub API) and no board items reference it — its work still flows through plain
GitHub issues/labels (e.g. `work:ready` on whilp/cosmopolitan#265), the exact
mechanism SKILL.md says the board superseded ("ALL work state lives in items on the
`board` branch — never in GitHub labels, issue comments...").

Concretely surfaced by G5 (whilp/cosmic 3HyEE7RJ, ended completed 2026-08-17): its
spec named whilp/cosmopolitan#265 (EncodeJson float-token defect, still open,
unfixed) as a "future child, opened there when this epic's cosmic-layer children
prove the pattern" — but now that G5 is ended, that pointer is buried in a `done`
item's history instead of visible anywhere on the live board. Nobody planning cosmic
work today would discover #265 exists without re-reading G5's closed spec.

The `items/*.tl` schema also has no field for "which repo" — so even if a planner
wanted to track a cosmopolitan-side item on the board today, there's no way to mark
it as belonging to a different repo than whilp/cosmic, and gitboard's GitHub-facing
verbs (`move ... check`, `land`) are written against whilp/cosmic specifically.

Open question for a planner to settle: does whilp/cosmopolitan get its own `board`
branch (mirroring whilp/cosmic's), or does whilp/cosmic's board grow a `repo` field
so one board can hold items against either repo? Either way, whilp/cosmopolitan#265
itself should get a real tracked item once the mechanism exists.

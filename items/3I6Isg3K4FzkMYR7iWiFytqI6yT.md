Found while refining board item 3I462rGo (2026-08-18).

`skills/work/decompose.md:136-141` on `main` still tells a planner that the
tool executes a spec's facts block:

> `check` and `move ID ready` RUN the block — in the product checkout the
> facts describe, not the board worktree asking — so a stale fact refuses the
> promotion rather than surviving to bounce the slice later.

That is no longer true. Commit `be28e47e` on the `board` branch deleted
`_work/facts.tl` (139 lines, holding `fact_failures`, which shelled each `$ `
line out through `cosmic.child`) and `_work/facts_test.tl`, along with
`gitgate.fact_problems` and the `--root` flag the execution needed. Today
`gitboard check` runs `gitverbs.tl:249` → `gitgate.ready_problems`
(`_work/gitgate.tl:173`), which is a pure graph-and-section lint and executes
nothing.

Confirmed by observation as well as by reading: `gitboard check 3I462rGo`
returned `meets the ready bar` against a spec whose facts block names commands
in a product checkout the board worktree cannot see, and returned instantly.

Why it matters rather than being a cosmetic staleness: the sentence is the
stated reason a planner may trust a facts block it did not re-measure. A
planner that believes promotion re-runs the facts will carry a fact forward
from an earlier refinement pass instead of measuring it again, and the stale
fact now reaches an implementer — which is exactly the bounce the sentence
claims is prevented. The measurement discipline in the paragraph above it is
still right; only the enforcement claim is false, so the fix is to say the
facts are the planner's to measure and unenforced by the tool, not to weaken
the discipline.

Adjacent, same shape, not investigated here: the same file's ready-bar
paragraph says `gitboard check ID` "lints that each is present and non-empty"
— that half appears to still hold — and board item 3I2qqRxr ("one gate pins
the skill's rule lists to the kinds and exemptions the tool actually has")
already proposes a mechanical gate against exactly this class of drift between
the skill's prose on `main` and the tool on `board`. This finding is evidence
for that item, and may be the cheaper direct fix to land first.

No fix attempted here; no diff touches `skills/` or `_work/`.

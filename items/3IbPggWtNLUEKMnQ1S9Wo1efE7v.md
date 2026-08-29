## Change

The policy half of parent 3IHDCJ3o: an open lane-repair item (an
item whose `lane` field is non-empty — the field and the minting
land in the blocking sibling) is the motion that cannot wait, and
lane state is visible on the board report. Blocked on the sibling;
measure these against the tree at pull time, after it lands:

1. `_work/flow.tl` (371 lines today, `wc -l`): the admission check
   at `flow.tl:150` (`n < DOING_LIMIT`) admits a take of a
   lane-repair item even at the bound, through the same
   admits-over-limit hole an accepted item's finish uses — read the
   existing mechanism first and extend it, don't fork it.
2. `_work/action.tl`: `next_action` offers an unclaimed lane-repair
   item ahead of ordinary pulls, in the finish-first class — the
   repair is a pull that outranks pulls, below true finishing
   motions (merge/review/rework stay first; a broken lane never
   outranks landing what is already accepted). The offer's reason
   names the lane (`lane repair: release.yml`).
3. `_work/gitview.tl`: bare `show` prints one `lanes` row from
   `lanes_state.tl` when the file exists (`release.yml=success
   fuzz.yml=failure ...`), reading it offline via `cosmic.literal`;
   no row when the file is absent (a fresh board that has never
   synced).
4. Tests in `_work/action_test.tl` and `_work/gitview_test.tl`:
   repair-over-pull ordering, repair admitted at the bound, merge
   still ahead of repair, and the lanes row render (present and
   absent file). Mutation-check each new guard before pushing.

## Non-goals

No expedite field, no class-of-service marker (parent's Direction
point 4): the `lane` field identifies WHAT the item is, and the
ordering consequence lives in action.tl's rules, not in a rank any
session can set. No observation/minting changes — that is the
sibling. Verdict lines, refusal texts, commit subjects, `flow
item=` grammars untouched (`_work/flowstats_test.tl`).

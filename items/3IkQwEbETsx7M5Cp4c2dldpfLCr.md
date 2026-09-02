## Evidence

`tool/net/help.txt` is redbean's hand-maintained embedded manual
(`tool/net/redbean.c`). It restates binding return shapes that
`tool/net/definitions.lua` is the source of truth for, and nothing
checks the two agree: every contract PR in the exact-contracts series
(#315, #321, #324, #328, #329, #331, #334, #335, #336) changed
`definitions.lua` and left `help.txt` untouched. Two concrete drifts
already on the board or found in review:

- item `tpkl_saTa`: gmtime/localtime/clearenv/sigpending document
  their pre-#321 shapes;
- found by the round-2 review of #336: `tool/net/help.txt:3502-3504`
  (at head `86bc3fb7`) still lists `└─→ nil, error:str, errno:int` for
  `unix.getpgrp()`, which #336 retyped to a bare `integer`.

Each drift is a per-binding doc fix; the class recurs on every contract
PR because no gate reads `help.txt`. Re-measure at pull time:
`grep -n 'getpgrp' tool/net/help.txt`, and
`grep -c '└─→' tool/net/help.txt` for how many shape lines the manual
carries.

## Change

Two parts, one PR on cosmic-lua/cosmopolitan:

1. `tool/net/help.txt`: fix the `unix.getpgrp()` entry to the
   one-branch shape (`└─→ pgid:int`, no failure tuple), matching
   `tool/net/definitions.lua`.
2. A test beside the existing definitions ratchets in `tool/lua/`
   (`test_definitions_coverage.lua` is the model) that, for every
   `unix.*` function `help.txt` documents with a `├─→`/`└─→` shape
   block, compares the declared branch COUNT (one branch = infallible,
   two = fallible) against `definitions.lua`'s annotation for the same
   name (a `@return` admitting `nil` in slot 1 = fallible), and fails
   naming each mismatch. Count-level, not per-slot type: that is the
   drift these PRs actually produce, and it keeps the parser trivial.
   Enrol it in `tool/lua/BUILD.mk` like its siblings. Whatever the
   first run reports beyond getpgrp and the four bindings in
   `tpkl_saTa` becomes the fix list for this same PR, unless it exceeds
   a dozen entries — then land the gate with an explicit allowlist of
   the remaining names and file the rest as one follow-up item.

## Non-goals

- No change to any binding or to `definitions.lua`.
- The four bindings `tpkl_saTa` owns are fixed there, not here; this
  item's gate simply stops listing them once that PR lands (block this
  item on `tpkl_saTa` if it is still open at pull time).

Two more drifts found by #338's review, same class: `tool/net/help.txt:4254`
still documents `unix.sigaction` as `oldhandler:func|int, flags:int,
mask:unix.Sigset` (now one `unix.SignalAction` table, #338), and
`help.txt:3772` still documents `unix.nanosleep` as `remseconds:int,
remnanos:int` (one remainder table since #315). Both are on this
item's fix list.

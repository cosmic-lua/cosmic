AGENTS.md sits exactly at the repo's hard 500-line file-length cap (enforced
by `cosmic --check lint`) with zero slack. Landing PR #1262 (item 3HyEla9L,
the deep-fuzz workflow) needed two small prose additions to AGENTS.md — a
workflow-list row and a CI-section bullet for the new `fuzz.yml` lane — and
the only way to fit them under the cap was to tighten the line-wrap (not the
wording) of the two neighboring `docs.yml`/`release.yml` bullets to free up
lines. That worked here, but it is a one-time trick: the file is back at
exactly 500 lines afterward, so the next required AGENTS.md addition hits the
same wall immediately, with no more wrapping slack to reclaim.

Worth someone deciding: should a prose documentation file be exempt from a
line cap whose stated rationale (`_tool`'s lint checks) is about `.tl`/`.lua`
source readability, not prose? The lint failure message itself points at
`.cosmicignore` as an escape hatch, which sits oddly next to AGENTS.md's own
"file length: all files must be ≤500 lines. no exceptions." wording — either
the no-exceptions rule needs an explicit prose carve-out, or AGENTS.md needs
to be split, or every future doc addition to it will keep needing this same
wrap-tightening trick.

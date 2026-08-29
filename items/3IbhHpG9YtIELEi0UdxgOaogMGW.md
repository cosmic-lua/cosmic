## Change

Evidence (review of PR 1529, 2026-08-29, reproduced on the base branch): `gitboard new "$(printf 'innocent\nfake line')"` is ACCEPTED — a multiline title lands in the item file and injects fake lines into `show`'s board render, so a hostile or accidental title can mimic other board lines. Refuse newlines (and leading/trailing whitespace) in titles at `new` and at `set --title`, with a test for each site; existing multiline titles on the board (measure: `grep -l "\\n" items/*.tl` on the title field) are repaired by one `set --title` each if any exist.

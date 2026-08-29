## Change

Evidence (2026-08-29, live board): bare `show`'s triage section renders the unchunked HEAD prefix — `gitview.tl:131` is `("  %s %s"):format(f.id:sub(1, 8), f.title)` — while every other reading surface (doing/todo lines, next target and or: alternates, show header) now leads with the chunked ksuid tail after the tail-8 swap landed. Live output shows `3IbEvcS1 gitboard lacks a retitle verb` beside `PtPT-MEq6 ...` in the same report. Flip gitview.tl:131 to the same `tail.chunk(f.id)` render as id_line, and pin it with an assertion in _work/gitview_test.tl.

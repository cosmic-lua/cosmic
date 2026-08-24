The snippets gate holds every code fence this repo shows a reader to
the formatter and the checker (`_build/snippets_test.tl`: "Every code
snippet this repository shows a reader is real code ... There is no
opt-out word"). Its doc-comment half only sees FENCES.

`doc_comment_fences` (`_build/snippets_test.tl:162-192`) matches
`doc:match("^```(%w*)")`. A doc comment that shows code as a markdown
INDENTED block instead — `---     local db = ...`, four spaces after
the `---` — is collected by nothing, yet `cosmic --docs <module>`
renders it as code exactly like a fence. The markdown half of the same
gate was already taught this lesson for list indentation
(`markdown_fences`, line 131: "anchoring at column 0 let an indented
block escape the gate entirely"); the doc-comment half never was.

Measured 2026-08-24 at 9bcb0f7d:

    grep -rc "^---     [^ ]" cosmic/**/*.tl   # 19 files, 84 lines

19 modules ship doc-comment code the gate cannot see, led by
`cosmic/flags/init.tl` (16 lines), `cosmic/quicksand/proc.tl` (9),
`cosmic/sqlite/init.tl` (7), `cosmic/errno.tl` (7). Only
`cosmic/shm.tl:288` uses the fenced form, so the covered population is
one file and the uncovered one is nineteen.

This is not hypothetical. The sqlite module header's indented example
does not compile — three separate ways (unnarrowed `sqlite.open`,
discarded `db:exec`, discarded `db:close`) — and cost a clean-room
eval agent its attempt-1 build. That instance is board item 3IK30UQA;
this item is the reason it could happen at all, and the reason it can
happen again in the other 18 files.

    o/bin/cosmic --check types <the header example, verbatim>
    # 7 errors

Fix direction (plan-phase, not settled here): either teach
`doc_comment_fences` to collect indented blocks too, or convert the 19
files to fences and add a lint forbidding the indented form so the
gate's population is closed by construction. The second is the more
honest shape — one form for reader code, gated everywhere — but it is
a 19-file diff whose breakage is unmeasured. Sizing that is the
refinement, and it likely wants the count of how many of the 84 lines
fail to compile today, which nothing has measured.

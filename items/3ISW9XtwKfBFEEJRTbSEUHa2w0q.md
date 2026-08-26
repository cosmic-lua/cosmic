D30's decision text says the justification grammar is "`-- exits:
<why>` on an `os.exit(` line", but the licence it grants (a process
boundary with no caller) plainly covers any exit call, and the
enforcement lint (PR #1412) reads the receiver to cover both
spellings after its census found six post-fork children exiting via
`unix.exit(` — `cosmic/quicksand/proxy.tl:135,152,159,161`,
`cosmic/quicksand/proxy/serve.tl:404`, `cosmic/quicksand/init.tl:127`
— all now carrying `-- exits:` markers. The record's sentence should
say an exit call (`os.exit`, `unix.exit`) rather than naming one
spelling; per the decide skill this is a "correct" (a detail the tree
outgrew, no claim changes, no status change), one line in
`docs/decisions/d30-throw-exit-boundaries.md`, plus the same phrase
in AGENTS.md's doctrine bullet if it names os.exit (verify at pull).

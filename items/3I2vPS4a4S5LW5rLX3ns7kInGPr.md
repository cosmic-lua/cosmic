Observed during the 2026-08-17 board migration: the coverage report
(`_tool/coverage/report.tl`) walks directories on its own and needed a
hardcoded `items/` exclusion beside `testdata/`, even though the build
model already excludes `items/` via the root `.cosmicignore`. Two
exclusion vocabularies for one question. The report (and any other
tool that scans the tree independently) should derive its exclusions
from `.cosmicignore` so an ignored tree is ignored everywhere at once.

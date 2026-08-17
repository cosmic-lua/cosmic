--- The board's binary: `o/bin/gitboard`, built from this branch by
--- `cosmic --make build`, carrying `_work/**` on a cosmic base.
---
--- The verbs live in `_work.gitboard` rather than here, so the CLI
--- stays a module the tests can call directly and this file is only
--- the entry point. `_work/gitboard.tl` keeps its own `is_main`
--- guard, so `cosmic --make run _work/gitboard.tl` remains a working
--- invocation for a checkout that has not built yet.
---
--- What a binary does NOT buy this branch is convergence: a gate
--- re-execs into what the tree built only for a project that defines
--- `cosmic/**` AND ships a binary called `cosmic`, and this one does
--- neither. Every `--make` verb here still runs under the pinned
--- release, so the pin is what decides which fence the tests execute
--- inside.
local gitboard = require("_work.gitboard")

os.exit(gitboard.main(...))

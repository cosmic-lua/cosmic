## Evidence

Found by the builder of `cosmic-lua/cosmopolitan#340` (`unix.wait`'s
return-tuple shape fix). `tool/net/help.txt` (the hand-maintained
redbean manual, `tool/net/redbean.c`) still documents `unix.wait`'s
pre-#340 three-positional-value shape around lines 3019-3047, e.g.:

```
pid, status, errno = unix.wait(-1, unix.WNOHANG)
```

`#340` changed the binding to return a single `unix.WaitResult` table
(`pid`, `wstatus`, `rusage` fields) as its sole success value, with
`(nil, error, errno)` on failure — the same class of drift this
item's siblings (`dldp_fLCr`, tracking `getpgrp`/`sigaction`/
`nanosleep`) already catalog, and the same shape as the gap `#338`
(`unix.sigaction`) left behind, closed as its own follow-up PR (`#339`,
"document gmtime/localtime/clearenv/sigpending's current shapes").

Re-locate at pull time: `grep -n 'unix.wait' tool/net/help.txt`.

## Change

`tool/net/help.txt`, the `unix.wait` example and any prose describing
its return shape: rewrite to the `unix.WaitResult` table shape `#340`
introduced (`result.pid`, `result.wstatus`, `result.rusage` on
success; `nil, error, errno` on failure), matching
`tool/net/definitions.lua`'s `unix.WaitResult` doc block. Land as its
own PR in `cosmic-lua/cosmopolitan`, the same convention `#339`
followed after `#338` — documentation only, no binding or
`definitions.lua` change.

## Non-goals

- No change to `unix.wait`'s implementation or annotation — `#340`
  already landed that.
- No other `help.txt` section; the broader help.txt-drift gate is
  `dldp_fLCr`.

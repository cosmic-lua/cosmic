`_perf/gate.tl`'s positional file arguments mix read and write roles
per verb, and a baseline passed to the wrong slot is silently
destroyed. Observed 2026-08-26 while landing the cosmos pin bump
(board 3IQtkyRA): after `compare BASE CUR SELFB` (BASE/CUR read, SELFB
written — documented), the session ran
`gate.tl selfcheck o/perf/base.json o/perf/selfb.json` to characterize
noise and selfcheck WROTE BOTH paths — re-measuring the current binary
over the old-pin baseline file — so the only copy of the old-pin
baseline was gone and had to be rebuilt from a stash of the old pin
(two full builds and two measurement runs, ~15 minutes). The optimize
skill does document "both paths are WRITTEN", so this is not a doc
gap; it is a tool-shape gap: the same filename means "input" to one
verb and "output" to its sibling, and nothing distinguishes them at
the call site. Candidate fixes, smallest first: selfcheck refuses to
overwrite an existing file unless the argument carries a flag
(`--overwrite`, or write-to `A-self.json` derived names); or selfcheck
takes zero file arguments and derives its own output names, since its
inputs are never pre-existing data by definition. Either keeps
`compare`'s contract untouched.

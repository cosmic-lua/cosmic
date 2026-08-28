## Evidence

`docs/design/make/resolution.md:231` reads:

> `_perf/run.tl:163` is that case in this repo — `pcall(require, name)`
> with `name` off argv, which is how every `_perf/bench/*_bench.tl`
> scenario loads.

`_perf/run.tl:163` is `if cv is string then meta.cosmic_version = cv end`.
The `pcall(require, name)` the sentence names is at `_perf/run.tl:175`
(`git show origin/main:_perf/run.tl | grep -n 'pcall(require, name)'` →
`175`). Measured against `origin/main` `40776231`.

The lint passes anyway. `_cli/citations.tl` checks an INLINE reference —
a whole backticked span that is nothing but `<path>:<line>` — by POSITION
only: the path must exist and the file must be long enough. Only a FENCED
reference (a `-- <path>:<line>` comment as a code block's first line,
followed by the quoted source) also compares TEXT. `resolution.md` carries
no `Measured against <sha>` line, so it is a live citation, not a
snapshot — the position is a claim about today's tree, and it is wrong.

Two possible slices, and the refinement should pick one:

- fix just this citation (repoint to `:175`, or convert it to a fenced
  citation so the text is checked from then on), or
- close the class: give the inline form something to check beyond line
  count. It cannot compare quoted text — there is none — but a citation
  whose surrounding sentence names an identifier could be checked against
  the cited line, or the doc could be pushed toward the fenced form the
  lint can really verify.

Found while refining 3IYAOXUC, whose change shortens `_perf/run.tl` by 11
lines and would move `pcall(require, name)` from `:175` to `:164` —
closer to the cited number, still wrong, and still green.

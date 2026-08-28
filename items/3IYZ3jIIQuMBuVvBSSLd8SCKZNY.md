An `## Acceptance` criterion can reach `ready` without anyone having run
its own commands, and 3IUBNQZZ shipped one that cannot run at all.

3IUBNQZZ's second Acceptance bullet ("The compare gate names them too,
over a genuine two-file compare") specifies three commands:

```
o/bin/cosmic --make run _perf/run.tl --only codec_base64_roundtrip_64k --out o/perf/a.json
o/bin/cosmic --make run _perf/run.tl --only codec_base64_roundtrip_64k --out o/perf/b.json
o/bin/cosmic --make run _perf/gate.tl compare o/perf/a.json o/perf/b.json o/perf/aa-b.json
```

and asserts the third "prints a `binaries:` line above the rows of every
table it prints". It cannot. Both results files are measured by the same
`o/bin/cosmic`, so `gate_inner`'s first act — `identity_refusal(opts.baseline,
opts.current, false)` at `_perf/gate.tl:160` — returns a refusal and the gate
returns 1 before any table exists. Reproduced during the review of #1485 at
head `37ea41cb`:

```
perf: o/perf/a.json and o/perf/b.json measured the SAME binary (1c82c311e98c). A binary compared against itself has no regression to find, so a clean result says nothing about your change.
perf-compare: FAIL
```

This is pre-existing `identity_refusal` behaviour, untouched by that diff and
correct — the criterion, not the gate, is what is wrong. The implementer
found it, disclosed it in the PR description, and satisfied the criterion's
intent by measuring a genuine second binary through `_perf/baserun.tl`
against `o/bootstrap/cosmic`; the review confirmed both runs. So the cost
here was one implementer's detour, not a bad merge — but the criterion was
the definition of done, and it was undefinable.

The bar's own words are what did not bind. The item took three refines,
and the last one (`## Refine — 2026-08-28`) states the omission outright:
*"Not measured here, and left to the implementer, deliberately. No perf
harness was run during this refine."* That reasoning is sound for a TIMING
claim — the refine correctly declined to take a reading the implementer
must re-take anyway — but it was applied to the command's RUNNABILITY too,
which does not drift and costs one invocation to establish. An Acceptance
command is not a measured claim; it is the definition of done, and a
definition of done nobody has executed once is a guess.

The candidate countermeasure, for whoever refines this: the ready bar
should separate the two, requiring every `## Acceptance` command to have
been INVOKED at refine time (exit code and first line recorded) even where
its numbers are explicitly left to the implementer. That is a `decompose.md`
change, so it is the docs tier of `enable.md`'s ordering, not core. Whether
a cheaper rule exists — for instance, requiring only that commands whose
ASSERTION is structural rather than numeric be run — is the refinement's
question, not this capture's.

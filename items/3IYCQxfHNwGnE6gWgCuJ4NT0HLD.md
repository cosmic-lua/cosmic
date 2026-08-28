## Evidence

`_perf/gate.tl` is out of room, and three open board items want to edit it.

Measured 2026-08-28 against `origin/main` at `40776231` and the two PRs
standing in `check`, `#1485` (`3IUBNQZZ`) and `#1486` (`3IVLAF3Z`). Both
branch from `3ff022d3`, where `_perf/gate.tl` is blob-identical to main
(`4561df2b87c65dbf8dcfe4e4e1ece091227785ea`), and both merge clean:

```
git merge-tree --write-tree origin/main pr/1485                # rc 0
git merge-tree --write-tree <that tree as a commit> pr/1486     # rc 0
git cat-file -p <tree>:_perf/gate.tl | wc -l      # 490  (10 free of 500)
git cat-file -p <tree>:_perf/compare.tl | wc -l   # 416  (84 free)
git cat-file -p <tree>:_perf/stats.tl | wc -l     # 127  (373 free)
```

`git show origin/main:_perf/gate.tl | wc -l` is 460 today, so merging the
two PRs in `check` spends 30 of the remaining 40 lines.

Who is waiting on the room:

- `3IWx3I4Z` (`plan`) — the baseline pair as a second control group. Its
  smallest possible plumbing, counted line by line against the merged text,
  is +9 lines (`compare_once` taking `{{string}}`, +4; a `@param` reword,
  +1; the call site at `:295-299`, +4) with NOT ONE line of comment, in a
  function whose neighbouring decision carries a twelve-line comment block
  at `:283-294`. 490 + 9 = 499.
- `3IHHKCyz` (`backlog`) — release artifacts after the gate change; its
  evidence already cites `_perf/gate.tl:157-163`.
- `3IRRr3VN` (`backlog`) — selfcheck overwrites the baseline handed to it;
  read and write roles indistinguishable at the call site.

## The shape a split would take

Not decided here — this is a capture. What a refinement has to settle: the
seam. `gate_inner` is one long function carrying four distinct stages (pass
1, the current retry, the baseline retry and its identity check, the final
triage), and the file also holds `compare_once`, `retry_path`,
`same_binary`, `identity_refusal`, `print_report`, `verdict`, `gate` and
`selfcheck`. The obvious candidates are a `_perf/gateio.tl` holding the
path/load/print helpers, or splitting the staged decision out of
`gate_inner`. Either is a pure move with no behaviour change, which is what
makes it safe to land alone.

## Constraints

- Behaviour-preserving. No verdict, threshold, credit or report line moves.
  `DEFAULT_THRESHOLD_PCT = 10.0` and `TRIAGE_K = 2.0` stay byte-identical,
  and `git grep -nE 'noise_floor|threshold_pct *=' -- _perf/bench` stays
  empty.
- `_perf/gate.tl`'s public surface (`gate`, `selfcheck`, `GateOptions`,
  `SelfcheckOptions`) is what `_perf/gate_test.tl`,
  `_perf/gate_strike_test.tl` and `_perf/gate_identity_test.tl` drive; a
  split may not change it.
- Land it after `#1485` and `#1486`, or it fights them for the same lines.
- `_perf/**` test files are runner mode (D29): `grep -c '^test_'` returns 0
  and only `bin/cosmic --make test` runs them (`3IUKyP4L`, `3IY0HUUk`).

Imported from whilp/cosmic#1198.

## Goal

G8 — the flow system (docs/goals.md). `stats` is the instrument the flow review
reads, and `--days` is the only knob on it; today the knob selects which issues are
fetched and then every number is computed over their whole lifetimes. (No epic
trace: #1117 closed 2026-08-16.)

## Change

Give `_work/stats.tl`&#39;s `summarize` the report window, and make each number honour
it according to what kind of number it is. Two files: `_work/stats.tl` and
`_work/stats_test.tl`. `_work/model.tl` and `_work/github.tl` are not touched.

**1. `summarize` takes the window.** Change its signature from
`summarize(all_stints: {Stint}, now_iso: string): FlowReport` to
`summarize(all_stints: {Stint}, since_iso: string, now_iso: string): FlowReport`,
in the function, in the `record stats` block, and in the doc comment. Derive both
bounds with the existing pure helper: `local from = epoch_of(since_iso) or 0`
beside the existing `local now_epoch = epoch_of(now_iso) or 0`. In `cmd_stats`,
the window start is already computed as `since_iso`
(`local since_iso = time.format_iso8601(now_epoch - days * 86400)`) and is passed
only to `gh.list_issues`; pass it to `summarize` as well, so the one call site
becomes `summarize(stints(events), since_iso, now_iso)`. All seven call sites are
enumerated in the facts block below: one in `_work/stats.tl`, six in
`_work/stats_test.tl`.

**2. `Stint` keeps meaning &#34;the real stint&#34;; the window is a parameter of the
numbers.** Do not build clipped copies of `Stint` and do not rewrite `start`,
`finish` or `ended`. Two reasons, both measured: `ended` and the true `finish` are
what the transition counters and the pickup latency read, and `_work/stats.tl` has
51 lines of headroom against the hard 500-line cap (facts below) — a
copy-producing `clip` function with its doc comment does not fit beside the rest of
this change, and the inline form below is ~25 lines.

**3. Interval numbers are window-scoped.** `stint_count`, `median_dwell_min`,
`max_dwell_min`, `peak_occupancy` and `at_limit_min` are computed over the window
only, by clipping at both ends at the two places that read a stint&#39;s instants:

- **Drop rule**, in the loop that buckets stints by phase: a stint enters its
  phase bucket iff `(s.finish or now_epoch) &gt; from and s.start &lt; now_epoch`. A
  stint that ended at or before `from` contributes nothing; so does one that begins
  at or after the window end.
- **Clamp**, in the dwell loop: `local start_in = s.start &gt; from and s.start or from`
  and `local fin_in = s.finish or now_epoch`, then `if fin_in &gt; now_epoch then
  fin_in = now_epoch end`; dwell is `(fin_in - start_in) / 60.0`.
- **Clamp**, in `occupancy`: give it a `from: integer` parameter (it already takes
  `now_epoch` and `limit`), and emit the `+1` delta at `start_in` and the `-1`
  delta at `fin_in`, computed with the same two expressions under the same two
  names, so a reviewer can diff the two sites by eye.

Do not use `math.max`/`math.min`: Teal types them as returning `number`, which
would force an `as integer` cast into a file that has no row in
`_build/casts_baseline.tl` (fact below) and must not gain one. The inline
conditionals above are integer-typed.

State the consequence in `summarize`&#39;s doc comment: `stint_count` counts stints
**overlapping** the window, and dwell is in-window dwell, not lifetime dwell.

**4. Event numbers are counted by their instant, not clipped.** `accepts`,
`reworks`, `bounces` and the pickup latencies iterate the unclipped `by_issue`
lists exactly as they do now, with one added guard: a transition is counted only
when its instant lies in the window, `cur.finish &gt;= from and cur.finish &lt;= now_epoch`.
A pickup latency stays the **full** wait, `(cur.finish - cur.start) / 60.0`, even
when the wait began before `from` — it measures how long one issue sat in `ready`,
not how the window was occupied, and clipping it would report a shorter wait than
the implementer actually experienced. Both window bounds are inclusive.

**5. The verdict predicate, settled and unchanged in meaning.** Over one issue&#39;s
stints sorted by `start`, for each adjacent pair `cur`, `nxt` with
`cur.ended == &#34;moved&#34;` and `cur.finish` inside the window, in this order:

| counter | predicate |
|---|---|
| bounce | `nxt.phase == &#34;plan&#34; and cur.phase ~= &#34;plan&#34;` |
| accept | `cur.phase == &#34;check&#34; and nxt.phase == &#34;land&#34;` |
| rework | `cur.phase == &#34;check&#34; and nxt.phase == &#34;do&#34;` |
| (nothing) | every other pair |

The three directions out of `check` landed in #1208 and their meaning does not move
here: accept is `check → land`, request-changes is `check → do`, reject is
`→ plan`, and the bounce branch is tested first so a `check → plan` reject counts
once, as a bounce. The one correction to make is the `cur.phase ~= &#34;plan&#34;` guard:
today a `plan` label removed and re-added produces two adjacent `plan` stints and
scores a bounce out of a phase the issue never left.

**6. The header names the window it measured.** In `cmd_stats`, change the header
format string to
`&#34;work flow — %s, %d day(s) since %s, %d issue(s)&#34;` with
`repo, days, since_iso, #issues`. The `work-stats: OK` and `work-stats: ERROR`
verdict lines are unchanged.

**7. Six tests, in `_work/stats_test.tl`&#39;s existing idiom** — a hand-built
`{LabeledEvent}` list of literal ISO 8601 timestamps, through `stats.stints(events)`
and then `stats.summarize(s, since_iso, now_iso)`, with the `secs(minutes)` helper
for interval assertions, `local function test_x()` … `end` and `test_x()` on the
very next line. No `gh.RawEvent`, no network, no recorded fixtures — that idiom
does not exist in this file and must not be introduced. The six existing calls
gain a `since_iso` argument; choose one that keeps each existing assertion true
(each fixture&#39;s events fall inside a window opening before its first event).

- `test_window_clips_a_stint_that_began_before_it` — one `do` stint starting 3h
  before the window, window opening 1h before `now`: `median_dwell_min == 60.0`,
  not 240.
- `test_window_drops_a_stint_that_ended_before_it` — a `do` stint entirely before
  `since_iso`: that phase&#39;s `stint_count == 0` and `median_dwell_min == 0`.
- `test_window_excludes_a_transition_outside_it` — one issue with a `check → land`
  accept before `since_iso` and a second issue with one inside it:
  `backward.accepts == 1`.
- `test_pickup_latency_is_the_full_wait` — a `ready` stint starting 2h before
  `since_iso` whose `ready → do` transition falls inside the window:
  `pickup.count == 1` and `pickup.median_min` is the full 120+ min wait, not the
  in-window part.
- `test_at_limit_minutes_are_window_scoped` — five `do` stints (limit 5) spanning
  the window&#39;s start: `at_limit_min` equals the in-window overlap only.
- `test_plan_relabel_is_not_a_bounce` — `labeled plan`, `unlabeled plan`,
  `labeled plan`: `backward.bounces == 0`.

**8. If the coverage ratchet complains**, run exactly
`bin/cosmic --make coverage --baseline`, commit the result, and confirm the
`_work/stats.tl` row did not go DOWN (a rewrite is a floor rewrite, not a refresh).
Never weaken a check to make the gate pass.

```facts
$ wc -l &lt; _work/stats.tl
449
$ wc -l &lt; _work/stats_test.tl
169
$ grep -c &#39;summarize(stints(events)&#39; _work/stats.tl
1
$ grep -c &#39;stats\.summarize(&#39; _work/stats_test.tl
6
$ grep -c &#39;summarize(stints(events), since_iso, now_iso)&#39; _work/stats.tl
0
$ grep -c &#39;since_iso&#39; _work/stats.tl
2
$ grep -c &#39;accepts = accepts + 1&#39; _work/stats.tl
1
$ grep -c &#39;local function occupancy&#39; _work/stats.tl
1
$ grep -c &#39;^test_&#39; _work/stats_test.tl
6
$ grep -c &#39;_work/stats.tl&#39; _build/casts_baseline.tl
0
$ grep -c &#39;_work/stats.tl&#39; .cosmic-coverage
1
$ wc -l &lt; _work/github.tl
485
```

## Non-goals

- **The accept/rework/bounce meanings do not move.** `check → land` is accept,
  `check → do` is rework, `→ plan` is reject-or-bounce. #1208 landed that split;
  this slice adds the in-window guard and the `cur.phase ~= &#34;plan&#34;` guard to the
  same branch and nothing else. Do not reintroduce the inference rule this issue
  originally proposed (classifying a `review → doing` transition by whether the
  issue later closed) — it is superseded by the phase split.
- **The pre-migration ambiguity is NOT fixed here.** `model.phase_of` maps the
  historical `plan:doing` → `do` and `plan:review` → `check`, so a
  pre-migration accept (`review → doing`, the same transition as a rework before
  #1208 landed 2026-08-16T19:04Z) still scores as a rework whenever the window
  reaches back past that instant. Fixing it needs a legacy-era discriminator on
  the event plus a fourth &#34;unclassifiable&#34; counter, which does not fit in
  `_work/stats.tl`&#39;s 51 remaining lines beside this change. Follow-up slice. What
  this slice does buy: with the in-window guard, any window that opens after the
  migration instant is clean by construction.
- **No pagination.** `gh.list_issues` still requests one `per_page=100` page and
  never follows the Link header. `_work/github.tl` is 485/500 lines, so a
  Link-header follower plus its test cannot land there in this slice. Separate
  slice; do not touch `_work/github.tl`.
- **No change to `_work/model.tl`** — `PHASES`, `LIMITS`, `phase_of`,
  `LEGACY_PHASE`, `is_return` all stay exactly as they are. The window is a
  property of a report, not of the board model.
- **No new flags, no new verbs, no recommendations in the tool.** `stats` measures;
  the planner judges. `--days`&#39; default stays 7 and its validation in
  `_work/board.tl` stays where it is.
- **No new `as` casts in `_work/stats.tl`**, and no new row for it in
  `_build/casts_baseline.tl`.
- **No change to the `work-stats: OK` / `work-stats: ERROR` verdict lines.**
- **No refactor of the module** — do not split the pure core out of
  `_work/stats.tl` while doing this, and do not rename `Stint`, `PhaseFlow`,
  `BackwardMoves`, `PickupLatency` or `FlowReport`.

## Acceptance

- `bin/cosmic --make test _work/stats_test.tl` ends `test: PASS (1 file)`.
- `grep -c &#39;^test_&#39; _work/stats_test.tl` returns `12` (6 today, plus the six named
  tests, each called on the line after its `end`).
- `grep -c &#39;summarize(stints(events), since_iso, now_iso)&#39; _work/stats.tl` returns
  `1` (`0` today) — the window reaches the pure core.
- `test $(wc -l &lt; _work/stats.tl) -le 500 &amp;&amp; echo ok` prints `ok`.
- `grep -c &#39;_work/stats.tl&#39; _build/casts_baseline.tl` returns `0` — no cast was
  added.
- `bin/cosmic --make ci` ends `ci: PASS`.

## Enablement

none needed. The change is confined to the pure core of `_work/stats.tl`, which
`_work/stats_test.tl` already exercises with hand-built event fixtures and no
network, so every new rule is provable by a test in an idiom that already exists in
the file. The two conventions this change could trip — the 500-line cap and the
cast justification — are both gates (`--make lint`) and both are pinned as facts
and acceptance commands above.


---
_Generated by [Claude Code](https://claude.ai/code)_
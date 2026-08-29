## Change

`_work/flowstats.tl`: the G8 flow reader — lead time, rework rate,
and bounce counts derived from the board's own git log, emitted as
`key=value` lines in the house grammar.

The board log already carries every event, in fixed grammars
(sampled 2026-08-29 from `git log --format='%ct %s' origin/board`):

    1788019810 done 3IVUGuv6 completed (from accepted)
    1788019766 verdict 3IVUGuv6 accept by review-3IVUGuv6-1788019588
    1788019571 take 3IVUGuv6 by wave-w3-1788018501 pr:1503
    1788019409 verdict 3IVUGuv6 request changes by review-...
    1788019157 review 3IVUGuv6 claimed by review-...

D37 amended G8's measured-by to lead time, rework rate, and the cost
ratchet; nothing computes the first two today (`ls _work/flowstats*`
→ no such file; the old flowstat.tl was deleted with the phases).

The change, two new files (no gitboard verb — the 14-verb surface is
settled; this is a report script run as
`bin/cosmic _work/flowstats.tl [--dir D] [--since EPOCH]`):

1. `_work/flowstats.tl` (≤500 lines), two halves:
   - PURE: `events_of(lines: {string}): {Event}` parsing
     `%ct %s`-formatted log lines into typed events (take with
     optional pr, drop with why, verdict accept/request-changes,
     done with reason, review claim; unknown subjects skipped), and
     `stats_of(events: {Event}): Stats` deriving, per completed item:
     lead_s (first take → done completed), review rounds (verdict
     count), bounces (non-review drop count); and board-wide: items
     completed, median and p90 lead_s, rework_rate (request-changes
     verdicts / all verdicts, rendered as the pair "x/y" beside the
     ratio), bounce total.
   - IO: read the log via one `cosmic.child` git call
     (`git log --format=%ct %s`, `--since` honored), print one
     `flow item=<id8> lead_s=N rounds=N bounces=N` line per completed
     item and one `flow summary items=N lead_p50_s=N lead_p90_s=N
     rework=x/y bounces=N` line, in the `key=value` grammar
     `cosmic.instrument`/`cosmic.log` share, so downstream readers
     parse it with the standing tools rather than a new format. Use
     `cosmic.proc.is_main()` for the dual-use entry.
2. `_work/flowstats_test.tl`: the pure halves over synthetic event
   lists — the sampled grammar lines above parse to the right events;
   a take→verdict(rc)→take pr→verdict(accept)→done item yields
   rounds=2 bounces=0 and its lead from first take to done; a
   take→drop→take→…→done item yields bounces=1 with lead still from
   FIRST take (time in the queue after a bounce is lead time, that is
   the point of measuring it); an incomplete item contributes
   nothing; summary medians over a three-item set.

## Non-goals

No new gitboard verb, no change to any existing verb or verdict-line
format, no cost ratchet in this slice (its input is CI billing data
the board does not hold — a later item), no persistence: the report
recomputes from the log every run.

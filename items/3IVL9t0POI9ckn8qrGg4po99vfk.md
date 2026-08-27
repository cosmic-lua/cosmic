The strike-twice rule (#1432, _perf/gate.tl:242-249) can discard a
real regression: `flagged_first` is keyed to pass 1's flags, judged
against the ORIGINAL baseline file, while passes 2/3 are judged
against the re-measured baseline (base_side, gate.tl:170). A scenario
whose pass-1 baseline reading was one-off SLOW (masking a true
regression) flags only in pass 2 against the honest baseline retry,
survives triage (real, controls quiet), and is then reclassified to
noise at line 243 ("flagged only in the retry — not reproduced").
Per-scenario baseline one-offs are common by the commit's own evidence
(release.yml cites -39%..+162% per-scenario drift), and because
release.yml re-baselines to the previous release daily, one escape is
absorbed into the ratchet permanently. Related asymmetry worth stating
in the same change: a borderline real regression gets exactly two
samples (gate.tl:200-202 returns 0 on a quiet pass 2 with no A/A and
no third look), so a ~10-15% regression comparable to the cited noise
swings escapes roughly half of runs — and the daily reset means it is
never re-asked. Fix direction: key reproduction on the scenario
flagging in EITHER pass judged against the SAME (retry) baseline, or
require the union rather than intersection to pass triage; state the
sampling asymmetry in the gate's doc either way.

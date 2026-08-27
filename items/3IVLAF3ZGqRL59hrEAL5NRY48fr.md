The perf gate's identity refusals are vacuous for stampless files, and
the noise floor is built on that vacuity: _perf/compare.tl:310-315
returns nil ("pair is sound") when bin_sha is missing, and
_perf/gate.tl:230 admits `current` as a SAME-BINARY noise control
whenever identity_refusal(retry, current, true) == nil — which
includes "current has no stamp at all". A stampless current measured
by a different binary dodges the baseline/current distinctness check
(gate.tl:132) and contributes cross-binary deltas to the noise floor,
inflating credit for every scenario. The comment at gate.tl:225-228
says the drop case "leaves exactly the one pair the gate read before",
but the no-stamp case is admit, not drop. run.tl warns on stampless
output but still writes it. Fix: a control pair requires BOTH stamps
present and equal; stampless files are excluded from controls (and
arguably refused as gate inputs). Related: 3IRRr3VN (selfcheck
overwrites its input) and 3IVEEDO8 (stamps written but never printed).

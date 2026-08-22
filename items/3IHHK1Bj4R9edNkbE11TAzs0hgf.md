Imported from whilp/cosmopolitan#265, where the full spec already
meets the ready bar (Goal/Evidence/Change with measured line numbers,
enumerated golden-file blast radius, Non-goals, Acceptance commands)
and carries the work:ready label.

## Goal

Serve G5 (adversarial verification) end to end: cosmic's json fuzz
slice found the bug; fixing it upstream retires the fuzz bound.

## Evidence

EncodeJson serializes a finite Lua float through ToShortest with no
trailing-decimal-point emission, so any integral-valued float below
1e21 prints as a bare digit string and DecodeJson reads it back as an
INTEGER; in [~1e17, 2^63) the value itself silently changes
(x = 1.775015055792255e18 round-trips to 1775015055792255000, integer;
901 of 2000 lossy samples in 10^[16,18]). Found by cosmic's fuzz
property whilp/cosmic#1128, seed 1, iteration 204 — the fuzz
instrument doing exactly its job.

## Direction

Implement whilp/cosmopolitan#265 as written (the rule: a float always
encodes carrying `.` or an exponent; seven enumerated goldens move).
Then, on the next cosmos pin bump, remove cosmic's #1128 fuzz bound so
the property guards the fix. Lands in whilp/cosmopolitan; the item's
spec IS the issue body.

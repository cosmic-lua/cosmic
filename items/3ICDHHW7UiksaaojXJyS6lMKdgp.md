## Evidence

2026-08-20 audit, reproduced on a local build at main 0b2907b9. In
`_fuzz/driver.tl:159-172` the failure detail `what` is computed from
the ORIGINAL failing iteration while `input`/`draws` come from the
minimized replay, and `shrink`'s `still_fails` accepts a candidate on
ANY failure, not the same one. Reproduced: a check that throws for
`#input > 5` but returns false for `#input > 2` reports
`input(base64)=AAAA` (3 bytes, which does NOT throw) with detail
`threw: …thrown-only-for-long-inputs`. The reported `draws=42` is
also inflated: value-shrinking the length draw leaves 38 recorded
tail draws the generator no longer consumes, so `draws=` overstates
the minimized input's cost. Fix shape: after shrinking, re-evaluate
check once on the minimized input for the reported detail, and
re-record draws through a fresh Recorder for the reported count.

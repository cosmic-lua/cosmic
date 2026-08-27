coldbuild_test and skew_test check that a bootstrap EXISTS, not that
it matches the pin: _build/coldbuild_test.tl:63 and
_perf/skew_test.tl:51 guard on o/bootstrap/cosmic being present, but
bin/cosmic refreshes it only on the cold path (bin/cosmic:138-148,156)
— while o/bin/cosmic exists it execs directly, so a local tree that
pulls a pin bump keeps the old bootstrap indefinitely, and a branch
switch to an older pin keeps a NEWER one: a genuine local false PASS
for the cold-build instrument. CI is sound (pr.yml:127's cache key
hashes bin/cosmic.pin), but these tests exist precisely to catch the
failure before CI. One-line fix: the guard asserts
o/bootstrap/cosmic.pin (or its sha) matches bin/cosmic.pin, and skips
loudly when it does not.

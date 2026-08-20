## Evidence

2026-08-20 audit at main 0b2907b9, by reading. `_fuzz/driver.tl:307-310`:
when `FUZZ_ISOLATE` is set and names a different property, `run()`
returns `true, "...skipped"`, and every fuzz test treats that as a
pass. The variable is documented as internal (set by the parent for
the child it spawns), but nothing refuses an AMBIENT value: a
leaked/exported `FUZZ_ISOLATE` in a CI environment would skip every
property in every file with a green result. Fix shape: the parent
should pass the marker only to the child's constructed env (as
COSMIC_MAKE_ROOT is dropped by testrun), or the driver should refuse
an ambient value that doesn't match its own spawn protocol.

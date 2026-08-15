# D4 — portability is delegated to Cosmopolitan

- **date:** 2026-07
- **status:** active
- **context:** cosmic claims six OSes on two arches, but CI runs on
  ubuntu only — under "documented behavior is verified behavior," an
  unverified claim is a bug. verifying the full matrix means BSD VMs,
  arm runners, and slow CI.
- **decision:** cross-OS portability is Cosmopolitan's promise,
  inherited and trusted. cosmic verifies its own layer on Linux and
  treats cross-OS breakage as an upstream bug. docs phrase the six-OS
  claim as inherited from Cosmopolitan, not verified by cosmic.
- **rejected:** full-matrix CI on every PR; tiered own-CI verification;
  demoting unverified platforms from the README.
- **consequences:** cheap CI; an acknowledged seam in the verification
  story, accepted deliberately. revisit if cross-OS breakage actually
  bites.


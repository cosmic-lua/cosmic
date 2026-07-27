# D7 — contained by default

- **date:** 2026-07
- **context:** cosmic has deep sandboxing machinery (pledge, unveil,
  landlock, quicksand, the `sandbox` facade), all opt-in from inside
  the script. self-sandboxing protects against bugs, not against
  generated or untrusted code that simply doesn't call it — and
  generated code is a first-class workload here.
- **decision:** scripts run under a restrictive default policy;
  capabilities are granted explicitly by the operator
  (`--allow-net`-style). the denial message names the capability and
  the exact grant — the denial experience is part of the interface
  (G2).
- **rejected:** sandbox-as-library (status quo); paved-path idiom
  without enforcement; operator-side opt-in policy files as the
  ceiling.
- **consequences:** a deliberate compatibility break for existing
  scripts (permitted by D10). **open question:** on platforms where
  Cosmopolitan cannot enforce containment, fail closed or warn-and-run?
  must be decided before G2 ships; leaning fail-closed per D3.


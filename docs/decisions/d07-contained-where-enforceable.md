# D7 — contained by default where the OS can enforce it

- **date:** 2026-07
- **status:** amended 2026-08 (rescoped by D25)
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

- **amended 2026-08 (rescoped by [D25](d25-outcomes-and-instruments.md)):**
  the open question is answered, and the answer is neither option it
  offered. the decision above assumed a single mediation point a policy
  could interpose, on the Deno model; cosmo has none — a script talks to
  libc directly, and enforcement is OS-gated (pledge/unveil, landlock,
  seccomp). so a portable default-deny is not enforceable, is not
  promised, and is now an explicit non-goal in goals.md.

  what survives is the whole decision minus its universality: deny by
  default on platforms whose OS can enforce it, a denial that names the
  capability and the exact flag that grants it, and containment status a
  script can always query — so an unenforcing platform is honest rather
  than silently unprotected. the title said "contained by default" flatly,
  which is the half that did not survive, and was corrected with the
  record.


# D10 — perpetual right to break

- **date:** 2026-07
- **context:** daily date-versioned releases, no semver, no
  compatibility promise — increasingly load-bearing as user projects
  couple to `cosmic.*` signatures via G4.
- **decision:** no stability promise. cosmic may break anything in any
  release; changelogs note breakage; users pin a release binary they
  trust. honest types make breakage loud at typecheck time, which is
  the safety mechanism.
- **rejected:** migration tooling as a requirement for breakage; a
  declared stable core; semver and a 1.0.
- **consequences:** maximum evolution speed. agents — a first-class
  user — refit code cheaply, making this cheaper than it looks. pinning
  is the user's responsibility and the documented idiom.


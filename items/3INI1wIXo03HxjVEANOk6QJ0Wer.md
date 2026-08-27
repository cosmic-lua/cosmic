## Goal

AGENTS.md's cosmo-to-cosmic mapping table sends a reader to a
function that exists: the table is exactly what a session reaches for
when it needs the cosmic name for a `cosmo.*` call, and it currently
names `fs.chmod`, which #988 renamed to `set_mode`.

## Change

One row in AGENTS.md's mapping table:
`| cosmo.unix.chmod(p, m) | require("cosmic.fs").chmod(p, m) |`
becomes
`| cosmo.unix.chmod(p, m) | require("cosmic.fs").set_mode(p, m) |`.

Verified 2026-08-27: `cosmic/fs/init.tl:149,283` export `set_mode`;
no `fs.chmod` exists. The `unix.chmod` calls inside `cosmic/fs/*`
are the C-binding side of the wrappers and stay.

## Non-goals

No rename revisit (settled at #988); no other table rows (swept:
the rest resolve).

## Acceptance

`grep -n "chmod" AGENTS.md` shows the row pointing at `set_mode`;
`--make ci` PASS.

## Enablement

None.

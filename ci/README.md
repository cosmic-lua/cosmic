# CI driver

`ci/` is a project of its own inside the checkout, distinct from cosmic's
own tree: it has no `core/` or `build/`, so cosmic's own build never walks
it (`build/work.tl`'s `foreign_trees`), and the pinned host never tries to
rebuild itself from the candidate. It is run in place by the pinned,
digest-verified host, with cwd `ci/`, so the host's project root is `ci/`
itself. `cosmic_ci/` is its Teal namespace; `testdata/` holds fixture input
and is excluded from module and test discovery. Its working database lands
at `ci/o/build.db` (gitignored).

`bootstrap-driver.sh` downloads and verifies the pinned host, caching it by
digest, and copies it to a runner path. `run-driver.sh` then runs the
driver in place: `cd ci && $COSMIC_DRIVER cosmic_ci/driver.tl ...`.

Orchestration copies `cosmic_ci/` once per fixture into a separate,
external fixture project, since each fixture needs a fresh working
database and the verdict cache is blind to the fixture's environment
overrides. Runner operation state is kept in a separately checked external
database. The checked-in pin (`cosmic-driver.pin`) is the production trust
root; local development may preseed a temporary pin cache with a
digest-verified locally built host, but that does not establish release
publication or immutability.

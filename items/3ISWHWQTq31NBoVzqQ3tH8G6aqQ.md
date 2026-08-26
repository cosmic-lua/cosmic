## Goal

The release lane runs again. Since #1382 (2026-08-25), `_perf/run.tl:148`
calls `cosmic.version_info()` as a typed field; release.yml's "compare
against the previous release" step runs the PREVIOUS release binary in
bare-script mode, where scripts resolve against the binary's EMBEDDED
modules and types — and the 2026-08-23 release's embedded `cosmic`
record predates the API. The step dies on
`invalid key 'version_info' in record 'cosmic'` before measuring
anything (run 32940138465, 2026-08-26). This is a bootstrap deadlock:
no release can publish until a release knows the API, and no release
knows the API until one publishes.

## Evidence

- Run 32940138465 (2026-08-26 schedule), step "compare against the
  previous release": `cosmic-lua: _perf/run.tl:148:20: error: invalid
  key 'version_info' in record 'cosmic' of type record cosmic`.
- `_perf/run.tl:148–152` (main `8f34339e`): `local v =
  cosmic.version_info()` then `meta.cosmic_version = v.cosmic`,
  `meta.cosmos_version = v.cosmos`.
- `cosmic.version_info` added by `47adef2c` (#1382, merged 2026-08-25
  21:41 UTC) — NOT an ancestor of the last published release
  `2026-08-23-d71d7f1` (verified with merge-base).
- AGENTS.md Performance: "bare scripts load the binary's embedded
  copies" — the compare step's baseline run is exactly that mode.

## Change

`_perf/run.tl` reads the version stamps tolerantly, so the file
type-checks and runs under an embedded env that predates the API:
look the function up through a map view of the module
(`(cosmic as {string: any}).version_info` with a `-- cast:` reason
naming the skew), guard with `is function(): any`, and narrow the
result's fields with the standard is-guards before assigning
`meta.cosmic_version`/`meta.cosmos_version`. Under an old binary the
field is nil and the stamps are simply absent — the same shape those
results had before #1382. Validate the exact shape with
`o/bin/cosmic --check types` on the edited file AND with the pinned
release binary (`2026-08-15` predates the API too, so
`bin/cosmic` cold-running the script is itself the reproduction).

Consequence to note in the PR: any `_perf/**` use of a cosmic API
newer than the previous release re-creates this deadlock; the general
guard (a compat rule for the harness, or the compare step measuring
the previous release with its own embedded scenarios) is a follow-up
decision, not this fix.

## Non-goals

- No release.yml change; no perf_gate skip.
- No touch of the two flagged perf regressions — 3ISWHyP7's.
- No change to what the stamps mean when present.

## Acceptance

- The reproduction first: the PINNED release binary (predates the
  API) running `_perf/run.tl` in bare-script mode fails today with
  the invalid-key error, and passes after the change (a short run,
  e.g. one bench module, suffices).
- `bin/cosmic --make ci` ends `ci: PASS`.
- `git diff --name-only origin/main` lists exactly `_perf/run.tl`.
- After land: the next release.yml run gets past "compare against the
  previous release"'s type check (its verdict is then 3ISWHyP7's
  perf question, not a crash).

## Enablement

none needed. The tolerant-lookup shape is the pre-#1382 pattern the
tree already used (pcall + cast); the pinned binary doubles as the
old-env reproduction, so no release download is required.

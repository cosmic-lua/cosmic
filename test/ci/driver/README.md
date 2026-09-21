# CI operation driver

`bootstrap-driver.sh` verifies the immutable prerelease pin on downloads, cache
hits, and the copied runner. It copies every `driver/*.tl.in` template, removing
only the final `.in`, to a temporary project outside the candidate checkout.
That project contains the driver modules, the shared fixture helper, and the
fixture test sources. The runner must also live outside the checkout. This
keeps the pinned Cosmic process responsible for CI control while candidate
Cosmic, applications, native decoders, and cores remain the explicit subjects
executed by each fixture case.

Product construction, transport validation, and format validation each run in
a fresh external Cosmic project containing only `fixture.tl` and the intended
`*_test.tl`. Candidate and fixture paths enter through named environment
values. The pinned runner executes `cosmic test`; the driver requires at least
one test to run and zero verdicts to stand, so a cached result can never supply
an integration verdict. Its controlled `TMPDIR` is under the worker directory,
where failed test directories and each direct-child stdout/stderr file remain
available to the platform diagnostics upload.

The driver writes a committed `start` event before launching each operation and
a separate `complete` event afterward. A killed driver therefore leaves an
`incomplete` operation visible to `report`. The SQLite events retain phase
elapsed time and exit detail. Fixture helpers additionally report per-subprocess
elapsed time and redirect output to retained files; diagnostics read bounded
previews rather than accumulating child output in memory.

Run an operation with:

```sh
cosmic driver.tl run DB WORKER RUN ATTEMPT PHASE CANDIDATE TIMEOUT_MS EXECUTABLE ARGS...
```

Write a Markdown report with:

```sh
cosmic driver.tl report DB REPORT.md
```

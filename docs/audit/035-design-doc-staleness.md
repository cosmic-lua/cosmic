# 035 — design docs behind (or ahead of) their own code

severity: low (docs), but the design docs are the project's spine
type: docs
area: `docs/design/make.md`, `docs/design/make-plan.md`,
`docs/design/make-log-selfbuild.md`, `skills/cosmic/make.md`

## issue

the branch's design record is unusually good, which makes the drift worth
sweeping — several statements now contradict the code or each other. one
item per line, verified against the tree at 180b0d3:

### make.md

1. **line ~306** — "`AddOptions.mtime` … is not plumbed through `embed.run`
   today." stale: `_make/artifact.tl:388` passes `mtime = embed.EPOCH` and
   `cosmic/embed/init.tl:412` forwards it. (skills/cosmic/make.md:83-86
   already states reproducibility as done — the design doc is behind its
   own skill.) note the `--embed` CLI half genuinely is unplumbed — see
   011 — so the corrected sentence should say which half.
2. **line ~155** — the unit table says a pin's output is "`D/<name from the
   url>` ⚠". stale since 6d6e71c: `landing()` joins `project.BUILD_DIR`,
   so bytes land at `o/D/…`. the same file's external-assets section
   (~line 234) already says "lands the bytes under `o/`" — the doc
   contradicts itself; fix the table row.
3. **line 39 and the verbs section (~470-498)** — `cosmic --make ci` shown
   as a working command and `run`/`regen`/`ci`/`coverage`/`enforce`/
   `reproducible`/`offline` listed without status. actual
   (`_make/init.tl:32-42`): build, check, clean, fetch, fmt, test are
   implemented; the other seven are stubs printing "planned but not
   implemented". the documented `ci` ordering also names `example` and
   `lint` stages that exist as no verb at all. mark statuses in the doc.

### make-plan.md

4. **lines 12-16** — describes a `bin/cosmic` + `bootstrap/cosmic.pin.tl`
   one-pin trust root that does not exist: the trust root is still
   `bin/make` with the bootstrap url+sha in `cook.mk`, two pinned
   artifacts. either build it or mark the section as target-state.
5. **lines ~388-392** — "`cosmic.instrument` and `cosmic.script_cache` are
   **public**". half stale: 18c94c6 re-internalized script_cache
   (`cosmic/_script_cache.tl`; the public surface is
   `cosmic.teal.compile_cached`). instrument remains public.

### make-log-selfbuild.md

6. **lines 181-190** — the "Not fixed here, and named so it is not lost"
   note about the duplicated compile-with-cache loop was subsequently fixed
   (`cosmic/teal.tl:457 compile_cached`, both callers converted, 18c94c6)
   and never closed out. add the closing line the log format uses.

### skills/cosmic/make.md

7. **lines 149-150** — "the fetched asset lands beside its pin …
   (`3p/lpeg/lpeg-1.0.2.tar.gz`)". stale since 6d6e71c; it lands at
   `o/3p/lpeg/…`. the rest of the skill checked out accurate (verbs table
   matches implemented/planned exactly; engine env vars; EPOCH mtime).

## suggested fix

one docs commit sweeping all seven, in the logs' own style (amend, don't
relitigate). 011's fix may land first and change what item 1's corrected
sentence should say.

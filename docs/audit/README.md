# audit — `cosmic --make` branch review

findings from a review of branch `claude/cosmic-make-embedded-artifact-qpfsgr`
at commit `180b0d3` ("make: close the fixpoint"). every file here is one issue,
with enough detail to find and fix it: location, failure scenario, and a
suggested fix. line numbers reference the tree at that commit.

`bin/make ci` passes on the branch; none of these block the branch's own
claims for this repo. several are traps for the downstream user-project case
`--make` targets, and the headline fixpoint claim is verified only by hand
(see 026).

## index

### bugs — high

| id | issue |
|---|---|
| [001](001-fetch-satisfied-skips-unpack.md) | a verified archive permanently skips unpacking after a failed unpack |
| [002](002-root-embed-gen-not-run.md) | a root `embed.gen.tl` never runs for `cmd/` binaries |
| [003](003-fmt-file-set-mismatch.md) | full `--make fmt` and selected `fmt` disagree on the file set |
| [004](004-literal-string-decoding.md) | `cosmic.literal` returns wrong string values (escapes, long brackets) |
| [005](005-literal-stack-overflow.md) | `cosmic.literal` throws on deep nesting — contract violation, crash on crafted pin |

### bugs — medium

| id | issue |
|---|---|
| [006](006-fetch-http-status.md) | non-2xx fetch responses are hashed instead of reported |
| [007](007-dtl-no-recompile.md) | `.d.tl` contract changes never recompile importers |
| [008](008-make-metachars-filenames.md) | make-significant characters missing from the filename gate |
| [009](009-stored-path-collisions.md) | stored-path collisions in the artifact resolve nondeterministically |
| [010](010-lua-test-files-ship.md) | `*_test.lua` / `*_example.lua` classify as modules and ship |
| [011](011-embed-mtime-not-default.md) | plain `cosmic --embed` output is not reproducible |

### security

| id | issue |
|---|---|
| [012](012-script-cache-poisoning.md) | script cache in shared `/tmp` executes unverified planted code |
| [013](013-exec-symlink-escape.md) | `exec` root check is lexical; a symlink under `o/` escapes it |
| [014](014-fence-unexercised.md) | derived fence is unexercised in production and its floor is incomplete |

### bugs — low

| id | issue |
|---|---|
| [015](015-root-init-never-ships.md) | root `init.tl` compiles but silently never ships |
| [016](016-cosmic-make-relative-path.md) | relative `COSMIC_MAKE` resolves against the project root, not cwd |
| [017](017-extract-make-tmp-race.md) | `extract_make` tmp-file race between concurrent builds |
| [018](018-imports-of-false-positives.md) | `imports_of` matches `require` in comments and strings |
| [019](019-pin-validation-gaps.md) | pin digest length and url-derived output name unvalidated |
| [020](020-duplicate-binary-names.md) | duplicate binary names silently overwrite each other |
| [021](021-strip-into-drops-symlinks.md) | `strip_into` silently drops symlinks tar deliberately preserved |
| [022](022-style-lint-silent-pass.md) | `style.lint_file` silently passes files it cannot read |
| [023](023-tar-drive-letter-paths.md) | tar path guard misses drive-letter names embed's guard rejects |
| [024](024-tar-partial-extraction.md) | tar failure semantics: partial extraction, missing terminator accepted |

### stripped artifacts

| id | issue |
|---|---|
| [036](036-literal-unloadable-stripped.md) | `cosmic.literal` fails to load in every stripped artifact |
| [037](037-searcher-stripped-error-shape.md) | the searcher turns every require miss into a `tl` error when stripped |

### tests and ci

| id | issue |
|---|---|
| [025](025-pin-test-wrong-path.md) | `test_a_mismatch_is_never_written` asserts a path nothing writes to |
| [026](026-fixpoint-not-in-ci.md) | the self-build fixpoint is not gated by any ci lane |
| [027](027-embed-gen-untested.md) | `cmd/cosmic/embed.gen.tl` has no payload test |
| [028](028-make-fetch-ungated-in-ci.md) | `--make fetch` never runs in ci against the real pins |
| [029](029-graph-tests-skip-silently.md) | `--make` graph tests degrade to green skips without the engine |

### refactor / cleanup

| id | issue |
|---|---|
| [030](030-dual-pin-fetch-pipelines.md) | two live pin-fetch pipelines over the same committed files |
| [031](031-build-flag-retirement.md) | `--build` retirement clock has no in-tree tracking |
| [032](032-import-scan-memoization.md) | import scans re-read and re-regex every source per consumer |
| [033](033-minor-cleanups.md) | minor cleanups: stale comments, stray export, duplicated helper |

### docs

| id | issue |
|---|---|
| [034](034-user-docs-pin-mechanism.md) | user-facing docs still document `3p/*/version.lua` pins |
| [035](035-design-doc-staleness.md) | design docs behind (or ahead of) their own code |

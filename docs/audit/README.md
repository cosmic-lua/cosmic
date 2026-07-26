# audit — `cosmic --make` branch review

findings from a review of branch `claude/cosmic-make-embedded-artifact-qpfsgr`,
originally at commit `180b0d3` ("make: close the fixpoint"), re-reviewed at
`4a15b92` ("make: fix 18 findings from the branch audit"). every file here is
one open issue, with enough detail to find and fix it: location, failure
scenario, and a suggested fix. ids are stable; resolved entries are deleted
(their text lives in this directory's git history) and listed below.

## open

### bugs

| id | severity | issue |
|---|---|---|
| [038](038-literal-u-escape-drops-chars.md) | high | `cosmic.literal` `\u{}` escape swallows the next two characters (regression in 4a15b92) |
| [007](007-dtl-no-recompile.md) | medium | `.d.tl` contract changes never recompile importers |
| [024](024-tar-partial-extraction.md) | low | tar failure semantics: partial extraction, missing terminator accepted |
| [039](039-import-scanners-disagree.md) | low | the two import scanners disagree again; long comments still refuse |

### security

| id | issue |
|---|---|
| [012](012-script-cache-poisoning.md) | script cache in shared `/tmp` executes unverified planted code |
| [013](013-exec-symlink-escape.md) | `exec` root check is lexical; a symlink under `o/` escapes it |
| [014](014-fence-unexercised.md) | derived fence is unexercised in production and its floor is incomplete |

### stripped artifacts

| id | issue |
|---|---|
| [036](036-literal-unloadable-stripped.md) | `cosmic.literal` fails to load in every stripped artifact |
| [037](037-searcher-stripped-error-shape.md) | the searcher turns every require miss into a `tl` error when stripped |

### design / durability

| id | severity | issue |
|---|---|---|
| [040](040-artifact-file-near-cap.md) | medium | `_make/artifact.tl` at 464/500 lines; split on its seams before the cap forces one |
| [041](041-verb-registry-fragmented.md) | medium | adding a verb touches five structures plus two if-chains; phase 4 adds seven verbs |
| [042](042-unpack-manifest-implicit-format.md) | low | `.unpacked` manifest is a line format over names nothing validates |
| [043](043-root-sentinel-strings.md) | low | `""` as the root-unit sentinel recurs unnamed across artifact.tl |
| [044](044-cast-clusters-mark-loose-types.md) | low | cast clusters mark types looser than the code they describe |

### tests and ci

| id | issue |
|---|---|
| [026](026-fixpoint-not-in-ci.md) | the self-build fixpoint is not gated by any ci lane |
| [028](028-make-fetch-ungated-in-ci.md) | `--make fetch` never runs in ci against the real pins |
| [029](029-graph-tests-skip-silently.md) | `--make` graph tests degrade to green skips without the engine |

### refactor / cleanup

| id | issue |
|---|---|
| [030](030-dual-pin-fetch-pipelines.md) | two live pin-fetch pipelines; 4a15b92 copied behavior across, widening the duplication |
| [031](031-build-flag-retirement.md) | `--build` retirement clock has no in-tree tracking |
| [032](032-import-scan-memoization.md) | import scans re-read and re-regex every source per consumer |
| [033](033-minor-cleanups.md) | minor cleanups: stale comments, stray export, duplicated helper |

### docs

| id | issue |
|---|---|
| [034](034-user-docs-pin-mechanism.md) | user-facing docs still document `3p/*/version.lua` pins |
| [035](035-design-doc-staleness.md) | design docs behind (or ahead of) their own code |

## resolved

fixed by `4a15b92` and verified against its diff (several empirically):

| ids | what was fixed |
|---|---|
| 001 | fetch `satisfied` requires unpack products (`.unpacked` manifest); repair re-unpacks |
| 002 | generation is a phase over the project; root generator runs once, before staging |
| 003 | `fmt` file set derives from one `types.fmt_kinds` for both facts and selection |
| 004 | literal decodes escapes and long brackets, accepts negatives — but see 038 |
| 005 | literal depth-capped at 32; polite refusal instead of a thrown stack overflow |
| 006 | non-2xx refused by status; retries and a 100 MB cap match `_build`'s fetcher |
| 008 | `%`, `:`, `=`, `,` added to the filename gate |
| 009 | stored-path collisions refused, naming both origins |
| 010 | `_test`/`_example` markers extension-agnostic; `.lua` tests run and don't ship |
| 011 | `--embed` defaults mtime to the floor epoch; rebuilds byte-identical |
| 015 | root `init.tl` refused by the validator ("did you mean main.tl?") |
| 016 | `COSMIC_MAKE` absolutized before the chdir, beside the `arg[-1]` handling |
| 017 | `extract_make` temp name is per-pid; losing the rename race is success |
| 018 | validator's import scan frontier-anchored, line comments stripped — residuals in 039 |
| 019 | pin sha must be exactly 64 hex; url-derived names validated before `fs.join` |
| 020 | duplicate binary names refused by `check_binaries` |
| 021 | archives containing symlinks refused loudly (kept honest for 013) |
| 022 | `style.lint_file` returns `nil, err` on unreadable files; callers updated |
| 023 | tar path guard rejects drive-letter prefixes, matching embed's guard |
| 025 | mismatch test asserts the real `o/` landing path; unpack-repair tests added |
| 027 | `cmd/cosmic/embed.gen.tl` tested against the real tree, contract entries named |

review notes on the fix pass itself: the quality is high — single-definition
kind sets (003), refusals over silent guesses (009, 015, 020, 021), comments
that record the why. two things came out of re-reviewing it: the `\u{}`
off-by-two (038, invisible to its own test because the only `\u` case sits at
end-of-string), and the validator/deps scanner asymmetry (039). the copied
fetch behaviors also widen 030's duplication.

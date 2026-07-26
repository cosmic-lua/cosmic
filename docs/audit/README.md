# audit — `cosmic --make` branch review

findings from a review of branch `claude/cosmic-make-embedded-artifact-qpfsgr`,
originally at `180b0d3` ("close the fixpoint"), re-reviewed at `4a15b92`
("fix 18 findings") and again at `1ca5fd1` (six fix commits: fixpoint gate,
cache security, exec realpath, tar terminator, `.d.tl` closures, doc sweeps).
every file here is one open issue with location, failure scenario, and a
suggested fix. ids are stable; resolved entries are deleted (their text lives
in git history) and listed below.

## open

### bugs

| id | severity | issue |
|---|---|---|
| [038](038-literal-u-escape-drops-chars.md) | **high — oldest open item** | `cosmic.literal` `\u{}` escape swallows the next two characters (regression in 4a15b92) |
| [039](039-import-scanners-disagree.md) | low | the two import scanners disagree; long comments still refuse |

### security

| id | issue |
|---|---|
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

### feature design (implementation-independent)

| id | severity | issue |
|---|---|---|
| [045](045-implicit-asset-default.md) | medium | assets ship by default; every other kind is opt-in by marker |
| [046](046-gen-marker-two-meanings.md) | medium | `.gen.tl` marks two different unit kinds, split by basename prose |
| [047](047-selection-means-different-things.md) | medium | selection narrows targets for `test`/`fmt`, truncates the pipeline for `build` |
| [048](048-ci-stages-without-verbs.md) | low | `ci`'s pipeline names stages no verb covers (doc half closed in 944a352) |
| [049](049-pin-grammar-coherence.md) | low | pin grammar: url-derived output naming and the dual sha spelling |
| [050](050-version-stamp-implicit-input.md) | low | `COSMIC_VERSION` is the one build input not enumerable from the tree |

### 3i readiness — removing the Makefile bridge

056 is the mechanism; it names the dependency order the others land in.

| id | issue |
|---|---|
| [051](051-bridge-gate-verb-parity.md) | the ci gate has no `--make` equivalent yet (ci, example, lint, coverage) |
| [052](052-bridge-enforcement-parity.md) | deleting the .mk files deletes today's only real sandbox (sequencing with 014) |
| [053](053-bridge-release-parity.md) | the release artifact still comes from the Makefile (debug variant, weight, parity gate) |
| [054](054-bridge-generation-workflows.md) | regen, type generation, and docs publishing have no `--make` home |
| [055](055-bridge-trust-root-swap.md) | the one-pin trust root (`bin/cosmic`) does not exist yet |
| [056](056-bridge-transition-mechanism.md) | the transition needs a dual gate and a target disposition table |

### tests and ci

| id | issue |
|---|---|
| [028](028-make-fetch-ungated-in-ci.md) | `--make fetch` never runs in ci against the real pins (now a 056 prerequisite) |
| [029](029-graph-tests-skip-silently.md) | `--make` graph tests degrade to green skips without the engine |

### ci convergence — the workflow files themselves

| id | severity | issue |
|---|---|---|
| [057](057-ci-setup-six-copies.md) | medium | the CI environment block is copied six times, and docs.yml has none |
| [058](058-ci-lanes-are-verbs.md) | medium | lane logic lives in YAML bash; the policy verbs are its destination |
| [059](059-ci-git-dependencies.md) | low | the gate's git dependencies retire with the verbs; assert the git-free gate |
| [060](060-coverage-environment-sensitivity.md) | low | the coverage ratchet's environment-sensitivity is the root of CI's pinning complexity |

### refactor / cleanup

| id | issue |
|---|---|
| [030](030-dual-pin-fetch-pipelines.md) | two live pin-fetch pipelines; 4a15b92 copied behavior across, widening the duplication |
| [031](031-build-flag-retirement.md) | `--build` retirement clock has no in-tree tracking |
| [032](032-import-scan-memoization.md) | import scans re-read and re-regex every source per consumer |
| [033](033-minor-cleanups.md) | one leftover: `tar.parse_pax` exported for tests only |

## resolved

### round 3 — the six commits through `1ca5fd1`, verified against their diffs

| ids | what was fixed |
|---|---|
| 007 | `.d.tl` files are source-closure deps (list per import path; declarations never built targets); the test that encoded the bug replaced |
| 012 | compile cache per-user (`$XDG_CACHE_HOME/cosmic/tl` else uid-suffixed tmp), 0700 at creation, load/store refuse un-owned or group/world-writable dirs; both directions tested against a planted trojan |
| 013 | `exec` resolves program AND root through realpath, refusal names the resolved path, prefix matches on a separator boundary (closing an `o-other/` sibling case beyond the audit's ask); in-root links still run |
| 024 | unterminated archives refused; partial-extraction documented as the contract (staging is the caller's job — recorded reasoning accepted) |
| 026 | fixpoint gated as `_make/fixpoint_test.tl` in existing lanes: gen2 capability smokes + gen2/gen3 byte compare, both halves falsified before commit |
| 034 | user docs rewritten around `*.pin.tl`; grep-verified no instruction-shaped `version.lua` hits remain |
| 035 | all seven design-doc items: units table, mtime claim, verb statuses `[now]`/`[planned]`, provisioning marked target-state, script_cache publicness, selfbuild close-out, skill landing path |
| 033 (most) | see the entry's resolved list; `appender:remove()` closed as won't-fix with the reason at the site |

### round 2 — fixed by `4a15b92`

001 (fetch unpack manifest + repair), 002 (generation phase), 003 (one
`fmt_kinds`), 004 (escape decoding — but see 038), 005 (depth cap),
006 (http status/retries/cap), 008 (make metacharacters), 009
(stored-path collisions refused), 010 (extension-agnostic test markers),
011 (`--embed` epoch mtime), 015 (root `init.tl` refused), 016
(`COSMIC_MAKE` absolutized), 017 (per-pid temp), 018 (anchored import
scan — residuals in 039), 019 (64-hex sha, name validation), 020
(duplicate binary names refused), 021 (symlinked archives refused),
022 (`lint_file` honest nil), 023 (drive-letter guard), 025 (mismatch
test asserts the real path), 027 (embed.gen tested against the real
tree).

## note for the next fix pass

**038 is the item to take first**: it is high severity, one line
(`literal.tl:75` — return `after` unmodified; a position capture is
already absolute), it was introduced by round 2's fix for 004, and it
has now survived two fix passes — likely because those passes worked
from the round-1 list. the round-3 commits were verified sound on
re-review; the exec fix and the cache fix are both better than the
audit asked for.

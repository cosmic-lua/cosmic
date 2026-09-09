# Make-only startup capability: executable evidence

The initial pass below records lmuu_JdtZ on product base
`0887935e2e072b0fffe52508a6115003f22eacc6`. It supersedes only the
startup assumption in [the earlier warm-tree reproduction](coldbuild-staleness.md).
It is capability evidence, not evidence that the old release was activated.

## Boundary and contracts

The dispatcher parses once and applies its existing environment fallbacks.
Only effective top-level make, without an explicit manifest, discovers an
absolute root and installs the source-only searcher before command handlers.
`_build/make_boundary.tl` names the pinned parser/root/searcher/compiler
prefix; `_build/make_boundary_test.tl` measures it in a fresh real child.
Successful discovery is shared with `_make.init` without an early chdir.

Each make-source compile has a fresh type environment and root-first sibling
lookup, including generated declarations. It neither reads nor writes the
normal code/type caches, and it never trusts implicit built Lua. The scoped
context and Teal lookup state are restored on success, diagnostics, and throws.
The small lookup adapter preserves Teal's foreign filename/file/errors tuple;
Teal's declaration omits the nil miss that its implementation returns, so the
adapter explicitly casts that foreign protocol rather than creating a new
three-slot Cosmic fallible API.

Generator children still receive the existing explicit closure manifest.
Their dispatcher no longer imports unused main handlers; `_cli.script`
retains the previous entry-script loader and the handler API forwards to it.
The measured tool boot list adds the two new startup/script module names;
stamp hashing, closure generation and manifest resolution are unchanged.
Explicit user requires still see the old manifest fallback/type-cache rules.

## Reproduce the cold control

The original bootstrap is the unmodified `2026-09-07-2b2002d` release,
SHA-256 `b4bb8bde84fc54c4298e4d63d949a1af071d2ff5a2e1ba095fa70d9e342ee434`.
Dependency caches were reused only after verifying their pin inputs matched;
no bootstrap source, pin, executable, or stamp was rewritten.

Run these from a worktree with verified dependencies and bootstrap present.
Each cold fixture destination must be new. The helper copies full source,
symlinks, `o/3p` and `o/bootstrap`, but no compiled output or code cache. It
widens both lint declarations and the handler caller as in PR #1775.

```sh
sh o/bootstrap/cosmic --make build
sh o/bin/cosmic _build/testdata/make_cold.tl o/bootstrap/cosmic o/cold-old-pin
sh o/bin/cosmic _build/testdata/make_cold.tl o/bin/cosmic o/cold-capability
```

The old-pin control failed in `_types/tlast_gen.tl` startup with the handler's
`given 2, expects 1` error. The production capability fixture completed its
first build: `build: PASS (661 files, 1 binary)`. The latter is an explicit
capability runtime invocation, not a warm convergence or a replaced old pin.
The earlier make-only research candidate failed the generator-child control;
the production mutation below also restores that unused dependency.

## Focused and mutation proof

```sh
sh o/bin/cosmic _build/testdata/make_mutations.tl
bin/cosmic --make coverage _make/startup_test.tl cosmic/_searcher_make_test.tl cosmic/_teal_project_test.tl _cli/script_test.tl _build/make_boundary_test.tl
bin/cosmic --make ci --min 76 --min-file 0
```

The manual driver mutates copies of the artifact's generated production Lua,
never tracked Teal or the baseline binary. Five focused files pass before and
after the mutations. All seven controls were killed by their intended tests:

- Remove early installation: the tree handler sentinel is not selected.
- Remove root precedence: widened sibling types no longer agree.
- Use strict persistent code caching: a sibling-only edit is missed.
- Prefer implicit built Lua: the stale built sentinel wins.
- Share type environments: a same-caller sibling/declaration edit is missed.
- Eagerly import main handlers: explicit-manifest child entry fails.
- Load scripts through main handlers: generator-script entry fails.

The focused tests also cover ordinary pin-first scripts and script arguments
that spell make; explicit-manifest priority and its preserved arity failure;
make help, unknown verbs and invalid roots; environment command precedence;
two roots, TL_PATH and generated declarations; compiler throws; absolute
POSIX/Windows/UNC root forms; and script shebangs, load errors and tracebacks.
Existing manifest scanner/closure/error and conflicting-command tests remain
unchanged and are included in the full suite.

The final local full gate passed build (661 files), format/types (663 files),
examples (40 files), and lint (780 files). Coverage passed 289/304 files.
The remaining files were the expected old-pin boundary check and 14 existing
macOS runtime failures/stalls: `_cli/build/recipe_test`, `_cli/driver_test`,
`_make/fixtures_test`, `_perf/perf_test`, `_tool/testrun_test`,
`cosmic/compile_test`, `cosmic/fs/times_test`, `cosmic/net/connect_test`,
`cosmic/net/init_test`, `cosmic/net/io_test`, `cosmic/proc_test`,
`cosmic/time_test`, `cosmic/tty_pty_test`, and `cosmic/tty_test` (all `.tl`).
The four stalled recipe/driver/net-io/PTY tests were explicitly terminated
after the other files finished; their termination is not a passing result.
The five new focused files, nil-return ratchet and boot-stamp ratchet passed.
Linux CI/coverage remains required; these local results are not a green gate.

## Activation still required

Both capability pieces must ship together. The original pin's conservative
whole-tree boundary overlay intentionally rejects the new `install_make_root`
call. Do not weaken the guard or silently replace that pin with a local build.

The ordinary release workflow itself runs full CI, so merely dispatching it
does not solve the old-pin overlay failure. Its existing `prerelease` input
changes the publication label, not the gate. A guarded new exemption would
need additional workflow/validation code and an explicitly scoped approval;
a one-time manual route would likewise need to audit an expected red gate.
Neither is necessary if an API-only prerequisite is released first.

An isolated base archive with ONLY `cosmic/searcher.tl`,
`cosmic/_searcher_make.tl`, `cosmic/_teal_engine.tl` and
`cosmic/_teal_project.tl` from this candidate cold-built under the unchanged
old pin (653 files, one binary). Its unchanged original cold ratchet passed
2/2 checks. A copy of this candidate's generated ratchet, explicitly selecting
that experimental API artifact instead of the bootstrap parameter, passed
3/3 checks over the complete candidate. This parameterized probe did not
rewrite the real pin or bootstrap and is not release activation evidence.

Recommended route, with normal gates and release workflow throughout:

1. Split and validate the additive API seam as a prerequisite, including its
   focused tests and Linux full gates. Release it normally; verify the asset
   digest and bump both fields in `bin/cosmic.pin` to that real release.
2. Rebase the complete startup/dispatcher capability on that API-bearing pin,
   require the unchanged full gate, and publish its normal release.
3. Verify and activate that complete release's URL and digest. Only this
   second activation claims the cold-start outcome: an API-only pin has no
   early dispatcher installation and is deliberately insufficient.

The probe establishes a bounded prerequisite implementation, not a need for
another open-ended design investigation. It does not replace either release's
Linux validation. No workflow exemption or workflow edit was made here.

After real release/pin activation, rerun the widened cold fixture through the
ordinary `bin/cosmic` wrapper, the boundary ratchet, full CI and supported
Linux lanes. No Linux container runtime was available during this local
macOS verification. The initial pass performed no release, push or pin update.

## API release activated; complete capability still pending

The resumed parent is based on `ba33269688b4abc2d1c86495b9a97a9b3ec77db1`.
The four API implementation files and their two tests are already landed;
this parent preserves them, including the child's stronger reentrancy test.
`bin/cosmic.pin` now names the real API release
`2026-09-09-ba33269`, with asset SHA-256
`15289c59ccead28369c8d5174a3735b9dd981dbb2031e6d6b8d6282a8e627b65`.
The unchanged wrapper downloaded it and independently verified the digest.
The asset's version command reports `unknown`; that observation does not
change its verified digest or substitute another binary for the release.

The ordinary unmodified-source wrapper cold build passes (661 files, one
binary). The helper now accepts `wrapper` explicitly: it selects the copied
fixture's own `bin/cosmic`, whose cd must not return to the source worktree.

```sh
bin/cosmic --make build
sh o/bin/cosmic _build/testdata/make_cold.tl wrapper o/cold-api-wrapper
sh o/bin/cosmic _build/testdata/make_cold.tl o/bin/cosmic o/cold-complete
sh o/bin/cosmic _build/testdata/make_mutations.tl
bin/cosmic --make ci --min 76 --min-file 0
```

The widened empty-o wrapper control fails as expected: the API-only release
still eagerly imports `_cli.main_handlers` from `/zip/main.lua` before
`_types/tlast_gen.tl` can run. Its handler reports `given 2, expects 1`.
The wrapper's fallback diagnostic explicitly names the activated API release.
The complete candidate's explicit-runtime cold fixture passes generation 1
(661 files, one binary), without compiled outputs in the starting fixture.
All seven mutations are killed and the restored five-file baseline passes.

The resumed full gate passes build (661 files), format/types (663 files),
examples (40 files), and lint (780 files). Coverage passes 290/304 files:
the same 14 macOS failures/stalls listed above remain, but the real API pin's
boundary ratchet now passes all three checks. The focused tests, nil-return
ratchet and boot-stamp ratchet pass. Four repeated host stalls were explicitly
terminated after the other files finished; no Linux container runtime was
available locally, and this is not a claim of green Linux CI.

This is not final cold-start acceptance. Publish a second release containing
both startup and command-local dispatcher changes, verify its asset digest,
activate that real URL/digest, then require the same widened wrapper proof
and supported Linux gates to pass. Neither a rebuilt artifact nor the API
release alone is that activation. No external release is performed by this
implementation pass.

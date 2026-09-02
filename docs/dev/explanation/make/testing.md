# Tests under `--make`

how a test runs and what it can see, for a contributor who changes
the `record` step, the test runner or a test's grants.
[verbs.md](verbs.md) covers `test`'s command line.

the rule is the one generators follow: inputs = grants = your staged
subtree.

- **writes:** the test's own `.got` base and `TEST_TMPDIR`, a fresh
  directory per test that `_tool/testrun.tl` creates and removes.
  anything else is a denial, on the author's machine, at the moment it
  happens. with `TMPDIR` unset the driver points it at a scratch
  directory under `o/` before fencing.
- **reads:** the project the test belongs to, with exec, because tests
  exec built binaries; plus an enumerated runtime list a test uses on
  purpose: pty devices, `/proc/self/fd`, the resolver files. `$HOME`
  and the rest of the filesystem are denied. there is no network.
- **children are fenced too.** Landlock restrictions are inherited
  across `exec`. on a host without Landlock the test runs unfenced; a
  portable gate for those hosts is planned.
- **one shared stage per run.** every verb that runs project code
  compiles the whole tree first, so a test reads built files that are
  current. selection changes which tests run, never what gets staged:
  a partial stage resolves differently than a full one.
- **the runner is `o/.testrun/cosmic`**: this cosmic with the project's
  root `embed/**` appended at its artifact paths, so `/zip/R` resolves
  inside a test exactly as inside the artifact. it is assembled before
  the graph runs and replaced only when the toolchain or the payload
  changes. a per-binary payload (`cmd/<name>/embed/**`) is not
  carried, because two binaries may store different bytes at one zip
  path; spawn `o/bin/<name>` to exercise that. without root payload
  the runner is the cosmic itself.
- **fixtures need no grant.** anything in the test's subtree is
  readable. `testdata/` exists to keep fixtures out of the artifact.
- **declared inputs.** a test that reads a file no `require` names
  says so with `--- reads: <path> <path>` in its header; a directory
  declares every file under it, and a path that does not exist fails
  the scan loudly. a test that reads an environment variable says
  `--- env: NAME NAME`; the values are hashed into
  `o/.env/<stem>.env`, so a changed value is a changed prerequisite.
  both feed scheduling and the content key. neither changes the fence,
  whose read half is the whole project.
- `testrun`'s contract is `.got`, `.out` and `.err` beside the
  output, with exit status 0 for pass, 2 for skip and anything else
  for fail.
- **selection is by path**, several accepted, globbed by the caller's
  shell: `cosmic --make test cosmic/sqlite/*_test.tl`. there is no
  filter flag; the shell does that better.
- **examples and benchmarks are siblings**: same staging, same
  closure, same fence, `Example_*` or `Benchmark_*` instead of the
  test contract. the example runner reads the source, because
  `-- Output:` comments are what compilation strips.

**ports are unfenced.** the fence cannot see them. a `TEST_PORT_BASE`
convention or a `net` helper is the open answer.

a ratchet test that reads the live tree (the workflow, cast and
coverage ratchets) lives at the project root, whose subtree is the
whole tree. that is the put-it-where-its-inputs-are corollary applied
to tests.

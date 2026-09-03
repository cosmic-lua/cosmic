## Change

`_make/policy_test.tl` (372 lines): `test_write_baseline_refuses_outside_recording_env` (lines 286-310) and `test_write_baseline_prints_each_move_and_unequal_counts` (324-370) each `fs.set_cwd(root)`, swap `io.stderr`/`io.output`, and flip `COSMIC_COVERAGE_ENV`, then call `policy.write_baseline(proj)` with no protection: a throw inside it (an `assert` on a `.cov` shape, a `check.must`) leaves the process in the fixture directory with the marker set, so every later case in the file — and the runner's `all policy tests passed` line — fails for the wrong reason.

Add one helper above the two cases, `with_baseline_env(root, marker: string | nil, fn: function(): integer): integer, string`, that saves cwd and the marker, chdirs, redirects `io.stderr` and `io.output` to files under `root`, runs `fn` under `pcall`, restores everything in the reverse order (unconditionally), then re-raises the error if `fn` threw and otherwise returns the exit code plus the captured stdout and stderr. Rewrite both cases on it; delete `save_coverage_env`/`restore_coverage_env` (247-262) if the helper is their only caller (`git grep -n 'save_coverage_env\|restore_coverage_env' origin/main -- _make` → only this file). Assertions and expected strings are unchanged.

## Evidence

The unprotected span (`git show origin/main:_make/policy_test.tl | sed -n 290,300p`):
```
  local cwd = check.must(fs.cwd())
  check.must(fs.set_cwd(root))
  local captured = fs.join(root, "stderr.txt")
  local real_stderr = io.stderr
  io.stderr = assert(io.open(captured, "w"))
  local saved = save_coverage_env()
  assert(env.unset("COSMIC_COVERAGE_ENV"))
  local code = policy.write_baseline(proj)
  restore_coverage_env(saved)
  io.stderr:close()
  io.stderr = real_stderr
```
Runner mode calls every `test_*` in order (D29, `docs/decisions/d29-tests-run-because-defined.md`), so a leaked cwd reaches the cases after line 310.

The `_build/size.tl` `or 0` half of the reported finding is withdrawn: `REPORT_SPEC` declares `agents_md_lines = shape.integer` (required, `_build/size.tl:50-58`), so `load_report` refuses a JSON without it and `prev.agents_md_lines or 0` at line 174 is dead defensiveness, not a wrong delta. No change there.

# Code Review: Dead Code and Test Quality

## Dead/Unused Code

### Unused Type Definition Files

Three type definition files in `lib/types/cosmo/` define bindings to cosmo
libraries that are never imported or used anywhere in the codebase:

1. **`lib/types/cosmo/finger.d.tl`** — Defines `FingerSyn`, `GetSynFingerOs`,
   `DescribeSyn` for TCP SYN fingerprinting. Zero references to
   `require("cosmo.finger")` anywhere in the codebase.

2. **`lib/types/cosmo/maxmind.d.tl`** — Defines `open` for GeoIP database
   lookup. Zero references to `require("cosmo.maxmind")` anywhere.

3. **`lib/types/cosmo/goodsocket.d.tl`** — Defines `socket` for optimized TCP
   socket creation. The only reference to `cosmo.goodsocket` is in the file's
   own doc comment example. Zero actual usage.

### Library Modules With No Internal Callers

These modules are importable library APIs with tests, but nothing in the
codebase actually uses them. They exist solely as public API surface:

1. **`lib/cosmic/sandbox.tl`** — Exports `pledge` and `unveil`. Imported only
   by `sandbox_test.tl`. No production code calls these functions.

2. **`lib/cosmic/syslog.tl`** — Exports `write`, `emerg`, `alert`, `crit`,
   `err`, `warning`, `notice`, `info`, `debug` and priority constants. Imported
   only by `syslog_test.tl`.

3. **`lib/cosmic/shm.tl`** — Exports `mapshared` (shared memory with atomic
   operations). Imported only by `shm_test.tl`.

These are defensible as public API for external users, but worth noting since
they carry maintenance cost with zero internal consumers.

### Modules Without Test Files

Five implementation files have no corresponding `_test.tl`:

| Module | Reason |
|--------|--------|
| `main.tl` | CLI entry point; tested indirectly by args_test, check_test, compile_test, script_test, binary_test, welcome_test |
| `init.tl` | Minimal; tested indirectly by cosmic_test.tl |
| `teal.tl` | Compilation/checking; tested indirectly by check_test.tl and compile_test.tl |
| `gendoc.tl` | Build script invoked by Makefile |
| `docindex.tl` | Build script invoked by Makefile |

The indirect coverage for `main.tl`, `init.tl`, and `teal.tl` is substantial
through the CLI integration tests. `gendoc.tl` and `docindex.tl` are build
scripts — their correctness is validated by the doc generation pipeline.

## Test Quality Issues

### Tests That Only Verify Exports Exist

**`lib/cosmic/sandbox_test.tl`** — All three test functions only verify that
`pledge` and `unveil` are non-nil and have type `"function"`. No function is
ever called with real arguments. The comment explains that pledge/unveil are
irreversible, but subprocess-based testing would be straightforward (the same
pattern used in `proc_test.tl` and `welcome_test.tl`).

```teal
-- This is the entirety of what sandbox_test.tl validates:
assert(sandbox.pledge ~= nil)
assert(sandbox.unveil ~= nil)
assert(type(sandbox.pledge) == "function")
assert(type(sandbox.unveil) == "function")
```

**`lib/cosmic/syslog_test.tl`** — Has three tiers:
1. Constants exist and have correct ordering ✓ (real validation)
2. Functions exist and have type `"function"` (export check only)
3. Calls `syslog.write`/`info`/`debug` but **asserts nothing about the result**
   — the comment says "should not throw" but there are no assertions on the
   calls at line 41-43. If syslog silently broke, this test would still pass.

### Tests With Conditional Logic That May Never Execute

**`lib/cosmic/tty_test.tl`** — Several test functions contain `if tty.isatty(N)
then ... end` guards. In CI (where tests actually run), stdin/stdout/stderr are
never TTYs. This means:

- `test_winsize_structure` (line 85-98): The body with actual structural
  assertions never executes in CI. Only the trivial non-TTY path runs.
- `test_getattr_structure` (line 133-147): Same — the real termios validation
  only runs in a TTY environment.
- These tests pass in CI by doing nothing meaningful on their guarded branches.

**`lib/cosmic/docs_test.tl`** — Multiple tests use `if result.ok then ... end`
or `if docs.has_docs() then ... end` patterns. When docs aren't available (which
depends on build state), many assertions are silently skipped:

- `test_run_list` (line 44): If `result.ok` is false, zero assertions on content
- `test_run_module` (line 58): Same conditional skip pattern
- `test_run_symbol` (line 72): Same
- `test_search_methods` (line 150): If no docs, prints "PASS" with zero validation

**`lib/cosmic/fetch_test.tl`** — Network-dependent tests properly skip with
messages, but `test_success_structure` (line 28) has an `if result.ok then ...
else ... end` structure where both branches "pass" — the test cannot fail
regardless of whether data URLs work or not.

### SSE Test Uses Mock Reader

**`lib/cosmic/sse_test.tl`** — 16 of 17 tests use a `mock_reader()` that
simulates a stream from a string. This is **appropriate** — the mock implements
the `fetch.Reader` interface and the real `sse.events()` parser is exercised
against it. The SSE parser doesn't need a real network connection to be
validated. The one network-integration test (`test_real_sse_endpoint`, line 305)
properly skips if unavailable and doesn't actually parse SSE events (httpbin
returns JSON lines, not SSE format), making it a no-op connectivity check.

### Test That Can't Fail

**`lib/cosmic/proc_test.tl:264-267`** — `test_sched_yield` calls
`proc.sched_yield()` and then asserts `true`. This will always pass regardless
of whether sched_yield works, errors out, or does nothing:

```teal
local function test_sched_yield()
  proc.sched_yield()
  assert(true, "sched_yield should not throw")
end
```

If `sched_yield()` throws, the error propagates and the test fails before
reaching the assert — but `assert(true)` itself adds no validation value. The
intent (verify it doesn't throw) is served by simply calling the function,
making the assert redundant rather than wrong.

### `cosmic_test.tl` Is Purely Structural

**`lib/cosmic/cosmic_test.tl`** — Tests that modules can be required and that
exports are non-nil. This is a smoke test / integration sanity check rather than
a behavioral test. Every assertion is of the form `assert(X ~= nil)`. This is
fine as a fast-feedback integration gate, but contributes zero behavioral
coverage:

```teal
assert(fs.dirname ~= nil)
assert(fs.basename ~= nil)
assert(fs.join ~= nil)
assert(fs.walk ~= nil)
-- etc.
```

## Summary

| Category | Count | Severity |
|----------|-------|----------|
| Unused type definition files | 3 | Low — dead code, safe to remove |
| Library modules with no internal callers | 3 | Info — public API, debatable |
| Tests that only verify exports exist | 1 | Medium — sandbox_test validates nothing behavioral |
| Tests with conditional branches that skip in CI | 3 | Medium — tty, docs, fetch have phantom coverage |
| Test with always-true assertion | 1 | Low — proc sched_yield |
| Modules without direct test files | 5 | Low — all have indirect coverage |

### Recommendations

1. **Remove** `finger.d.tl`, `goodsocket.d.tl`, `maxmind.d.tl` — pure dead
   code with zero consumers.
2. **Strengthen sandbox_test.tl** — Use subprocess isolation (like
   `welcome_test.tl` does) to actually call `pledge`/`unveil` and verify behavior.
3. **Add assertions to syslog_test.tl `test_write_calls`** — At minimum verify
   the functions return without error, or use subprocess + syslog capture.
4. **Mark tty_test.tl TTY-only tests as skipped** — Instead of silently passing
   with empty branches, use `os.exit(2)` or print `"SKIP"` when not in a TTY,
   so the test reporter accurately reflects coverage.
5. **Consider adding teal_test.tl** — `teal.tl` is a 200+ line module with
   compilation and type-checking logic that only has indirect CLI-level tests.

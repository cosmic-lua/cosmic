--- `cosmic test [options] [selector...]`: builds the tree in the
--- working directory, then runs every test it defines. A test is one
--- of four things (`cosmic docs cosmic.layout` says where each lives):
---
--- - a top-level `local function test_*` of a `<name>_test.tl` file,
---   which fails when it raises an error, so `assert` is enough;
--- - a top-level `local function bench_*(b: Bench.B)` of the same file,
---   a bench, which a plain run calls once with `b.n` 1 and `--bench`
---   times ([`cosmic.bench`]);
--- - a function of the record named `Example` that a
---   `<name>_example.tl` file returns, which `cosmic docs` also shows
---   under every symbol it calls;
--- - a block tagged `teal` or `lua` in a guide, doc/guides/<name>.md,
---   which compiles, and runs when a block tagged `output` after it
---   says what it prints.
---
--- Beside `tally.tl`, say, a file `tally_test.tl`:
---
---     local Tally = require("tally")
---
---     local function test_words()
---       assert(Tally.words("a b  c") == 3)
---     end
---
--- `cosmic test tally_test.tl` runs that file's tests, and `cosmic test
--- tally_test.tl:test_words` runs that one test. A selector narrows the
--- run to the modules it names: a file, a module name (`tally_test`) or a
--- directory. `<file or module>:<name>` narrows it to the one test of that
--- name, a `test_*` or an example's, and a name that no test there has is
--- refused.
---
--- Each test runs in a process of its own. It fails when it runs past its
--- timeout (`--timeout`; a module's `Test.policy { timeout = n }` makes it
--- longer). What a failing test printed is shown beneath it, and
--- `--show-output` shows what a passing test printed too.
---
--- Each run reports its line coverage, and coverage alone never fails a
--- run. `--min PCT` and `--min-file PCT` hold a whole run to a floor, for
--- the tree and for each file. A run below the floor fails (status 1) and
--- names what fell short. Each run writes its line coverage to the
--- `coverage` table of build.db, which `cosmic sql --build` reads.
---
--- A test function is given a fresh directory, `<scratch>/tmp`. TMPDIR is
--- its scratch directory, `<scratch>`, so [`Fs.mkdtemp`] makes a sibling of
--- it. The scratch directory is removed after a pass. After a failure of
--- an unsandboxed test, it is kept.
---
--- The sandbox:
---
--- Where the kernel can sandbox (Linux), each test runs sandboxed. It
--- is given its module's import closure and what the module declares
--- with [`Test.policy`]
--- (`cosmic docs cosmic.test`), and nothing else of the tree or the host.
--- A test that starts a host program, such as /bin/sh or `sleep`, grants
--- it by its absolute path. When a test fails because its sandbox left out
--- something at an absolute path (a program it started, a file it read),
--- the report beneath it says so and names what to declare. It does the
--- same for a test that read a file of the tree by a relative path without
--- a grant.
---
--- What runs again:
---
--- A test whose verdict still stands is not run again. A verdict stands
--- when this checkout reached it (in its build directory's build.db), or
--- when any checkout of the same content did. Every sandboxed run shares
--- verdicts through `$XDG_CACHE_HOME/cosmic/verdicts`
--- (`~/.cache/cosmic/verdicts`). COSMIC_VERDICT_CACHE names another file,
--- and COSMIC_VERDICT_CACHE=0 turns off only that shared cache: a verdict
--- of this checkout still stands, and only `--all` runs its test again. A
--- run whose workers are not sandboxed (COSMIC_TEST_SANDBOX=0, or macOS)
--- shares verdicts only through a file that COSMIC_VERDICT_CACHE names.
---
--- An edit to a test file, including to a comment, runs its tests again. A
--- comment in a module that the test imports runs them again only when
--- the test is given that module's text: a test that declares
--- `store_text` or `store`, starts the program, or runs unsandboxed.
--- doc/testing.md ("the pure store") lists every case.
---
--- A module is not compiled again, and a source is not parsed again, when
--- any checkout compiled or parsed the same text. They are shared through
--- `$XDG_CACHE_HOME/cosmic/build` (`~/.cache/cosmic/build`).
--- COSMIC_BUILD_CACHE names another file, and COSMIC_BUILD_CACHE=0 turns
--- the cache off.
---
--- The tree:
---
--- The tree is the working directory, with one exception. When no build
--- of the working directory has written its projection (cosmic.db in its
--- build directory, as `run` names it), and an ancestor below the home
--- directory has one whose build staged the working directory, the tree
--- is that ancestor. Then the tree is named on stderr, and paths are read
--- from the working directory. COSMIC_TREE=<dir> names the tree outright,
--- with `.` for the working directory.
--- @public

local Flags = require("cosmic.flags")

local command: Flags.Command = {
  about = "build the tree and run its tests",
  usage = "[selector...]",
  examples = {
    { line = "", about = "run every test of the tree" },
    { line = "tally_test.tl", about = "run one file's tests" },
    { line = "tally_test.tl:test_words", about = "run one test" },
    { line = "--bench tally_test.tl", about = "time one file's benches" },
  },
  spec = {
    ["--all"] = { about = "run every test, whatever verdict stands for it (COSMIC_TEST_ALL=1); " ..
        "COSMIC_VERDICT_CACHE=0 turns off only the shared verdict cache" },
    ["--profile"] = { value = "dir", about = "run every test it selects, whatever verdict stands, each worker " ..
        "writing a profile into this directory, made if missing (a relative one is the tree root's); " ..
        "`cosmic profile <dir>` reads them" },
    ["--bench"] = { about = "time each bench it selects (a top-level `local function bench_*(b: Bench.B)` of a " ..
        "*_test.tl file, which a plain run calls once), whatever verdict stands, one at a time, and print its " ..
        "fastest and median ns per operation on stdout (cosmic docs cosmic.bench)" },
    ["--rounds"] = { value = "n", integer = { min = 1, max = 1000 }, about = "with --bench: the batches timed of " ..
        "each bench (default 5)" },
    ["--target-ms"] = { value = "ms", integer = { min = 1, max = 60000 }, about = "with --bench: the least " ..
        "length of one batch; its n doubles until a batch takes it (default 50)" },
    ["--json"] = { about = "with --bench: print one JSON object per bench, a line each, in place of the table" },
    ["--show-output"] = { about = "also list what a passing test printed, beneath it; a test " ..
        "that stands is not run and prints nothing (--all runs it)" },
    ["--no-shared"] = { about = "stand on no verdict another checkout reached; what " ..
        "this run reaches is still shared (COSMIC_TEST_NO_SHARED=1)" },
    ["--bail"] = { about = "start no test after the first failure; those already running " ..
        "finish, the tests not started keep no verdict, and the run fails " ..
        "(COSMIC_TEST_BAIL=1)" },
    ["--deadline"] = { value = "seconds", about = "start no test once this many seconds have " ..
        "passed since the run began; those already running finish and keep their verdicts, " ..
        "the tests not started keep none, and the run fails (COSMIC_TEST_DEADLINE)" },
    ["--census"] = { about = "say the digests every key of the run holds, and where none " ..
        "stood on the shared cache, how many rows it holds, even in a checkout " ..
        "that ran before" },
    ["--check-types"] = { about = "compile the tree with a run-time check of each declared " ..
        "parameter, return value and record field write against its type's kind, run every " ..
        "test, and report the values that fail one; a parameter declared under cosmic/ also " ..
        "fails the test that passes it (COSMIC_TEST_CHECK_TYPES=1)" },
    ["--jobs"] = { value = "n", about = "run n tests at once; by default one for each processor and one more" },
    ["--min"] = { value = "pct", about = "fail the run, as a failing test does (status 1), when the " ..
        "tree's line coverage, C included, is under pct percent; a run on standing verdicts " ..
        "has the lines they hit; needs a whole run (no selector, no --shard)" },
    ["--min-file"] = { value = "pct", about = "fail the run when any one file's line coverage is " ..
        "under pct percent, naming each file with its percentage; needs a whole run" },
    ["--shard"] = { value = "i/n", about = "run only the i-th of n shares of the chosen " ..
        "tests, dealt in turn in sorted order, so n runs, i = 1 to n, run each test once" },
    ["--timeout"] = { value = "seconds",
      about = "fail a test that runs longer (COSMIC_TEST_TIMEOUT, else 30, or ten times FUZZ_SECONDS " ..
        "where that is set); a module's " ..
        "Test.policy { timeout = n } lengthens it for that module" },
  },
}

return command

# coverage

 Line coverage collection for cosmic programs.
 Counts executed (source, line) pairs via a line hook and dumps the
 counts as a Lua-serialized .cov file for `cosmic --coverage-report`
 to merge and render. When the runtime carries the C collector
 (cosmo.cov), the hook runs in C at a small fraction of the per-line
 cost; otherwise a Lua debug hook does the same accounting.

 The CLI arms collection automatically when the COSMIC_COVERAGE
 environment variable names a directory: the hook starts before the
 script loads and a .cov file is written there when the script
 finishes (including via os.exit). `cosmic --test` rewrites the
 variable to a per-test directory, so `cosmic --make coverage` gets one
 .cov file per process, safe under parallel make.

 start/stop nest: a script that exercises coverage itself while
 running under coverage leaves the outer collection running.

## Types

### CCov

 The runtime's C line-hit collector (require("cosmo.cov")), when
 this runtime carries one. Same attribution as the Lua hook below —
 chunks keyed by their debug source, values line -> hit count — at a
 small fraction of the per-line cost.

```teal
local record CCov
  start: function()
  stop: function()
  running: function(): boolean
  arm: function(thread: thread)
  snapshot: function(): {string: {integer: integer}}
  reset: function()
end
```

### CoverageModule

```teal
local record CoverageModule
  start: function()
  stop: function()
  running: function(): boolean
  snapshot: function(): {string: {integer: integer}}
  reset: function()
  dump: function(dir?: string): boolean, string
  seal: function()
  keep_on_restrict: function()
  is_kept_on_restrict: function(): boolean
  enable: function(dir: string)
  dir_from_env: function(): string | nil
  enable_from_env: function(): function() | nil
  report: function(paths: {string}): integer
  --  Ratchet a run against a committed baseline file (exit-code result).
  gate: function(baseline_path: string, only: string, paths: {string}): integer
  --  Render fresh baseline text from .cov dirs (+ previous floor).
  baseline_text: function(paths: {string}, previous?: string): string | nil, string
  --  Rows a fresh baseline lowers relative to the committed one.
  baseline_lowered: function(before: string, after: string): {string}
end
```

## Functions

### running

```teal
function running(): boolean
```

 Check whether collection is active.

**Returns:**

- boolean

### start

```teal
function start()
```

 Begin collecting line hits (nestable).
 The first start installs the line hook; nested starts only increment
 the nesting depth, so libraries and tests can bracket their own
 collection without tearing down an outer one.

### stop

```teal
function stop()
```

 Stop collecting line hits (nestable).
 Removes the line hook when the last nested start is balanced.
 Collected counts are kept; use reset() to discard them.

### snapshot

```teal
function snapshot(): {string: {integer: integer}}
```

 Return a copy of the collected counts.
 Keys are chunk sources as reported by debug.getinfo (e.g.
 "@o/cosmic/fs/init.lua"), values map line number to hit count.

**Returns:**

- {string: - {integer: integer}}

### reset

```teal
function reset()
```

 Discard all collected counts.

### dump

```teal
function dump(dir?: string): boolean, string
```

 Write collected counts as a .cov file into a directory.
 The filename is stable per process (pid plus start timestamp), so
 repeated dumps from one process overwrite instead of double-counting;
 concurrent processes never collide.

**Parameters:**

- `dir` (string?) - Directory to write into (default: the enable() directory)

**Returns:**

- boolean - True on success, false on failure
- string? - Error message if the write failed

### seal

```teal
function seal()
```

 Flush collected counts now and prevent every later dump.
 The pledge/unveil/landlock wrappers call this before dropping
 rights: after the sandbox lands, a dump would fail — and under
 pledge the write attempt would kill the process. Lines executed
 after sealing are still collected but never reported.

### keep_on_restrict

```teal
function keep_on_restrict()
```

 Declare that the active sandbox policy grants the coverage
 directory, so the pre-restrict seal must NOT run: the process keeps
 reporting what it does after the sandbox lands. Only build tooling
 that granted the directory itself may call this (#989: this
 declaration replaces the keep_coverage flag the four containment
 policy records used to carry). Irreversible for the process, like
 the policies it describes.

### is_kept_on_restrict

```teal
function is_kept_on_restrict(): boolean
```

 Whether keep_on_restrict() was declared; consulted by
 cosmic._seal_coverage before sealing on behalf of the containment
 shards.

### enable

```teal
function enable(dir: string)
```

 Arm collection for this process, dumping into dir on exit.
 Used by the CLI when COSMIC_COVERAGE names a directory; also wraps
 os.exit so early exits (like a test skip) still flush their counts.
 A nested enable never re-targets an outer one's directory.

**Parameters:**

- `dir` (string) - Directory to write the .cov file into

### dir_from_env

```teal
function dir_from_env(): string | nil
```

 Read the coverage directory from the COSMIC_COVERAGE variable.
 Boolean-ish values ("", "0", "1", "true", "false") mean coverage is
 requested or off but name no directory, so they return nil; anything
 else is the directory to dump into.

**Returns:**

- string - | nil The dump directory, or nil when not configured

### enable_from_env

```teal
function enable_from_env(): function() | nil
```

 Arm collection from the COSMIC_COVERAGE variable, if it names a
 directory. The CLI calls this before running a script.

**Returns:**

- function() - | nil A dump callback when armed, nil otherwise

### report

```teal
function report(paths: {string}): integer
```

 Merge and render .cov files; the --coverage-report CLI entry point.
 source directories to include as zero-coverage candidates

**Parameters:**

- `paths` ({string}) - .cov files, directories to scan for them, and

**Returns:**

- integer - Exit code (0 on success, 1 when no data was found)

# walk

 Directory walking and file collection utilities.
 Provides recursive directory traversal, pattern-based file collection,
 and file iteration.

## Types

### WalkDirHandle

 Handle for reading directory entries (internal).
 `read`'s second return is the dirent d_type (unix.DT_DIR / DT_REG /
 DT_LNK / ... / DT_UNKNOWN) where the filesystem supports it, letting
 callers that only need "is this a directory" skip a stat(2) call.

```teal
local record WalkDirHandle
  read: function(self): string, number
  close: function(self)
end
```

### FsWalkModule

```teal
local record FsWalkModule
  --  Walk dir tree. visitor(path, name, st, ctx): path is the FULL path; name is the basename.
  --  Do NOT join path and name — path is already complete.
  walk: function < T > (dir: string, visitor: function(string, string, WalkStat, T), ctx?: T): T | nil, string
  collect: function(dir: string, pattern: string): {string} | nil, string
  collect_all: function(dir: string): {string: FileInfo} | nil, string
  files: function(dir: string, pattern?: string): FileIter, string, any, any
end
```

## Functions

### walk

```teal
function walk(dir: string, visitor: function(string, string, WalkStat, T), ctx?: T): T | nil, string
```

 Walk a directory tree, calling visitor for each entry.
 Recursively traverses all subdirectories.
 Does NOT recurse into symlinked directories to prevent symlink cycles.
 The visitor receives four arguments:
   path  (string)  — the full path to the entry (e.g. "dir/sub/file.txt").
   name  (string)  — the basename of the entry (e.g. "file.txt").
   st    (WalkStat) — stat result for the entry.
   ctx   (T)       — the context value passed to walk().
 IMPORTANT: do NOT join path and name — path is already the full path.
 Joining them produces doubled paths like "dir/sub/file.txt/file.txt".
 WalkStat is defined in cosmic.fs.types. Import it as:
   local types = require("cosmic.fs.types")
   local type WalkStat = types.WalkStat
 If the root directory cannot be opened, returns nil plus the error.
 Failures below the root (unreadable subdirectory, vanished entry) do
 not stop the walk; the first such error is returned alongside the
 context so callers never mistake a partial walk for a complete one.

**Parameters:**

- `dir` (string) - The directory to walk
- `visitor` (function) - Called for each entry: function(path, name, st, ctx)
- `ctx` (T) - Optional context passed to every visitor call

**Returns:**

- T - | nil The context object, or nil if the root could not be opened
- string - First error encountered, if any

### collect

```teal
function collect(dir: string, pattern: string): {string} | nil, string
```

 Collect file paths matching a pattern.
 Recursively walks directory tree and returns matching file paths.
 If the root directory cannot be opened, returns nil plus the error.
 Failures below the root do not stop the collection; the first such
 error is returned alongside the results.

**Parameters:**

- `dir` (string) - The directory to search
- `pattern` (string) - Glob pattern (*.lua) or Lua pattern (%.lua$)

**Returns:**

- {string} - | nil List of matching paths, or nil if the root failed
- string - First error encountered, if any

### collect_all

```teal
function collect_all(dir: string): {string: FileInfo} | nil, string
```

 Recursively collect all files with their Unix permissions.
 Returns a map of relative paths to file information.
 If the root directory cannot be opened, returns nil plus the error.
 Failures below the root do not stop the collection; the first such
 error is returned alongside the results.

**Parameters:**

- `dir` (string) - The directory to walk

**Returns:**

- {string:FileInfo} - | nil Map of relative paths to file information
- string - First error encountered, if any

### files

```teal
function files(dir: string, pattern?: string): FileIter, string, any, any
```

 Iterate over files matching a pattern.
 Returns an iterator that yields file paths. The fourth return value
 is a to-be-closed guard: a plain `for f in fs.files(dir) do ... end`
 loop adopts it as the loop's closing value (Lua 5.4), so directory
 handles are closed even when the loop exits early via break/error.
 If the root directory cannot be opened, the iterator yields nothing
 and the error is returned as the second value.

**Parameters:**

- `dir` (string) - The directory to search
- `pattern` (string) - Glob pattern (*.lua) - defaults to all files (*)

**Returns:**

- function - Iterator yielding file paths
- string - Error if the root directory could not be opened
- nil - Unused (generic-for control slot)
- any - Closing guard that releases open directory handles

# fs_walk

 Directory walking and file collection utilities.
 Provides recursive directory traversal, pattern-based file collection,
 and file iteration.

## Types

### WalkDirHandle

 Handle for reading directory entries (internal).

```teal
local record WalkDirHandle
  read: function(self): string
  close: function(self)
end
```

### FsWalkModule

```teal
local record FsWalkModule
  --  Walk dir tree. visitor(path, name, st, ctx): path is the FULL path; name is the basename.
  --  Do NOT join path and name — path is already complete.
  walk: function < T > (dir: string, visitor: function(string, string, WalkStat, any), ctx?: T): T
  collect: function(dir: string, pattern: string): {string}
  collect_all: function(dir: string): {string: FileInfo}
  files: function(dir: string, pattern?: string): function(): string
end
```

## Functions

### walk

```teal
function walk(dir: string, visitor: function(string, string, WalkStat, any), ctx?: T): T
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
 WalkStat is defined in cosmic.fs_types. Import it as:
   local types = require("cosmic.fs_types")
   local WalkStat = types.WalkStat

**Parameters:**

- `dir` (string) - The directory to walk
- `visitor` (function) - Called for each entry: function(path, name, st, ctx)
- `ctx` (T) - Optional context passed to every visitor call

**Returns:**

- T - The context object, potentially modified by visitor

### collect

```teal
function collect(dir: string, pattern: string): {string}
```

 Collect file paths matching a pattern.
 Recursively walks directory tree and returns matching file paths.

**Parameters:**

- `dir` (string) - The directory to search
- `pattern` (string) - Glob pattern (*.lua) or Lua pattern (%.lua$)

**Returns:**

- {string} - List of full paths to matching files

### collect_all

```teal
function collect_all(dir: string): {string: FileInfo}
```

 Recursively collect all files with their Unix permissions.
 Returns a map of relative paths to file information.

**Parameters:**

- `dir` (string) - The directory to walk

**Returns:**

- {string:FileInfo} - Map of relative paths to file information

### files

```teal
function files(dir: string, pattern?: string): function(): string
```

 Iterate over files matching a pattern.
 Returns an iterator that yields file paths.

**Parameters:**

- `dir` (string) - The directory to search
- `pattern` (string) - Glob pattern (*.lua) - defaults to all files (*)

**Returns:**

- function - Iterator yielding file paths

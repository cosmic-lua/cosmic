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

**Parameters:**

- `dir` (string) - The directory to walk
- `visitor` (function) - Visitor callback Function called for each file and directory
- `ctx` (T) - Optional context passed to visitor function

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

# walk

 Directory tree walking utilities.
 Recursively traverse directories with visitor pattern or glob matching.

## Types

### Stat

 File or directory metadata.

```teal
local record Stat
  mode: function(self): number
  size: function(self): number
  mtim: function(self): number
end
```

### DirHandle

 Handle for reading directory entries.

```teal
local record DirHandle
  read: function(self): string
  close: function(self)
end
```

### FileInfo

 File information with Unix permissions.

```teal
local record FileInfo
  mode: number
end
```

### WalkModule

```teal
local record WalkModule
  walk: function<T>(dir: string, visitor: Visitor, ctx?: T): T
  collect: function(dir: string, pattern: string): {string}
  collect_all: function(dir: string, base?: string, files?: {string:FileInfo}): {string:FileInfo}
end
```

## Functions

### walk

```teal
function walk(dir: string, visitor: Visitor, ctx?: T): T
```

 Walk a directory tree, calling visitor for each entry.
 Recursively traverses subdirectories unless visitor returns false.

**Parameters:**

- `dir` (string) - The directory to walk
- `visitor` (Visitor) - Function called for each file and directory
- `ctx` (T) - Optional context passed to visitor function

**Returns:**

- T - The context object, potentially modified by visitor

### collect

```teal
function collect(dir: string, pattern: string): {string}
```

 Collect file paths matching a Lua pattern.
 Recursively walks directory tree and returns matching file paths.

**Parameters:**

- `dir` (string) - The directory to search
- `pattern` (string) - Lua pattern to match against file basenames

**Returns:**

- {string} - List of full paths to matching files

### collect_all

```teal
function collect_all(dir: string, base?: string, files?: {string:FileInfo}): {string:FileInfo}
```

 Recursively collect all files with their Unix permissions.
 Returns a map of relative paths to file information.

**Parameters:**

- `dir` (string) - The directory to walk
- `base` (string) - Internal: relative path prefix (used during recursion)
- `files` ({string:FileInfo}) - Internal: accumulator map (used during recursion)

**Returns:**

- {string:FileInfo} - Map of relative paths to file information

## Examples

### collect

 Example_collect demonstrates collecting files matching a pattern

```teal
  local walk_m = require("cosmic.walk")
  local unix_m = require("cosmo.unix")
  local path_m = require("cosmo.path")

  -- Create temp dir with test files
  local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp/walk_example"
  unix_m.makedirs(tmpdir)
  local f1 = io.open(path_m.join(tmpdir, "a.lua"), "w")
  if f1 then f1:write("-- a") f1:close() end
  local f2 = io.open(path_m.join(tmpdir, "b.lua"), "w")
  if f2 then f2:write("-- b") f2:close() end
  local f3 = io.open(path_m.join(tmpdir, "c.txt"), "w")
  if f3 then f3:write("text") f3:close() end

  local files = walk_m.collect(tmpdir, "%.lua$")
  table.sort(files)
  print("found", #files, "lua files")
  for _, file in ipairs(files) do
    print(path_m.basename(file))
  end

  unix_m.rmrf(tmpdir)
```

Output:
```
found	2	lua files
  -- a.lua
  -- b.lua

```

### walk

 Example_walk demonstrates walking a directory tree with a visitor

```teal
  local walk_m = require("cosmic.walk")
  local unix_m = require("cosmo.unix")
  local path_m = require("cosmo.path")

  -- Create temp dir with test structure
  local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp/walk_example2"
  unix_m.makedirs(path_m.join(tmpdir, "sub"))
  local f1 = io.open(path_m.join(tmpdir, "root.txt"), "w")
  if f1 then f1:write("root") f1:close() end
  local f2 = io.open(path_m.join(tmpdir, "sub", "child.txt"), "w")
  if f2 then f2:write("child") f2:close() end

  local count = 0
  walk_m.walk(tmpdir, function(_: string, _: string, s: any, _: any): boolean
    local st = s as Stat
    if not unix_m.S_ISDIR(st:mode()) then
      count = count + 1
    end
    return true
  end)
  print("visited", count, "files")

  unix_m.rmrf(tmpdir)
```

Output:
```
visited	2	files

```

# fs_path

 Path manipulation functions for the filesystem module.
 Pure string operations for dirname, basename, join, normalize, etc.

## Types

### FsPathModule

```teal
local record FsPathModule
  dirname: function(str: string): string
  basename: function(str: string): string
  join: function(...: string): string
  exists: function(path: string): boolean
  isfile: function(path: string): boolean
  isdir: function(path: string): boolean
  islink: function(path: string): boolean
  normalize: function(p: string): string
  abspath: function(p: string): string
  relpath: function(p: string, base?: string): string
  splitext: function(p: string): string, string
  ext: function(p: string): string
end
```

## Functions

### dirname

```teal
function dirname(str: string): string
```

 Strip final component from path.
 Examples: "/usr/lib" -> "/usr", "usr" -> ".", "/" -> "/"

**Parameters:**

- `str` (string) - The path to get the directory from

**Returns:**

- string - The directory portion of the path

### basename

```teal
function basename(str: string): string
```

 Return final component of path.
 Examples: "/usr/lib" -> "lib", "/" -> "/", "." -> "."

**Parameters:**

- `str` (string) - The path to get the basename from

**Returns:**

- string - The final component of the path

### join

```teal
function join(...: string): string
```

 Concatenate path components.
 Absolute paths in later arguments reset the result.
 Nil arguments are skipped; exclusively nil returns nil.

**Parameters:**

- `...` (string) - Path components to join

**Returns:**

- string - The joined path

### exists

```teal
function exists(p: string): boolean
```

 Check if path exists (regular file, directory, or special file).
 Symbolic links are followed. Returns false on error.

**Parameters:**

- `p` (string) - The path to check

**Returns:**

- boolean - True if the path exists

### isfile

```teal
function isfile(p: string): boolean
```

 Check if path is a regular file.
 Symbolic links are not followed. Returns false on error.

**Parameters:**

- `p` (string) - The path to check

**Returns:**

- boolean - True if the path is a regular file

### isdir

```teal
function isdir(p: string): boolean
```

 Check if path is a directory.
 Symbolic links are not followed. Returns false on error.

**Parameters:**

- `p` (string) - The path to check

**Returns:**

- boolean - True if the path is a directory

### islink

```teal
function islink(p: string): boolean
```

 Check if path is a symbolic link.
 Returns false on error.

**Parameters:**

- `p` (string) - The path to check

**Returns:**

- boolean - True if the path is a symbolic link

### normalize

```teal
function normalize(p: string): string
```

 Normalize path by removing `.` and `..` components without filesystem access.
 Also removes redundant slashes. Pure string manipulation.
 Examples: "/usr/./lib" -> "/usr/lib", "/usr/lib/../bin" -> "/usr/bin"

**Parameters:**

- `p` (string) - The path to normalize

**Returns:**

- string - The normalized path

### abspath

```teal
function abspath(p: string): string
```

 Convert relative path to absolute by prepending cwd.
 Does NOT resolve symlinks or access filesystem (except to get cwd).

**Parameters:**

- `p` (string) - The path to make absolute

**Returns:**

- string - The absolute path

### relpath

```teal
function relpath(p: string, base: string): string
```

 Make path relative to another path (defaults to cwd).
 Pure string manipulation - does not access the filesystem.

**Parameters:**

- `p` (string) - The path to make relative
- `base` (string) - The base path (defaults to cwd)

**Returns:**

- string - The relative path

### splitext

```teal
function splitext(p: string): string, string
```

 Split path into root and extension.
 Extension includes the dot. Handles multiple extensions by splitting at
 the last dot in the basename. Hidden files (starting with .) have no extension.
 Examples: "foo.txt" -> "foo", ".txt"; ".bashrc" -> ".bashrc", ""

**Parameters:**

- `p` (string) - The path to split

**Returns:**

- string - The root portion (path without extension)
- string - The extension (including dot, or empty string)

### ext

```teal
function ext(p: string): string
```

 Return the extension of a path.
 Extension includes the dot. Convenience wrapper around splitext.

**Parameters:**

- `p` (string) - The path to get extension from

**Returns:**

- string - The extension (including dot, or empty string)

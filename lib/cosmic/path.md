# path

 Path manipulation utilities.
 Wraps cosmo.path for path operations: dirname, basename, join, exists, isfile, isdir, islink.

## Types

### PathModule

```teal
local record PathModule
  dirname: function(str: string): string
  basename: function(str: string): string
  join: function(...: string): string
  exists: function(path: string): boolean
  isfile: function(path: string): boolean
  isdir: function(path: string): boolean
  islink: function(path: string): boolean
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

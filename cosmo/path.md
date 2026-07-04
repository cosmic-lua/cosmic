# path

Type declarations for the `path` module.

## Functions

### dirname

```teal
function dirname(str: string): string
```

 Strips final component of path, e.g.
     path      │ dirname
     ───────────────────
     .         │ .
     ..        │ .
     /         │ /
     usr       │ .
     /usr/     │ /
     /usr/lib  │ /usr
     /usr/lib/ │ /usr

**Parameters:**

- `str` (string)

**Returns:**

- string

### basename

```teal
function basename(str: string): string
```

 Returns final component of path, e.g.
     path      │ basename
     ─────────────────────
     .         │ .
     ..        │ ..
     /         │ /
     usr       │ usr
     /usr/     │ usr
     /usr/lib  │ lib
     /usr/lib/ │ lib

**Parameters:**

- `str` (string)

**Returns:**

- string

### join

```teal
function join(str?: string, ...: string): string | nil
```

 Concatenates path components, e.g.
     x         │ y        │ joined
     ─────────────────────────────────
     /         │ /        │ /
     /usr      │ lib      │ /usr/lib
     /usr/     │ lib      │ /usr/lib
     /usr/lib  │ /lib     │ /lib
 You may specify 1+ arguments.
 Specifying no arguments will raise an error. If `nil` arguments are specified,
 then they're skipped over. If exclusively `nil` arguments are passed, then `nil`
 is returned. Empty strings behave similarly to `nil`, but unlike `nil` may
 coerce a trailing slash.

**Parameters:**

- `str` (string)
- `...` (string)

**Returns:**

- string | nil

### exists

```teal
function exists(path: string): boolean
```

 Returns `true` if path exists.
 This function is inclusive of regular files, directories, and special files.
 Symbolic links are followed are resolved. On error, `false` is returned.

**Parameters:**

- `path` (string)

**Returns:**

- boolean

### isfile

```teal
function isfile(path: string): boolean
```

 Returns `true` if path exists and is regular file.
 Symbolic links are not followed. On error, `false` is returned.

**Parameters:**

- `path` (string)

**Returns:**

- boolean

### isdir

```teal
function isdir(path: string): boolean
```

 Returns `true` if path exists and is directory.
 Symbolic links are not followed. On error, `false` is returned.

**Parameters:**

- `path` (string)

**Returns:**

- boolean

### islink

```teal
function islink(path: string): boolean
```

 Returns `true` if path exists and is symbolic link.
 Symbolic links are not followed. On error, `false` is returned.

**Parameters:**

- `path` (string)

**Returns:**

- boolean

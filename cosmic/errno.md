# errno

 Error information from system calls.

 Failed `cosmo.unix` calls return `nil, err, errno`: a formatted string
 (`"open: ENOENT: No such file or directory"`) plus the numeric errno.
 This module provides the canonical formatter (`format`) that most
 `cosmic.*` wrappers use to add operation context, and helpers for
 programmatic errno handling (`is_code`, `code_of`, `name_in`, and
 the `codes` name -> number table), so error messages share one shape
 across the stdlib:

     local ok, err = unix.mkdir(path, mode)
     if not ok then return false, errno.format(err, "mkdir: " .. path) end
     -- -> "mkdir: /x: EACCES: Permission denied"


## Types

### ErrnoModule

```teal
local record ErrnoModule
  format: function(err: any, prefix?: string): string
  code_of: function(name: string): integer | nil
  is_code: function(eno: any, name: string): boolean
  name_in: function(msg: string): string | nil
  codes: {string: integer}
end
```

## Functions

### format

```teal
function format(err: any, prefix?: string): string
```

 Format an error as one canonical string, optionally prefixed with the
 failing operation or context. Binding error strings already name the
 failing call (`"mkdir: EACCES: Permission denied"`); when a prefix is
 supplied, that lowercase `call: ` head is dropped so the operation is
 not stated twice (`"mkdir: /x: EACCES: Permission denied"`, not
 `"mkdir: /x: mkdir: EACCES: ..."`). Errno names are uppercase, so
 they are never mistaken for a call head. Any non-string value falls
 back to `tostring`; `nil` becomes `"unknown error"`.

**Parameters:**

- `err` (any) - the error value (a string, or nil)
- `prefix?` (string) - operation/context to prepend

**Returns:**

- string - canonical error string

### code_of

```teal
function code_of(name: string): integer | nil
```

 The numeric errno for a named constant (e.g. `code_of("ENOENT")`), or nil
 if the host does not define it. A thin lookup over `unix.E*`.

**Parameters:**

- `name` (string) - errno constant name

**Returns:**

- integer - | nil errno number, nil when the host does not define it

### is_code

```teal
function is_code(eno: any, name: string): boolean
```

 True when a failed call's numeric errno (the third return value of a
 failed `unix.*` call) matches the named constant. Enables programmatic
 handling without string-matching:
     local n, err, eno = unix.poll(fds, timeout)
     if errno.is_code(eno, "EINTR") then retry() end

**Parameters:**

- `eno` (any) - the numeric errno from a failed call
- `name` (string) - errno constant name (e.g. "ENOENT")

**Returns:**

- boolean

### name_in

```teal
function name_in(msg: string): string | nil
```

 The errno constant name embedded in a canonical error string, or nil
 if the message carries none. Enables programmatic checks on errors
 whose numeric errno is no longer at hand:
     local data, err = fs.read(path)
     if errno.name_in(err) == "ENOENT" then ... end
 Matches the first `ENAME:` token — an uppercase word starting with E
 at a word boundary, so uppercase tails of other words (`"FAILED:"`)
 are never mistaken for an errno name.

**Parameters:**

- `msg` (string) - the error string

**Returns:**

- string - | nil errno constant name (e.g. "ENOENT"), or nil

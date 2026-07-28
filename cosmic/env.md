# env

 Environment variable utilities.
 Provides get, set, unset, clear, and all functions for environment variables.
 For the common case of reading a single variable, use env.get(), which
 returns nil when the variable is not set, or env.get_or() when you have
 a fallback. Use env.all() to get all variables as a {string:string} map
 parsed from unix.environ().

## Types

### EnvModule

```teal
local record EnvModule
  get: function(name: string): string | nil
  get_or: function(name: string, default: string): string
  set: function(name: string, value: string, overwrite?: boolean): boolean, string
  unset: function(name: string): boolean, string
  clear: function(): boolean, string
  all: function(): {string: string}
  list: function(): {string}
end
```

## Functions

### get

```teal
function get(name: string): string | nil
```

 Get the value of an environment variable, or nil when it is not set.
 **The nil is in the type**, which is the whole point of this
 function's shape. An optional default with a bare `string` return
 is a lie the checker cannot see: with no default the body returns
 the parameter, which is `string` inside the function and nil at the
 call site, so `local v: string = env.get("X")` type-checks strictly
 and crashes on the next line. A reading that can fail says so, and
 the caller narrows -- see `get_or` for the half that cannot fail.

**Parameters:**

- `name` (string) - The name of the environment variable

**Returns:**

- string|nil - The value, or nil when the variable is not set

### get_or

```teal
function get_or(name: string, default: string): string
```

 Get the value of an environment variable, or `default` when unset.
 The infallible half, and it is a separate function rather than an
 optional argument because the two have genuinely different types: a
 read with a fallback CANNOT fail, so making its caller narrow would
 be noise, and folding both into one signature is what produced a
 return type that was wrong half the time.

**Parameters:**

- `name` (string) - The name of the environment variable
- `default` (string) - The value to return when it is not set

**Returns:**

- string - The value, or `default`

### set

```teal
function set(name: string, value: string, overwrite?: boolean): boolean, string
```

 Set an environment variable.

**Parameters:**

- `name` (string) - The name of the environment variable
- `value` (string) - The value to set
- `overwrite?` (boolean) - If false, won't overwrite existing variables (defaults to true)

**Returns:**

- boolean - True on success
- string? - Error message if setting failed

### unset

```teal
function unset(name: string): boolean, string
```

 Unset an environment variable.

**Parameters:**

- `name` (string) - The name of the environment variable to remove

**Returns:**

- boolean - True on success
- string? - Error message if unsetting failed

### clear

```teal
function clear(): boolean, string
```

 Clear all environment variables.
 Warning: This removes ALL environment variables from the process.

**Returns:**

- boolean - True on success
- string? - Error message if clearing failed

### all

```teal
function all(): {string: string}
```

 Get all environment variables.
 Returns a table mapping variable names to their values.

**Returns:**

- {string:string} - A table of all environment variables

### list

```teal
function list(): {string}
```

 Get all environment variables as a list.
 Returns a list of "KEY=VALUE" strings suitable for passing to
 child.spawn or execve.

**Returns:**

- {string} - A list of "KEY=VALUE" strings

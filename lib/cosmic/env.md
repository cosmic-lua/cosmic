# env

 Environment variable utilities.
 Provides get, set, unset, clear, and all functions for environment variables.
 For the common case of reading a single variable, use env.get() — it wraps
 os.getenv() internally and is the simplest approach. Use env.all() to get
 all variables as a {string:string} map parsed from unix.environ().

## Types

### EnvModule

```teal
local record EnvModule
  get: function(name: string): string
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
function get(name: string): string
```

 Get the value of an environment variable.
 Returns nil if the variable is not set.

**Parameters:**

- `name` (string) - The name of the environment variable

**Returns:**

- string? - The value of the environment variable, or nil if not set

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

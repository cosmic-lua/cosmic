# tty

 Terminal (TTY) utilities.
 Wraps cosmo.unix for terminal detection and window size queries.

## Types

### TtyModule

 Module type for TTY operations.

```teal
local record TtyModule
  rows: number
  cols: number
  isatty: function(fd: number): boolean
  winsize: function(fd: number): WinSize, string
  stdin_isatty: function(): boolean
  stdout_isatty: function(): boolean
  stderr_isatty: function(): boolean
end
```

## Functions

### isatty

```teal
function isatty(fd: number): boolean
```

 Checks if a file descriptor refers to a terminal.

**Parameters:**

- `fd` (number) - File descriptor to check (0=stdin, 1=stdout, 2=stderr)

**Returns:**

- boolean - True if fd is a terminal

### winsize

```teal
function winsize(fd: number): TtyModule.WinSize, string
```

 Gets the terminal window size for a file descriptor.

**Parameters:**

- `fd` (number) - File descriptor (typically 0, 1, or 2)

**Returns:**

- WinSize|nil - Window size record with rows and cols, or nil on error
- string|nil - Error message if not a terminal

### stdin_isatty

```teal
function stdin_isatty(): boolean
```

 Checks if stdin is a terminal.

**Returns:**

- boolean - True if stdin is a terminal

### stdout_isatty

```teal
function stdout_isatty(): boolean
```

 Checks if stdout is a terminal.

**Returns:**

- boolean - True if stdout is a terminal

### stderr_isatty

```teal
function stderr_isatty(): boolean
```

 Checks if stderr is a terminal.

**Returns:**

- boolean - True if stderr is a terminal

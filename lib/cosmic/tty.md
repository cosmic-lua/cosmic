# tty

 Terminal (TTY) utilities.
 Wraps cosmo.unix for terminal detection, window size, and terminal modes.

## Types

### Termios

 Terminal I/O settings.

```teal
local record Termios
  iflag: number
  oflag: number
  cflag: number
  lflag: number
  cc: {number}
  ispeed: number
  ospeed: number
end
```

### UnixTty

```teal
local record UnixTty
  isatty: function(fd: number): boolean
  tiocgwinsz: function(fd: number): number, number
  tcgetattr: function(fd: number): Termios, Errno
  tcsetattr: function(fd: number, action: number, termios: Termios): boolean, Errno
  TCSANOW: number
  TCSADRAIN: number
  TCSAFLUSH: number
  ECHO: number
  ICANON: number
  ISIG: number
  IEXTEN: number
end
```

### WinSize

 Window size information.

```teal
local record WinSize
  rows: number
  cols: number
end
```

### TtyModule

 Module type for TTY operations.

```teal
local record TtyModule
  --  Terminal I/O settings.
  Termios: Termios
  --  tcsetattr actions.
  NOW: number
  DRAIN: number
  FLUSH: number
  --  Common lflag constants.
  ECHO: number
  ICANON: number
  ISIG: number
  IEXTEN: number
  isatty: function(fd: number): boolean
  winsize: function(fd: number): WinSize | nil, string
  stdin_isatty: function(): boolean
  stdout_isatty: function(): boolean
  stderr_isatty: function(): boolean
  getattr: function(fd: number): Termios | nil, string
  setattr: function(fd: number, action: number, termios: Termios): boolean, string
  raw: function(fd: number): Termios | nil, string
  noecho: function(fd: number): Termios | nil, string
  restore: function(fd: number, termios: Termios): boolean, string
  getpass: function(prompt: string): string | nil, string
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
function winsize(fd: number): TtyModule.WinSize | nil, string
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

### getattr

```teal
function getattr(fd: number): Termios | nil, string
```

 Gets terminal attributes for a file descriptor.

**Parameters:**

- `fd` (number) - File descriptor (typically 0 for stdin)

**Returns:**

- Termios - | nil Terminal attributes
- string? - Error message if not a terminal

### setattr

```teal
function setattr(fd: number, action: number, termios: Termios): boolean, string
```

 Sets terminal attributes for a file descriptor.

**Parameters:**

- `fd` (number) - File descriptor
- `action` (number) - When to apply changes (NOW, DRAIN, or FLUSH)
- `termios` (Termios) - Terminal attributes to set

**Returns:**

- boolean - True on success
- string? - Error message on failure

### raw

```teal
function raw(fd: number): Termios | nil, string
```

 Puts terminal into raw mode (no echo, no line buffering, no signals).
 Returns the original termios for later restoration.

**Parameters:**

- `fd` (number) - File descriptor (typically 0 for stdin)

**Returns:**

- Termios - | nil Original terminal attributes for restore()
- string? - Error message if not a terminal

### noecho

```teal
function noecho(fd: number): Termios | nil, string
```

 Disables echo on terminal (for password input).
 Returns the original termios for later restoration.

**Parameters:**

- `fd` (number) - File descriptor (typically 0 for stdin)

**Returns:**

- Termios - | nil Original terminal attributes for restore()
- string? - Error message if not a terminal

### restore

```teal
function restore(fd: number, termios: Termios): boolean, string
```

 Restores terminal attributes.

**Parameters:**

- `fd` (number) - File descriptor
- `termios` (Termios) - Terminal attributes from raw() or noecho()

**Returns:**

- boolean - True on success
- string? - Error message on failure

### getpass

```teal
function getpass(prompt: string): string | nil, string
```

 Reads a password from the terminal without echoing.
 Writes the prompt to stderr, disables echo, reads a line from stdin,
 then restores the terminal state before returning.
 If stdin is not a terminal, reads normally without echo manipulation.

**Parameters:**

- `prompt` (string) - Text to display before reading

**Returns:**

- string|nil - The password (without trailing newline), or nil on error
- string? - Error message on failure

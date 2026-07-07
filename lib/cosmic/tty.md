# tty

 Terminal (TTY) utilities.
 Wraps cosmo.unix for terminal detection, window size, and terminal modes.

## Types

### WinSize

 Window size information.

```teal
local record WinSize
  rows: number
  cols: number
end
```

### RawOptions

 Options for raw()/make_raw().

```teal
local record RawOptions
  --  Keep ISIG set so Ctrl-C/Ctrl-Z still generate signals.
  keep_signals: boolean
end
```

### TtyModule

 Module type for TTY operations.

```teal
local record TtyModule
  --  tcsetattr actions.
  NOW: number
  DRAIN: number
  FLUSH: number
  --  Common lflag constants.
  ECHO: number
  ICANON: number
  ISIG: number
  IEXTEN: number
  --  Input/output mode flag constants (for make_raw assertions).
  IXON: number
  ICRNL: number
  BRKINT: number
  OPOST: number
  --  cc indices (C-style; the Lua cc array is 1-based, so cc[VMIN + 1]).
  VMIN: number
  VTIME: number
  isatty: function(fd: number): boolean
  winsize: function(fd: number): WinSize | nil, string
  stdin_isatty: function(): boolean
  stdout_isatty: function(): boolean
  stderr_isatty: function(): boolean
  getattr: function(fd: number): Termios | nil, string
  setattr: function(fd: number, action: number, termios: Termios): boolean, string
  make_raw: function(termios: Termios, opts?: RawOptions): Termios
  raw: function(fd: number, opts?: RawOptions): Termios | nil, string
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

### make_raw

```teal
function make_raw(termios: Termios, opts?: TtyModule.RawOptions): Termios
```

 Compute raw-mode attributes from current ones (cfmakeraw semantics).
 Pure: returns a new Termios, the input is not mutated. Clears input
 translation and flow control (IXON, ICRNL, BRKINT, ...), output
 post-processing (OPOST), echo, canonical mode, and signal generation
 (unless opts.keep_signals), selects 8-bit characters, and sets
 VMIN=1/VTIME=0 so reads deliver one byte at a time without timeout.

**Parameters:**

- `termios` (Termios) - Current terminal attributes
- `opts` (RawOptions?) - keep_signals: keep Ctrl-C/Ctrl-Z generating signals

**Returns:**

- Termios - New attributes to pass to setattr()

### raw

```teal
function raw(fd: number, opts?: TtyModule.RawOptions): Termios | nil, string
```

 Puts terminal into raw mode: no echo, no line buffering, no signal
 keys (unless opts.keep_signals), no \r translation, no Ctrl-S flow
 control, no output post-processing (see make_raw).
 Returns the original termios for later restoration.

**Parameters:**

- `fd` (number) - File descriptor (typically 0 for stdin)
- `opts` (RawOptions?) - keep_signals: keep Ctrl-C/Ctrl-Z generating signals

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

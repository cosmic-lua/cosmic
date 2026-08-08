# tty

 Terminal (TTY) utilities.
 Wraps cosmo.unix for terminal detection, window size, and terminal modes.

## Types

### WindowSize

 Window size information.

```teal
local record WindowSize
  rows: integer
  cols: integer
end
```

### Pty

 An open pseudoterminal pair (see open_pty).

```teal
local record Pty
  manager: integer
  subordinate: integer
  name: string
end
```

### Options

 Options for raw()/make_raw().

```teal
local record Options
  --  Keep ISIG set so Ctrl-C/Ctrl-Z still generate signals.
  keep_signals: boolean
end
```

### TtyModule

 Module type for TTY operations.

```teal
local record TtyModule
  --  tcsetattr actions.
  NOW: integer
  DRAIN: integer
  FLUSH: integer
  --  Common lflag constants.
  ECHO: integer
  ICANON: integer
  ISIG: integer
  IEXTEN: integer
  --  Input/output mode flag constants (for make_raw assertions).
  IXON: integer
  ICRNL: integer
  BRKINT: integer
  OPOST: integer
  --  1-BASED cc indices (#999): `t.cc[tty.VMIN]` is C's c_cc[VMIN].
  --  The generated unix constants are C's 0-based values; these are
  --  pre-shifted for Lua's 1-based cc array so no caller writes `+ 1`.
  VMIN: integer
  VTIME: integer
  is_tty: function(fd?: integer): boolean
  window_size: function(fd: integer): WindowSize | nil, string
  attributes: function(fd: integer): Termios | nil, string
  apply_attributes: function(fd: integer, action: integer, termios: Termios): boolean, string
  make_raw: function(termios: Termios, opts?: Options): Termios
  raw: function(fd: integer, opts?: Options): Termios | nil, string
  disable_echo: function(fd: integer): Termios | nil, string
  restore: function(fd: integer, termios: Termios, action?: integer): boolean, string
  read_password: function(prompt: string): string | nil, string
  open_pty: function(): Pty | nil, string
  login_tty: function(fd: integer): boolean, string
end
```

### Termios

 Terminal I/O settings (the generated unix.Termios record).

alias of `cosmo.unix.Termios` — field and method table: `cosmic --docs cosmo.unix.Termios`

## Functions

### open_pty

```teal
function open_pty(): TtyModule.Pty | nil, string
```

 Opens a new pseudoterminal pair.
 The subordinate fd IS a terminal: is_tty, attributes, raw, disable_echo and
 the rest operate on it. That is what makes terminal code testable
 where no terminal exists -- a CI container, or any process whose
 stdio is a pipe. Both descriptors belong to the caller; close them.

**Returns:**

- TtyModule.Pty - | nil The open pair
- string? - Error message on failure

### login_tty

```teal
function login_tty(fd: integer): boolean, string
```

 Makes fd the controlling terminal of this process.
 Creates a new session, attaches fd as its controlling terminal, and
 dups it onto stdin/stdout/stderr. Intended for the child of a fork,
 between openpty() and exec -- it replaces this process's session, so
 never call it in a process you want to keep.

**Parameters:**

- `fd` (integer) - A terminal descriptor (ENOTTY otherwise)

**Returns:**

- boolean - True on success
- string? - Error message on failure

### is_tty

```teal
function is_tty(fd?: integer): boolean
```

 Checks if a file descriptor refers to a terminal (api-review-8:
 one is_tty(fd?) replaces isatty plus the three per-stream wrappers).
 (the default — "is my output a terminal" is the common question),
 2=stderr

**Parameters:**

- `fd` (integer?) - File descriptor to check: 0=stdin, 1=stdout

**Returns:**

- boolean - True if fd is a terminal

### window_size

```teal
function window_size(fd: integer): TtyModule.WindowSize | nil, string
```

 Gets the terminal window size for a file descriptor.

**Parameters:**

- `fd` (integer) - File descriptor (typically 0, 1, or 2)

**Returns:**

- WindowSize|nil - Window size record with rows and cols, or nil on error
- string|nil - Error message if not a terminal

### attributes

```teal
function attributes(fd: integer): Termios | nil, string
```

 Gets terminal attributes for a file descriptor.

**Parameters:**

- `fd` (integer) - File descriptor (typically 0 for stdin)

**Returns:**

- Termios - | nil Terminal attributes
- string? - Error message if not a terminal

### apply_attributes

```teal
function apply_attributes(fd: integer, action: integer, termios: Termios): boolean, string
```

 Sets terminal attributes for a file descriptor.

**Parameters:**

- `fd` (integer) - File descriptor
- `action` (integer) - When to apply changes (NOW, DRAIN, or FLUSH)
- `termios` (Termios) - Terminal attributes to set

**Returns:**

- boolean - True on success
- string? - Error message on failure

### make_raw

```teal
function make_raw(termios: Termios, opts?: TtyModule.Options): Termios
```

 Compute raw-mode attributes from current ones (cfmakeraw semantics).
 Pure: returns a new Termios, the input is not mutated. Clears input
 translation and flow control (IXON, ICRNL, BRKINT, ...), output
 post-processing (OPOST), echo, canonical mode, and signal generation
 (unless opts.keep_signals), selects 8-bit characters, and sets
 VMIN=1/VTIME=0 so reads deliver one byte at a time without timeout.

**Parameters:**

- `termios` (Termios) - Current terminal attributes
- `opts` (Options?) - keep_signals: keep Ctrl-C/Ctrl-Z generating signals

**Returns:**

- Termios - New attributes to pass to apply_attributes()

### raw

```teal
function raw(fd: integer, opts?: TtyModule.Options): Termios | nil, string
```

 Puts terminal into raw mode: no echo, no line buffering, no signal
 keys (unless opts.keep_signals), no \r translation, no Ctrl-S flow
 control, no output post-processing (see make_raw).
 Returns the original termios for later restoration.

**Parameters:**

- `fd` (integer) - File descriptor (typically 0 for stdin)
- `opts` (Options?) - keep_signals: keep Ctrl-C/Ctrl-Z generating signals

**Returns:**

- Termios - | nil Original terminal attributes for restore()
- string? - Error message if not a terminal

### disable_echo

```teal
function disable_echo(fd: integer): Termios | nil, string
```

 Disables echo on terminal (for password input).
 Returns the original termios for later restoration.

**Parameters:**

- `fd` (integer) - File descriptor (typically 0 for stdin)

**Returns:**

- Termios - | nil Original terminal attributes for restore()
- string? - Error message if not a terminal

### restore

```teal
function restore(fd: integer, termios: Termios, action?: integer): boolean, string
```

 Restores terminal attributes.
 pending output is written), or FLUSH (DRAIN + discard pending input)

**Parameters:**

- `fd` (integer) - File descriptor
- `termios` (Termios) - Terminal attributes from raw() or disable_echo()
- `action` (integer?) - When to apply: NOW (default), DRAIN (after

**Returns:**

- boolean - True on success
- string? - Error message on failure

### read_password

```teal
function read_password(prompt: string): string | nil, string
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

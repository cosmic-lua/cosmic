--- Terminal (TTY) utilities.
--- Wraps cosmo.unix for terminal detection, window size, and terminal modes.
local unix = require("cosmo.unix")
local errstr = require("cosmic.errno").str

--- Terminal I/O settings (the generated unix.Termios record).
local type Termios = unix.Termios

--- Module type for TTY operations.
local record TtyModule
  --- Window size information.
  record WinSize
    rows: number
    cols: number
  end

  --- Terminal I/O settings.
  type Termios = Termios

  --- Options for raw()/make_raw().
  record RawOpts
    --- Keep ISIG set so Ctrl-C/Ctrl-Z still generate signals.
    keep_signals: boolean
  end

  --- tcsetattr actions.
  NOW: number
  DRAIN: number
  FLUSH: number

  --- Common lflag constants.
  ECHO: number
  ICANON: number
  ISIG: number
  IEXTEN: number

  --- Input/output mode flag constants (for make_raw assertions).
  IXON: number
  ICRNL: number
  BRKINT: number
  OPOST: number

  --- cc indices (C-style; the Lua cc array is 1-based, so cc[VMIN + 1]).
  VMIN: number
  VTIME: number

  isatty: function(fd: number): boolean
  winsize: function(fd: number): WinSize | nil, string
  stdin_isatty: function(): boolean
  stdout_isatty: function(): boolean
  stderr_isatty: function(): boolean
  getattr: function(fd: number): Termios | nil, string
  setattr: function(fd: number, action: number, termios: Termios): boolean, string
  make_raw: function(termios: Termios, opts?: RawOpts): Termios
  raw: function(fd: number, opts?: RawOpts): Termios | nil, string
  noecho: function(fd: number): Termios | nil, string
  restore: function(fd: number, termios: Termios): boolean, string
  getpass: function(prompt: string): string | nil, string
end

--- Checks if a file descriptor refers to a terminal.
--- @param fd number File descriptor to check (0=stdin, 1=stdout, 2=stderr)
--- @return boolean True if fd is a terminal
local function isatty(fd: number): boolean
  return (unix.isatty(fd))
end

--- Gets the terminal window size for a file descriptor.
--- @param fd number File descriptor (typically 0, 1, or 2)
--- @return WinSize|nil Window size record with rows and cols, or nil on error
--- @return string|nil Error message if not a terminal
local function winsize(fd: number): TtyModule.WinSize | nil, string
  local rows, cols = unix.tiocgwinsz(fd)
  if rows == nil then
    -- On failure the binding returns (nil, err, errno): the error string
    -- arrives in the second slot, where the columns would have been.
    return nil, errstr(cols, "tiocgwinsz")
  end
  return {rows = rows, cols = cols}
end

--- Checks if stdin is a terminal.
--- @return boolean True if stdin is a terminal
local function stdin_isatty(): boolean
  return (unix.isatty(0))
end

--- Checks if stdout is a terminal.
--- @return boolean True if stdout is a terminal
local function stdout_isatty(): boolean
  return (unix.isatty(1))
end

--- Checks if stderr is a terminal.
--- @return boolean True if stderr is a terminal
local function stderr_isatty(): boolean
  return (unix.isatty(2))
end

--- Gets terminal attributes for a file descriptor.
--- @param fd number File descriptor (typically 0 for stdin)
--- @return Termios | nil Terminal attributes
--- @return string? Error message if not a terminal
local function getattr(fd: number): Termios | nil, string
  local termios, err = unix.tcgetattr(fd)
  if not termios then
    return nil, errstr(err, "tcgetattr")
  end
  return termios
end

--- Sets terminal attributes for a file descriptor.
--- @param fd number File descriptor
--- @param action number When to apply changes (NOW, DRAIN, or FLUSH)
--- @param termios Termios Terminal attributes to set
--- @return boolean True on success
--- @return string? Error message on failure
local function setattr(fd: number, action: number, termios: Termios): boolean, string
  local ok, err = unix.tcsetattr(fd, action, termios)
  if not ok then
    return false, errstr(err, "tcsetattr")
  end
  return true
end

--- Deep-copy terminal attributes. The cc control-character table is
--- copied element by element: a shallow copy would alias the live table,
--- and mutating the copy (or the terminal state) would corrupt the
--- snapshot that restore() later applies.
--- @param t Termios Terminal attributes to copy
--- @return Termios An independent copy
local function copy_termios(t: Termios): Termios
  local cc: {number} = {}
  for i, v in ipairs(t.cc) do
    cc[i] = v
  end
  return {
    iflag = t.iflag,
    oflag = t.oflag,
    cflag = t.cflag,
    lflag = t.lflag,
    cc = cc,
    ispeed = t.ispeed,
    ospeed = t.ospeed,
  }
end

--- Compute raw-mode attributes from current ones (cfmakeraw semantics).
--- Pure: returns a new Termios, the input is not mutated. Clears input
--- translation and flow control (IXON, ICRNL, BRKINT, ...), output
--- post-processing (OPOST), echo, canonical mode, and signal generation
--- (unless opts.keep_signals), selects 8-bit characters, and sets
--- VMIN=1/VTIME=0 so reads deliver one byte at a time without timeout.
--- @param termios Termios Current terminal attributes
--- @param opts RawOpts? keep_signals: keep Ctrl-C/Ctrl-Z generating signals
--- @return Termios New attributes to pass to setattr()
local function make_raw(termios: Termios, opts?: TtyModule.RawOpts): Termios
  local t = copy_termios(termios)
  t.iflag = t.iflag & ~ (unix.IGNBRK | unix.BRKINT | unix.PARMRK | unix.ISTRIP
    | unix.INLCR | unix.IGNCR | unix.ICRNL | unix.IXON)
  t.oflag = t.oflag & ~ unix.OPOST
  local lclear = unix.ECHO | unix.ECHONL | unix.ICANON | unix.IEXTEN
  if not (opts and opts.keep_signals) then
    lclear = lclear | unix.ISIG
  end
  t.lflag = t.lflag & ~ lclear
  t.cflag = (t.cflag & ~ (unix.CSIZE | unix.PARENB)) | unix.CS8
  -- The Lua cc array is 1-based: cc[i + 1] holds C's c_cc[i].
  t.cc[(unix.VMIN + 1) as integer] = 1
  t.cc[(unix.VTIME + 1) as integer] = 0
  return t
end

--- Puts terminal into raw mode: no echo, no line buffering, no signal
--- keys (unless opts.keep_signals), no \r translation, no Ctrl-S flow
--- control, no output post-processing (see make_raw).
--- Returns the original termios for later restoration.
--- @param fd number File descriptor (typically 0 for stdin)
--- @param opts RawOpts? keep_signals: keep Ctrl-C/Ctrl-Z generating signals
--- @return Termios | nil Original terminal attributes for restore()
--- @return string? Error message if not a terminal
local function raw(fd: number, opts?: TtyModule.RawOpts): Termios | nil, string
  local termios, err = getattr(fd)
  if not termios then
    return nil, err
  end
  local t = termios as Termios
  local original = copy_termios(t)
  local ok, set_err = setattr(fd, unix.TCSANOW, make_raw(t, opts))
  if not ok then
    return nil, set_err
  end
  return original
end

--- Disables echo on terminal (for password input).
--- Returns the original termios for later restoration.
--- @param fd number File descriptor (typically 0 for stdin)
--- @return Termios | nil Original terminal attributes for restore()
--- @return string? Error message if not a terminal
local function noecho(fd: number): Termios | nil, string
  local termios, err = getattr(fd)
  if not termios then
    return nil, err
  end
  local t = termios as Termios
  local original = copy_termios(t)
  t.lflag = t.lflag & ~ unix.ECHO
  local ok, set_err = setattr(fd, unix.TCSANOW, t)
  if not ok then
    return nil, set_err
  end
  return original
end

--- Restores terminal attributes.
--- @param fd number File descriptor
--- @param termios Termios Terminal attributes from raw() or noecho()
--- @return boolean True on success
--- @return string? Error message on failure
local function restore(fd: number, termios: Termios): boolean, string
  return setattr(fd, unix.TCSANOW, termios)
end

--- Reads a password from the terminal without echoing.
--- Writes the prompt to stderr, disables echo, reads a line from stdin,
--- then restores the terminal state before returning.
--- If stdin is not a terminal, reads normally without echo manipulation.
--- @param prompt string Text to display before reading
--- @return string|nil The password (without trailing newline), or nil on error
--- @return string? Error message on failure
local function getpass(prompt: string): string | nil, string
  io.stderr:write(prompt)
  -- If stdin is not a tty, read without echo manipulation
  if not unix.isatty(0) then
    local line = io.stdin:read("l")
    if line == nil then
      return nil, "EOF"
    end
    return line
  end
  -- Disable echo on stdin (fd 0)
  local original, err = noecho(0)
  if not original then
    return nil, err
  end
  -- Read one line inside pcall so we always restore the terminal, even if
  -- io.stdin:read raises an error (e.g. EINTR or a Lua I/O error).
  local read_ok, line_or_err = pcall(function(): string
      return io.stdin:read("l")
    end)
  -- Write newline to stderr since echo is off (regardless of outcome)
  io.stderr:write("\n")
  restore(0, original as Termios)
  if not read_ok then
    -- pcall caught an error: line_or_err is the error message
    return nil, tostring(line_or_err)
  end
  local line = line_or_err as string
  if line == nil then
    return nil, "EOF"
  end
  return line
end

local M: TtyModule = {
  isatty = isatty,
  winsize = winsize,
  stdin_isatty = stdin_isatty,
  stdout_isatty = stdout_isatty,
  stderr_isatty = stderr_isatty,
  getattr = getattr,
  setattr = setattr,
  make_raw = make_raw,
  raw = raw,
  noecho = noecho,
  restore = restore,
  getpass = getpass,

  -- Constants
  NOW = unix.TCSANOW,
  DRAIN = unix.TCSADRAIN,
  FLUSH = unix.TCSAFLUSH,
  ECHO = unix.ECHO,
  ICANON = unix.ICANON,
  ISIG = unix.ISIG,
  IEXTEN = unix.IEXTEN,
  IXON = unix.IXON,
  ICRNL = unix.ICRNL,
  BRKINT = unix.BRKINT,
  OPOST = unix.OPOST,
  VMIN = unix.VMIN,
  VTIME = unix.VTIME,
}

return M

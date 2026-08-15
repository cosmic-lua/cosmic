--- Terminal (TTY) utilities.
--- Wraps cosmo.unix for terminal detection, window size, and terminal modes.
local unix = require("cosmo.unix")
local errstr = require("cosmic.errno").format

-- 1-based Lua indices into Termios.cc: C's 0-based VMIN/VTIME shifted
-- once, here, so neither this module nor any caller writes +1.
local VMIN < const > = unix.VMIN + 1
local VTIME < const > = unix.VTIME + 1

--- Terminal I/O settings (the generated unix.Termios record).
local type Termios = unix.Termios

--- Module type for TTY operations.
local record TtyModule
  --- Window size information.
  record WindowSize
    rows: integer
    cols: integer
  end

  --- Terminal I/O settings.
  type Termios = Termios

  --- An open pseudoterminal pair (see open_pty).
  record Pty
    manager: integer -- controlling side; write here to feed the terminal
    subordinate: integer -- the terminal itself, what a program's stdio sees
    name: string -- filesystem path of the subordinate, e.g. /dev/pts/3
  end

  --- Options for raw()/make_raw().
  record Options
    --- Keep ISIG set so Ctrl-C/Ctrl-Z still generate signals.
    keep_signals: boolean
  end

  --- tcsetattr actions.
  NOW: integer
  DRAIN: integer
  FLUSH: integer

  --- Common lflag constants.
  ECHO: integer
  ICANON: integer
  ISIG: integer
  IEXTEN: integer

  --- Input/output mode flag constants (for make_raw assertions).
  IXON: integer
  ICRNL: integer
  BRKINT: integer
  OPOST: integer

  --- 1-BASED cc indices: `t.cc[tty.VMIN]` is C's c_cc[VMIN].
  --- The generated unix constants are C's 0-based values; these are
  --- pre-shifted for Lua's 1-based cc array so no caller writes `+ 1`.
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

--- Opens a new pseudoterminal pair.
--- The subordinate fd IS a terminal: is_tty, attributes, raw, disable_echo and
--- the rest operate on it. That is what makes terminal code testable
--- where no terminal exists -- a CI container, or any process whose
--- stdio is a pipe. Both descriptors belong to the caller; close them.
--- @return TtyModule.Pty | nil The open pair
--- @return string? Error message on failure
local function open_pty(): TtyModule.Pty | nil, string
  local mfd, sfd, name = unix.openpty()
  if not mfd then
    -- on failure the binding returns (nil, err, errno), so the second
    -- slot carries the error string rather than a descriptor
    return nil, errstr(sfd, "openpty")
  end
  return {manager = mfd, subordinate = sfd, name = name}
end

--- Makes fd the controlling terminal of this process.
--- Creates a new session, attaches fd as its controlling terminal, and
--- dups it onto stdin/stdout/stderr. Intended for the child of a fork,
--- between openpty() and exec -- it replaces this process's session, so
--- never call it in a process you want to keep.
--- @param fd integer A terminal descriptor (ENOTTY otherwise)
--- @return boolean True on success
--- @return string? Error message on failure
local function login_tty(fd: integer): boolean, string
  local ok, err = unix.login_tty(fd)
  if not ok then
    return false, errstr(err, "login_tty")
  end
  return true
end

--- Checks if a file descriptor refers to a terminal.
--- @param fd integer? File descriptor to check: 0=stdin, 1=stdout
--- (the default — "is my output a terminal" is the common question),
--- 2=stderr
--- @return boolean True if fd is a terminal
local function is_tty(fd?: integer): boolean
  return (unix.isatty(fd or 1))
end

--- Gets the terminal window size for a file descriptor.
--- @param fd integer File descriptor (typically 0, 1, or 2)
--- @return WindowSize|nil Window size record with rows and cols, or nil on error
--- @return string|nil Error message if not a terminal
local function window_size(fd: integer): TtyModule.WindowSize | nil, string
  local rows, cols = unix.tiocgwinsz(fd)
  if rows == nil then
    -- On failure the binding returns (nil, err, errno): the error string
    -- arrives in the second slot, where the columns would have been.
    return nil, errstr(cols, "tiocgwinsz")
  end
  return {rows = rows, cols = cols}
end

--- Gets terminal attributes for a file descriptor.
--- @param fd integer File descriptor (typically 0 for stdin)
--- @return Termios | nil Terminal attributes
--- @return string? Error message if not a terminal
local function attributes(fd: integer): Termios | nil, string
  local termios, err = unix.tcgetattr(fd)
  if not termios then
    return nil, errstr(err, "tcgetattr")
  end
  return termios
end

--- Sets terminal attributes for a file descriptor.
--- @param fd integer File descriptor
--- @param action integer When to apply changes (NOW, DRAIN, or FLUSH)
--- @param termios Termios Terminal attributes to set
--- @return boolean True on success
--- @return string? Error message on failure
local function apply_attributes(fd: integer, action: integer, termios: Termios): boolean, string
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
  local cc: {integer} = {}
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
--- @param opts Options? keep_signals: keep Ctrl-C/Ctrl-Z generating signals
--- @return Termios New attributes to pass to apply_attributes()
local function make_raw(termios: Termios, opts?: TtyModule.Options): Termios
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
  t.cc[VMIN] = 1
  t.cc[VTIME] = 0
  return t
end

--- Puts terminal into raw mode: no echo, no line buffering, no signal
--- keys (unless opts.keep_signals), no \r translation, no Ctrl-S flow
--- control, no output post-processing (see make_raw).
--- Returns the original termios for later restoration.
--- @param fd integer File descriptor (typically 0 for stdin)
--- @param opts Options? keep_signals: keep Ctrl-C/Ctrl-Z generating signals
--- @return Termios | nil Original terminal attributes for restore()
--- @return string? Error message if not a terminal
local function raw(fd: integer, opts?: TtyModule.Options): Termios | nil, string
  local termios, err = attributes(fd)
  if not termios then
    return nil, err
  end
  local t = termios
  local original = copy_termios(t)
  local ok, set_err = apply_attributes(fd, unix.TCSANOW, make_raw(t, opts))
  if not ok then
    return nil, set_err
  end
  return original
end

--- Disables echo on terminal (for password input).
--- Returns the original termios for later restoration.
--- @param fd integer File descriptor (typically 0 for stdin)
--- @return Termios | nil Original terminal attributes for restore()
--- @return string? Error message if not a terminal
local function disable_echo(fd: integer): Termios | nil, string
  local termios, err = attributes(fd)
  if not termios then
    return nil, err
  end
  local t = termios
  local original = copy_termios(t)
  t.lflag = t.lflag & ~ unix.ECHO
  local ok, set_err = apply_attributes(fd, unix.TCSANOW, t)
  if not ok then
    return nil, set_err
  end
  return original
end

--- Restores terminal attributes.
--- @param fd integer File descriptor
--- @param termios Termios Terminal attributes from raw() or disable_echo()
--- @param action integer? When to apply: NOW (default), DRAIN (after
--- pending output is written), or FLUSH (DRAIN + discard pending input)
--- @return boolean True on success
--- @return string? Error message on failure
local function restore(fd: integer, termios: Termios, action?: integer): boolean, string
  return apply_attributes(fd, action or unix.TCSANOW, termios)
end

--- Reads a password from the terminal without echoing.
--- Writes the prompt to stderr, disables echo, reads a line from stdin,
--- then restores the terminal state before returning.
--- If stdin is not a terminal, reads normally without echo manipulation.
--- @param prompt string Text to display before reading
--- @return string|nil The password (without trailing newline), or nil on error
--- @return string? Error message on failure
local function read_password(prompt: string): string | nil, string
  io.stderr:write(prompt)
  -- If stdin is not a tty, read without echo manipulation
  if not is_tty(0) then
    local line = io.stdin:read("l")
    if line == nil then
      return nil, "EOF"
    end
    return line
  end
  -- Disable echo on stdin (fd 0)
  local original, err = disable_echo(0)
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
  local _ok, _err = restore(0, original)
  if not read_ok then
    -- pcall caught an error: line_or_err is the error message
    return nil, tostring(line_or_err)
  end
  local line = line_or_err
  if line == nil then
    return nil, "EOF"
  end
  return line
end

local M: TtyModule = {
  is_tty = is_tty,
  window_size = window_size,
  attributes = attributes,
  apply_attributes = apply_attributes,
  make_raw = make_raw,
  raw = raw,
  disable_echo = disable_echo,
  restore = restore,
  read_password = read_password,
  open_pty = open_pty,
  login_tty = login_tty,

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
  VMIN = VMIN,
  VTIME = VTIME,
}

return M

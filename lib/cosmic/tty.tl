--- Terminal (TTY) utilities.
--- Wraps cosmo.unix for terminal detection, window size, and terminal modes.

--- Terminal I/O settings.
local record Termios
  iflag: number
  oflag: number
  cflag: number
  lflag: number
  cc: {number}
  ispeed: number
  ospeed: number
end

local record Errno
  doc: function(self: Errno): string
end

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

local unix = require("cosmo.unix") as UnixTty

--- Module type for TTY operations.
local record TtyModule
  --- Window size information.
  record WinSize
    rows: number
    cols: number
  end

  --- Terminal I/O settings.
  Termios: Termios

  --- tcsetattr actions.
  NOW: number
  DRAIN: number
  FLUSH: number

  --- Common lflag constants.
  ECHO: number
  ICANON: number
  ISIG: number
  IEXTEN: number

  isatty: function(fd: number): boolean
  winsize: function(fd: number): WinSize, string
  stdin_isatty: function(): boolean
  stdout_isatty: function(): boolean
  stderr_isatty: function(): boolean
  getattr: function(fd: number): Termios, string
  setattr: function(fd: number, action: number, termios: Termios): boolean, string
  raw: function(fd: number): Termios, string
  noecho: function(fd: number): Termios, string
  restore: function(fd: number, termios: Termios): boolean, string
end

--- Checks if a file descriptor refers to a terminal.
--- @param fd number File descriptor to check (0=stdin, 1=stdout, 2=stderr)
--- @return boolean True if fd is a terminal
local function isatty(fd: number): boolean
  return unix.isatty(fd)
end

--- Gets the terminal window size for a file descriptor.
--- @param fd number File descriptor (typically 0, 1, or 2)
--- @return WinSize|nil Window size record with rows and cols, or nil on error
--- @return string|nil Error message if not a terminal
local function winsize(fd: number): TtyModule.WinSize, string
  local rows, cols = unix.tiocgwinsz(fd)
  if not rows or not cols then
    return nil, "not a terminal"
  end
  return {rows = rows, cols = cols}
end

--- Checks if stdin is a terminal.
--- @return boolean True if stdin is a terminal
local function stdin_isatty(): boolean
  return unix.isatty(0)
end

--- Checks if stdout is a terminal.
--- @return boolean True if stdout is a terminal
local function stdout_isatty(): boolean
  return unix.isatty(1)
end

--- Checks if stderr is a terminal.
--- @return boolean True if stderr is a terminal
local function stderr_isatty(): boolean
  return unix.isatty(2)
end

--- Gets terminal attributes for a file descriptor.
--- @param fd number File descriptor (typically 0 for stdin)
--- @return Termios Terminal attributes
--- @return string? Error message if not a terminal
local function getattr(fd: number): Termios, string
  local termios, err = unix.tcgetattr(fd)
  if not termios then
    if err and err.doc then
      return nil, err:doc()
    end
    return nil, "tcgetattr failed"
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
    if err and err.doc then
      return false, err:doc()
    end
    return false, "tcsetattr failed"
  end
  return true
end

--- Puts terminal into raw mode (no echo, no line buffering, no signals).
--- Returns the original termios for later restoration.
--- @param fd number File descriptor (typically 0 for stdin)
--- @return Termios Original terminal attributes for restore()
--- @return string? Error message if not a terminal
local function raw(fd: number): Termios, string
  local termios, err = getattr(fd)
  if not termios then
    return nil, err
  end
  local original: Termios = {
    iflag = termios.iflag,
    oflag = termios.oflag,
    cflag = termios.cflag,
    lflag = termios.lflag,
    cc = termios.cc,
    ispeed = termios.ispeed,
    ospeed = termios.ospeed,
  }
  -- Disable echo, canonical mode, signals, and extended input processing
  termios.lflag = termios.lflag & ~ (unix.ECHO | unix.ICANON | unix.ISIG | unix.IEXTEN)
  local ok, set_err = setattr(fd, unix.TCSANOW, termios)
  if not ok then
    return nil, set_err
  end
  return original
end

--- Disables echo on terminal (for password input).
--- Returns the original termios for later restoration.
--- @param fd number File descriptor (typically 0 for stdin)
--- @return Termios Original terminal attributes for restore()
--- @return string? Error message if not a terminal
local function noecho(fd: number): Termios, string
  local termios, err = getattr(fd)
  if not termios then
    return nil, err
  end
  local original: Termios = {
    iflag = termios.iflag,
    oflag = termios.oflag,
    cflag = termios.cflag,
    lflag = termios.lflag,
    cc = termios.cc,
    ispeed = termios.ispeed,
    ospeed = termios.ospeed,
  }
  termios.lflag = termios.lflag & ~ unix.ECHO
  local ok, set_err = setattr(fd, unix.TCSANOW, termios)
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

local M: TtyModule = {
  isatty = isatty,
  winsize = winsize,
  stdin_isatty = stdin_isatty,
  stdout_isatty = stdout_isatty,
  stderr_isatty = stderr_isatty,
  getattr = getattr,
  setattr = setattr,
  raw = raw,
  noecho = noecho,
  restore = restore,

  -- Constants
  NOW = unix.TCSANOW,
  DRAIN = unix.TCSADRAIN,
  FLUSH = unix.TCSAFLUSH,
  ECHO = unix.ECHO,
  ICANON = unix.ICANON,
  ISIG = unix.ISIG,
  IEXTEN = unix.IEXTEN,
}

return M

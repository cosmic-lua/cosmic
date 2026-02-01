--- Terminal (TTY) utilities.
--- Wraps cosmo.unix for terminal detection and window size queries.
local unix = require("cosmo.unix")

--- Module type for TTY operations.
local record TtyModule
  --- Window size information.
  record WinSize
    rows: number
    cols: number
  end
  isatty: function(fd: number): boolean
  winsize: function(fd: number): WinSize, string
  stdin_isatty: function(): boolean
  stdout_isatty: function(): boolean
  stderr_isatty: function(): boolean
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

local M: TtyModule = {
  isatty = isatty,
  winsize = winsize,
  stdin_isatty = stdin_isatty,
  stdout_isatty = stdout_isatty,
  stderr_isatty = stderr_isatty,
}

return M

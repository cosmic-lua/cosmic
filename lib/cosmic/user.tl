--- User and group identity operations.
--- Wraps cosmo.unix for user/group ID queries and modifications.
local unix = require("cosmo.unix")

--- Get the real user ID of the calling process.
--- @return number The real user ID
local function getuid(): number
  return unix.getuid()
end

--- Get the real group ID of the calling process.
--- On Windows this is polyfilled as getuid().
--- @return number The real group ID
local function getgid(): number
  return unix.getgid()
end

--- Get the effective user ID of the calling process.
--- For example, if your binary is setuid, getuid() returns the uid of the user
--- running the program, while geteuid() returns the uid of the file owner.
--- On Windows this is polyfilled as getuid().
--- @return number The effective user ID
local function geteuid(): number
  return unix.geteuid()
end

--- Get the effective group ID of the calling process.
--- On Windows this is polyfilled as getuid().
--- @return number The effective group ID
local function getegid(): number
  return unix.getegid()
end

--- Get the login name of the user running the process.
--- Returns nil if the login name cannot be determined.
--- @return string The login name, or nil on failure
local function getlogin(): string
  return unix.getlogin()
end

--- Set the user ID of the calling process.
--- Returns ENOSYS on Windows NT if uid isn't getuid().
--- @param uid number The user ID to set
--- @return boolean True on success, nil on failure
local function setuid(uid: number): boolean
  return unix.setuid(uid)
end

--- Set the group ID of the calling process.
--- Returns ENOSYS on Windows NT if gid isn't getgid().
--- @param gid number The group ID to set
--- @return boolean True on success, nil on failure
local function setgid(gid: number): boolean
  return unix.setgid(gid)
end

--- Set the filesystem user ID.
--- @param uid number The filesystem user ID to set
--- @return boolean True on success, nil on failure
local function setfsuid(uid: number): boolean
  return unix.setfsuid(uid)
end

--- Set real, effective, and saved user IDs.
--- Pass -1 for any argument to leave that ID unchanged.
--- @param real number The real user ID to set (-1 to leave unchanged)
--- @param effective number The effective user ID to set (-1 to leave unchanged)
--- @param saved number The saved user ID to set (-1 to leave unchanged)
--- @return boolean True on success, nil on failure
local function setresuid(real: number, effective: number, saved: number): boolean
  return unix.setresuid(real, effective, saved)
end

--- Set real, effective, and saved group IDs.
--- Pass -1 for any argument to leave that ID unchanged.
--- @param real number The real group ID to set (-1 to leave unchanged)
--- @param effective number The effective group ID to set (-1 to leave unchanged)
--- @param saved number The saved group ID to set (-1 to leave unchanged)
--- @return boolean True on success, nil on failure
local function setresgid(real: number, effective: number, saved: number): boolean
  return unix.setresgid(real, effective, saved)
end

--- Set the file mode creation mask.
--- The umask is used by open(), mkdir(), etc. to modify the permissions
--- of newly created files and directories.
--- @param newmask number The new file mode creation mask
--- @return number The previous umask value
local function umask(newmask: number): number
  return unix.umask(newmask)
end

--- Change the root directory.
--- Changes the root directory of the calling process to the specified path.
--- This call requires appropriate privileges (typically root).
--- @param path string The new root directory path
--- @return boolean True on success, nil on failure
local function chroot(path: string): boolean
  return unix.chroot(path)
end

local record UserModule
  getuid: function(): number
  getgid: function(): number
  geteuid: function(): number
  getegid: function(): number
  getlogin: function(): string
  setuid: function(uid: number): boolean
  setgid: function(gid: number): boolean
  setfsuid: function(uid: number): boolean
  setresuid: function(real: number, effective: number, saved: number): boolean
  setresgid: function(real: number, effective: number, saved: number): boolean
  umask: function(newmask: number): number
  chroot: function(path: string): boolean
end

local M: UserModule = {
  getuid = getuid,
  getgid = getgid,
  geteuid = geteuid,
  getegid = getegid,
  getlogin = getlogin,
  setuid = setuid,
  setgid = setgid,
  setfsuid = setfsuid,
  setresuid = setresuid,
  setresgid = setresgid,
  umask = umask,
  chroot = chroot,
}

return M

--- User and group identity operations.
--- Wraps cosmo.unix for user/group ID queries and modifications.
local unix = require("cosmo.unix")
local errstr = require("cosmic.errno").format

--- Get the real user ID of the calling process.
--- @return integer The real user ID
local function getuid(): integer
  return unix.getuid()
end

--- Get the real group ID of the calling process.
--- On Windows this is polyfilled as getuid().
--- @return integer The real group ID
local function getgid(): integer
  return unix.getgid()
end

--- Get the effective user ID of the calling process.
--- For example, if your binary is setuid, getuid() returns the uid of the user
--- running the program, while geteuid() returns the uid of the file owner.
--- On Windows this is polyfilled as getuid().
--- @return integer The effective user ID
local function geteuid(): integer
  return unix.geteuid()
end

--- Get the effective group ID of the calling process.
--- On Windows this is polyfilled as getuid().
--- @return integer The effective group ID
local function getegid(): integer
  return unix.getegid()
end

--- Get the login name of the user running the process.
--- @return string | nil The login name, or nil on failure
--- @return string? Error message if the login name cannot be determined
local function getlogin(): string | nil, string
  local name, err = unix.getlogin()
  if not name then
    return nil, errstr(err, "getlogin")
  end
  return name
end

--- Set the user ID of the calling process.
--- Returns ENOSYS on Windows NT if uid isn't getuid().
--- @param uid integer The user ID to set
--- @return boolean True on success
--- @return string? Error message on failure
local function setuid(uid: integer): boolean, string
  local ok, err = unix.setuid(uid)
  if not ok then
    return false, errstr(err, "setuid")
  end
  return true
end

--- Set the group ID of the calling process.
--- Returns ENOSYS on Windows NT if gid isn't getgid().
--- @param gid integer The group ID to set
--- @return boolean True on success
--- @return string? Error message on failure
local function setgid(gid: integer): boolean, string
  local ok, err = unix.setgid(gid)
  if not ok then
    return false, errstr(err, "setgid")
  end
  return true
end

--- Set real, effective, and saved user IDs.
--- Pass -1 for any argument to leave that ID unchanged.
--- @param real integer The real user ID to set (-1 to leave unchanged)
--- @param effective integer The effective user ID to set (-1 to leave unchanged)
--- @param saved integer The saved user ID to set (-1 to leave unchanged)
--- @return boolean True on success
--- @return string? Error message on failure
local function setresuid(real: integer, effective: integer, saved: integer): boolean, string
  local ok, err = unix.setresuid(real, effective, saved)
  if not ok then
    return false, errstr(err, "setresuid")
  end
  return true
end

--- Set real, effective, and saved group IDs.
--- Pass -1 for any argument to leave that ID unchanged.
--- @param real integer The real group ID to set (-1 to leave unchanged)
--- @param effective integer The effective group ID to set (-1 to leave unchanged)
--- @param saved integer The saved group ID to set (-1 to leave unchanged)
--- @return boolean True on success
--- @return string? Error message on failure
local function setresgid(real: integer, effective: integer, saved: integer): boolean, string
  local ok, err = unix.setresgid(real, effective, saved)
  if not ok then
    return false, errstr(err, "setresgid")
  end
  return true
end

local record UserModule
  getuid: function(): integer
  getgid: function(): integer
  geteuid: function(): integer
  getegid: function(): integer
  getlogin: function(): string | nil, string
  setuid: function(uid: integer): boolean, string
  setgid: function(gid: integer): boolean, string
  setresuid: function(real: integer, effective: integer, saved: integer): boolean, string
  setresgid: function(real: integer, effective: integer, saved: integer): boolean, string
end

local M: UserModule = {
  getuid = getuid,
  getgid = getgid,
  geteuid = geteuid,
  getegid = getegid,
  getlogin = getlogin,
  setuid = setuid,
  setgid = setgid,
  setresuid = setresuid,
  setresgid = setresgid,
}

return M

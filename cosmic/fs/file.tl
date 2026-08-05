--- Whole-file content operations: read, write, truncate, write_atomic.
--- Internal submodule used by cosmic.fs.
local cosmo = require("cosmo")
local unix = require("cosmo.unix")
local errno = require("cosmic.errno")
local cfd = require("cosmic.fd")
local stream = require("cosmic.stream")
local errstr = errno.str

--- Read entire file contents.
--- @param path string Path to the file
--- @return string | nil File contents, or nil on error
--- @return string Error message if failed
local function read(path: string): string | nil, string
  local data, err = cosmo.Slurp(path)
  if not data then
    -- The binding error already names the path (e.g. "open: /x: ENOENT: ...").
    return nil, err or ("failed to read file: " .. path)
  end
  return data
end

--- Write data to a file, creating or overwriting it.
--- @param path string Path to the file
--- @param data string Data to write
--- @param mode integer Permission bits when creating (default 0644)
--- @return boolean True on success
--- @return string Error message if failed
local function write(path: string, data: string, mode?: integer): boolean, string
  local ok, err = cosmo.Barf(path, data, {mode = mode})
  if not ok then
    return false, err or ("failed to write file: " .. path)
  end
  return true
end

--- Truncate a file to the given length (default 0).
--- @param path string Path to the file
--- @param length integer New length in bytes (default 0)
--- @return boolean True on success
--- @return string Error message if failed
local function truncate(path: string, length?: integer): boolean, string
  local ok, err = unix.truncate(path, length)
  if not ok then
    return false, errstr(err, "truncate: " .. path)
  end
  return true
end

--- Write data to a file atomically: write to a temporary file in the
--- same directory, fsync it, then rename over the destination. Readers
--- see either the old contents or the complete new contents, never a
--- partial write; on failure the original file is untouched and the
--- temporary file is removed. The write loop retries automatically on
--- EINTR, matching cosmic.fd's signal-safety posture.
--- @param path string Destination path
--- @param data string Data to write
--- @param mode integer Permission bits for the file (default 0644)
--- @return boolean True on success
--- @return string Error message if failed
local function write_atomic(path: string, data: string, mode?: integer): boolean, string
  -- The binding returns (fd, path) on success and (nil, Errno) on failure.
  local fd, tmp = unix.mkstemp(path .. ".XXXXXX")
  if not fd then
    return false, errstr(tmp, "write_atomic: mkstemp: " .. path .. ".XXXXXX")
  end
  -- The Handle owns fd from here; EINTR retries and the short-write
  -- loop live in fd.Handle + stream.write_all, not a local copy.
  local h = cfd.wrap(fd)
  local function fail(err: string): boolean, string
    h:close()
    unix.unlink(tmp)
    return false, err
  end
  local wok, werr = stream.write_all(h, data)
  if not wok then
    return fail("write_atomic: write: " .. tmp .. ": " .. tostring(werr))
  end
  local synced, serr = h:sync()
  if not synced then
    return fail("write_atomic: fsync: " .. tmp .. ": " .. tostring(serr))
  end
  -- mkstemp creates the file 0600; apply the requested bits before the
  -- rename so the destination never appears with the wrong mode.
  local chmodded, cerr = unix.chmod(tmp, mode or tonumber("644", 8))
  if not chmodded then
    return fail(errstr(cerr, "write_atomic: chmod: " .. tmp))
  end
  local closed, clerr = h:close()
  if not closed then
    unix.unlink(tmp)
    return false, "write_atomic: close: " .. tmp .. ": " .. tostring(clerr)
  end
  local renamed, rerr = unix.rename(tmp, path, unix.AT_FDCWD, unix.AT_FDCWD)
  if not renamed then
    unix.unlink(tmp)
    return false, errstr(rerr, "write_atomic: rename: " .. tmp .. " -> " .. path)
  end
  return true
end

local record FsFileModule
  read: function(path: string): string | nil, string
  write: function(path: string, data: string, mode?: integer): boolean, string
  truncate: function(path: string, length?: integer): boolean, string
  write_atomic: function(path: string, data: string, mode?: integer): boolean, string
end

local M: FsFileModule = {
  read = read,
  write = write,
  truncate = truncate,
  write_atomic = write_atomic,
}

return M

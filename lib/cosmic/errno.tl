--- Error information from system calls.
---
--- Failed `cosmo.unix` calls return `nil, err, errno`: a formatted string
--- (`"open: ENOENT: No such file or directory"`) plus the numeric errno.
--- This module provides the canonical formatter (`str`) that most
--- `cosmic.*` wrappers use to add operation context, and helpers for
--- programmatic errno handling (`is`, `code`), so error messages share
--- one shape across the stdlib:
---
---     local ok, err = unix.mkdir(path, mode)
---     if not ok then return false, errno.str(err, "mkdir: " .. path) end
---     -- -> "mkdir: /x: EACCES: Permission denied"
local unix = require("cosmo.unix")

--- Format an error as one canonical string, optionally prefixed with the
--- failing operation or context. Binding error strings already name the
--- failing call (`"mkdir: EACCES: Permission denied"`); when a prefix is
--- supplied, that lowercase `call: ` head is dropped so the operation is
--- not stated twice (`"mkdir: /x: EACCES: Permission denied"`, not
--- `"mkdir: /x: mkdir: EACCES: ..."`). Errno names are uppercase, so
--- they are never mistaken for a call head. Any non-string value falls
--- back to `tostring`; `nil` becomes `"unknown error"`.
---
--- @param err any the error value (a string, or nil)
--- @param prefix? string operation/context to prepend
--- @return string canonical error string
local function str(err: any, prefix?: string): string
  local msg: string
  if err == nil then
    msg = "unknown error"
  else
    msg = tostring(err)
  end
  if prefix and prefix ~= "" then
    local stripped = string.match(msg, "^[%l_][%w_]*: (.+)$")
    if stripped then
      msg = stripped
    end
    return prefix .. ": " .. msg
  end
  return msg
end

--- The numeric errno for a named constant (e.g. `code("ENOENT")`), or nil
--- if the host does not define it. A thin lookup over `unix.E*`.
---
--- @param name string errno constant name
--- @return integer? errno number
local function code(name: string): integer
  return (unix as {string: any})[name] as integer
end

--- True when a failed call's numeric errno (the third return value of a
--- failed `unix.*` call) matches the named constant. Enables programmatic
--- handling without string-matching:
---
---     local n, err, eno = unix.poll(fds, timeout)
---     if errno.is(eno, "EINTR") then retry() end
---
--- @param eno any the numeric errno from a failed call
--- @param name string errno constant name (e.g. "ENOENT")
--- @return boolean
local function is(eno: any, name: string): boolean
  if not (eno is number) then return false end
  local want = code(name)
  if want == nil then return false end
  return eno == want
end

return {
  str = str,
  code = code,
  is = is,
}

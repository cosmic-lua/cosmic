--- Error information from system calls.
---
--- Provides the `Errno` error type plus a canonical formatter (`str`)
--- and helpers for programmatic errno handling (`is`, `code`). Most
--- `cosmic.*` wrappers surface a failed `unix.*` call's error through
--- `str`, so error messages share one shape across the stdlib:
---
---     local ok, err = unix.mkdir(path, mode)
---     if not ok then return false, errno.str(err, "mkdir: " .. path) end
---     -- -> "mkdir: /x: EACCES: Permission denied"
local unix = require("cosmo.unix")

--- A system-call error object, returned in the second slot of a failed
--- `unix.*` call. Structurally matches the generated `unix.Errno`,
--- including its `__tostring` metamethod (which the previous local
--- declaration dropped).
local record Errno
  errno: function(self: Errno): number
  winerr: function(self: Errno): number
  name: function(self: Errno): string
  call: function(self: Errno): string
  doc: function(self: Errno): string
  __tostring: function(self: Errno): string
end

--- Format an error as one canonical string, optionally prefixed with the
--- failing operation or context. A `unix.Errno` renders as
--- `"NAME: description"` (e.g. `"EACCES: Permission denied"`); any other
--- value falls back to `tostring`; `nil` becomes `"unknown error"`. With
--- a prefix the result is `"<prefix>: NAME: description"`.
---
--- @param err any the error value (a `unix.Errno`, a string, or nil)
--- @param prefix? string operation/context to prepend
--- @return string canonical error string
local function str(err: any, prefix?: string): string
  local msg: string
  if err == nil then
    msg = "unknown error"
  else
    local e = err as Errno
    if e.doc then
      msg = e:doc()
      if e.name then
        local n = e:name()
        if n and n ~= "" then
          msg = n .. ": " .. msg
        end
      end
    else
      msg = tostring(err)
    end
  end
  if prefix and prefix ~= "" then
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

--- True when `err` is a `unix.Errno` whose number matches the named errno
--- constant. Enables programmatic handling without string-matching:
--- `if errno.is(err, "EAGAIN") then retry() end`.
---
--- @param err any the error value
--- @param name string errno constant name (e.g. "ENOENT")
--- @return boolean
local function is(err: any, name: string): boolean
  if err == nil then return false end
  local e = err as Errno
  if not e.errno then return false end
  local want = code(name)
  if want == nil then return false end
  return e:errno() == want
end

return {
  Errno = Errno,
  str = str,
  code = code,
  is = is,
}

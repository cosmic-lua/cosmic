--- Error information from system calls.
---
--- Failed `cosmo.unix` calls return `nil, err, errno`: a formatted string
--- (`"open: ENOENT: No such file or directory"`) plus the numeric errno.
--- This module provides the canonical formatter (`format`) that most
--- `cosmic.*` wrappers use to add operation context, and helpers for
--- programmatic errno handling (`is_code`, `code_of`, `name_in`, and
--- the `codes` name -> number table), so error messages share one shape
--- across the stdlib:
---
---     local ok, err = unix.mkdir(path, mode)
---     if not ok then return false, errno.format(err, "mkdir: " .. path) end
---     -- -> "mkdir: /x: EACCES: Permission denied"
---
--- The pre-rename names (`wrap`, `is`, `code`, `name_of`, `constants`)
--- are DEPRECATED aliases carried through the D20 transition: the
--- pinned bootstrap binary type-checks tree modules against its own
--- embedded errno record, so in-tree callers flip to the canonical
--- names only once a release carrying them becomes bin/cosmic.pin;
--- the aliases are deleted in that same cleanup (#981).
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
local function format(err: any, prefix?: string): string
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

--- The numeric errno for a named constant (e.g. `code_of("ENOENT")`), or nil
--- if the host does not define it. A thin lookup over `unix.E*`.
---
--- @param name string errno constant name
--- @return integer | nil errno number, nil when the host does not define it
local function code_of(name: string): integer | nil
  return (unix as {string: any})[name] as integer -- cast: dynamic E* lookup, from any
end

--- True when a failed call's numeric errno (the third return value of a
--- failed `unix.*` call) matches the named constant. Enables programmatic
--- handling without string-matching:
---
---     local n, err, eno = unix.poll(fds, timeout)
---     if errno.is_code(eno, "EINTR") then retry() end
---
--- @param eno any the numeric errno from a failed call
--- @param name string errno constant name (e.g. "ENOENT")
--- @return boolean
local function is_code(eno: any, name: string): boolean
  if not (eno is number) then return false end
  local want = code_of(name)
  if want == nil then return false end
  return eno == want
end

--- The errno constant name embedded in a canonical error string, or nil
--- if the message carries none. Enables programmatic checks on errors
--- whose numeric errno is no longer at hand:
---
---     local data, err = fs.read(path)
---     if errno.name_in(err) == "ENOENT" then ... end
---
--- Matches the first `ENAME:` token — an uppercase word starting with E
--- at a word boundary, so uppercase tails of other words (`"FAILED:"`)
--- are never mistaken for an errno name.
---
--- @param msg string the error string
--- @return string | nil errno constant name (e.g. "ENOENT"), or nil
local function name_in(msg: string): string | nil
  if msg == nil then return nil end
  return string.match(msg, "%f[%w](E[%u%d]+):")
end

-- Every errno name cosmo.unix may define. An explicit list rather than an
-- `E*` scan of the module, which would pick up the termios flags (ECHO,
-- ECHOE, ECHOK, ECHONL). Names the host does not define are skipped.
local ERRNO_NAMES < const >: {string} = {
  "E2BIG", "EACCES", "EADDRINUSE", "EADDRNOTAVAIL", "EAFNOSUPPORT",
  "EAGAIN", "EALREADY", "EBADF", "EBADFD", "EBADMSG", "EBUSY",
  "ECANCELED", "ECHILD", "ECONNABORTED", "ECONNREFUSED", "ECONNRESET",
  "EDEADLK", "EDESTADDRREQ", "EDOM", "EDQUOT", "EEXIST", "EFAULT",
  "EFBIG", "EFTYPE", "EHOSTDOWN", "EHOSTUNREACH", "EHWPOISON", "EIDRM",
  "EILSEQ", "EINPROGRESS", "EINTR", "EINVAL", "EIO", "EISCONN",
  "EISDIR", "ELOOP", "EMEDIUMTYPE", "EMFILE", "EMLINK", "EMSGSIZE",
  "EMULTIHOP", "ENAMETOOLONG", "ENETDOWN", "ENETRESET", "ENETUNREACH",
  "ENFILE", "ENOBUFS", "ENODATA", "ENODEV", "ENOENT", "ENOEXEC",
  "ENOLCK", "ENOLINK", "ENOMEDIUM", "ENOMEM", "ENOMSG", "ENONET",
  "ENOPROTOOPT", "ENOSPC", "ENOSR", "ENOSTR", "ENOSYS", "ENOTBLK",
  "ENOTCONN", "ENOTDIR", "ENOTEMPTY", "ENOTRECOVERABLE", "ENOTSOCK",
  "ENOTSUP", "ENOTTY", "ENXIO", "EOPNOTSUPP", "EOVERFLOW", "EOWNERDEAD",
  "EPERM", "EPFNOSUPPORT", "EPIPE", "EPROTO", "EPROTONOSUPPORT",
  "EPROTOTYPE", "ERANGE", "EREMOTE", "ERESTART", "ERFKILL", "EROFS",
  "ESHUTDOWN", "ESOCKTNOSUPPORT", "ESPIPE", "ESRCH", "ESTALE", "ETIME",
  "ETIMEDOUT", "ETOOMANYREFS", "ETXTBSY", "EUSERS", "EXDEV",
}

--- Errno name -> number for every constant the host defines
--- (`codes.ENOENT`, `codes["EAGAIN"]`, ...). The table form of
--- `code_of`: use it to iterate, to look names up dynamically, or to avoid
--- reaching through `cosmo.unix` for a raw constant.
local codes: {string: integer} = {}
for _, name in ipairs(ERRNO_NAMES) do
  local v = (unix as {string: any})[name] -- cast: dynamic E* lookup
  if v is number then
    codes[name] = v as integer -- cast: number to integer
  end
end

local record ErrnoModule
  format: function(err: any, prefix?: string): string
  code_of: function(name: string): integer | nil
  is_code: function(eno: any, name: string): boolean
  name_in: function(msg: string): string | nil
  codes: {string: integer}

  --- DEPRECATED (D20 transition): pre-rename aliases of the five
  --- canonical names above, deleted at the next pin advance (#981).
  wrap: function(err: any, prefix?: string): string
  code: function(name: string): integer | nil
  is: function(eno: any, name: string): boolean
  name_of: function(msg: string): string | nil
  constants: {string: integer}
end

local M: ErrnoModule = {
  format = format,
  code_of = code_of,
  is_code = is_code,
  name_in = name_in,
  codes = codes,
  wrap = format,
  code = code_of,
  is = is_code,
  name_of = name_in,
  constants = codes,
}

return M

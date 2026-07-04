# errno

 Error information from system calls.

 Provides the `Errno` error type plus a canonical formatter (`str`)
 and helpers for programmatic errno handling (`is`, `code`). Most
 `cosmic.*` wrappers surface a failed `unix.*` call's error through
 `str`, so error messages share one shape across the stdlib:

     local ok, err = unix.mkdir(path, mode)
     if not ok then return false, errno.str(err, "mkdir: " .. path) end
     -- -> "mkdir: /x: EACCES: Permission denied"

## Types

### Errno

 A system-call error object, returned in the second slot of a failed
 `unix.*` call. Structurally matches the generated `unix.Errno`,
 including its `__tostring` metamethod (which the previous local
 declaration dropped).

```teal
local record Errno
  errno: function(self: Errno): number
  winerr: function(self: Errno): number
  name: function(self: Errno): string
  call: function(self: Errno): string
  doc: function(self: Errno): string
  __tostring: function(self: Errno): string
end
```

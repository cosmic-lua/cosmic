--- Error information from system calls.
--- Provides detailed error codes and human-readable descriptions.
local record Errno
  errno: function(self: Errno): number
  winerr: function(self: Errno): number
  name: function(self: Errno): string
  call: function(self: Errno): string
  doc: function(self: Errno): string
end

return {Errno = Errno}

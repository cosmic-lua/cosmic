-- Reporting a failure, as the core provides it.

local record errors
  -- The call stack as text, with `message` at the top when one is
  -- given. `level` says how many frames to skip; 1 is the caller.
  trace: function(message?: string, level?: integer): string
end

return errors

--- Reporting a failure, as the core provides it.

local record errors
  --- The call stack as text, with `message` at the top when one is
  --- given. `level` says how many frames to skip; 1 is the caller.
  trace: function(message?: string, level?: integer): string
  --- The call stack of coroutine `co` as text, from its top -- from the
  --- caller, for the running one -- with `message` at the top when one
  --- is given: for one that raised, where it raised, kept until the
  --- coroutine is closed.
  trace_of: function(co: thread, message?: string): string
end

return errors

--- Saying where a failure happened.
---
--- A failure travels as a value: `T | nil, string` for a value and
--- `boolean, string` for an effect. This is for the place that reports
--- one to a person, where the message alone is not enough.

local errors = require("cosmic.errors")

local record Errors
end

--- The call stack as text, with `message` at the top when one is given.
--- `level` says how many frames to skip; 1, the default, is the caller.
function Errors.trace(message?: string, level?: integer): string
  return errors.trace(message, level or 1)
end

return Errors

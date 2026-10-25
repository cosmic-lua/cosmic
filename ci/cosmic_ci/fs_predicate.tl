local Fs = require("cosmic.fs")

local record Predicate
end

local function checked(answer: boolean?, trouble: string): boolean
  assert(answer ~= nil, trouble)
  return answer
end

function Predicate.exists(path: string): boolean
  return checked(Fs.exists(path))
end

function Predicate.is_dir(path: string): boolean
  return checked(Fs.is_dir(path))
end

--- Whether `path` has no status: nothing is there, or it cannot be looked at.
function Predicate.absent(path: string): boolean
  local status, _ = Fs.stat(path)
  return status == nil
end

return Predicate

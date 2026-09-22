local Fs = require("cosmic.fs")

local record Predicate
end

local function checked(answer: boolean | nil, trouble?: string): boolean
  assert(answer ~= nil, trouble)
  return answer
end

function Predicate.exists(path: string): boolean
  return checked(Fs.exists(path))
end

function Predicate.is_dir(path: string): boolean
  return checked(Fs.is_dir(path))
end

return Predicate

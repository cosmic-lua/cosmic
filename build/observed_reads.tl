--- Observes file opens made while calling a function. The syscall table is
--- restored after both an ordinary return and an error.

local sys = require("cosmic.sys")

local record observed_reads
end

function observed_reads.call(fn: function(any...): (any...)): boolean, any, {string}
  local reads: {string} = {}
  local original = sys.open
  sys.open = function(path: string, flags: integer,
                      mode?: integer): integer | nil, string, integer
    reads[#reads + 1] = path
    return original(path, flags, mode)
  end
  local ok, produced = pcall(fn)
  sys.open = original
  return ok, produced, reads
end

--- Returns both lists in observation order, without changing either input.
function observed_reads.join(first: {string}, second: {string}): {string}
  local joined: {string} = {}
  for _, path in ipairs(first) do
    joined[#joined + 1] = path
  end
  for _, path in ipairs(second) do
    joined[#joined + 1] = path
  end
  return joined
end

return observed_reads

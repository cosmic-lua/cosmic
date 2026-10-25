--- The process's environment.

local sys = require("cosmic.sys")

local record Env
end

--- One variable, or nil when it is not set; this is the os.getenv
--- operation, C's `getenv`.
function Env.get(name: string): string?
  return sys.getenv(name)
end

--- One variable, or the fallback when it is not set.
function Env.get_or(name: string, fallback: string): string
  local value = sys.getenv(name)
  if value == nil then
    return fallback
  end
  return value
end

--- Every variable the process has, in a table of the caller's own: it may be changed (a child's environment is built that
--- way) without changing the process's.
function Env.all(): mut {string:string}
  local copy: mut {string:string} = {}
  for name, value in pairs(sys.environ()) do
    copy[name] = value
  end
  return copy
end

return Env

--- The process's environment.

local sys = require("cosmic.syscalls")

local record Env
end

--- One variable, or nil when it is not set.
function Env.get(name: string): string | nil
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

--- Every variable the process has.
function Env.all(): {string:string}
  return sys.environ()
end

return Env

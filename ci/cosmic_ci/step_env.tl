--- Reads of a workflow step's environment that the steps share.
local record StepEnv
end

--- `env[name]`, which must be set and not empty. A missing one raises: it is
--- the workflow's mistake, not the step's.
function StepEnv.required(env: {string:string}, name: string): string
  local value = env[name]
  assert(value and value ~= "", "missing required environment variable: " .. name)
  return value
end

--- A whole number of `name` in `env`, `default` where it names none, nil
--- and why where it is no whole number.
function StepEnv.whole(env: {string:string}, name: string, default: integer): integer?, string
  local text = env[name]
  if text == nil or text == "" then return default, "" end
  local value = math.tointeger(tonumber(text))
  if value == nil or value < 0 then return nil, name .. " is no whole number: " .. text end
  return value, ""
end

return StepEnv

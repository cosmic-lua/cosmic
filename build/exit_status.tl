--- The exit code a program's return value asks for, as the core decides
--- it for a built program (`cosmic_tostatus`, build/exit_status_test.tl),
--- for the runs that return from Teal rather than through the core: a
--- file run and `-e` (build/dispatch.tl) and `--standalone`
--- (build/standalone.tl).

local log = require("build.verdict").log

local record exit_status
end

--- The exit status `value` asks for, as `cosmic_tostatus` reads it:
--- nil is 0, and a number or numeric text (" 3 ", "0x3", "3.0") whose
--- value is a whole number from 0 to 255 is that number. Anything else
--- -- a boolean, other text, a table, 1.5, -1, 256 -- is nil.
function exit_status.status(value: any): integer | nil
  if value == nil then
    return 0
  end
  local whole: integer | nil = nil
  if value is number or value is string then
    local number = tonumber(value)
    whole = number ~= nil and math.tointeger(number) or nil
  end
  if whole == nil or whole < 0 or whole > 255 then
    return nil
  end
  return whole
end

--- `exit_status.status` of `value`, or, for one that is none, 2 after a
--- complaint on stderr as `what`'s (a file's name, or `-e`).
function exit_status.of(what: string, value: any): integer
  local status = exit_status.status(value)
  if status == nil then
    log:complain(what .. " returned " ..
      (value is string and string.format("%q", value) or tostring(value)) ..
      ", not an exit status 0-255")
    return 2
  end
  return status
end

return exit_status

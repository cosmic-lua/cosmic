--- The exit code a program's return value asks for, as the core decides
--- it for a built program (`cosmic_tostatus`, build/exit_status_test.tl),
--- for the runs that return from Teal rather than through the core: a
--- file run and `-e` (build/dispatch.tl) and `--standalone`
--- (build/standalone.tl).

local Fs = require("cosmic.fs")

--- nil is 0, and a whole number from 0 to 255 is itself. Anything else
--- -- a boolean, text, a table, 1.5, -1, 256 -- is complained about on
--- stderr as `what`'s (a file's name, or `-e`), and exits 2.
local function exit_status(what: string, value: any): integer
  if value == nil then
    return 0
  end
  local whole = value is number and math.tointeger(value) or nil
  if whole == nil or whole < 0 or whole > 255 then
    local _, _ = Fs.put(Fs.stderr, "cosmic: " .. what .. " returned " .. tostring(value) ..
      ", not an exit status 0-255\n")
    return 2
  end
  return whole
end

return exit_status

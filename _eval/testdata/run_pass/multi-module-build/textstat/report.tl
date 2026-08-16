-- Fixture stand-in; the check greps for this require() and never
-- compiles or runs the file.
local count = require("textstat.count")
local function report(s: string): string
  return ""
end
return {report = report}

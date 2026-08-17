-- Fixture stand-in; the check greps for this require() and never
-- compiles or runs the file.
local tokenize = require("textstat.tokenize")
local function count(s: string): {string: integer}
  return {}
end
return {count = count}

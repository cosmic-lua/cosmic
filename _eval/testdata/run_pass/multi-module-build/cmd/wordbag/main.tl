-- Fixture stand-in; the check greps for this require() and never
-- compiles or runs the file.
local report = require("textstat.report")
print(report.report(""))

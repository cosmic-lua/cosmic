-- Fixture stand-in for the agent's CLI wrapper source; the check greps
-- this file for require("slug") and never compiles or runs it.
local slug = require("slug")
print(slug.slugify(arg[1] or ""))

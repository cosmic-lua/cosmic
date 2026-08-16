-- Fixture stand-in; the check greps for this require() and .apply(
-- call and never compiles or runs the file (the built o/bin/copybox
-- stub carries the actual behavior the check exercises).
local sandbox = require("cosmic.sandbox")
sandbox.apply({fs = {rw = {}}})

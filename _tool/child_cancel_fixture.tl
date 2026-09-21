-- End-to-end fixture: its parent signals this driver alone; Child.run must
-- clean up this shell's whole process group before re-delivering the signal.
local Child = require("cosmic.child")

local result, trouble = Child.run({ "/bin/sh", "-c",
  "sleep 30 & printf %s $!; wait" })
if not result then error(trouble) end

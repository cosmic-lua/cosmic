local fs = require("cosmic.fs")
-- The asset ships at its relative path, so it is /zip/<rel> at run time.
local note: string = fs.read("/zip/data/note.txt") or "MISSING"
io.write("asset: " .. note)

local fs = require("cosmic.fs")
-- Payload ships at its path INSIDE embed/, so embed/data/note.txt is
-- /zip/data/note.txt at run time. README.md beside this file does NOT
-- ship: shipping is opt-in, and a repo is full of files that are about
-- the project rather than part of its binary.
local note: string = fs.read("/zip/data/note.txt") or "MISSING"
local readme: string = fs.read("/zip/README.md") and "SHIPPED" or "absent"
io.write("asset: " .. note .. "\nreadme: " .. readme .. "\n")

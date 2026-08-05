#!/usr/bin/env cosmic
--- Generate markdown documentation from a Teal file.
--- Usage: cosmic gendoc.tl <file.tl>

local doc = require("cosmic.doc")

local file_path = arg[1]
if not file_path then
  io.stderr:write("Usage: cosmic gendoc.tl <file.tl>\n")
  os.exit(1)
end

local output, rerr = doc.render_file(file_path)
if output then
  io.write(output)
  os.exit(0)
end
io.stderr:write(tostring(rerr) .. "\n")
os.exit(1)

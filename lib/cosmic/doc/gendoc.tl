#!/usr/bin/env cosmic
--- Generate markdown documentation from a Teal file.
--- Usage: cosmic gendoc.tl <file.tl>

require("tl").loader()

local doc = require("cosmic.doc")

local file_path = arg[1]
if not file_path then
  io.stderr:write("Usage: cosmic gendoc.tl <file.tl>\n")
  os.exit(1)
end

local ok, output = doc.render_file(file_path)
if ok then
  io.write(output)
  os.exit(0)
else
  io.stderr:write(output .. "\n")
  os.exit(1)
end

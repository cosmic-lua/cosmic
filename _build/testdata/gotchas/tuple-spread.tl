local str = require("cosmic.string")

local parts: {string} = {}
local line = "key=value"
table.insert(parts, str.partition(line, "="))

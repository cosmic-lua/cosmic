--- Writes one executable artifact per corrupted manifest core range.

local Fs = require("cosmic.fs")
local fixture = require("test.portable.artifact_fixture")

return function(argv: {string}): integer
  local source, out = argv[1], argv[2]
  local selected = math.tointeger(tonumber(argv[3]))
  assert(source ~= nil and out ~= nil and selected ~= nil,
    "usage: corrupt_runtime_ranges.tl ARTIFACT OUT SELECTED_OFFSET")
  local artifact = assert(fixture.read(source))
  local listing: {string} = {}
  for index, entry in ipairs(artifact.entries) do
    local path = out .. "/corrupt-range-" .. index
    local corrupt = assert(fixture.change_byte(artifact.bytes, entry.offset))
    assert(Fs.write(path, corrupt, 0x1ed))
    local kind = entry.offset == selected and "selected" or "nonselected"
    listing[#listing + 1] = path .. " " .. kind .. "\n"
  end
  assert(Fs.write(out .. "/corrupt-ranges", table.concat(listing)))
  return 0
end

--- Extracts the exact reusable prefix and manifest from a built product.

local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local fixture = require("test.portable.artifact_fixture")

local record Target
  id: integer
  configuration: integer
  name: string
end

local function verify_ranges(path: string, artifact: fixture.Artifact,
                             targets: {Target}, cores: string)
  assert(#artifact.entries == #targets,
    path .. ": manifest entry count differs from generated targets")
  for _, target in ipairs(targets) do
    local entry = assert(fixture.entry(artifact, target.id,
      target.configuration), path .. ": generated target is absent")
    local core_path = cores .. "/" .. target.name .. "/cosmic-core"
    local core = assert(Fs.read(core_path))
    assert(entry.length == #core,
      path .. ": manifest core length differs from raw core")
    assert(entry.digest == Hash.sha256(core),
      path .. ": manifest core digest differs from raw core")
    assert(artifact.bytes:sub(entry.offset + 1,
      entry.offset + entry.length) == core,
      path .. ": manifest core range differs from raw core")
    local first, last = artifact.bytes:find(core, 1, true)
    assert(first == entry.offset + 1 and last == entry.offset + entry.length,
      path .. ": raw core occurs outside its manifest range")
    assert(artifact.bytes:find(core, (first as integer) + 1, true) == nil,
      path .. ": raw core occurs more than once")
  end
end

return function(argv: {string}): integer
  local program, prefix_path, manifest_path, targets_path, cores =
    argv[1], argv[2], argv[3], argv[4], argv[5]
  assert(program ~= nil and prefix_path ~= nil and manifest_path ~= nil and
    targets_path ~= nil and cores ~= nil,
    "usage: product_extract.tl PROGRAM PREFIX MANIFEST TARGETS CORES APPLICATION...")
  local records = assert(Fs.read(targets_path))
  local targets: {Target} = {}
  for line in records:gmatch("[^\n]+") do
    local id, configuration, kind, name =
      line:match("^(%d+)\t(%d+)\t([^\t]+)\t([^\t]+)\t")
    assert(id ~= nil and configuration ~= nil and kind == "release" and
      name ~= nil, "portable product: invalid generated target record")
    targets[#targets + 1] = {
      id = assert(math.tointeger(tonumber(id))),
      configuration = assert(math.tointeger(tonumber(configuration))),
      name = name,
    }
  end
  assert(#targets > 0, "portable product: generated targets are empty")
  local artifact = assert(fixture.read(program))
  verify_ranges(program, artifact, targets, cores)
  local prefix = fixture.prefix(artifact)
  for at = 6, #argv do
    local application = assert(fixture.read(argv[at]))
    assert(fixture.prefix(application) == prefix,
      argv[at] .. ": application prefix differs from Cosmic")
    verify_ranges(argv[at], application, targets, cores)
  end
  assert(Fs.write(prefix_path, prefix, 0x1a4))
  assert(Fs.write(manifest_path,
    artifact.bytes:sub(artifact.manifest_offset + 1,
      artifact.manifest_offset + 4096), 0x1a4))
  return 0
end

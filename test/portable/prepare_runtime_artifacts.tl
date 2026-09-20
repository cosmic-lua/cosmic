--- Derives hashes, prefixes, and deterministic corruptions from runtime files.

local Fs = require("cosmic.fs")
local fixture = require("test.portable.artifact_fixture")

return function(argv: {string}): integer
  local root, targets_path = argv[1], argv[2]
  assert(root ~= nil and targets_path ~= nil,
    "usage: prepare_runtime_artifacts.tl ROOT TARGETS")

  local new_path = root .. "/runtime.new"
  local changed = assert(fixture.read(new_path))
  local padding_at = 16370
  assert(changed.bytes:sub(padding_at + 1, padding_at + 1) == " ",
    "runtime fixture: expected shell comment padding")
  changed.bytes = assert(fixture.change_byte(changed.bytes, padding_at))
  assert(Fs.write(new_path, changed.bytes, 0x1ed))

  for _, name in ipairs({
    "runtime.release", "runtime.old", "runtime.new", "runtime.basis",
    "runtime.missing", "runtime.sanitized",
  }) do
    local artifact = assert(fixture.read(root .. "/" .. name))
    assert(Fs.write(root .. "/" .. name .. ".prefix-sha256",
      fixture.prefix_hash(artifact) .. "\n"))
  end

  local old = assert(fixture.read(root .. "/runtime.old"))
  assert(Fs.write(root .. "/runtime.old.prefix", fixture.prefix(old)))
  assert(Fs.write(root .. "/runtime.old.prefix-length",
    tostring(old.prefix_length) .. "\n"))

  local target_names: {integer:string} = {}
  local records = assert(Fs.read(targets_path))
  for line in records:gmatch("[^\n]+") do
    local id, name = line:match("^(%d+)	%d+	[^	]+	([^	]+)	")
    assert(id ~= nil and name ~= nil, "runtime fixture: invalid target record")
    target_names[assert(math.tointeger(tonumber(id)))] = name
  end
  for _, selected in ipairs(old.entries) do
    if selected.configuration == 1 then
      local other: fixture.Entry | nil = nil
      for _, candidate in ipairs(old.entries) do
        if candidate.target ~= selected.target then other = candidate; break end
      end
      assert(other ~= nil, "runtime fixture: no nonselected core range")
      local offset = other.offset + math.min(128, other.length - 1)
      local corrupt = assert(fixture.change_byte(old.bytes, offset))
      local name = assert(target_names[selected.target],
        "runtime fixture: target name is missing")
      assert(Fs.write(root .. "/runtime.corrupt-" .. name, corrupt, 0x1ed))
    end
  end
  return 0
end

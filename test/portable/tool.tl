--- Portable-fixture helper, one subcommand per fixture step. init.tl
--- ([`test.portable`]) is the shared v1 reader and writer-input library;
--- probe.tl ([`test.portable.probe`]) holds the subcommands that run from an
--- unpacked tree, which this file runs too.
--- Run as:
---   cosmic test/portable/tool.tl SUBCOMMAND ARGS...

local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
local artifact = require("build.artifact")
local fixture = require("test.portable")
local probe = require("test.portable.probe")

local record Target
  id: integer
  configuration: integer
  name: string
end

local function text(value: string): Sqlite.Value
  return { text = value }
end

--- Makes the portable database variants consumed by the runtime fixture.
local function prepare_databases(argv: {string}): integer
  assert(#argv == 4,
    "usage: tool.tl prepare-databases OLD NEW BASIS MISSING")
  local function update(path: string, marker: string)
    local db = assert(Sqlite.open(path, { writable = true }))
    assert(Sqlite.run(db,
      "INSERT OR REPLACE INTO meta (key, value) VALUES (?1, ?2)",
      { text("retained_fixture"), text(marker) }))
    if marker == "basis" then
      assert(Sqlite.run(db,
        "UPDATE meta SET value = ?1 WHERE key = 'runtime_basis'",
        { text(Hash.hex_sha256("portable fixture basis variant")) }))
    elseif marker == "missing" then
      assert(Sqlite.run(db, "DELETE FROM meta WHERE key = 'runtime_basis'"))
    end
    assert(db:close())
  end
  local markers = { "old", "new", "basis", "missing" }
  for index, marker in ipairs(markers) do update(assert(argv[index]), marker) end

  local db = assert(Sqlite.open(assert(argv[1])))
  local rows = assert(Sqlite.text_rows(db, "SELECT key FROM meta"))
  local keys: mut {string:boolean} = {}
  for _, row in ipairs(rows) do keys[row:text(1)] = true end
  local images = assert(Sqlite.text_rows(db,
    "SELECT count(*) FROM sqlite_schema WHERE name = 'images'"))
  assert(db:close())
  for _, forbidden in ipairs({ "host", "host_image", "runtime" }) do
    assert(keys[forbidden] == nil,
      "portable runtime build: per-host metadata survived: " .. forbidden)
  end
  local image_tables = assert(images[1])
  assert(keys["runtime_basis"] == true and image_tables:text(1) == "0",
    "portable runtime build: projection lacks basis or has an images table")
  return 0
end

--- Derives hashes, prefixes, and deterministic corruptions from runtime files.
local function prepare_artifacts(argv: {string}): integer
  local root, targets_path = argv[1], argv[2]
  assert(root ~= nil and targets_path ~= nil,
    "usage: tool.tl prepare-artifacts ROOT TARGETS")

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
    local one = assert(fixture.read(root .. "/" .. name))
    assert(Fs.write(root .. "/" .. name .. ".prefix-sha256",
      fixture.prefix_hash(one) .. "\n"))
  end

  local old = assert(fixture.read(root .. "/runtime.old"))
  assert(Fs.write(root .. "/runtime.old.prefix", fixture.prefix(old)))
  assert(Fs.write(root .. "/runtime.old.prefix-length",
    tostring(old.prefix_length) .. "\n"))

  local target_names: mut {integer:string} = {}
  local records = assert(Fs.read(targets_path))
  for line in records:gmatch("[^\n]+") do
    local id, name = line:match("^(%d+)\t%d+\t[^\t]+\t([^\t]+)\t")
    assert(id ~= nil and name ~= nil, "runtime fixture: invalid target record")
    target_names[assert(math.tointeger(tonumber(id)))] = name
  end
  for _, selected in ipairs(old.entries) do
    if selected.configuration == 1 then
      local other: fixture.Entry? = nil
      for _, candidate in ipairs(old.entries) do
        if candidate.target ~= selected.target then
          other = candidate
          break
        end
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

--- Checks that each manifest entry of `from` holds exactly the raw core
--- built for its target, once, at the range the entry names.
local function verify_ranges(path: string, from: fixture.Artifact,
                             targets: {Target}, cores: string)
  assert(#from.entries == #targets,
    path .. ": manifest entry count differs from generated targets")
  for _, target in ipairs(targets) do
    local found = assert(fixture.entry(from, target.id, target.configuration),
      path .. ": generated target is absent")
    local core_path = cores .. "/" .. target.name .. "/cosmic-core"
    local core = assert(Fs.read(core_path))
    assert(found.length == #core,
      path .. ": manifest core length differs from raw core")
    assert(found.digest == Hash.sha256(core),
      path .. ": manifest core digest differs from raw core")
    assert(from.bytes:sub(found.offset + 1, found.offset + found.length) == core,
      path .. ": manifest core range differs from raw core")
    local first, last = from.bytes:find(core, 1, true)
    assert(first ~= nil and first == found.offset + 1 and
        last == found.offset + found.length,
      path .. ": raw core occurs outside its manifest range")
    assert(from.bytes:find(core, first + 1, true) == nil,
      path .. ": raw core occurs more than once")
  end
end

--- Checks a built product and its applications against the raw cores,
--- then writes the reusable prefix and the manifest of the product.
local function product_extract(argv: {string}): integer
  local program, prefix_path, manifest_path, targets_path, cores =
    argv[1], argv[2], argv[3], argv[4], argv[5]
  assert(program ~= nil and prefix_path ~= nil and manifest_path ~= nil and
      targets_path ~= nil and cores ~= nil,
    "usage: tool.tl product-extract PROGRAM PREFIX MANIFEST TARGETS CORES APPLICATION...")
  local records = assert(Fs.read(targets_path))
  local targets: mut {Target} = {}
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
  local program_artifact = assert(fixture.read(program))
  verify_ranges(program, program_artifact, targets, cores)
  local prefix = fixture.prefix(program_artifact)
  for at = 6, #argv do
    local path = assert(argv[at])
    local application = assert(fixture.read(path))
    assert(fixture.prefix(application) == prefix,
      path .. ": application prefix differs from Cosmic")
    verify_ranges(path, application, targets, cores)
  end
  assert(Fs.write(prefix_path, prefix, 0x1a4))
  assert(Fs.write(manifest_path,
    program_artifact.bytes:sub(program_artifact.manifest_offset + 1,
      program_artifact.manifest_offset + 4096), 0x1a4))
  return 0
end

--- Checks that DATABASE holds the bytes of the database PROGRAM carries
--- ([`build.artifact`]'s `split`): the product's cosmic.db, which the
--- runtime setup writes its artifacts from, is the one its cosmic runs
--- on, so a fixture keyed by those artifacts is keyed by what it runs.
local function product_database(argv: {string}): integer
  local program, database = argv[1], argv[2]
  assert(program ~= nil and database ~= nil,
    "usage: tool.tl product-database PROGRAM DATABASE")
  local parts = assert(artifact.split((assert(Fs.read(program)))))
  assert(parts.database == assert(Fs.read(database)),
    database .. ": not the database " .. program .. " carries")
  return 0
end

--- Writes format fixtures from build.zig's generated target TSV and real
--- raw cores. This is test support, not a product build path.
local function write_format_fixture(argv: {string}): integer
  local records_path, core_root, output = argv[1], argv[2], argv[3]
  assert(records_path ~= nil and core_root ~= nil and output ~= nil,
    "usage: tool.tl write-format-fixture TARGETS CORE_ROOT OUTPUT")
  local targets = fixture.load_by_target(records_path,
    function(target: string): string
      return core_root .. "/" .. target .. "/cosmic-core"
    end)
  local cores, records = targets.blobs, targets.records
  local prefix = assert(artifact.prefix(records, cores))
  local database_a = "SQLite format 3\0fixture database A"
  local database_b = "SQLite format 3\0fixture database B"
  local program_a = assert(artifact.program(prefix, database_a))
  local program_b = assert(artifact.program(prefix, database_b))
  assert(Fs.write(output .. ".prefix", prefix))
  assert(Fs.write(output .. ".a", program_a))
  assert(Fs.write(output .. ".b", program_b))
  for line in records:gmatch("[^\n]+") do
    local id, configuration, target = line:match("^(%d+)\t(%d+)\t[^\t]+\t([^\t]+)\t")
    assert(id ~= nil and configuration ~= nil and target ~= nil)
    local bytes = assert(cores[target])
    local host = assert(artifact.host_program({
      target_id = assert(math.tointeger(tonumber(id))),
      configuration_id = assert(math.tointeger(tonumber(configuration))),
      bytes = bytes,
      digest = Hash.sha256(bytes),
    }, database_a))
    assert(Fs.write(output .. ".host-" .. target, host))
    local subset_prefix = assert(artifact.prefix(line, cores))
    local subset = assert(artifact.program(subset_prefix, database_a))
    assert(Fs.write(output .. ".subset-" .. target, subset))
  end
  return 0
end

--- Builds executable launcher fixtures around small native contract payloads.
--- The test prefix adds synchronization hooks to the production artifact
--- layout.
local function write_launcher_fixture(argv: {string}): integer
  local records_path, payload_root, output = argv[1], argv[2], argv[3]
  assert(records_path ~= nil and payload_root ~= nil and output ~= nil,
    "usage: tool.tl write-launcher-fixture TARGETS PAYLOAD_ROOT OUTPUT")
  local targets = fixture.load_by_target(records_path,
    function(target: string): string
      return payload_root .. "/payload-" .. target
    end)
  local payloads, records = targets.blobs, targets.records
  local release = assert(artifact.prefix(records, payloads))
  local testing = assert(artifact.test_prefix(records, payloads))
  local database = "SQLite format 3\0launcher contract fixture"
  local release_program = assert(artifact.program(release, database))
  local test_program = assert(artifact.program(testing, database))
  assert(Fs.write(output .. ".release", release_program))
  assert(Fs.write(output .. ".test", test_program))
  return 0
end

--- Writes a new-format Cosmic fixture from the generated target records, the
--- real raw cores, and a supplied application database. A trailing "test"
--- argument selects the hook-bearing test prefix instead of the release one.
local function write_runtime_fixture(argv: {string}): integer
  local records_path, cores_root, database_path, output =
    argv[1], argv[2], argv[3], argv[4]
  assert(records_path ~= nil and cores_root ~= nil and
      database_path ~= nil and output ~= nil,
    "usage: tool.tl write-runtime-fixture TARGETS CORES DATABASE OUTPUT [test]")
  local targets = fixture.load_by_target(records_path,
    function(target: string): string
      return cores_root .. "/" .. target .. "/cosmic-core"
    end)
  local cores, records = targets.blobs, targets.records
  local prefix = if argv[5] == "test" then
    assert(artifact.test_prefix(records, cores))
  else
    assert(artifact.prefix(records, cores))
  end
  local database = assert(Fs.read(database_path))
  local program = assert(artifact.program(prefix, database))
  assert(Fs.write(output, program))
  return 0
end

local subcommands: mut {string:function({string}):integer} = {
  ["prepare-databases"] = prepare_databases,
  ["prepare-artifacts"] = prepare_artifacts,
  ["product-database"] = product_database,
  ["product-extract"] = product_extract,
  ["write-format-fixture"] = write_format_fixture,
  ["write-launcher-fixture"] = write_launcher_fixture,
  ["write-runtime-fixture"] = write_runtime_fixture,
}
-- The subcommands the fixtures also run from an unpacked tree ([`test.portable.probe`]).
for name, run in pairs(probe.commands) do
  subcommands[name] = run
end

return function(argv: {string}): integer
  local command = argv[1]
  local handler = if command ~= nil then subcommands[command] else nil end
  if handler == nil then
    local _, _ = Fs.put(Fs.stderr, "usage: tool.tl SUBCOMMAND ARGS...\n")
    local names: mut {string} = {}
    for name in pairs(subcommands) do names[#names + 1] = name end
    table.sort(names)
    local _, _ = Fs.put(Fs.stderr, "subcommands: " .. table.concat(names, ", ") .. "\n")
    return 2
  end
  -- Reindex argv[2:] down to [1:].
  local rest: mut {string} = {}
  for index, word in ipairs(argv) do
    if index > 1 then rest[#rest + 1] = word end
  end
  return handler(rest)
end

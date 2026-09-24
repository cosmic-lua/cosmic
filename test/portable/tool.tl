--- Consolidated portable-fixture helper. Each local function below replaces
--- one former single-purpose script; init.tl (`test.portable`) remains the shared
--- v1 reader/writer-input library. Run as:
---   cosmic test/portable/tool.tl SUBCOMMAND ARGS...

local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Proc = require("cosmic.proc")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local Time = require("cosmic.time")
local artifact = require("build.artifact")
local fixture = require("test.portable")
local sys = require("cosmic.sys")

local record Target
  id: integer
  configuration: integer
  name: string
end

local function text(value: string): Sqlite.Value
  return { text = value }
end

--- Prints one portable manifest entry for shell fixture setup.
local function entry(argv: {string}): integer
  local target = math.tointeger(tonumber(argv[2]))
  local configuration = math.tointeger(tonumber(argv[3]))
  assert(argv[1] ~= nil and target ~= nil and configuration ~= nil,
    "usage: tool.tl entry ARTIFACT TARGET CONFIGURATION")
  local read_artifact = assert(fixture.read(argv[1]))
  local found = assert(fixture.entry(read_artifact, target, configuration),
    "identity fixture: selected manifest entry is missing")
  print(found.offset, found.length, Hash.hex(found.digest))
  return 0
end

--- Proves that a checked portable artifact actually selected its checked core.
local function checked_context(argv: {string}): integer
  local core, target = argv[1], argv[2]
  assert(core ~= nil and target ~= nil,
    "usage: tool.tl checked-context RAW_CHECKED_CORE TARGET")
  local bytes = assert(Fs.read(core))
  assert(Store.meta("runtime_context") == "portable-v1")
  assert(Store.meta("host") == target)
  assert(Store.meta("host_image") == Hash.hex_sha256(bytes),
    "checked artifact did not execute the checked raw core")
  return 0
end

--- Writes one executable artifact per corrupted manifest core range.
local function corrupt_ranges(argv: {string}): integer
  local source, out = argv[1], argv[2]
  local selected = math.tointeger(tonumber(argv[3]))
  assert(source ~= nil and out ~= nil and selected ~= nil,
    "usage: tool.tl corrupt-ranges ARTIFACT OUT SELECTED_OFFSET")
  local read_artifact = assert(fixture.read(source))
  local listing: {string} = {}
  for index, one in ipairs(read_artifact.entries) do
    local path = out .. "/corrupt-range-" .. index
    local corrupt = assert(fixture.change_byte(read_artifact.bytes, one.offset))
    assert(Fs.write(path, corrupt, 0x1ed))
    local kind = one.offset == selected and "selected" or "nonselected"
    listing[#listing + 1] = path .. " " .. kind .. "\n"
  end
  assert(Fs.write(out .. "/corrupt-ranges", table.concat(listing)))
  return 0
end

--- Adds hostile project metadata used to prove portable context wins.
local function spoof_database(argv: {string}): integer
  local path = assert(argv[1], "usage: tool.tl spoof-database DATABASE")
  local db = assert(Sqlite.open(path, true))
  local values: {string:string} = {
    host = "spoofed",
    host_image = "spoofed",
    runtime = string.rep("f", 64),
    runtime_basis = "spoofed",
    artifact = "/spoofed",
    runtime_context = "legacy-spoof",
  }
  for key, value in pairs(values) do
    assert(Sqlite.run(db,
      "INSERT OR REPLACE INTO meta (key, value) VALUES (?1, ?2)",
      { text(key), text(value) }))
  end
  assert(db:close())
  return 0
end

--- Checks that release, changed-basis, and sanitized contexts stay distinct.
local function verify_verdicts(argv: {string}): integer
  local database, counter = argv[1], argv[2]
  assert(database ~= nil and counter ~= nil,
    "usage: tool.tl verify-verdicts DATABASE COUNTER")
  local db = assert(Sqlite.open(database, false))
  local keys = assert(Sqlite.text_rows(db,
    "SELECT key FROM verdicts ORDER BY key"))
  assert(db:close())
  local content = assert(Fs.read(counter))
  local lines: {string} = {}
  local distinct: {string:boolean} = {}
  for line in content:gmatch("([^\n]+)\n?") do
    lines[#lines + 1] = line
    distinct[line] = true
  end
  local distinct_count = 0
  for _ in pairs(distinct) do distinct_count = distinct_count + 1 end
  assert(#keys == 3 and #lines == 3 and distinct_count == 3,
    "identity fixture: expected three distinct runtime verdicts")
  return 0
end

--- Makes the portable database variants consumed by the runtime fixture.
local function prepare_databases(argv: {string}): integer
  assert(#argv == 4,
    "usage: tool.tl prepare-databases OLD NEW BASIS MISSING")
  local function update(path: string, marker: string)
    local db = assert(Sqlite.open(path, true))
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
  for index, marker in ipairs(markers) do update(argv[index], marker) end

  local db = assert(Sqlite.open(argv[1], false))
  local rows = assert(Sqlite.text_rows(db, "SELECT key FROM meta"))
  local keys: {string:boolean} = {}
  for _, row in ipairs(rows) do keys[row[1]] = true end
  local images = assert(Sqlite.text_rows(db,
    "SELECT count(*) FROM sqlite_schema WHERE name = 'images'"))
  assert(db:close())
  for _, forbidden in ipairs({ "host", "host_image", "runtime" }) do
    assert(not keys[forbidden],
      "portable runtime build: per-host metadata survived: " .. forbidden)
  end
  assert(keys["runtime_basis"] and images[1][1] == "0",
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

  local target_names: {integer:string} = {}
  local records = assert(Fs.read(targets_path))
  for line in records:gmatch("[^\n]+") do
    local id, name = line:match("^(%d+)\t%d+\t[^\t]+\t([^\t]+)\t")
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

--- Extracts the exact reusable prefix and manifest from a built product.
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
    assert(first == found.offset + 1 and last == found.offset + found.length,
      path .. ": raw core occurs outside its manifest range")
    assert(from.bytes:find(core, (first as integer) + 1, true) == nil,
      path .. ": raw core occurs more than once")
  end
end

local function product_extract(argv: {string}): integer
  local program, prefix_path, manifest_path, targets_path, cores =
    argv[1], argv[2], argv[3], argv[4], argv[5]
  assert(program ~= nil and prefix_path ~= nil and manifest_path ~= nil and
    targets_path ~= nil and cores ~= nil,
    "usage: tool.tl product-extract PROGRAM PREFIX MANIFEST TARGETS CORES APPLICATION...")
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
  local program_artifact = assert(fixture.read(program))
  verify_ranges(program, program_artifact, targets, cores)
  local prefix = fixture.prefix(program_artifact)
  for at = 6, #argv do
    local application = assert(fixture.read(argv[at]))
    assert(fixture.prefix(application) == prefix,
      argv[at] .. ": application prefix differs from Cosmic")
    verify_ranges(argv[at], application, targets, cores)
  end
  assert(Fs.write(prefix_path, prefix, 0x1a4))
  assert(Fs.write(manifest_path,
    program_artifact.bytes:sub(program_artifact.manifest_offset + 1,
      program_artifact.manifest_offset + 4096), 0x1a4))
  return 0
end

--- Writes transitional format fixtures from build.zig's generated target TSV
--- and real raw cores. This is test support, not a product build path.
local function write_format_fixture(argv: {string}): integer
  local records_path, core_root, output = argv[1], argv[2], argv[3]
  assert(records_path ~= nil and core_root ~= nil and output ~= nil,
    "usage: tool.tl write-format-fixture TARGETS CORE_ROOT OUTPUT")
  local cores, records = fixture.load_by_target(records_path,
    function(target: string): string
      return core_root .. "/" .. target .. "/cosmic-core"
    end)
  local prefix = assert(artifact.prefix(records, cores))
  local database_a = "SQLite format 3\0fixture database A"
  local database_b = "SQLite format 3\0fixture database B"
  local program_a = assert(artifact.program(prefix, database_a))
  local program_b = assert(artifact.program(prefix, database_b))
  assert(Fs.write(output .. ".prefix", prefix))
  assert(Fs.write(output .. ".a", program_a))
  assert(Fs.write(output .. ".b", program_b))
  return 0
end

--- Builds executable launcher fixtures around small native contract payloads.
--- The test prefix adds synchronization hooks to the production artifact
--- layout.
local function write_launcher_fixture(argv: {string}): integer
  local records_path, payload_root, output = argv[1], argv[2], argv[3]
  assert(records_path ~= nil and payload_root ~= nil and output ~= nil,
    "usage: tool.tl write-launcher-fixture TARGETS PAYLOAD_ROOT OUTPUT")
  local payloads, records = fixture.load_by_target(records_path,
    function(target: string): string
      return payload_root .. "/payload-" .. target
    end)
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
  local cores, records = fixture.load_by_target(records_path,
    function(target: string): string
      return cores_root .. "/" .. target .. "/cosmic-core"
    end)
  local prefix = argv[5] == "test" and
    assert(artifact.test_prefix(records, cores)) or
    assert(artifact.prefix(records, cores))
  local database = assert(Fs.read(database_path))
  local program = assert(artifact.program(prefix, database))
  assert(Fs.write(output, program))
  return 0
end

--- Times one portable re-entry without a host `time` command.
local function time_runtime(argv: {string}): integer
  local marker = "COSMIC_FIXTURE_TIMING_STARTED"
  local target, cache = argv[1], argv[2]
  assert(target ~= nil and cache ~= nil and argv[3] == nil,
    "usage: tool.tl time-runtime ARTIFACT CACHE")
  local started = Env.get(marker)
  if started ~= nil then
    assert(assert(Proc.executable()) == target,
      "runtime timing re-entry changed logical executable")
    local before = assert(math.tointeger(tonumber(started)),
      "runtime timing marker is invalid")
    local after = Time.monotonic_ns()
    print(string.format("real %.6f", (after - before) / 1000000000))
    return 0
  end

  local environment = Env.all()
  environment[marker] = tostring(Time.monotonic_ns())
  environment["COSMIC_PORTABLE_CACHE"] = cache
  local arguments = { target, argv[0], "time-runtime", target, cache }
  local _, trouble = Proc.exec(target, arguments, environment)
  error(trouble)
end

--- Proves that VFS reads and the trusted private-prefix capability still work
--- on a retained artifact descriptor, from inside a real Cosmic runtime.
local function retained_prefix_probe(argv: {string}): integer
  local function phase(name: string)
    local _, _ = Fs.put(Fs.stderr, "cosmic portable probe phase: " .. name .. "\n")
  end
  local expected_prefix = assert(argv[1])
  local expected_marker = assert(argv[2])
  -- This checkout has its own build/artifact.tl. The reserved binary module
  -- must win over that project row or it receives no retained-FD capability.
  phase("prefix entering")
  local prefix = assert(artifact.trusted_prefix())
  phase("prefix read")
  assert(Hash.hex(Hash.sha256(prefix)) == expected_prefix)
  phase("prefix hashed")
  assert(Store.meta("retained_fixture") == expected_marker)
  phase("fixture metadata read")
  local executable = assert(Store.meta("artifact"))
  phase("artifact metadata read")
  assert(assert(Proc.executable()) == executable)
  phase("Proc executable read")
  assert(assert(sys.executable()) == executable)
  phase("sys executable read")
  local private = {
    "COSMIC_PORTABLE_ARTIFACT_FD", "COSMIC_PORTABLE_CORE_FD",
    "COSMIC_PORTABLE_TARGET_ID", "COSMIC_PORTABLE_CONFIGURATION_ID",
    "COSMIC_PORTABLE_CORE_OFFSET", "COSMIC_PORTABLE_CORE_LENGTH",
    "COSMIC_PORTABLE_CORE_SHA256",
  }
  for _, name in ipairs(private) do
    assert(sys.getenv(name) == nil, name .. " escaped portable startup")
  end
  phase("private environment checked")
  local _, _ = Fs.put(Fs.stdout, expected_marker .. " " .. expected_prefix .. "\n")
  return 0
end

--- Confirms startup removed every named reserved variable while preserving the
--- public cache setting. The shell fixture supplies adjacent, numerous, and
--- long names to a real portable process.
local function environment_clean(argv: {string}): integer
  assert(Env.get("COSMIC_PORTABLE_CACHE") == argv[1])
  for i = 2, #argv do
    assert(Env.get(argv[i]) == nil, argv[i] .. " escaped startup")
  end
  print("portable environment: clean")
  return 0
end

local subcommands: {string:function({string}):integer} = {
  ["entry"] = entry,
  ["checked-context"] = checked_context,
  ["corrupt-ranges"] = corrupt_ranges,
  ["spoof-database"] = spoof_database,
  ["verify-verdicts"] = verify_verdicts,
  ["prepare-databases"] = prepare_databases,
  ["prepare-artifacts"] = prepare_artifacts,
  ["product-extract"] = product_extract,
  ["write-format-fixture"] = write_format_fixture,
  ["write-launcher-fixture"] = write_launcher_fixture,
  ["write-runtime-fixture"] = write_runtime_fixture,
  ["time-runtime"] = time_runtime,
  ["retained-prefix-probe"] = retained_prefix_probe,
  ["environment-clean"] = environment_clean,
}

return function(argv: {string}): integer
  local command = argv[1]
  local handler = command ~= nil and subcommands[command] or nil
  if handler == nil then
    local _, _ = Fs.put(Fs.stderr, "usage: tool.tl SUBCOMMAND ARGS...\n")
    local names: {string} = {}
    for name in pairs(subcommands) do names[#names + 1] = name end
    table.sort(names)
    local _, _ = Fs.put(Fs.stderr, "subcommands: " .. table.concat(names, ", ") .. "\n")
    return 2
  end
  -- Reindex argv[2:] down to [1:], keeping [0] (this script's own path) for
  -- time-runtime's self re-exec.
  local rest: {string} = { [0] = argv[0] }
  local at = 1
  while argv[at + 1] ~= nil do
    rest[at] = argv[at + 1]
    at = at + 1
  end
  return handler(rest)
end

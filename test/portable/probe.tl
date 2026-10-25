--- The subcommands of test/portable/tool.tl that the fixtures run from an unpacked tree (`Fixture.tool_tree` in
--- ci/cosmic_ci/fixture.tl), under a runtime they start: those that read an artifact, a database or the environment, and
--- write no artifact. The tree holds this file's closure (ci/cosmic_ci/runtime_setup.tl), with ci/testdata/portable/artifact_row.tl
--- as its row of [`build.artifact`]: the runtime carries [`build.artifact`] itself, a project's row of it is compiled whole under
--- the checker's every rule though the runtime's module is the one that loads, and the checkout's holds a hand-off
--- of the raw store that no rule admits. tool.tl runs these too, as subcommands of its own. Run as:
---   cosmic test/portable/probe.tl SUBCOMMAND ARGS...

local Codec = require("cosmic.codec")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Proc = require("cosmic.proc")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local artifact = require("build.artifact")
local fixture = require("test.portable")
local sys = require("cosmic.sys")

local record probe
  --- Each subcommand by its name: what it is given after the name, and the exit status it answers.
  mut commands: {string:function({string}):integer}
end

local function text(value: string): Sqlite.Value
  return { text = value }
end

--- Prints one portable manifest entry for shell fixture setup.
local function entry(argv: {string}): integer
  local target = math.tointeger(tonumber(argv[2]))
  local configuration = math.tointeger(tonumber(argv[3]))
  local source = argv[1]
  assert(source ~= nil and target ~= nil and configuration ~= nil,
    "usage: tool.tl entry ARTIFACT TARGET CONFIGURATION")
  local read_artifact = assert(fixture.read(source))
  local found = assert(fixture.entry(read_artifact, target, configuration),
    "identity fixture: selected manifest entry is missing")
  print(found.offset, found.length, Codec.hex(found.digest))
  return 0
end

--- Writes one executable artifact per corrupted manifest core range.
local function corrupt_ranges(argv: {string}): integer
  local source, out = argv[1], argv[2]
  local selected = math.tointeger(tonumber(argv[3]))
  assert(source ~= nil and out ~= nil and selected ~= nil,
    "usage: tool.tl corrupt-ranges ARTIFACT OUT SELECTED_OFFSET")
  local read_artifact = assert(fixture.read(source))
  local listing: mut {string} = {}
  for index, one in ipairs(read_artifact.entries) do
    local path = out .. "/corrupt-range-" .. tostring(index)
    local corrupt = assert(fixture.change_byte(read_artifact.bytes, one.offset))
    assert(Fs.write(path, corrupt, 0x1ed))
    local kind = if one.offset == selected then "selected" else "nonselected" end
    listing[#listing + 1] = path .. " " .. kind .. "\n"
  end
  assert(Fs.write(out .. "/corrupt-ranges", table.concat(listing)))
  return 0
end

--- Adds hostile project metadata used to prove portable context wins.
local function spoof_database(argv: {string}): integer
  local path = assert(argv[1], "usage: tool.tl spoof-database DATABASE")
  local db = assert(Sqlite.open(path, { writable = true }))
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

--- Checks that release, changed-basis, and sanitized contexts stay
--- distinct: three runtimes in the counter. The runs kept four verdicts:
--- runtime.new's differs from runtime.old's only in its launcher's
--- padding, which the key of a run a portable artifact starts holds
--- (build/declared_key.tl's `launcher_identity`), though its runtime is
--- the release's.
local function verify_verdicts(argv: {string}): integer
  local database, counter = argv[1], argv[2]
  assert(database ~= nil and counter ~= nil,
    "usage: tool.tl verify-verdicts DATABASE COUNTER")
  local db = assert(Sqlite.open(database))
  local keys = assert(Sqlite.text_rows(db,
    "SELECT key FROM verdicts ORDER BY key"))
  assert(db:close())
  local content = assert(Fs.read(counter))
  local lines: mut {string} = {}
  local distinct: mut {string:boolean} = {}
  for line in content:gmatch("([^\n]+)\n?") do
    lines[#lines + 1] = line
    distinct[line] = true
  end
  local distinct_count = 0
  for _ in pairs(distinct) do distinct_count = distinct_count + 1 end
  assert(#keys == 4 and #lines == 4 and distinct_count == 3 and lines[2] == lines[1],
    "identity fixture: expected four verdicts of three distinct runtimes, the second the " ..
      "first's")
  return 0
end

--- Proves that VFS reads and the trusted private-prefix capability still work
--- on a retained artifact descriptor, from inside a real Cosmic runtime.
local function retained_prefix_probe(argv: {string}): integer
  local function phase(name: string)
    local _, _ = Fs.put(Fs.stderr, "cosmic portable probe phase: " .. name .. "\n")
  end
  local expected_prefix = assert(argv[1])
  local expected_marker = assert(argv[2])
  phase("prefix entering")
  -- This checkout has its own build/artifact.tl. The reserved binary module
  -- must win over that project row or it receives no retained-FD capability.
  local prefix = assert(artifact.trusted_prefix())
  phase("prefix read")
  assert(Codec.hex(Hash.sha256(prefix)) == expected_prefix)
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
    local name = assert(argv[i])
    assert(Env.get(name) == nil, name .. " escaped startup")
  end
  print("portable environment: clean")
  return 0
end

probe.commands = {
  ["entry"] = entry,
  ["corrupt-ranges"] = corrupt_ranges,
  ["spoof-database"] = spoof_database,
  ["verify-verdicts"] = verify_verdicts,
  ["retained-prefix-probe"] = retained_prefix_probe,
  ["environment-clean"] = environment_clean,
}

--- Runs the subcommand `argv[1]` names with the words after it.
function probe.main(argv: {string}): integer
  local command = argv[1]
  local handler = if command ~= nil then probe.commands[command] else nil end
  if handler == nil then
    local names: mut {string} = {}
    for name in pairs(probe.commands) do names[#names + 1] = name end
    table.sort(names)
    local _, _ = Fs.put(Fs.stderr, "usage: probe.tl SUBCOMMAND ARGS...\nsubcommands: " .. table.concat(names, ", ") .. "\n")
    return 2
  end
  local rest: mut {string} = {}
  for index, word in ipairs(argv) do
    if index > 1 then rest[#rest + 1] = word end
  end
  return handler(rest)
end

return probe

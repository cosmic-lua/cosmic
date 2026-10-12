--- The halves of a boot ([`build.boot`]): `--stage` does the Teal work
--- without reading a raw core, and `--assemble` writes the tool from the
--- cores and the carried database `--stage` left. `bin/zig build boot`
--- runs them as two steps, the second after every core is linked, so the
--- assembly has to refuse what it cannot build whole and leave the
--- previous tool where it was.

local Fs = require("cosmic.fs")
local artifact = require("build.artifact")
local boot = require("build.boot")
local build_paths = require("build.paths")

local records <const> = table.concat({
  "1\t1\trelease\tx86\tLinux\tx86_64",
  "2\t1\trelease\tarm\tLinux\taarch64",
  "3\t1\trelease\tmac\tDarwin\tarm64",
}, "\n") .. "\n"

local cores <const>: {string:string} = {
  x86 = "ELF-x86\0CosmicM1-in-core",
  arm = "ELF-arm-contents",
  mac = "MACHO-signed-core-contents",
}

local carried <const> = "SQLite format 3\0carried database bytes"

--- A build directory under `tmp` holding every raw core but those in
--- `without`, the carried database unless `no_database`, and a tool a
--- failed assembly must leave alone. Returns the directory and the
--- records file.
local function directory(tmp: string, without?: {string}, no_database?: boolean): string, string
  local layout = build_paths.under(tmp .. "/build")
  for name, image in pairs(cores) do
    local omitted = false
    for _, left in ipairs(without or {}) do
      if left == name then omitted = true end
    end
    if not omitted then
      assert(Fs.mkdirs(layout.cores .. "/" .. name))
      assert(Fs.write(build_paths.core(layout, name), image))
    end
  end
  assert(Fs.mkdirs(layout.bin))
  assert(Fs.write(layout.tool, "previous tool", 0x1ed))
  if not no_database then
    assert(Fs.write(layout.carried, carried))
  end
  assert(Fs.write(tmp .. "/targets.tsv", records))
  return layout.directory, tmp .. "/targets.tsv"
end

local function run(mode: string, records_path: string, build_directory: string,
                   extra?: {string}): integer
  local argv: {integer:string} = { [0] = "cosmic-core", "--boot", "/nonexistent-tree",
    "/nonexistent-tl", mode, "x86", records_path, build_directory }
  for _, argument in ipairs(extra or {}) do
    argv[#argv + 1] = argument
  end
  return boot("/nonexistent-tree", argv, "")
end

local function tool_of(build_directory: string): string
  return (assert(Fs.read(build_paths.under(build_directory).tool)))
end

--- The assembly is the artifact's prefix over the three cores with the
--- carried database after it, exactly what a whole boot publishes.
local function test_assemble_writes_the_prefix_and_the_carried_database(tmp: string)
  local build_directory, records_path = directory(tmp)
  assert(run("--assemble", records_path, build_directory) == 0)
  local prefix = assert(artifact.prefix(records, cores))
  assert(tool_of(build_directory) == assert(artifact.program(prefix, carried)))
end

local function test_assemble_refuses_a_missing_core_and_keeps_the_previous_tool(tmp: string)
  local build_directory, records_path = directory(tmp, { "mac" })
  assert(run("--assemble", records_path, build_directory) == 1)
  assert(tool_of(build_directory) == "previous tool")
end

local function test_assemble_without_the_carried_database_keeps_the_previous_tool(tmp: string)
  local build_directory, records_path = directory(tmp, nil, true)
  assert(run("--assemble", records_path, build_directory) == 1)
  assert(tool_of(build_directory) == "previous tool")
end

local function test_assemble_refuses_a_host_the_records_do_not_name(tmp: string)
  local build_directory, records_path = directory(tmp)
  local argv: {integer:string} = { [0] = "cosmic-core", "--boot", "/nonexistent-tree",
    "/nonexistent-tl", "--assemble", "riscv", records_path, build_directory }
  assert(boot("/nonexistent-tree", argv, "") == 1)
  assert(tool_of(build_directory) == "previous tool")
end

--- A half boot is built for the release cores alone: a checked core's
--- slots would make the tool by a path nothing runs in two steps.
local function test_a_half_boot_takes_no_checked_core(tmp: string)
  local build_directory, records_path = directory(tmp)
  for _, mode in ipairs({ "--stage", "--assemble" }) do
    assert(run(mode, records_path, build_directory, { tmp .. "/checked-core" }) == 1)
  end
  assert(tool_of(build_directory) == "previous tool")
end

--- A stage reads no core: with none built it still gets past the target
--- records to making the build directory's `bin`, its first work. It
--- then goes on to load the tree's build code, which a test has no way to
--- run, so how it ends is not what is checked. An assembly with no core
--- fails before making anything.
local function test_stage_does_not_need_the_cores(tmp: string)
  local layout = build_paths.under(tmp .. "/build")
  assert(Fs.mkdirs(layout.directory))
  assert(Fs.write(tmp .. "/targets.tsv", records))
  local _, _ = pcall(run, "--stage", tmp .. "/targets.tsv", layout.directory)
  assert(Fs.stat(layout.bin) ~= nil, "the stage stopped before its own work")
  assert(Fs.stat(layout.tool) == nil)

  local other = build_paths.under(tmp .. "/other")
  assert(Fs.mkdirs(other.directory))
  assert(run("--assemble", tmp .. "/targets.tsv", other.directory) == 1)
  assert(Fs.stat(other.bin) == nil, "the assembly went on without a core")
end

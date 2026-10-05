local Clock = require("cosmic.clock")
local Predicate = require("cosmic_ci.fs_predicate")
local Hash = require("cosmic.hash")
local Fixture = require("cosmic_ci.fixture")

local Test = require("cosmic.test")

--- Run unsandboxed and sharing nothing (cosmic_ci/orchestration.tl's
--- `fixture`), its worker is given the variables it names: what the
--- driver says where the candidate and its products are
--- (COSMIC_FIXTURE_*) and what the children it starts read
--- ([`Fixture.inherited`], which each of them hands on and no more, and
--- which cosmic_ci/orchestration_test.tl holds this list to).
Test.policy{
  env = {
    "COSMIC_FIXTURE_FORMAT",
    "COSMIC_FIXTURE_ROOT",
    "COSMIC_FIXTURE_TARGET",
    "PATH",
    "HOME",
    "XDG_CACHE_HOME",
    "TMPDIR",
    "COSMIC_PORTABLE_CACHE",
    "COSMIC_VERDICT_CACHE",
    "COSMIC_AUTO_BOOT",
    "COSMIC_TEST_SANDBOX",
    "COSMIC_SANDBOX",
    "COSMIC_TEST_HELD",
    "COSMIC_BOOTSTRAP",
    "COSMIC_ZIG",
    "COSMIC_ZIG_CACHE",
    "COSMIC_ZIG_GLOBAL_CACHE",
    "ZIG_LIB_DIR",
    "ZIG_GLOBAL_CACHE_DIR",
    "ZIG_LOCAL_CACHE_DIR",
    "SDKROOT",
    "DEVELOPER_DIR",
  },
}

local native_build_timeout_ns <const> = Clock.seconds(120)

local function test_decoder_inspection_records_are_exact(tmp: string)
  local digest = string.rep("a", 64)
  local prefix = "prefix 100 manifest 20 4096 database 100 10 entries 1\n"
  local entry = "entry 1 1 10 10 " .. digest .. "\n"
  local valid = tmp .. "/valid"
  Fixture.write(valid, prefix .. entry)
  local parsed = Fixture.inspection(valid)
  assert(parsed.entry_count == 1 and Fixture.entry(parsed, 1, 1),
    "valid inspection did not parse to its one entry")
  for name, contents in pairs({
      suffix = prefix .. entry:sub(1, -2) .. " trailing\n",
      duplicate = prefix .. entry .. entry,
      blank = prefix .. "\n" .. entry,
  }) do
    local path = tmp .. "/" .. name
    Fixture.write(path, contents)
    assert(not pcall(Fixture.inspection, path),
      "malformed decoder inspection was accepted: " .. name)
  end
end

local function test_portable_format_contract(tmp: string)
  local root = Fixture.required("COSMIC_FIXTURE_ROOT")
  local publish = Fixture.required("COSMIC_FIXTURE_FORMAT")
  local publish_target = Fixture.required("COSMIC_FIXTURE_TARGET")
  local cosmic = root .. "/o/bin/cosmic"
  local program = tmp .. "/program"
  local diagnostics = tmp .. "/logs"
  Fixture.run("fixture-write", { cosmic, root .. "/test/portable/tool.tl",
    "write-format-fixture", root .. "/o/targets.tsv", root .. "/o/core",
    program }, root, diagnostics)
  Fixture.run("native-decoder-build", { root .. "/bin/zig", "build",
    "portable-format-native" }, root, diagnostics, nil,
    native_build_timeout_ns)
  local decoder = tmp .. "/format-test"
  Fixture.copy(root .. "/o/portable-fixture/format/format-test-native",
    decoder, 0x1ed)
  Fixture.run("malformed-mutations", { decoder, program .. ".a" }, root,
    diagnostics)
  local inspection = Fixture.run("inspection", { decoder, "--inspect",
    program .. ".a" }, root, diagnostics)
  local decoded = Fixture.inspection(inspection.out)
  local artifact = Fixture.read(program .. ".a")
  local targets = Fixture.targets(root .. "/o/targets.tsv")
  assert(decoded.entry_count == #targets, "format entry count differs")
  for _, target in ipairs(targets) do
    assert(target.kind == "release", "format target is not release")
    local entry = assert(Fixture.entry(decoded, target.id, target.configuration),
      "missing format entry for " .. target.name)
    local core = Fixture.read(root .. "/o/core/" .. target.name .. "/cosmic-core")
    local host_path = program .. ".host-" .. target.name
    local host_inspection = Fixture.run("host-inspection-" .. target.name,
      { decoder, "--inspect-host", host_path }, root, diagnostics)
    local host = Fixture.inspection(host_inspection.out)
    local host_entry = assert(Fixture.entry(host, target.id, target.configuration),
      "host inspection identity differs: " .. target.name)
    local host_bytes = Fixture.read(host_path)
    assert(host.entry_count == 1 and host_entry.offset == 0 and
        host_entry.length == #core and host_bytes:sub(1, #core) == core and
        host_entry.digest == Hash.hex_sha256(core),
      "host inspection does not describe the leading core: " .. target.name)
    local subset_path = program .. ".subset-" .. target.name
    local subset_inspection = Fixture.run("subset-inspection-" .. target.name,
      { decoder, "--inspect", subset_path }, root, diagnostics)
    local subset = Fixture.inspection(subset_inspection.out)
    local subset_entry = assert(Fixture.entry(subset, target.id, target.configuration),
      "subset inspection identity differs: " .. target.name)
    local subset_bytes = Fixture.read(subset_path)
    assert(subset.entry_count == 1 and subset_entry.length == #core and
        subset_bytes:sub(subset_entry.offset + 1, subset_entry.offset + #core) == core and
        subset_entry.digest == Hash.hex_sha256(core),
      "subset inspection does not describe its core: " .. target.name)
    assert(#core == entry.length, "format core length differs: " .. target.name)
    local extracted = artifact:sub(entry.offset + 1,
      entry.offset + entry.length)
    assert(extracted == core and Hash.hex_sha256(extracted) == entry.digest,
      "format core range differs: " .. target.name)
  end
  local prefix = Fixture.read(program .. ".prefix")
  assert(#prefix == decoded.prefix_length, "format prefix length differs")
  assert(artifact:sub(1, decoded.prefix_length) == prefix,
    "written program prefix differs")
  local other = Fixture.read(program .. ".b")
  assert(other:sub(1, decoded.prefix_length) == prefix,
    "fixture program prefixes differ")
  assert(artifact ~= other, "fixture programs unexpectedly match")

  local supported = false
  for _, target in ipairs(Fixture.targets(root .. "/o/targets.tsv")) do
    if target.name == publish_target then supported = true end
  end
  assert(supported, "unsupported target: " .. publish_target)
  local publish_exists = Predicate.exists(publish)
  assert(not publish_exists, "format output already exists: " .. publish)
  Fixture.mkdir(publish)
  Fixture.copy(program .. ".a", publish .. "/program")
  Fixture.copy(root .. "/o/targets.tsv", publish .. "/targets.tsv")
  Fixture.run("target-decoder-build", { root .. "/bin/zig", "build",
    "portable-format-" .. publish_target }, root, diagnostics, nil,
    native_build_timeout_ns)
  Fixture.copy(root .. "/o/portable-fixture/format/format-test-" ..
      publish_target, publish .. "/format-test-" .. publish_target, 0x1ed)
end

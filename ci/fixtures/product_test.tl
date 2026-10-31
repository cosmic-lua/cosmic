local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Fixture = require("cosmic_ci.fixture")
local Test = require("cosmic.test")

-- The product (o/fixtures/product), each file of it the test reads,
-- so every byte it checks is in the verdict's key and no verdict stands
-- for a product it was not reached on (cosmic_ci/orchestration.tl's
-- `sandboxed_fixtures`); and the target's format decoder
-- (o/fixtures/format). A file of another target's is not there, and
-- is keyed as missing. `system`: the applications launch through /bin/sh,
-- and macOS's leg runs /usr/bin/codesign (COSMIC_FIXTURE_CODESIGN).
Test.policy{
  grants = {
    { path = "o/fixtures/product/cosmic", letters = "r" },
    { path = "o/fixtures/product/hashes.sha256", letters = "r" },
    { path = "o/fixtures/product/prefix", letters = "r" },
    { path = "o/fixtures/product/manifest", letters = "r" },
    { path = "o/fixtures/product/apps/hello", letters = "r" },
    { path = "o/fixtures/product/apps/second", letters = "r" },
    { path = "o/fixtures/product/cosmic.db", letters = "r" },
    { path = "o/fixtures/product/targets.tsv", letters = "r" },
    { path = "o/fixtures/product/cores/x86_64-linux-musl/cosmic-core", letters = "r" },
    { path = "o/fixtures/product/cores/aarch64-linux-musl/cosmic-core", letters = "r" },
    { path = "o/fixtures/product/cores/aarch64-macos/cosmic-core", letters = "r" },
    { path = "o/fixtures/product/cores/x86_64-linux-musl/cosmic-unzstd", letters = "r" },
    { path = "o/fixtures/product/cores/aarch64-linux-musl/cosmic-unzstd", letters = "r" },
    { path = "o/fixtures/product/cores/aarch64-macos/cosmic-unzstd", letters = "r" },
    { path = "o/fixtures/format/format-test-x86_64-linux-musl", letters = "r" },
    { path = "o/fixtures/format/format-test-aarch64-linux-musl", letters = "r" },
    { path = "o/fixtures/format/format-test-aarch64-macos", letters = "r" },
  },
  env = { "COSMIC_FIXTURE_TARGET", "COSMIC_FIXTURE_CODESIGN" },
  profiles = { "system" },
}

local function expected_hashes(product: string): {string:string}
  local hashes: mut {string:string} = {}
  for line in Fixture.read(product .. "/hashes.sha256"):gmatch("[^\n]+") do
    local digest, name = line:match("^([0-9a-f]+)  (.+)$")
    assert(digest ~= nil and #digest == 64 and name ~= nil and hashes[name] == nil,
      "invalid product hash record: " .. line)
    hashes[name] = digest
  end
  return hashes
end

local function check_hashes(product: string)
  local hashes = expected_hashes(product)
  local names = { "cosmic", "prefix", "manifest", "apps/hello",
    "apps/second", "cosmic.db", "targets.tsv" }
  for _, target in ipairs(Fixture.targets(product .. "/targets.tsv")) do
    assert(target.kind == "release", "product target is not release")
    names[#names + 1] = "cores/" .. target.name .. "/cosmic-core"
    names[#names + 1] = "cores/" .. target.name .. "/cosmic-unzstd"
  end
  local seen: mut {string:boolean} = {}
  for _, name in ipairs(names) do
    assert(hashes[name] and Fixture.hash(product .. "/" .. name) == hashes[name],
      "transported hash differs: " .. name)
    seen[name] = true
  end
  for name in pairs(hashes) do
    assert(seen[name], "unexpected product hash record: " .. name)
  end
end

-- What a release weighs. The cores are stored compressed (13.3 MB raw, 5.6 MB
-- stored with their stubs), so the prefix every program shares, and the
-- programs, stay under these: a ceiling is lowered when the artifact shrinks
-- and raised never, so an addition meets it in CI and not in a release.
local prefix_ceiling <const> = 6000000
local tool_ceiling <const> = 19000000
local application_ceiling <const> = 9500000

local function test_transported_product(tmp: string)
  local product = Fixture.placed("product")
  local target_name = Fixture.required("COSMIC_FIXTURE_TARGET")
  local decoder = Fixture.placed("format") .. "/format-test-" ..
    target_name
  local codesign = Fixture.required("COSMIC_FIXTURE_CODESIGN") == "true"
  for _, executable in ipairs({ product .. "/cosmic",
      product .. "/apps/hello", product .. "/apps/second", decoder }) do
    Fixture.assert_executable(executable)
  end
  check_hashes(product)
  local diagnostics = tmp .. "/logs"
  local inspection = Fixture.run("inspection", { decoder, "--inspect",
    product .. "/cosmic" }, tmp, diagnostics)
  local decoded = Fixture.inspection(inspection.out)
  local selected: Fixture.Target? = nil
  for _, target in ipairs(Fixture.targets(product .. "/targets.tsv")) do
    if target.name == target_name then
      assert(selected == nil, "duplicate selected product target")
      selected = target
    end
  end
  assert(selected, "selected product target is missing: " .. target_name)
  local entry = assert(Fixture.entry(decoded, selected.id,
    selected.configuration), "selected product entry is missing")
  local artifact = Fixture.read(product .. "/cosmic")
  local core = Fixture.read(product .. "/cores/" .. target_name ..
      "/cosmic-core")
  -- The artifact stores the core as the frame the stub decodes: the
  -- range hashes to the stored digest, and decodes to the build's raw core.
  local stored = artifact:sub(entry.offset + 1, entry.offset + entry.stored_length)
  assert(#stored == entry.stored_length and Hash.hex_sha256(stored) == entry.stored_digest,
    "selected core's stored range differs from its digest")
  assert(entry.codec == 1, "the release stores its core compressed")
  -- TODO: once ci/cosmic-driver.pin names a release with Compress.zstd and Compress.zstd_decoder, call them in-process instead
  -- The pinned release has no decoder to call, so the target's own stub decodes
  -- the stored range, as the launcher runs it: on the artifact, at the range.
  -- A product carried between legs may lose its modes, so the stub runs
  -- from a copy of its bytes made executable here.
  local stub_path = tmp .. "/cosmic-unzstd"
  Fixture.write(stub_path, Fixture.read(product .. "/cores/" .. target_name .. "/cosmic-unzstd"), 493)
  local stub_run = Fixture.call_with_descriptors("decode-core", { stub_path, "3", tostring(entry.offset),
    tostring(entry.stored_length), tostring(entry.length) }, tmp, tmp .. "/logs", Fixture.environment(),
    { [3] = product .. "/cosmic" })
  Fixture.succeeded("decode-core", stub_run)
  local extracted = Fixture.read(stub_run.out)
  assert(#core == entry.length and #extracted == entry.length and extracted == core and
      Hash.hex_sha256(extracted) == entry.digest, "selected core range differs")
  local stub = assert(Fixture.entry(decoded, selected.id, selected.configuration, 2),
    "selected product entry has no decoder stub")
  local built_stub = Fixture.read(product .. "/cores/" .. target_name .. "/cosmic-unzstd")
  assert(stub.codec == 0 and stub.length == #built_stub and stub.stored_length == #built_stub and
      artifact:sub(stub.offset + 1, stub.offset + stub.stored_length) == built_stub and
      stub.stored_digest == Hash.hex_sha256(built_stub), "selected decoder stub range differs")

  assert(decoded.manifest_length == 4096 and
      decoded.manifest_offset % 16384 == 0, "product prefix record differs")
  assert(decoded.prefix_length <= prefix_ceiling, "the prefix is " .. tostring(decoded.prefix_length) ..
      " bytes, over its ceiling of " .. tostring(prefix_ceiling))
  assert(#artifact <= tool_ceiling, "cosmic is " .. tostring(#artifact) ..
      " bytes, over its ceiling of " .. tostring(tool_ceiling))
  for _, application in ipairs({ "hello", "second" }) do
    local size = assert(Fs.stat(product .. "/apps/" .. application)).size
    assert(size <= application_ceiling, application .. " is " .. tostring(size) ..
        " bytes, over its ceiling of " .. tostring(application_ceiling))
  end
  local prefix = Fixture.read(product .. "/prefix")
  assert(#prefix == decoded.prefix_length and
      artifact:sub(1, decoded.prefix_length) == prefix,
    "product prefix differs")
  assert(artifact:sub(decoded.manifest_offset + 1,
    decoded.manifest_offset + decoded.manifest_length) ==
      Fixture.read(product .. "/manifest"),
    "product manifest differs")
  for _, application in ipairs({ "hello", "second" }) do
    assert(Fixture.read(product .. "/apps/" .. application):sub(
      1, decoded.prefix_length) == prefix, application .. " prefix differs")
  end
  if codesign then
    Fixture.run("codesign", { "/usr/bin/codesign", "--verify", "--strict",
      "--verbose=2", product .. "/cores/" .. target_name .. "/cosmic-core" },
      tmp, diagnostics)
    Fixture.run("codesign-stub", { "/usr/bin/codesign", "--verify", "--strict",
      "--verbose=2", product .. "/cores/" .. target_name .. "/cosmic-unzstd" },
      tmp, diagnostics)
  end
  Fixture.mkdir(tmp .. "/run")
  local hello = Fixture.run("hello", { product .. "/apps/hello" },
    tmp .. "/run", diagnostics, { COSMIC_PORTABLE_CACHE = tmp .. "/cache" })
  local second = Fixture.run("second", { product .. "/apps/second" },
    tmp .. "/run", diagnostics, { COSMIC_PORTABLE_CACHE = tmp .. "/cache" })
  Fixture.contains(hello.out, "hello from the portable fixture")
  Fixture.contains(second.out, "second portable application")
  check_hashes(product)
end

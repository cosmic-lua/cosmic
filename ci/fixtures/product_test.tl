local Hash = require("cosmic.hash")
local Fixture = require("cosmic_ci.fixture")

local function expected_hashes(product: string): {string:string}
  local hashes: {string:string} = {}
  for line in Fixture.read(product .. "/hashes.sha256"):gmatch("[^\n]+") do
    local digest, name = line:match("^([0-9a-f]+)  (.+)$")
    assert(digest and #digest == 64 and name and hashes[name] == nil,
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
  end
  local seen: {string:boolean} = {}
  for _, name in ipairs(names) do
    assert(hashes[name] and Fixture.hash(product .. "/" .. name) == hashes[name],
      "transported hash differs: " .. name)
    seen[name] = true
  end
  for name in pairs(hashes) do
    assert(seen[name], "unexpected product hash record: " .. name)
  end
end

local function test_transported_product(tmp: string)
  local product = Fixture.required("COSMIC_FIXTURE_PRODUCT")
  local target_name = Fixture.required("COSMIC_FIXTURE_TARGET")
  local decoder = Fixture.required("COSMIC_FIXTURE_DECODER")
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
  local selected: Fixture.Target | nil = nil
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
  local extracted = artifact:sub(entry.offset + 1, entry.offset + entry.length)
  assert(#core == entry.length and extracted == core and
    Hash.hex_sha256(extracted) == entry.digest, "selected core range differs")

  assert(decoded.manifest_length == 4096 and
    decoded.manifest_offset % 16384 == 0, "product prefix record differs")
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

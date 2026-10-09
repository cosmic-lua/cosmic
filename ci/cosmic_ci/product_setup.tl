local BuildPaths = require("cosmic_ci.build_paths")
local Fs = require("cosmic.fs")
local Predicate = require("cosmic_ci.fs_predicate")
local Fixture = require("cosmic_ci.fixture")

local record ProductSetup
end

function ProductSetup.build(root: string, product: string, tmp: string): string
  local cosmic = BuildPaths.directory(root) .. "/bin/cosmic"
  local targets_path = BuildPaths.directory(root) .. "/targets.tsv"
  local product_exists = Predicate.exists(product)
  assert(not product_exists, "product already exists: " .. product)
  for _, required in ipairs({ cosmic, BuildPaths.directory(root) .. "/carried.db", targets_path }) do
    assert(assert(Fs.stat(required)).kind == "file",
      "boot output is missing: " .. required)
  end
  Fixture.assert_executable(cosmic)

  local project = tmp .. "/project"
  Fixture.mkdir(project .. "/cmd/hello")
  Fixture.mkdir(project .. "/cmd/second")
  Fixture.copy(root .. "/ci/testdata/portable/cmd/hello/main.tl",
    project .. "/cmd/hello/main.tl")
  Fixture.copy(root .. "/ci/testdata/portable/cmd/second/main.tl",
    project .. "/cmd/second/main.tl")
  local diagnostics = tmp .. "/logs"
  local built = Fixture.run("application-build", { cosmic, "build" }, project,
    diagnostics, { COSMIC_PORTABLE_CACHE = tmp .. "/cache" })
  -- The application's build directory, as the tool built from `root`
  -- names it: `root`'s resolver, asked of the project. The build line
  -- names each program it wrote there.
  local built_bin = BuildPaths.directory(project, nil, root) .. "/bin"
  local hello = built_bin .. "/hello"
  local second = built_bin .. "/second"
  Fixture.contains(built.out, "build: PASS (" .. hello .. ", " .. second .. ", ")
  Fixture.assert_executable(hello)
  Fixture.assert_executable(second)
  local hello_run = Fixture.run("hello", { hello }, project, diagnostics,
    { COSMIC_PORTABLE_CACHE = tmp .. "/cache" })
  local second_run = Fixture.run("second", { second }, project, diagnostics,
    { COSMIC_PORTABLE_CACHE = tmp .. "/cache" })
  Fixture.contains(hello_run.out, "hello from the portable fixture")
  Fixture.contains(second_run.out, "second portable application")

  Fixture.mkdir(product .. "/apps")
  Fixture.mkdir(product .. "/cores")
  Fixture.copy(cosmic, product .. "/cosmic", 0x1ed)
  Fixture.copy(hello, product .. "/apps/hello", 0x1ed)
  Fixture.copy(second, product .. "/apps/second", 0x1ed)
  -- The database the tool carries, not the whole projection: that holds
  -- the tree's tests too, and signs them in its meta, so an edit to a
  -- test would move the runtime artifacts written from it
  -- (runtime_setup.tl) and every fixture keyed by one.
  Fixture.copy(BuildPaths.directory(root) .. "/carried.db", product .. "/cosmic.db")
  Fixture.copy(targets_path, product .. "/targets.tsv")
  local targets = Fixture.targets(product .. "/targets.tsv")
  for _, target in ipairs(targets) do
    assert(target.kind == "release", "product target is not release")
    local directory = product .. "/cores/" .. target.name
    Fixture.mkdir(directory)
    Fixture.copy(BuildPaths.directory(root) .. "/core/" .. target.name .. "/cosmic-core",
      directory .. "/cosmic-core")
  end
  Fixture.run("product-extract", { cosmic,
    root .. "/test/portable/tool.tl", "product-extract",
    product .. "/cosmic", product .. "/prefix", product .. "/manifest",
    product .. "/targets.tsv", product .. "/cores",
    product .. "/apps/hello", product .. "/apps/second" }, root, diagnostics)

  Fixture.run("product-database", { cosmic,
    root .. "/test/portable/tool.tl", "product-database",
    product .. "/cosmic", product .. "/cosmic.db" }, root, diagnostics)

  local names = { "cosmic", "prefix", "manifest", "apps/hello",
    "apps/second", "cosmic.db", "targets.tsv" }
  for _, target in ipairs(targets) do
    names[#names + 1] = "cores/" .. target.name .. "/cosmic-core"
  end
  local hashes: {string} = {}
  for _, name in ipairs(names) do
    hashes[#hashes + 1] = Fixture.hash(product .. "/" .. name) ..
      "  " .. name .. "\n"
  end
  Fixture.write(product .. "/hashes.sha256", table.concat(hashes))
  assert(assert(Fs.stat(product .. "/cosmic")).kind == "file",
    "product setup did not produce cosmic")
  return product
end

--- Which of `product`'s files differs from `recorded`, the text of the
--- hashes.sha256 `build` wrote for it. Answers "hashes.sha256" where
--- that file does not hold `recorded`, the name of the first file that
--- differs, or nil where none does. A file differs where it is not a
--- regular file, or its bytes are not the ones recorded, or, for the
--- programs (cosmic and apps/), where it is not executable by everyone.
function ProductSetup.changed(product: string, recorded: string): string | nil
  local now = Fs.read(product .. "/hashes.sha256")
  if now ~= recorded then return "hashes.sha256" end
  for line in recorded:gmatch("[^\n]+") do
    local digest, name = line:match("^([0-9a-f]+)  (.+)$")
    assert(digest and name, "invalid product hash record: " .. line)
    local path = product .. "/" .. name
    local st = Fs.stat(path)
    if not st or st.kind ~= "file" or Fixture.hash(path) ~= digest then
      return name
    end
    local program = name == "cosmic" or name:sub(1, 5) == "apps/"
    if program and st.mode & 0x49 ~= 0x49 then return name end
  end
  return nil
end

return ProductSetup

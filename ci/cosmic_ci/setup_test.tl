local Fixture = require("cosmic_ci.fixture")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local LauncherSetup = require("cosmic_ci.launcher_setup")
local ProductSetup = require("cosmic_ci.product_setup")
local RuntimeSetup = require("cosmic_ci.runtime_setup")
local Test = require("cosmic.test")

-- The setup resolves outputs through the running driver before boot.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

local function fails(action: function(), expected: string)
  local ok, problem = pcall(function(): boolean
    action()
    return true
  end)
  assert(not ok, "setup unexpectedly succeeded")
  assert(tostring(problem):find(expected, 1, true),
    "setup failure did not name " .. expected .. ": " .. tostring(problem))
end

local function test_product_setup_rejects_missing_boot_outputs(tmp: string)
  assert(Fs.mkdirs(tmp .. "/root/build"))
  assert(Fs.write(tmp .. "/root/build/paths.tl", "local Fs = require(\"cosmic.fs\")\nlocal record Paths end\nfunction Paths.main(argv: {integer:string}): integer\n  assert(Fs.put(Fs.stdout, argv[1] .. \"/o\\n\"))\n  return 0\nend\nreturn Paths\n"))
  fails(function()
    ProductSetup.build(tmp .. "/root", tmp .. "/product", tmp .. "/work")
  end, "/o/bin/cosmic")
  assert(Fs.exists(tmp .. "/product") == false, "failed setup created a product")
end

local function test_launcher_setup_rejects_missing_targets(tmp: string)
  assert(Fs.mkdirs(tmp .. "/root/build"))
  assert(Fs.write(tmp .. "/root/build/paths.tl", "local Fs = require(\"cosmic.fs\")\nlocal record Paths end\nfunction Paths.main(argv: {integer:string}): integer\n  assert(Fs.put(Fs.stdout, argv[1] .. \"/o\\n\"))\n  return 0\nend\nreturn Paths\n"))
  fails(function()
    LauncherSetup.build(tmp .. "/root", tmp .. "/launcher", "target",
      tmp .. "/work")
  end, "/o/targets.tsv")
  assert(Fs.exists(tmp .. "/launcher") == false, "failed setup created a launcher")
end

local function test_runtime_setup_rejects_missing_writer(tmp: string)
  assert(Fs.mkdirs(tmp .. "/prebuilt"))
  assert(Fs.write(tmp .. "/database", "database"))
  fails(function()
    RuntimeSetup.build(tmp .. "/root", tmp .. "/prebuilt",
      tmp .. "/missing-writer", tmp .. "/database", tmp .. "/runtime",
      tmp .. "/work")
  end, "missing-writer")
  assert(Fs.exists(tmp .. "/runtime") == false, "failed setup created a runtime")
end

--- The product fixture runs once, before the portable suite and the
--- regressions; after them the driver checks every file of the product
--- against the hashes its setup recorded, and each program's mode, as a
--- second run of the fixture would.
local function test_a_product_file_changed_after_setup_is_named(tmp: string)
  local product = tmp .. "/product"
  assert(Fs.mkdirs(product .. "/apps"))
  assert(Fs.write(product .. "/cosmic", "cosmic", 0x1ed))
  assert(Fs.write(product .. "/apps/hello", "hello", 0x1ed))
  local recorded = Hash.hex_sha256("cosmic") .. "  cosmic\n" ..
    Hash.hex_sha256("hello") .. "  apps/hello\n"
  assert(Fs.write(product .. "/hashes.sha256", recorded))
  assert(ProductSetup.changed(product, recorded) == nil, "an unchanged product changed")
  assert(Fs.chmod(product .. "/cosmic", 0x1a4))
  local changed = ProductSetup.changed(product, recorded)
  assert(changed == "cosmic", "no longer executable: " .. tostring(changed))
  assert(Fs.chmod(product .. "/cosmic", 0x1ed))
  assert(Fs.write(product .. "/apps/hello", "changed", 0x1ed))
  changed = ProductSetup.changed(product, recorded)
  assert(changed == "apps/hello", "changed: " .. tostring(changed))
  assert(Fs.remove(product .. "/apps/hello"))
  changed = ProductSetup.changed(product, recorded)
  assert(changed == "apps/hello", "removed: " .. tostring(changed))
  assert(Fs.write(product .. "/hashes.sha256", "0  cosmic\n"))
  changed = ProductSetup.changed(product, recorded)
  assert(changed == "hashes.sha256", "record: " .. tostring(changed))
end

--- A sandboxed fixture reads what the runtime setup packs for it as one
--- file whose bytes key its verdict (runtime_setup.tl's `pack`): the
--- closure of the module it names, followed through the tree's modules
--- but not the runtime's own, and the same files packed twice make the
--- same bytes, which unpack to what they were.
local function test_the_runtime_setup_packs_a_closure_the_same_each_time(tmp: string)
  local root = tmp .. "/root"
  assert(Fs.mkdirs(root .. "/test/portable") and Fs.mkdirs(root .. "/build") and
      Fs.mkdirs(root .. "/cosmic"))
  assert(Fs.write(root .. "/test/portable/tool.tl",
    'local Fs = require("cosmic.fs")\nlocal fixture = require("test.portable")\n' ..
      'local a = require( "build.a" )\nlocal gone = require("build.gone")\n'))
  assert(Fs.write(root .. "/test/portable/init.tl", 'local a = require("build.a")\n'))
  assert(Fs.write(root .. "/build/a.tl", 'local b = require("build.b")\n', 0x1ed))
  assert(Fs.write(root .. "/build/b.tl", "return {}\n"))
  assert(Fs.write(root .. "/build/b_test.tl", "local _ = 1\n"))
  assert(Fs.write(root .. "/build/c_test.tl", "local _ = 2\n"))
  assert(Fs.write(root .. "/cosmic/fs.tl", "return {}\n"))
  local closure = RuntimeSetup.closure(root, "test/portable/tool.tl")
  assert(table.concat(closure, " ") ==
      "build/a.tl build/b.tl test/portable/init.tl test/portable/tool.tl",
    table.concat(closure, " "))
  local files = RuntimeSetup.files_but_tests(root, "build", "build/c_test.tl")
  assert(table.concat(files, " ") == "build/a.tl build/b.tl build/c_test.tl",
    table.concat(files, " "))
  -- The files' times move between the two packs, as a checkout's do
  -- from one run to the next: the tars must not.
  for _, relative in ipairs(closure) do
    assert(Fs.set_mtime(root .. "/" .. relative, 1000000000))
  end
  RuntimeSetup.pack(root, closure, tmp .. "/one.tar")
  for _, relative in ipairs(closure) do
    assert(Fs.set_mtime(root .. "/" .. relative, 2000000000))
  end
  RuntimeSetup.pack(root, closure, tmp .. "/two.tar")
  local one = assert(Fs.read(tmp .. "/one.tar"))
  assert(one == assert(Fs.read(tmp .. "/two.tar")), "the same files packed differently")
  local out = Fixture.unpack(tmp .. "/one.tar", tmp .. "/out")
  for _, relative in ipairs(closure) do
    assert(Fs.read(out .. "/" .. relative) == Fs.read(root .. "/" .. relative), relative)
  end
  assert(assert(Fs.stat(out .. "/build/a.tl")).mode & 0x1ff == 0x1ed, "a mode was not kept")
end

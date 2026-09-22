local Fs = require("cosmic.fs")
local LauncherSetup = require("cosmic_ci.launcher_setup")
local ProductSetup = require("cosmic_ci.product_setup")
local RuntimeSetup = require("cosmic_ci.runtime_setup")

local function fails(action: function(), expected: string)
  local ok, problem = pcall(function(): boolean action(); return true end)
  assert(not ok, "setup unexpectedly succeeded")
  assert(tostring(problem):find(expected, 1, true),
    "setup failure did not name " .. expected .. ": " .. tostring(problem))
end

local function test_product_setup_rejects_missing_boot_outputs(tmp: string)
  assert(Fs.mkdirs(tmp .. "/root"))
  fails(function()
    ProductSetup.build(tmp .. "/root", tmp .. "/product", tmp .. "/work")
  end, "/o/bin/cosmic")
  assert(Fs.exists(tmp .. "/product") == false, "failed setup created a product")
end

local function test_launcher_setup_rejects_missing_targets(tmp: string)
  assert(Fs.mkdirs(tmp .. "/root/o"))
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

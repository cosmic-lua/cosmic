local check = require("cosmic.check")
local surface = require("_tool.surface")

local function extracted(sources: {string: string}): surface.Surface
  return check.must(surface.extract(sources))
end

local function test_exact_modules_and_entries()
  local found = extracted({
      ["cosmic/zeta.tl"] = [[local record Config
  count: integer
  enum Mode
    "quick"
  end
end]],
      ["cosmic/alpha.tl"] = [[global enum Choice
  "yes"
end
local record Item
  label: string
end]],
    })
  check.equal(found.modules, {"cosmic.alpha", "cosmic.zeta"})
  check.equal(found.entries, {
      ["cosmic.alpha.Choice.yes"] = "enum",
      ["cosmic.alpha.Item.label"] = "string",
      ["cosmic.zeta.Config.Mode.quick"] = "enum",
      ["cosmic.zeta.Config.count"] = "integer",
    })
end

local function test_directory_init_normalization_and_shard_folding()
  local found = extracted({
      ["cosmic/fs/init.tl"] = "local record Root own: boolean end",
      ["cosmic/fs/path.tl"] = "local record Path separator: string end",
      ["cosmic/fs/deep/stat.tl"] = "local enum Kind 'file' 'dir' end",
    })
  check.equal(found.modules, {"cosmic.fs"})
  check.equal(found.entries, {
      ["cosmic.fs.Root.own"] = "boolean",
      ["cosmic.fs.Path.separator"] = "string",
      ["cosmic.fs.Kind.file"] = "enum",
      ["cosmic.fs.Kind.dir"] = "enum",
    })
end

local function test_flat_owner_also_folds_directory_shards()
  local found = extracted({
      ["cosmic/net.tl"] = "local record Client port: integer end",
      ["cosmic/net/http.tl"] = "local record Request path: string end",
    })
  check.equal(found.modules, {"cosmic.net"})
  check.equal(found.entries["cosmic.net.Client.port"], "integer")
  check.equal(found.entries["cosmic.net.Request.path"], "string")
end

local function test_init_directory_is_a_valid_owner()
  local found = extracted({
      ["cosmic/init/init.tl"] = "local record Root own: boolean end",
      ["cosmic/init/part.tl"] = "local record Part value: string end",
      ["cosmic/init.tl"] = "local record Bare ignored: integer end",
    })
  check.equal(found.modules, {"cosmic.init"})
  check.equal(found.entries, {
      ["cosmic.init.Root.own"] = "boolean",
      ["cosmic.init.Part.value"] = "string",
    })
end

local function test_init_directory_root_scan_errors_propagate()
  local found, err = surface.extract({
      ["cosmic/init/init.tl"] = "local record Broken value: string",
      ["cosmic/init/part.tl"] = "local record Part value: string end",
    })
  check.equal(found, nil)
  check.truthy(err:find("cosmic/init/init.tl:", 1, true), err)
end

local function test_every_exclusion()
  local sources: {string: string} = {
    ["cosmic/ok.tl"] = "local record Kept value: string end",
    ["cosmic/init.tl"] = "local record Bare value: string end",
    ["cosmic/_private.tl"] = "local record Hidden value: string end",
    ["cosmic/ok/_private.tl"] = "local record A value: string end",
    ["cosmic/ok/deep/_private/more.tl"] = "local record B value: string end",
    ["cosmic/ok/helper_test.tl"] = "local record C value: string end",
    ["cosmic/ok/helper_example.tl"] = "local record D value: string end",
    ["cosmic/ok/not_teal.lua"] = "local record E value: string end",
    ["other/ok.tl"] = "local record F value: string end",
  }
  local found = extracted(sources)
  check.equal(found.modules, {"cosmic.ok"})
  check.equal(found.entries, {["cosmic.ok.Kept.value"] = "string"})
end

local function test_excluded_roots_do_not_invent_owners()
  local found = extracted({
      ["cosmic/lone_test.tl"] = "local record Root value: string end",
      ["cosmic/lone/part.tl"] = "local record Part value: string end",
      ["cosmic/demo_example.tl"] = "local record Root value: string end",
      ["cosmic/demo/part.tl"] = "local record Part value: string end",
    })
  check.equal(found.modules, {})
  check.equal(found.entries, {})
end

local function test_orphan_shards_do_not_invent_modules()
  local found = extracted({
      ["cosmic/orphan/part.tl"] = "local record Part value: string end",
      ["cosmic/orphan/deep/more.tl"] = "local enum More 'x' end",
    })
  check.equal(found.modules, {})
  check.equal(found.entries, {})
end

local function test_identical_duplicates_are_deduplicated()
  local found = extracted({
      ["cosmic/cache.tl"] = "local record Entry key: string end",
      ["cosmic/cache/entry.tl"] = "local record Entry key: string end",
      ["cosmic/cache/init.tl"] = "local record Entry key: string end",
    })
  check.equal(found.modules, {"cosmic.cache"})
  check.equal(found.entries, {["cosmic.cache.Entry.key"] = "string"})
end

local function test_conflicting_duplicates_name_sorted_locations()
  local found, err = surface.extract({
      ["cosmic/cache/z.tl"] = "local record Entry\n  key: integer\nend",
      ["cosmic/cache.tl"] = "local record Entry\n  key: string\nend",
    })
  check.equal(found, nil)
  check.equal(err, "conflicting surface entry cosmic.cache.Entry.key: " ..
    "cosmic/cache.tl:2:3 and cosmic/cache/z.tl:2:3")
end

local function test_scan_errors_include_the_path()
  local found, err = surface.extract({
      ["cosmic/good.tl"] = "local record Good value: string end",
      ["cosmic/good/broken.tl"] = "local record Broken value: string",
    })
  check.equal(found, nil)
  check.truthy(err:find("cosmic/good/broken.tl:", 1, true), err)
end

local function test_excluded_and_orphan_errors_are_not_scanned()
  local found = extracted({
      ["cosmic/good.tl"] = "local record Good value: string end",
      ["cosmic/good/bad_test.tl"] = "local record Broken value: string",
      ["cosmic/orphan/broken.tl"] = "local record Broken value: string",
    })
  check.equal(found.entries, {["cosmic.good.Good.value"] = "string"})
end

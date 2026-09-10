--- reads: cosmic
local check = require("cosmic.check")
local fs = require("cosmic.fs")
local zip = require("cosmic.zip")
local archive_surface = require("_tool.surface_archive")

local tmpdir = os.getenv("TEST_TMPDIR")

local function zip_path(name: string): string
  return fs.join(tmpdir, name)
end

local function make_zip(name: string,
    entries: {string: string}): string
  local path = zip_path(name)
  local writer = check.must(zip.open(path, {mode = "write"}))
  for entry, contents in pairs(entries) do
    local ok, err = writer:add(entry, contents)
    assert(ok, err)
  end
  local ok, err = writer:close()
  assert(ok, err)
  return path
end

local function is_in_text(text: string, needle: string): boolean
  return text:find(needle, 1, true) ~= nil
end

local function test_collects_embedded_sources_and_ignores_others()
  local path = make_zip("surface-good.zip", {
      [".tl/cosmic/alpha.tl"] =
      "local record Root value: string end",
      [".tl/cosmic/alpha/part.tl"] =
      "local enum Choice 'yes' end",
      [".tl/cosmic/zeta/init.tl"] =
      "local record Item count: integer end",
      [".tl/cosmic/ignored.lua"] =
      "local record Broken value: string",
      ["cosmic/outside.tl"] =
      "local record Broken value: string",
      [".tl/other/wrong.tl"] =
      "local record Broken value: string",
      ["notes.txt"] = "ignored",
    })

  local found, err = archive_surface.surface_of(path)
  assert(found, err)
  check.equal(found.modules, {"cosmic.alpha", "cosmic.zeta"})
  check.equal(found.entries, {
      ["cosmic.alpha.Root.value"] = "string",
      ["cosmic.alpha.Choice.yes"] = "enum",
      ["cosmic.zeta.Item.count"] = "integer",
    })
end

local function test_missing_embedded_sources_names_path_and_selection()
  local path = make_zip("surface-missing.zip", {
      [".tl/cosmic/not-teal.lua"] = "ignored",
      ["cosmic/outside.tl"] = "ignored",
    })

  local found, err = archive_surface.surface_of(path)
  check.equal(found, nil)
  assert(is_in_text(err, path), err)
  assert(is_in_text(err, "select sources failed"), err)
  assert(is_in_text(err, ".tl/cosmic/**.tl"), err)
end

local function test_malformed_archive_names_path_and_open()
  local path = zip_path("surface-malformed.zip")
  local ok, write_err = fs.write(path, "this is not a ZIP")
  assert(ok, write_err)

  local found, err = archive_surface.surface_of(path)
  check.equal(found, nil)
  assert(is_in_text(err, path), err)
  assert(is_in_text(err, "open failed"), err)
end

local function test_extraction_error_is_propagated()
  local path = make_zip("surface-extract-error.zip", {
      [".tl/cosmic/broken.tl"] =
      "local record Broken value: string",
    })

  local found, err = archive_surface.surface_of(path)
  check.equal(found, nil)
  assert(is_in_text(err, path), err)
  assert(is_in_text(err, "extract failed"), err)
  assert(is_in_text(err, "cosmic/broken.tl:"), err)
end

local function test_repository_sources_extract_with_folded_duplicate_types()
  local entries: {string: string} = {}
  local paths, find_err = fs.find("cosmic")
  assert(paths, find_err)
  for _, path in ipairs(paths) do
    if path:sub(-3) == ".tl" then
      entries[".tl/" .. path] = check.must(fs.read(path))
    end
  end
  local archive = make_zip("surface-repository.zip", entries)
  local found, err = archive_surface.surface_of(archive)
  assert(found, err)
  check.equal(found.entries["cosmic.sqlite.Db.exec"],
    '@types ["function ( self : Db , sql : string , params ? : any ) : boolean , string",' ..
    '"function ( self : Db , sql : string , params ? : bind_mod . Params ) : boolean , string"]')
  check.equal(found.entries["cosmic.quicksand.CapsModule.capabilities"],
    "function ( ) : types . Capabilities")
  check.equal(found.entries["cosmic.sandbox.Options.best_effort"], "boolean")
end

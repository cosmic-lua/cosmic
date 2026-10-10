--- [`build.teal`]'s use of [`cosmic.removed`], apart from
--- build/teal_test.tl so that only these are keyed by the catalog: the
--- globals the checker is stripped of are the catalog's own, and a
--- refusal quotes what it says to write instead.
local Removed = require("cosmic.removed")
local Sqlite = require("cosmic.sqlite")
local teal = require("build.teal")

--- build.teal spells the globals it strips (`withheld`) rather than
--- reading them from the catalog, so that the compiler's identity holds
--- them without the rest of it: they must be the very names the runtime
--- removes, in the same order.
local function test_the_withheld_globals_are_the_catalog_s_order()
  assert(#teal.withheld == #Removed.order,
    table.concat(teal.withheld, " ") .. " against " .. table.concat(Removed.order, " "))
  for i, name in ipairs(Removed.order) do
    assert(teal.withheld[i] == name, i .. ": " .. tostring(teal.withheld[i]) ..
        " against the catalog's " .. name)
  end
end

--- The same for the fields of `package`, which the runtime removes.
local function test_the_withheld_package_fields_are_the_catalog_s_order()
  assert(table.concat(teal.withheld_package, " ") == table.concat(Removed.package_fields, " "))
end

--- The checker's environment lacks each of them, as a global and as a
--- module.
local function test_the_checker_is_stripped_of_each_withheld_global()
  local built = assert(teal.load())
  local db = assert(Sqlite.memory())
  local env = assert(teal.environment_for(built, db, "/nonexistent"))
  for _, name in ipairs(Removed.order) do
    assert(env.globals[name] == nil, name .. " is still a global")
    assert(env.modules[name] == nil, name .. " is still a module")
  end
end

--- A test whose closure holds the catalog is told what it says: the
--- field's replacement for a removed global, and a removed member's.
local function test_a_refusal_quotes_the_catalog()
  assert(teal.replacement("unknown variable: os", "return os.getenv('HOME')\n", 1, 8) ==
      Removed.message("os", "getenv"))
  local source = 'local Hash = require("cosmic.hash")\nreturn Hash.hex\n'
  assert(teal.replacement("invalid key 'hex' in record 'Hash' of type Hash", source, 2, 13) ==
      "Hash.hex was removed: " .. Removed.members["cosmic.hash.hex"])
  -- A removed member's answer comes before the record's fields.
  assert(teal.replacement("invalid key 'hex' in record 'Hash' of type Hash", source, 2, 13,
    { "hmac", "sha256" }) == "Hash.hex was removed: " .. Removed.members["cosmic.hash.hex"])
  local cache = 'local Fs = require("cosmic.fs")\nreturn Fs.cache_path("zig")\n'
  assert(teal.replacement("invalid key 'cache_path' in record 'Fs' of type Fs", cache, 2, 11) ==
      "Fs.cache_path was removed: " .. Removed.members["cosmic.fs.cache_path"])
end

--- `package.path` and its three siblings type-check in tl's own
--- declarations; cosmic's checker refuses them as a missing key, and the
--- refusal quotes the catalog. The rest of `package` is untouched.
local function test_the_checker_refuses_the_removed_package_fields()
  local built = assert(teal.load())
  local db = assert(Sqlite.memory())
  for _, field in ipairs(Removed.package_fields) do
    local source = "local x = package." .. field .. "\nprint(x)\n"
    -- A checked environment keeps the errors it found.
    local fresh = assert(teal.environment_for(built, db, "/nonexistent"))
    local result = built.check_string(source, fresh, "removed_package", "tl")
    local found: string | nil = nil
    for _, e in ipairs(result.type_errors) do
      if e.msg:find("invalid key '" .. field .. "' in record 'package'", 1, true) then
        found = e.msg
      end
    end
    local seen: {string} = {}
    for _, e in ipairs(result.type_errors) do seen[#seen + 1] = e.msg end
    assert(found ~= nil, field .. " was not refused: " .. table.concat(seen, "; "))
    assert(teal.replacement(found, source, 1, 11) == Removed.message("package", field), found)
  end
  local kept_env = assert(teal.environment_for(built, db, "/nonexistent"))
  local kept = built.check_string(
    "print(package.loaded, package.preload, package.searchers, package.config)\n",
    kept_env, "kept_package", "tl")
  assert(#kept.type_errors == 0 and #kept.syntax_errors == 0)
end

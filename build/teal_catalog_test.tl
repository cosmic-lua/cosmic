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

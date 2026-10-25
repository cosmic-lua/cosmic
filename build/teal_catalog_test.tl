--- [`build.teal`]'s use of [`cosmic.removed`], apart from
--- build/teal_test.tl so that only these are keyed by the catalog: the
--- globals the checker is stripped of are the catalog's own, and a
--- refusal quotes what it says to write instead.
local Removed = require("cosmic.removed")
local Sqlite = require("cosmic.sqlite")
local teal = require("build.teal")
local type compiler = require("build.compiler")

--- The checker's refusal of `key` through the variable `variable`, a record
--- of the type shown `subject`, at `y`:`x`.
local function refused_key(key: string, variable: string, subject: string, y: integer,
                           x: integer, fields?: {string}): compiler.Error
  return { code = "invalid_key", key = key, variable = variable, subject = subject,
    subject_kind = "nominal", resolved_kind = "record", fields = fields, msg = "",
    filename = "", y = y, x = x }
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
  assert(teal.replacement({ code = "unknown_variable", variable = "os", msg = "", filename = "", y = 1, x = 8 },
    "return os.getenv('HOME')\n") ==
      Removed.message("os", "getenv"))
  local source = 'local Hash = require("cosmic.hash")\nreturn Hash.hex\n'
  assert(teal.replacement(refused_key("hex", "Hash", "Hash", 2, 13), source) ==
      "Hash.hex was removed: " .. Removed.members["cosmic.hash.hex"])
  -- A removed member's answer comes before the record's fields.
  assert(teal.replacement(refused_key("hex", "Hash", "Hash", 2, 13, { "hmac", "sha256" }), source) ==
      "Hash.hex was removed: " .. Removed.members["cosmic.hash.hex"])
  local cache = 'local Fs = require("cosmic.fs")\nreturn Fs.cache_path("zig")\n'
  assert(teal.replacement(refused_key("cache_path", "Fs", "Fs", 2, 11), cache) ==
      "Fs.cache_path was removed: " .. Removed.members["cosmic.fs.cache_path"])
end

--- A removed member is quoted for a module bound by a `require` written
--- over two lines or without parentheses, as for one on a line, and for
--- one in parentheses or on the left of an `or`, whose record the
--- checker still names the local after.
local function test_a_refusal_quotes_the_catalog_however_the_require_is_written()
  for _, source in ipairs({
      'local Hash =\n  require("cosmic.hash")\nreturn Hash.hex\n',
      'local Hash <const> = require "cosmic.hash"\nreturn Hash.hex\n',
      "local Hash = require'cosmic.hash'\nreturn Hash.hex\n",
      'local Hash = require("cosmic.hash") or {}\nreturn Hash.hex\n',
      'local Hash = (require("cosmic.hash"))\nreturn Hash.hex\n',
  }) do
    assert(teal.replacement(refused_key("hex", "Hash", "Hash", 2, 13), source) ==
        "Hash.hex was removed: " .. Removed.members["cosmic.hash.hex"], source)
  end
  -- A field of the module is another value, which the module binds to no name.
  assert(teal.replacement(refused_key("hex", "Hash", "Hash", 2, 13),
    'local Hash = require("cosmic.hash").sha256\nreturn Hash.hex\n') == nil)
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
    local found: compiler.Error? = nil
    for _, e in ipairs(result.type_errors) do
      if e.code == "invalid_key" and e.key == field and e.variable == "package" then
        found = e
      end
    end
    local seen: mut {string} = {}
    for _, e in ipairs(result.type_errors) do seen[#seen + 1] = e.msg end
    assert(found ~= nil, field .. " was not refused: " .. table.concat(seen, "; "))
    assert(teal.replacement(found, source) == Removed.message("package", field), found.msg)
  end
  local kept_env = assert(teal.environment_for(built, db, "/nonexistent"))
  local kept = built.check_string(
    "print(package.loaded, package.preload, package.searchers, package.config)\n",
    kept_env, "kept_package", "tl")
  assert(#kept.type_errors == 0 and #kept.syntax_errors == 0)
end

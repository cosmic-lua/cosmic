--- The boot bridge's compiles kept in the cache every checkout shares
--- (core/bridge.lua): when a boot takes them from it and when it must
--- not. Each case boots a tree of stand-in modules with a bare core
--- (as core/boot_test.tl does) and a compiler that records each compile
--- it makes, so a boot's compiles are counted and the status
--- [`build.boot`] ends with says which module sources it ran.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local artifact = require("build.artifact")
local cache_formats = require("build.cache_formats")

Test.policy{ grants = { { path = "core/bridge.lua", letters = "r" } } }

--- A compiler that passes its source through, writing a file to the
--- directory `COUNT_DIR` names for each compile it makes: `compiler-N`
--- for a compile of itself (its source holds `search_module`) and
--- `module-N` for any other.
local compiler <const> = [[
local dir = os.getenv("COUNT_DIR")
local made = 0
return {
  search_module = function() return nil end,
  new_env = function() return {} end,
  gen = function(source)
    made = made + 1
    local kind = source:find("search_module", 1, true) and "compiler" or "module"
    io.open(dir .. "/" .. kind .. "-" .. made, "w"):close()
    local edit = os.getenv("EDIT_A")
    if kind == "module" and made == 1 and edit then
      local file = io.open(edit, "w")
      file:write("return { n = 2 }\n")
      file:close()
    end
    return source, {}
  end,
}
]]

--- Declarations that `DECL` decides, so a boot can derive others from
--- the same files.
local gen_syscalls <const> = [[
local sys = require("cosmic.sys")
return {
  targets = { { path = "cosmic.sys", target = { header = "core/syscalls.h" } } },
  declaration = function() return "return " .. (sys.getenv("DECL") or "1") end,
}
]]

--- Ends with the sum of the modules' numbers, so the status says which
--- sources the boot ran.
local boot_source <const> = [[
local a = require("build.a")
local b = require("build.b")
return function() return a.n + b.n end
]]

local bridge_source = assert(Fs.read("core/bridge.lua"))

local record Fixture
  core: string
  tmp: string
  tree: string
  tl: string
  cache: string
  runs: integer
end

local function put(path: string, text: string)
  assert(Fs.mkdirs(Fs.dirname(path)))
  assert(Fs.write(path, text))
end

--- A tree under `tmp`/`name` to boot, and a private directory for its
--- cache file. The bare core is copied once into `tmp` for every tree
--- of the test: a worker's directory holds only so much.
local function fixture(tmp: string, name: string): Fixture
  local base = tmp .. "/" .. name
  local core = tmp .. "/cosmic-core"
  if Fs.stat(core) == nil then
    put(core, assert(artifact.trusted_core()).bytes)
    assert(Fs.chmod(core, 0x1ed))
  end
  local f: Fixture = { core = core, tmp = base, tree = base .. "/tree", tl = base .. "/tl",
    cache = base .. "/cache/cache.db", runs = 0 }
  put(f.tree .. "/core/bridge.lua", bridge_source)
  put(f.tree .. "/core/syscalls.h", "/* stand-in */\n")
  put(f.tree .. "/build/gen_syscalls.tl", gen_syscalls)
  put(f.tree .. "/build/boot.tl", boot_source)
  put(f.tree .. "/build/a.tl", "return { n = 1 }\n")
  put(f.tree .. "/build/b/init.tl", "return { n = 20 }\n")
  put(f.tree .. "/build/note.md", "not a source\n")
  put(f.tl .. "/tl.lua", compiler)
  put(f.tl .. "/tl.tl", compiler)
  assert(Fs.mkdirs(Fs.dirname(f.cache)))
  assert(Fs.chmod(Fs.dirname(f.cache), 0x1c0))
  return f
end

local record Boot
  status: integer
  compiler: integer
  modules: integer
end

--- Boots `f`'s tree once, with `variables` beside the environment that
--- names its cache, and answers its exit status and how many compiles it
--- made of the compiler and of modules.
local function boot(f: Fixture, variables?: {string:string}): Boot
  f.runs = f.runs + 1
  local counts = f.tmp .. "/counts-" .. f.runs
  assert(Fs.mkdirs(counts))
  local env: {string:string} = {}
  for name, value in pairs(Env.all()) do env[name] = value end
  env.COSMIC_BUILD_CACHE = f.cache
  env.COUNT_DIR = counts
  env.TL_PATH = nil
  for name, value in pairs(variables or {}) do env[name] = value end
  local r = assert(Child.run({ f.core, "--boot", f.tree, f.tl, "go" },
    { stdout = "capture", stderr = "capture", env = env, timeout_ns = Clock.seconds(30) }))
  assert(r.code ~= nil and r.code >= 20, "exit " .. tostring(r.code) .. ": " .. tostring(r.stderr))
  local out: Boot = { status = r.code, compiler = 0, modules = 0 }
  for _, name in ipairs((assert(Fs.list(counts)))) do
    if name:find("^compiler%-") then
      out.compiler = out.compiler + 1
    else
      out.modules = out.modules + 1
    end
  end
  return out
end

local function rows(f: Fixture, where?: string): integer
  local db = assert(Sqlite.open(f.cache))
  local found = assert(Sqlite.text_rows(db, "SELECT count(*) FROM bridge_v1 " .. (where or "")))
  assert(db:close())
  return math.tointeger(tonumber(found[1][1])) as integer
end

local function sql(f: Fixture, statement: string)
  local db = assert(Sqlite.open(f.cache, { writable = true }))
  assert(db:exec(statement))
  assert(db:close())
end

--- Everything the stand-in tree loads: the generator of declarations,
--- two modules and [`build.boot`].
local loaded <const> = 4

--- A boot that finds the compiles of an earlier boot of the same tree
--- compiles nothing, in the compiler or in the modules, and runs the same
--- code.
local function test_a_second_boot_takes_every_compile_from_the_cache(tmp: string)
  local f = fixture(tmp, "hit")
  local first = boot(f)
  assert(first.status == 21 and first.compiler == 1 and first.modules == loaded,
    "the first boot made " .. first.compiler .. " and " .. first.modules)
  assert(rows(f) == 2, "the first boot kept " .. rows(f) .. " rows")
  local again = boot(f)
  assert(again.status == 21, "the second boot ran other code")
  assert(again.compiler == 0, "the compiler was compiled again")
  assert(again.modules == 0, "modules were compiled again: " .. again.modules)
end

--- A row whose digest fails is a miss, and the compile that follows
--- replaces it. A row that decodes to something else, with the digest of
--- what it held, is the same.
local function test_a_row_whose_digest_fails_is_a_miss(tmp: string)
  local f = fixture(tmp, "digest")
  boot(f)
  assert(rows(f) == 2, "the first boot kept nothing")
  sql(f, "UPDATE bridge_v1 SET digest = 'bad' WHERE kind = 'modules'")
  assert(boot(f).modules == loaded, "a module row with a bad digest was used")
  assert(boot(f).modules == 0, "the bad row was not replaced")
  sql(f, "UPDATE bridge_v1 SET payload = deflate('tampered') WHERE kind = 'compiler'")
  assert(boot(f).compiler == 1, "a compiler row that was tampered with was used")
  assert(boot(f).compiler == 0, "the tampered row was not replaced")
  sql(f, "UPDATE bridge_v1 SET payload = x'00ff' WHERE kind = 'modules'")
  assert(boot(f).modules == loaded, "a row that does not inflate was used")
  assert(rows(f) == 2)
end

--- Whatever a compile can read moves the key: a module's source, a
--- module added where the searcher or the checker would find it, a header
--- the declarations are made from, the compiler and the bridge itself.
--- A file nothing reads does not.
local function test_any_input_that_changes_is_a_miss(tmp: string)
  local changes: {{string, boolean, function(Fixture)}} = {
    { "a module's source", false, function(f: Fixture)
      put(f.tree .. "/build/a.tl", "return { n = 2 }\n")
    end },
    { "a module of a directory", false, function(f: Fixture)
      put(f.tree .. "/build/b/init.tl", "return { n = 30 }\n")
    end },
    { "a module added", false, function(f: Fixture)
      put(f.tree .. "/build/c.tl", "return 3\n")
    end },
    { "a declaration file added", false, function(f: Fixture)
      put(f.tree .. "/build/a.d.tl", "return 4\n")
    end },
    { "a header", false, function(f: Fixture)
      put(f.tree .. "/core/syscalls.h", "/* edited */\n")
    end },
    { "the compiler's source", true, function(f: Fixture)
      put(f.tl .. "/tl.tl", compiler .. "-- edited\n")
    end },
    { "the vendored compiler", true, function(f: Fixture)
      put(f.tl .. "/tl.lua", compiler .. "-- edited\n")
    end },
    { "the bridge", true, function(f: Fixture)
      put(f.tree .. "/core/bridge.lua", bridge_source .. "\n-- edited\n")
    end },
  }
  for index, change in ipairs(changes) do
    local f = fixture(tmp, "stale-" .. index)
    boot(f)
    local control = boot(f)
    assert(control.modules == 0 and control.compiler == 0, change[1] .. ": the control boot missed")
    change[3](f)
    local after = boot(f)
    assert(after.modules == loaded, change[1] .. ": a module was taken from a stale row")
    assert((after.compiler == 1) == change[2], change[1] .. ": the compiler's row " ..
        (change[2] and "stood" or "missed"))
  end
  local f = fixture(tmp, "unrelated")
  boot(f)
  put(f.tree .. "/build/note.md", "also not a source\n")
  assert(boot(f).modules == 0, "a file no compile reads moved the key")
end

--- A file edited after the key is made but before the bridge reads it is
--- not kept under that key: the row would hold code of the edited file
--- for the tree before it, and undoing the edit would take it as a hit.
--- (The stand-in compiler edits `build/a.tl` as it compiles the first
--- module, which is after the bridge took the manifest.)
local function test_a_file_edited_while_the_bridge_runs_is_not_kept(tmp: string)
  local f = fixture(tmp, "race")
  local a = f.tree .. "/build/a.tl"
  local edited = boot(f, { EDIT_A = a })
  assert(edited.status == 22, "the stand-in compiler did not edit the module: " .. edited.status)
  assert(rows(f, "WHERE kind = 'modules'") == 0, "a row was kept for a tree that changed under it")
  put(a, "return { n = 1 }\n")
  local restored = boot(f)
  assert(restored.status == 21 and restored.modules == loaded,
    "the restored tree took the edited code from the cache")
  assert(boot(f).modules == 0, "the restored tree's own row was not kept")
end

--- A module the bridge compiled with other declarations than it is
--- given now is not taken from the row, though no file differs; the
--- modules loaded before any declaration exist (the generator's own) are.
local function test_changed_declarations_are_a_miss(tmp: string)
  local f = fixture(tmp, "declared")
  boot(f, { DECL = "{ x = 1 }" })
  assert(boot(f, { DECL = "{ x = 1 }" }).modules == 0, "the control boot missed")
  local other = boot(f, { DECL = "{ x = 2 }" })
  assert(other.modules == loaded - 1, "modules compiled against other declarations were taken: " ..
      other.modules)
  assert(boot(f, { DECL = "{ x = 2 }" }).modules == 0, "the row was not made again")
end

--- `COSMIC_BUILD_CACHE=0`, a name that is not absolute and `TL_PATH` each
--- turn the cache off: nothing is read or kept.
local function test_the_cache_can_be_turned_off(tmp: string)
  local control = fixture(tmp, "control")
  boot(control)
  assert(rows(control) == 2, "the control kept nothing")
  local cases: {{string, {string:string}}} = {
    { "0", { COSMIC_BUILD_CACHE = "0" } },
    { "a relative name", { COSMIC_BUILD_CACHE = "cache.db" } },
    { "TL_PATH", { TL_PATH = "/nowhere/?.lua" } },
    { "an empty TL_PATH", { TL_PATH = "" } },
  }
  for index, case in ipairs(cases) do
    local f = fixture(tmp, "off-" .. index)
    assert(boot(f, case[2]).modules == loaded)
    assert(boot(f, case[2]).modules == loaded, case[1] .. " did not turn the cache off")
    if index ~= 3 then assert(Fs.stat(f.cache) == nil, case[1] .. " made the file") end
  end
  local f = fixture(tmp, "off-read")
  boot(f)
  assert(boot(f, { COSMIC_BUILD_CACHE = "0" }).modules == loaded, "rows were read with the cache off")
end

--- Rows become code that runs, so a file or directory that anyone else
--- could write is neither read nor written, and a link is not taken for
--- the file.
local function test_a_cache_others_could_write_is_refused(tmp: string)
  local function refused(name: string, spoil: function(Fixture))
    local f = fixture(tmp, name)
    boot(f)
    assert(rows(f) == 2, name .. ": the control kept nothing")
    spoil(f)
    assert(boot(f).modules == loaded, name .. ": rows were read from a cache others could write")
  end
  refused("group-writable-file", function(f: Fixture) assert(Fs.chmod(f.cache, 0x1b0)) end)
  refused("world-writable-directory", function(f: Fixture)
    assert(Fs.chmod(Fs.dirname(f.cache), 0x1c7))
  end)
  refused("linked-file", function(f: Fixture)
    assert(Fs.rename(f.cache, f.cache .. ".real"))
    assert(Fs.symlink(f.cache .. ".real", f.cache))
  end)

  local f = fixture(tmp, "unwritten")
  assert(Fs.chmod(Fs.dirname(f.cache), 0x1f8))
  assert(boot(f).modules == loaded)
  assert(Fs.stat(f.cache) == nil, "a file was made in a directory others could write")
end

--- The file keeps the newest rows of each kind and no more.
local function test_the_cache_keeps_a_bounded_number_of_rows(tmp: string)
  local f = fixture(tmp, "bound")
  for round = 1, 20 do
    put(f.tree .. "/build/a.tl", "return { n = " .. round .. " }\n")
    boot(f)
  end
  assert(rows(f, "WHERE kind = 'modules'") == 16, "module rows: " .. rows(f, "WHERE kind = 'modules'"))
  assert(rows(f, "WHERE kind = 'compiler'") == 1)
  assert(boot(f).modules == 0, "the newest row was dropped")
end

--- The bridge makes its table in plain Lua; it has to be the one
--- [`build.cache_formats`] names, which the file's maintenance reads.
local function test_the_bridge_makes_the_table_the_formats_name(tmp: string)
  local f = fixture(tmp, "table")
  boot(f)
  local function schema(db: Sqlite.Handle): string
    local found = assert(Sqlite.text_rows(db,
      "SELECT sql FROM sqlite_schema WHERE name LIKE 'bridge_v%' ORDER BY name"))
    local out: {string} = {}
    for _, row in ipairs(found) do out[#out + 1] = row[1]:gsub("%s+", "") end
    return table.concat(out, ";")
  end
  local made = assert(Sqlite.open(f.cache))
  local expected = assert(Sqlite.memory())
  for _, statement in ipairs(cache_formats.bridge_statements) do
    assert(expected:exec(statement))
  end
  assert(schema(made) ~= "" and schema(made) == schema(expected), schema(made))
  assert(made:close())
  assert(expected:close())
end

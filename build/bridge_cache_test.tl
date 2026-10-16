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
local teal = require("build.teal")

Test.policy{ grants = {
  { path = "core/bridge.lua", letters = "r" },
  { path = "build/checker_wrapper.tl", letters = "r" },
} }

--- A stand-in compiler is the seed here: the Lua the pinned release
--- writes for the checker's files, which the stand-in "compiles" by
--- passing each through, so a file's Lua is its text.
---
--- A compiler that passes its source through, writing a file to the
--- directory `COUNT_DIR` names for each compile it makes: `compiler-N`
--- for a compile of itself (its source holds `search_module`) and
--- `module-N` for any other.
local compiler <const> = [[
local sys = require("cosmic.sys")
local dir = sys.getenv("COUNT_DIR")
local made = 0
local function write(path, text)
  local fd = assert(sys.open(path, sys.O_WRONLY | sys.O_CREAT | sys.O_TRUNC, 420))
  assert(sys.write(fd, text))
  sys.close(fd)
end
local compiler
compiler = {
  search_module = function() return nil end,
  new_env = function() return {} end,
  gen = function(source)
    made = made + 1
    local kind = source:find("search_module", 1, true) and "compiler" or "module"
    write(dir .. "/" .. kind .. "-" .. made, "")
    local action, path = sys.getenv("DEP_ACTION"), sys.getenv("DEP_PATH")
    if kind == "module" and made == 1 and action then
      -- A search for another module, as the checker's `require` of a
      -- dependency searches for it, and a write of the file it finds.
      local name, all = sys.getenv("DEP_NAME"), sys.getenv("DEP_ALL") ~= nil
      local function read()
        local _, handle = compiler.search_module(name, all)
        if handle == nil then return nil end
        local text = handle:read("*a")
        handle:close()
        return text
      end
      if action == "read" then
        read()
      elseif action == "edit" then
        write(path, "return { n = 9 }\n")
        read()
      elseif action == "twice" then
        local text = read()
        write(path, "-- other\n")
        read()
        write(path, text)
        read()
      elseif action == "vanish" then
        sys.unlink(path)
        read()
      end
    end
    local edit = sys.getenv("EDIT_A")
    if kind == "module" and made == 1 and edit then
      write(edit, "return { n = 2 }\n")
    end
    return source, {}
  end,
}
return compiler
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
return function(_root, _argv, carried)
  local sys = require("cosmic.sys")
  local path = sys.getenv("CARRIED_FILE")
  if path then
    local fd = assert(sys.open(path, sys.O_WRONLY | sys.O_CREAT | sys.O_TRUNC, 420))
    assert(sys.write(fd, carried))
    sys.close(fd)
  end
  return a.n + b.n
end
]]

local bridge_source = assert(Fs.read("core/bridge.lua"))

local held: {string:string} = {}

--- The Lua of build/checker_wrapper.tl, which a seed holds beside the
--- checker's: the real wrapper, since the bridge joins the parts with it.
local function wrapper(): string
  if held.wrapper == nil then
    local built = assert(teal.load(true))
    local env = assert(built.new_env({ defaults = {
      feat_lax = "off", gen_compat = "off", gen_target = "5.4",
    } }))
    local made, result = built.gen(assert(Fs.read("build/checker_wrapper.tl")), env, nil, "tl")
    assert(made ~= nil and #result.syntax_errors == 0, "the wrapper did not compile")
    held.wrapper = made
  end
  return held.wrapper
end

local record Fixture
  core: string
  tmp: string
  tree: string
  --- The seed directory.
  tl: string
  cache: string
  runs: integer
  --- Whether `boot` writes the seed from the tree's checker first, as a
  --- release that agrees with it would; a case about a seed that does not
  --- agree clears it and writes its own.
  seeded: boolean
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
    cache = base .. "/cache/cache.db", runs = 0, seeded = true }
  put(f.tree .. "/core/bridge.lua", bridge_source)
  put(f.tree .. "/core/syscalls.h", "/* stand-in */\n")
  put(f.tree .. "/build/gen_syscalls.tl", gen_syscalls)
  put(f.tree .. "/build/boot.tl", boot_source)
  put(f.tree .. "/build/a.tl", "return { n = 1 }\n")
  put(f.tree .. "/build/b/init.tl", "return { n = 20 }\n")
  put(f.tree .. "/build/note.md", "not a source\n")
  put(f.tree .. "/build/dep.tl", "return { n = 7 }\n")
  put(f.tree .. "/checker/tl.tl", compiler)
  put(f.tree .. "/checker/stdlib.d.tl", "-- the standard library\n")
  assert(Fs.mkdirs(Fs.dirname(f.cache)))
  assert(Fs.chmod(Fs.dirname(f.cache), 0x1c0))
  return f
end

local record Boot
  status: integer
  compiler: integer
  modules: integer
end

--- Writes the seed a release that agrees with `f`'s checker would: the
--- wrapper's Lua, and the text of each of the checker's files.
local function reseed(f: Fixture)
  put(f.tl .. "/checker_wrapper.lua", wrapper())
  put(f.tl .. "/tl.lua", (assert(Fs.read(f.tree .. "/checker/tl.tl"))))
  for _, name in ipairs((assert(Fs.list(f.tree .. "/checker")))) do
    local stem = name:match("^([%a_][%w_]*)%.tl$")
    if stem ~= nil and stem ~= "tl" then
      put(f.tl .. "/" .. stem .. ".lua", (assert(Fs.read(f.tree .. "/checker/" .. name))))
    end
  end
end

--- Boots `f`'s tree once, with `variables` beside the environment that
--- names its cache: the process's result and the directory of its counts.
local function start(f: Fixture, variables?: {string:string}): Child.Result, string
  if f.seeded then reseed(f) end
  f.runs = f.runs + 1
  local counts = f.tmp .. "/counts-" .. f.runs
  assert(Fs.mkdirs(counts))
  local env: {string:string} = {}
  for name, value in pairs(Env.all()) do env[name] = value end
  env.COSMIC_BUILD_CACHE = f.cache
  env.COUNT_DIR = counts
  env.CARRIED_FILE = f.tmp .. "/carried"
  for name, value in pairs(variables or {}) do env[name] = value end
  local r = assert(Child.run({ f.core, "--boot", f.tree, f.tl, "go" },
    { stdout = "capture", stderr = "capture", env = env, timeout_ns = Clock.seconds(30) }))
  return r, counts
end

--- Boots `f`'s tree once and answers its exit status and how many
--- compiles it made of the compiler and of modules.
local function boot(f: Fixture, variables?: {string:string}): Boot
  local r, counts = start(f, variables)
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
  return math.tointeger(tonumber(found[1]:text(1))) as integer
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
      put(f.tree .. "/checker/tl.tl", compiler .. "-- edited\n")
    end },
    { "the standard library's declarations", true, function(f: Fixture)
      put(f.tree .. "/checker/stdlib.d.tl", "-- edited\n")
    end },
    { "the seed", true, function(f: Fixture)
      f.seeded = false
      put(f.tl .. "/tl.lua", compiler .. "-- edited\n")
      put(f.tree .. "/checker/SEED_DIFFERS", "tl.lua\n")
    end },
    { "the seed's wrapper", true, function(f: Fixture)
      f.seeded = false
      put(f.tl .. "/checker_wrapper.lua", wrapper() .. "\n-- edited\n")
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

--- The checker's other files are compiled with its entry: each is a record
--- of the compiler's row, and an edit to one, or a file added beside the
--- entry, is a miss of that row. A declaration file beside the entry is
--- not one of them. (The stand-in compiler counts a source that holds
--- `search_module` as a compile of the compiler.)
local function test_a_checker_file_beside_the_entry_is_part_of_the_compilers_row(tmp: string)
  local f = fixture(tmp, "part")
  local part = f.tree .. "/checker/part.tl"
  put(part, "-- search_module\nreturn 1\n")
  local first = boot(f)
  assert(first.status == 21 and first.compiler == 2,
    "the first boot made " .. first.compiler .. " compiles of the compiler")
  local again = boot(f)
  assert(again.status == 21 and again.compiler == 0, "the compiler's row was not used")
  put(part, "-- search_module\nreturn 2\n")
  assert(boot(f).compiler == 2, "an edit to a checker file was taken from a stale row")
  put(f.tree .. "/checker/other.tl", "-- search_module\nreturn 3\n")
  assert(boot(f).compiler == 3, "a checker file added was taken from a stale row")
  put(f.tree .. "/checker/other.d.tl", "-- declarations\n")
  assert(boot(f).compiler == 0, "a declaration file beside the entry was compiled")
end

--- A checker file can require another, and only a plain `name.tl` beside
--- the entry is one: an editor's leftover is not compiled. The entry here
--- requires a part that requires a second at load, so a boot whose parts
--- cannot reach each other dies before it runs the tree (exit 1, not 21);
--- the bad file would fail the compile if it were taken.
local function test_a_checker_file_requires_another(tmp: string)
  local f = fixture(tmp, "chain")
  put(f.tree .. "/checker/tl.tl", "local a = require(\"checker.a\")\nassert(a.n == 2)\n" .. compiler)
  put(f.tree .. "/checker/a.tl", "-- search_module\nreturn { n = require(\"checker.b\").n + 1 }\n")
  put(f.tree .. "/checker/b.tl", "-- search_module\nreturn { n = 1 }\n")
  put(f.tree .. "/checker/.#a.tl", "this is not Lua (")
  put(f.tree .. "/checker/a~.tl", "this is not Lua (")
  put(f.tree .. "/checker/a.bak.tl", "this is not Lua (")
  assert(boot(f).status == 21, "the parts could not reach each other")
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

--- What a compile reads is held to the key as the searcher's own reads
--- are, whichever way the checker asks. Each case has the stand-in
--- compiler search for a module as it compiles the first one; only a read
--- of a file as the manifest has it leaves the row kept.
local function test_every_read_of_a_compile_is_held_to_the_key(tmp: string)
  local function dep(f: Fixture): string return f.tree .. "/build/dep.tl" end
  local function reads(f: Fixture, action: string): {string:string}
    return { DEP_ACTION = action, DEP_NAME = "build.dep", DEP_PATH = dep(f) }
  end

  -- The control: a dependency read as the manifest has it is kept.
  local f = fixture(tmp, "read-control")
  boot(f, reads(f, "read"))
  assert(rows(f, "WHERE kind = 'modules'") == 1, "an unchanged dependency read kept no row")
  assert(boot(f).modules == 0)

  -- A dependency edited before it is read.
  f = fixture(tmp, "read-edit")
  boot(f, reads(f, "edit"))
  assert(rows(f, "WHERE kind = 'modules'") == 0, "a row was kept for an edited dependency")

  -- The same file read as different bytes, ending as the manifest has it.
  f = fixture(tmp, "read-twice")
  boot(f, reads(f, "twice"))
  assert(rows(f, "WHERE kind = 'modules'") == 0, "a row was kept for a file read two ways")

  -- A file under the root that the manifest does not list: the `.lua`
  -- the search opens when no `.d.tl` or `.tl` is there.
  f = fixture(tmp, "read-unlisted")
  put(f.tree .. "/build/note.lua", "return {}\n")
  boot(f, { DEP_ACTION = "read", DEP_NAME = "build.note", DEP_ALL = "1" })
  assert(rows(f, "WHERE kind = 'modules'") == 0, "a row was kept after a read the key does not name")

  -- A name that climbs out of the root to a file with a listed path's
  -- tail and the same bytes is refused, not read: a read of it would not
  -- be the manifest's and would keep the row from being kept, so the row
  -- being kept (as in the control) is the refusal.
  f = fixture(tmp, "read-outside")
  put(tmp .. "/read-outside/twin/build/a.tl", "return { n = 1 }\n")
  assert(#(f.tree .. "/") == #(tmp .. "/read-outside/twin/"))
  boot(f, { DEP_ACTION = "read", DEP_NAME = "x/../../twin/build/a" })
  assert(rows(f, "WHERE kind = 'modules'") == 1, "a name that leaves the root was read")

  -- A listed file that was gone when it was looked for: restoring it
  -- must not take the row.
  f = fixture(tmp, "read-vanish")
  boot(f, reads(f, "vanish"))
  assert(rows(f, "WHERE kind = 'modules'") == 0, "a row was kept though a listed file was missing")
  put(dep(f), "return { n = 7 }\n")
  assert(boot(f).modules == loaded, "the restored tree took a row")
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

--- `COSMIC_BUILD_CACHE=0` and a name that is not absolute each
--- turn the cache off: nothing is read or kept.
local function test_the_cache_can_be_turned_off(tmp: string)
  local control = fixture(tmp, "control")
  boot(control)
  assert(rows(control) == 2, "the control kept nothing")
  local cases: {{string, {string:string}}} = {
    { "0", { COSMIC_BUILD_CACHE = "0" } },
    { "a relative name", { COSMIC_BUILD_CACHE = "cache.db" } },
  }
  for index, case in ipairs(cases) do
    local f = fixture(tmp, "off-" .. index)
    assert(boot(f, case[2]).modules == loaded)
    assert(boot(f, case[2]).modules == loaded, case[1] .. " did not turn the cache off")
    assert(Fs.stat(f.cache) == nil, case[1] .. " made the file")
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
    for _, row in ipairs(found) do out[#out + 1] = row:text(1):gsub("%s+", "") end
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

--- A seed whose Lua is not what the checker compiles itself to fails the
--- boot, naming the files: a seed that miscompiles, or a generator that
--- writes other Lua than the release's. A tree that lists the files
--- (`checker/SEED_DIFFERS`) boots, and what it carries is the second
--- stage's Lua, never the seed's.
local function test_a_seed_that_differs_from_the_second_stage_fails_the_boot(tmp: string)
  local f = fixture(tmp, "differs")
  put(f.tree .. "/checker/part.tl", "-- search_module\nreturn 1\n")
  assert(boot(f).status == 21)
  f.seeded = false
  put(f.tl .. "/part.lua", "-- search_module\nreturn 2\n")
  local r = start(f)
  assert(r.code == 1, "exit " .. tostring(r.code))
  local said = tostring(r.stderr)
  assert(said:find("differs from the checker compiled by itself in part.lua", 1, true), said)
  assert(said:find("SEED_DIFFERS", 1, true), said)
  put(f.tree .. "/checker/SEED_DIFFERS", "part.lua\n")
  assert(boot(f).status == 21, "a declared difference did not boot")
  local carried = assert(Fs.read(f.tmp .. "/carried"))
  assert(carried:find("return 1", 1, true) and not carried:find("return 2", 1, true),
    "the tool carries the seed's Lua, not the second stage's")
end

--- The list holds file by file: a difference in a file it does not name
--- still fails the boot, so a seed that miscompiles one file is not
--- excused by the declared change to another.
local function test_a_difference_in_an_unlisted_file_fails_the_boot(tmp: string)
  local f = fixture(tmp, "unlisted")
  put(f.tree .. "/checker/part.tl", "-- search_module\nreturn 1\n")
  f.seeded = false
  reseed(f)
  put(f.tl .. "/part.lua", "-- search_module\nreturn 2\n")
  put(f.tl .. "/tl.lua", compiler .. "-- seed\n")
  put(f.tree .. "/checker/SEED_DIFFERS", "tl.lua\n")
  local r = start(f)
  assert(r.code == 1, "exit " .. tostring(r.code))
  local said = tostring(r.stderr)
  assert(said:find("itself in part.lua:", 1, true), said)
  put(f.tree .. "/checker/SEED_DIFFERS", "tl.lua\npart.lua\n")
  local carried_boot = boot(f)
  assert(carried_boot.status == 21)
  local carried = assert(Fs.read(f.tmp .. "/carried"))
  assert(not carried:find("-- seed", 1, true), "the tool carries the seed's Lua")
end

--- The list holds only while it is true: a file it names that does not
--- differ fails the boot, even on a boot that finds the compiler in the
--- cache, naming the file; so does a file that names nothing.
local function test_a_declared_difference_the_seed_does_not_have_fails_the_boot(tmp: string)
  local f = fixture(tmp, "stale-declaration")
  assert(boot(f).status == 21)
  put(f.tree .. "/checker/SEED_DIFFERS", "tl.lua\n")
  local r = start(f)
  assert(r.code == 1, "exit " .. tostring(r.code))
  local said = tostring(r.stderr)
  assert(said:find("differs in tl.lua, and it does not: remove", 1, true), said)
  put(f.tree .. "/checker/SEED_DIFFERS", "\n")
  r = start(f)
  assert(r.code == 1 and tostring(r.stderr):find("names no file: remove it", 1, true),
    tostring(r.stderr))
end

--- An entry that is not a bare name of a file the seed writes (a path, a
--- comment) is refused as that, not taken for a file that does not differ.
local function test_a_declared_name_that_is_no_seed_file_fails_the_boot(tmp: string)
  local f = fixture(tmp, "bad-entry")
  assert(boot(f).status == 21)
  for _, entry in ipairs({ "checker/tl.lua", "# the generator moved" }) do
    put(f.tree .. "/checker/SEED_DIFFERS", entry .. "\n")
    local r = start(f)
    assert(r.code == 1, "exit " .. tostring(r.code))
    local said = tostring(r.stderr)
    assert(said:find(entry .. " names no file the seed writes: list bare output names", 1, true), said)
  end
end

--- A seed directory that lacks a file says which, and that the seed step
--- of build.zig writes it.
local function test_a_seed_without_a_file_fails_the_boot_naming_it(tmp: string)
  local f = fixture(tmp, "missing")
  put(f.tree .. "/checker/part.tl", "-- search_module\nreturn 1\n")
  f.seeded = false
  reseed(f)
  assert(Fs.remove(f.tl .. "/part.lua"))
  local r = start(f)
  assert(r.code == 1, "exit " .. tostring(r.code))
  local said = tostring(r.stderr)
  assert(said:find("/part.lua: ", 1, true) and said:find("seed step of build.zig", 1, true), said)
end

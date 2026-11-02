--- A store that carries a module's row without its source (the pure store of a test, [`build.closure_store`]) answers
--- [`Store.source`] with why, not with a failure to inflate nothing, and what decides a module is held from its source
--- ([`Store.withheld`]) tells it from one the binary does not hold. The program runs on a sealed database whose rows
--- were emptied, so no switch of the test run is needed.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Proc = require("cosmic.proc")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local Test = require("cosmic.test")
local searchable = require("build.searchable")
local this_program = require("build.this_program")

Test.policy{
  profiles = { "cosmic" },
  grants = { { path = "o/bin", letters = "rx" }, { path = "o/cosmic.db", letters = "r" } },
  requires = { "sandbox" },
  env = { "HOME", "XDG_CACHE_HOME", "PATH", "TMPDIR", "COSMIC_PORTABLE_CACHE", "COSMIC_VERDICT_CACHE",
    "COSMIC_BUILD_CACHE", "COSMIC_BUILD_HOME", "COSMIC_AUTO_BOOT", "COSMIC_TEST_SANDBOX" },
}

local function test_a_withheld_source_is_said_so_and_not_taken_for_absent(tmp: string)
  local roots = { "build.importer", "build.pipeline", "build.derivation", "build.analysis_schema", "build.bind",
    "build.doctest", "build.gen_syscalls", "build.link_text", "cosmic.json", "cosmic.fs" }
  local path = tmp .. "/withheld.db"
  -- The program asks the store about a module whose source is withheld, one whose source it carries and one it
  -- does not hold, and what the importer and the checker's provider make of the withheld one, and prints what it
  -- finds. It holds no upvalue but the environment, so its bytecode is the program sealed.
  local program = string.dump(function(...: any): any
    local sealed_store = require("cosmic.store")
    local sealed_sqlite = require("cosmic.sqlite")
    local importer = require("build.importer")
    local Pipeline = require("build.pipeline")
    local standard = Pipeline.carried()
    local function show(label: string, ...: any)
      local words: mut {string} = {}
      for i = 1, select("#", ...) do words[i] = tostring((select(i, ...))) end
      print(label .. "\t" .. table.concat(words, "\t"))
    end
    local function provided(name: string): string
      local ok, found = pcall(standard, name)
      return tostring(ok) .. "\t" .. tostring(found)
    end
    show("withheld", sealed_store.source("cosmic.json"))
    show("absent", sealed_store.source("no.such.module"))
    show("held", sealed_store.source("cosmic.fs") ~= nil)
    show("flag_withheld", sealed_store.withheld("cosmic.json") ~= nil)
    show("flag_held", sealed_store.withheld("cosmic.fs"))
    show("flag_absent", sealed_store.withheld("no.such.module"))
    local databases = sealed_store.databases()
    local binary = assert(databases[#databases])
    show("query", sealed_sqlite.text_rows(binary, "SELECT inflate(source) FROM modules WHERE path = 'cosmic.json'"))
    show("decl", sealed_store.source("cosmic.decl_only"))
    show("decl_flag", sealed_store.withheld("cosmic.decl_only") ~= nil)
    show("analyzer", importer.analyzer_modules())
    local ok, raised = pcall(importer.analyzer_identity)
    show("identity", tostring(ok), raised)
    show("provider", provided("cosmic.json"))
    show("provider_held", (provided("cosmic.fs")):sub(1, 4))
    show("provider_absent", provided("cosmic.no_such_module"))
    return ...
  end)
  assert(Store.seal(Store.closure(roots), path, { unchecked_bytecode = true,
    extra = { name = "main", bytecode = program, source = "", requires = { "cosmic.store", "cosmic.sqlite",
      "build.importer", "build.pipeline" } } }))
  local db = assert(Sqlite.open(path, { writable = true }))
  assert(Sqlite.run(db, "UPDATE modules SET source = X'' WHERE path IN ('cosmic.json', 'build.bind')"))
  assert(Sqlite.run(db, "INSERT INTO decls (path, source) VALUES ('cosmic.decl_only', X'')"))
  assert(db:close())

  searchable.open(tmp)
  searchable.share(path)
  local started = this_program.program({ "sandbox", "--database", path, "--", (assert(Proc.executable())) }, {
    cwd = tmp, env = this_program.environment(), stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(120),
  })
  local ran = assert(Child.run(started.argv, started.options))
  if ran.code == 125 and ((ran.stderr or ""):find("Landlock", 1, true) or (ran.stderr or ""):find("seccomp", 1, true) or
      (ran.stderr or ""):find("not implemented", 1, true)) ~= nil then
    Test.skip(ran.stderr or "")
  end
  local out = ran.stdout or ""
  local function line(label: string): string
    return ("\n" .. out):match("\n" .. label .. "\t([^\n]*)") or ""
  end
  local detail = tostring(ran.code) .. "\n" .. out .. (ran.stderr or "")
  local withheld = line("withheld")
  assert(withheld:find("^nil\t.*'cosmic.json' is withheld"), detail)
  assert(withheld:find("store_text = true", 1, true) ~= nil, detail)
  assert(withheld:find("truncated", 1, true) == nil, detail)
  assert(line("absent") == "nil\tno module 'no.such.module' in the binary", detail)
  assert(line("held") == "true", detail)
  assert(line("flag_withheld") == "true", detail)
  assert(line("flag_held") == "nil\t", detail)
  assert(line("flag_absent") == "nil\t", detail)
  assert(line("query"):find("^nil\t.*the value is empty.*store_text = true"), detail)
  -- The importer names the withheld module, not a shorter set of the analyzer's modules.
  assert(line("decl"):find("^nil\t.*'cosmic.decl_only' is withheld"), detail)
  assert(line("decl_flag") == "true", detail)
  -- The analyzer's identity is refused with the reason, not named for a binary that carries none of the source.
  assert(line("identity"):find("^false\t.*'build.bind' is withheld"), detail)
  assert(line("analyzer"):find("^nil\t.*'build.bind' is withheld"), detail)
  -- The checker's provider raises for a withheld module and answers nil only for an absent one.
  assert(line("provider"):find("^false\t.*'cosmic.json' is withheld"), detail)
  assert(line("provider_held") == "true", detail)
  assert(line("provider_absent") == "true\tnil", detail)
end

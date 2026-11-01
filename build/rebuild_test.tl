--- What [`rebuild.stage`] stages for `cosmic lsp`: a directory a build was
--- started in, never one that is no project, and nothing while another
--- run holds the working database, which it waits for no more than to
--- find it held, nor in one of another schema.

local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local build_paths = require("build.paths")
local GrammarMode = require("build.grammar_mode")
local Pipeline = require("build.pipeline")
local rebuild = require("build.rebuild")
local work = require("build.work")
local Test = require("cosmic.test")

Test.policy{ cpu_features = true }

local function test_a_directory_that_is_no_project_is_never_staged(tmp: string)
  local root = tmp .. "/stray"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/notes.tl", "return {}\n"))
  local where = assert(rebuild.stage(root))
  assert(not where.project and not where.busy)
  local made, trouble = Fs.exists(build_paths.required(root))
  assert(made ~= nil, trouble)
  assert(made == false, "a directory that is no project gets a build directory")
end

--- A directory whose first build failed, which left the working database
--- every build opens first, is a project, staged as `cosmic test` stages it.
local function test_a_directory_a_build_was_started_in_is_staged(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  assert(work.close((assert(work.open(root)))))
  assert(Fs.write(root .. "/a.tl", "return {}\n"))
  local where = assert(rebuild.stage(root))
  assert(where.project and not where.busy)
  local db = assert(Sqlite.open(build_paths.required(root) .. "/build.db"))
  local rows = assert(Sqlite.text_rows(db, "SELECT path FROM inputs"))
  assert(db:close())
  assert(#rows == 1 and assert(rows[1]):text(1) == "a", tostring(#rows))
end

local function test_a_stage_waits_for_no_run_holding_the_database(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  assert(work.close((assert(work.open(root)))))
  assert(Fs.write(root .. "/a.tl", "return {}\n"))
  local held = assert(Sqlite.open(build_paths.required(root) .. "/build.db", { writable = true }))
  assert(held:exec("BEGIN IMMEDIATE"))
  local started = Clock.monotonic_ns()
  local where = assert(rebuild.stage(root))
  local took = Clock.monotonic_ns() - started
  assert(held:exec("ROLLBACK"))
  assert(held:close())
  assert(where.project and where.busy)
  assert(took < Clock.seconds(10), tostring(took) .. " ns")
end

--- A lookup's build of a project whose working database an older tool made
--- makes it again, as the newer writer, rather than leave it and say so on
--- every call; a database of a newer schema it leaves.
local function test_a_lookups_build_makes_a_database_of_an_older_schema_again(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/a.tl", "--- A.\nlocal record A\nend\n\nreturn A\n"))
  local path = build_paths.required(root) .. "/build.db"
  local function schema_of(): string
    local db = assert(Sqlite.open(path))
    local rows = assert(Sqlite.text_rows(db, "SELECT value FROM meta WHERE key = 'schema'"))
    assert(db:close())
    return assert(rows[1]):text(1)
  end
  assert(work.close((assert(work.open(root)))))
  local current = schema_of()
  local function stamp(schema: string)
    local db = assert(Sqlite.open(path, { writable = true }))
    assert(Sqlite.run(db, "UPDATE meta SET value = ?1 WHERE key = 'schema'", { { text = schema } }))
    assert(db:close())
  end
  stamp("99")
  assert(rebuild.here("docs", false, root))
  assert(schema_of() == "99", "a database of a newer schema was made again")
  stamp("1")
  assert(rebuild.here("docs", false, root))
  assert(schema_of() == current, "a database of an older schema was left: " .. schema_of())
end

--- A stage that finds the working database of another schema, another
--- tool's, stages nothing in it and leaves it where it is, answering the
--- schema it found.
local function test_a_stage_leaves_a_database_of_another_schema(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  local made = assert(work.open(root))
  assert(Sqlite.run(made.db, "UPDATE meta SET value = 'another' WHERE key = 'schema'"))
  assert(work.close(made))
  assert(Fs.write(root .. "/a.tl", "return {}\n"))
  local path = build_paths.required(root) .. "/build.db"
  local before = assert(Fs.stat(path)).ino
  local where = assert(rebuild.stage(root))
  assert(where.project and not where.busy)
  assert(where.other_schema == "another", tostring(where.other_schema))
  assert(assert(Fs.stat(path)).ino == before, "the file was removed")
  local db = assert(Sqlite.open(path))
  local rows = assert(Sqlite.text_rows(db, "SELECT path FROM inputs"))
  assert(db:close())
  assert(#rows == 0, "staged " .. tostring(#rows) .. " files in it")
end

--- The compiler a projection records is the compiler's, the mode's and the code that reads, so that a lookup reads a
--- projection only of the code that wrote it ([`writer.other_code`]).
local function test_a_projection_names_the_new_checkers_code_as_its_compiler()
  local new = rebuild.compiled_by("new")
  assert(#new == 64, new)
  assert(new == Pipeline.coded(GrammarMode.tool(Store.meta("compiler") or "", "new")))
  assert(rebuild.compiled_by("new") == new)
end

--- A stage reads the sources with the new checker's syntax tree, which reads what only the new grammar spells (`mut`,
--- `name?: T`), and the rows of its docs are staged.
local function test_a_stage_reads_the_sources_with_the_new_checker(tmp: string)
  local source = "--- A box.\nlocal record Box\n  --- How wide.\n  mut width: integer\n  --- A label.\n  label?: string\nend\nreturn Box\n"
  local root = tmp .. "/new"
  assert(Fs.mkdirs(root))
  assert(work.close((assert(work.open(root)))))
  assert(Fs.write(root .. "/a.tl", source))
  local where = assert(rebuild.stage(root))
  assert(where.project and not where.busy)
  local db = assert(Sqlite.open(build_paths.required(root) .. "/build.db"))
  local rows = assert(Sqlite.text_rows(db,
    "SELECT d.symbol FROM docs d JOIN inputs i ON i.source_hash = d.source_hash WHERE i.file = 'a.tl' ORDER BY d.line"))
  assert(db:close())
  local symbols = ""
  for slot, row in ipairs(rows) do
    symbols = symbols .. (if slot > 1 then "," else "" end) .. row:text(1)
  end
  assert(symbols == ",Box,width,label", symbols)
end

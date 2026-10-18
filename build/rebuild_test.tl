--- What [`rebuild.stage`] stages for `cosmic lsp`: a directory a build was
--- started in, never one that is no project, and nothing while another
--- run holds the working database, which it waits for no more than to
--- find it held.

local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local build_paths = require("build.paths")
local rebuild = require("build.rebuild")
local teal = require("build.teal")
local work = require("build.work")

local function test_a_directory_that_is_no_project_is_never_staged(tmp: string)
  local root = tmp .. "/stray"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/notes.tl", "return {}\n"))
  local where = assert(rebuild.stage(root, (assert(teal.load()))))
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
  local where = assert(rebuild.stage(root, (assert(teal.load()))))
  assert(where.project and not where.busy)
  local db = assert(Sqlite.open(build_paths.required(root) .. "/build.db"))
  local rows = assert(Sqlite.text_rows(db, "SELECT path FROM inputs"))
  assert(db:close())
  assert(#rows == 1 and rows[1]:text(1) == "a", tostring(#rows))
end

local function test_a_stage_waits_for_no_run_holding_the_database(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  assert(work.close((assert(work.open(root)))))
  assert(Fs.write(root .. "/a.tl", "return {}\n"))
  local held = assert(Sqlite.open(build_paths.required(root) .. "/build.db", { writable = true }))
  assert(held:exec("BEGIN IMMEDIATE"))
  local started = Clock.monotonic_ns()
  local where = assert(rebuild.stage(root, (assert(teal.load()))))
  local took = Clock.monotonic_ns() - started
  assert(held:exec("ROLLBACK"))
  assert(held:close())
  assert(where.project and where.busy)
  assert(took < Clock.seconds(10), tostring(took) .. " ns")
end

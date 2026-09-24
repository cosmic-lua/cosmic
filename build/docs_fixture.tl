--- A shipped database for a test, made from sources by the build's own
--- code rather than from rows written by hand.
---
--- A test of `build.docs` or of a reader of the `docs`, `uses` and
--- `examples` tables needs rows shaped as the build writes them: an
--- exported member's own name (`find`) beside the name it was written
--- as (`Proc.find`), a use recorded without the module's record. Rows
--- written by hand drift from that shape silently. Here each source is
--- staged into a working database as `build.work` stages a tree, parsed
--- by `build.importer.derive` -- the same `build.positions` analysis a
--- build runs -- and projected by `build.writer.write_result`, the
--- function that writes `o/cosmic.db`.

local Sqlite = require("cosmic.sqlite")
local importer = require("build.importer")
local teal = require("build.teal")
local work = require("build.work")
local writer = require("build.writer")

local record docs_fixture
end

--- How many databases this process has written, so each has a file of
--- its own under a directory one test shares.
local written = 0

--- The shipped database the tree `files` would build to, written as
--- a file of its own under `dir` and opened read-only. `files` maps each file's path
--- in the tree (`cosmic/fs.tl`, `cosmic/fs_example.tl`, `app/main.tl`,
--- `core/syscalls.h`) to its contents; a path decides a module's import
--- path and kind as it does in a tree. Nothing is compiled, so a source
--- need not type-check, and every module the tree holds is planned.
function docs_fixture.database(dir: string, files: {string: string}): Sqlite.Handle
  local db = assert(Sqlite.memory())
  for _, statement in ipairs(work.schema) do
    assert(db:exec(statement))
  end
  local paths: {string} = {}
  for path in pairs(files) do paths[#paths + 1] = path end
  table.sort(paths)
  for _, path in ipairs(paths) do
    assert(Sqlite.run(db,
      "INSERT INTO files (path, size, mtime_ns, ino, dev, sha256, data) " ..
      "VALUES (?1, length(CAST(?2 AS BLOB)), 0, 0, 0, lower(hex(sha256(?2))), ?2)",
      { { text = path }, { text = files[path] } }))
  end
  local handle: work.Handle = { db = db, root = dir, run = 1, inside = false }
  local built = assert(teal.load())
  assert(importer.derive(handle, true, built))
  -- `build.importer.compile` plans each module under its key, beside
  -- its compile; this stands in for both, planning every module with
  -- nothing compiled, which no table the fixture is for reads.
  -- TODO: a use through a typed value (`w:add_file(...)`, which
  -- `build.receivers` finds) is recorded only while a module compiles,
  -- so no fixture has one; plan through `importer.compile` once it can
  -- compile a tree staged without a root on disk.
  assert(db:exec(
    "INSERT INTO plan (path, key, ordinal) SELECT path, source_hash, " ..
    "row_number() OVER (ORDER BY path) FROM inputs " ..
    "WHERE kind NOT IN ('decl', 'vendor')"))
  assert(db:exec(
    "INSERT INTO compiled (key, tool, lua, bytecode, seen) " ..
    "SELECT key, '', '', '', 0 FROM plan"))
  written = written + 1
  local path = dir .. "/cosmic-" .. written .. ".db"
  assert(writer.write_result(handle, path, {
    modules = {}, tool = "", refused = {}, compiled = 0, cached = 0,
  }))
  assert(db:close())
  return (assert(Sqlite.open(path, false)))
end

return docs_fixture

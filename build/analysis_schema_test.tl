--- `build.analysis_schema`: the one definition of the kind of a Teal file, asked in SQL by the `inputs` view and in Teal
--- by everything else.

local Sqlite = require("cosmic.sqlite")
local analysis_schema = require("build.analysis_schema")

local paths: {string} = {
  "cosmic/fs.tl", "cosmic/fs_test.tl", "cosmic/fs_example.tl", "cosmic/internal/store.tl", "lang/prelude.d.tl",
  "core/syscalls.d.tl", "cmd/tool/main.tl", "cmd/tool/sub/main.tl", "cmd/main.tl", "cmd/tool/main_test.tl",
  "build/init.tl", "a_test.tl.tl", "x.d.tl", "test/portable/tool.tl", "docs/guide_example.tl",
}

--- Every path is the same kind to the `inputs` view and to [`analysis_schema.kind_of`], and the kinds are the five a
--- file can be.
local function test_the_view_and_teal_kinds_of_a_path_agree(_: string)
  local db = assert(Sqlite.memory())
  assert(Sqlite.run(db, "CREATE TABLE files (path TEXT PRIMARY KEY, sha256 TEXT, data BLOB) WITHOUT ROWID"))
  for _, statement in ipairs(analysis_schema.statements) do assert(Sqlite.run(db, statement)) end
  for _, path in ipairs(paths) do
    assert(Sqlite.run(db, "INSERT INTO files (path, sha256, data) VALUES (?1, 'h', '')", { { text = path } }))
  end
  local rows = assert(Sqlite.text_rows(db, "SELECT file, kind FROM inputs"))
  assert(#rows == #paths, "the view reads " .. tostring(#rows) .. " of " .. tostring(#paths) .. " files")
  local seen: mut {string: boolean} = {}
  for _, row in ipairs(rows) do
    local path, sql = row:text(1), row:text(2)
    assert(sql == analysis_schema.kind_of(path), path .. ": the view says " .. sql .. ", Teal " .. analysis_schema.kind_of(path))
    seen[sql] = true
  end
  for _, kind in ipairs({ "decl", "test", "example", "main", "module" }) do
    assert(seen[kind] == true, "no path of the fixture is a " .. kind)
  end
end

--- Only a main of `cmd/<name>/` is a main: not one a directory deeper, nor `cmd/main.tl`.
local function test_a_main_is_cmd_name_main(_: string)
  assert(analysis_schema.kind_of("cmd/tool/main.tl") == "main")
  assert(analysis_schema.kind_of("cmd/tool/sub/main.tl") == "module")
  assert(analysis_schema.kind_of("cmd/main.tl") == "module")
end

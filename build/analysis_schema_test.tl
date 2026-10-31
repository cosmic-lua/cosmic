--- `build.analysis_schema`: the one definition of the kind of a Teal file, asked in SQL by the `inputs` view and in Teal
--- by everything else.

local Sqlite = require("cosmic.sqlite")
local analysis_schema = require("build.analysis_schema")

local paths: {string} = {
  "cosmic/fs.tl", "cosmic/fs_test.tl", "cosmic/fs_example.tl", "cosmic/internal/store.tl", "lang/prelude.d.tl",
  "core/syscalls.d.tl", "cmd/tool/main.tl", "cmd/tool/sub/main.tl", "cmd/main.tl", "cmd/tool/main_test.tl",
  "build/init.tl", "a_test.tl.tl", "x.d.tl", "test/portable/tool.tl", "docs/guide_example.tl",
  -- Shapes a pattern language mishandles: the characters `LIKE` and a regular expression take for their own are
  -- plain in `GLOB`, a bracket is no class in a name, and `GLOB` is case-sensitive.
  "a%b/x.tl", "a%b/x_test.tl", "a_b/x_example.tl", "what?/x.d.tl", "dir[1]/x_test.tl", "dir[1]/main.tl",
  "cmd/a%b/main.tl", "cmd/a_b/main.tl", "cmd/what?/main.tl", "cmd/[x]/main.tl",
  "Cmd/x/main.tl", "cmd/X/Main.tl", "Foo_test.tl", "FOO_TEST.tl", "x_test.d.tl", "x_example.d.tl",
  "cmd/x/main.tl.tl", "cmd//main.tl", "cmd/x/y/main.tl", ".tl.tl", "_test.tl",
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
  assert(analysis_schema.kind_of("cmd/x/main.tl.tl") == "module")
  assert(analysis_schema.kind_of("x_test.d.tl") == "decl")
  assert(analysis_schema.kind_of("cmd/a%b/main.tl") == "main")
  assert(analysis_schema.kind_of("Cmd/x/main.tl") == "module")
  assert(analysis_schema.kind_of("cmd/tool/main.tl") == "main")
  assert(analysis_schema.kind_of("cmd/tool/sub/main.tl") == "module")
  assert(analysis_schema.kind_of("cmd/main.tl") == "module")
end

--- The declaration predicate selects the rows the literal comparisons it replaced did, in SQL and in Teal, over every
--- kind a row of `inputs` has (a derived row's kind is given, so `vendor` and a kind that is none are in it too).
local function test_the_declaration_predicate_selects_what_the_comparisons_did(_: string)
  local db = assert(Sqlite.memory())
  assert(Sqlite.run(db, "CREATE TABLE files (path TEXT PRIMARY KEY, sha256 TEXT, data BLOB) WITHOUT ROWID"))
  for _, statement in ipairs(analysis_schema.statements) do assert(Sqlite.run(db, statement)) end
  local kinds = { "decl", "module", "main", "test", "example", "vendor", "binding", "" }
  for index, kind in ipairs(kinds) do
    assert(Sqlite.run(db, "INSERT INTO derived (file, path, kind, origin, from_hash, source, source_hash) " ..
        "VALUES (?1, ?2, ?3, 'fixture', 'h', '', 'h')", { { text = "f" .. tostring(index) }, { text = "m" .. tostring(index) },
          { text = kind } }))
  end
  local function selected(where: string): string
    local rows = assert(Sqlite.text_rows(db, "SELECT path FROM inputs WHERE " .. where .. " ORDER BY path"))
    local out: mut {string} = {}
    for _, row in ipairs(rows) do out[#out + 1] = row:text(1) end
    return table.concat(out, " ")
  end
  assert(selected(analysis_schema.declaration("kind")) == selected("kind = 'decl'"))
  assert(selected(analysis_schema.not_declaration("kind")) == selected("kind <> 'decl'"))
  assert(selected(analysis_schema.not_declaration("kind") .. " AND kind <> 'vendor'") ==
      selected("kind NOT IN ('decl', 'vendor')"))
  for _, kind in ipairs(kinds) do
    assert(analysis_schema.is_declaration(kind) == (kind == "decl"), kind)
  end
end

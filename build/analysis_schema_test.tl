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

--- A declaration that holds the binding line on a line of its own is a `binding`, to the view and to Teal alike; the
--- line inside another line, with anything after it, or in a file that is no declaration, is not.
local function test_a_declaration_is_a_binding_only_given_the_line_on_a_line_of_its_own(_: string)
  local cases: {{string}} = {
    { "b/first.d.tl", "--- @kind binding\nlocal record R end\nreturn R\n", "binding" },
    { "b/middle.d.tl", "--- A table.\n--- @kind binding\nlocal record R end\n", "binding" },
    { "b/last.d.tl", "local record R end\n--- @kind binding", "binding" },
    { "b/inside.d.tl", "-- see --- @kind binding for what it means\nlocal record R end\n", "decl" },
    { "b/after.d.tl", "--- @kind binding \nlocal record R end\n", "decl" },
    { "b/other.d.tl", "--- @kind bindings\nlocal record R end\n", "decl" },
    { "b/plain.d.tl", "local record R end\n", "decl" },
    { "b/module.tl", "--- @kind binding\nreturn 1\n", "module" },
    { "b/test_test.tl", "--- @kind binding\n", "test" },
  }
  local db = assert(Sqlite.memory())
  assert(Sqlite.run(db, "CREATE TABLE files (path TEXT PRIMARY KEY, sha256 TEXT, data BLOB) WITHOUT ROWID"))
  for _, statement in ipairs(analysis_schema.statements) do assert(Sqlite.run(db, statement)) end
  for _, case in ipairs(cases) do
    assert(Sqlite.run(db, "INSERT INTO files (path, sha256, data) VALUES (?1, 'h', ?2)",
      { { text = assert(case[1]) }, { text = assert(case[2]) } }))
  end
  local rows = assert(Sqlite.text_rows(db, "SELECT file, kind FROM inputs"))
  local said: mut {string: string} = {}
  for _, row in ipairs(rows) do said[row:text(1)] = row:text(2) end
  for _, case in ipairs(cases) do
    local path, text, wanted = assert(case[1]), assert(case[2]), assert(case[3])
    assert(said[path] == wanted, path .. ": the view says " .. tostring(said[path]) .. ", wanted " .. wanted)
    assert(analysis_schema.kind_of(path, text) == wanted, path .. ": Teal says " .. analysis_schema.kind_of(path, text))
    assert(analysis_schema.is_declaration(wanted) == (wanted == "decl" or wanted == "binding"))
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

--- The declaration predicate selects the declarations (`decl`, and `binding` among them), in SQL and in Teal, over every
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
  -- A binding is a declaration; nothing else is added to what `kind = 'decl'` selected.
  assert(selected(analysis_schema.declaration("kind")) == selected("kind IN ('decl', 'binding')"))
  assert(selected(analysis_schema.not_declaration("kind")) == selected("kind NOT IN ('decl', 'binding')"))
  assert(selected(analysis_schema.not_declaration("kind") .. " AND kind <> 'vendor'") ==
      selected("kind NOT IN ('decl', 'binding', 'vendor')"))
  for _, kind in ipairs(kinds) do
    assert(analysis_schema.is_declaration(kind) == (kind == "decl" or kind == "binding"), kind)
  end
end

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
  local record Source
    path: string
    text: string
    kind: string
  end
  local cases: {Source} = {
    { path = "b/first.d.tl", text = "--- @kind binding\nlocal record R end\nreturn R\n", kind = "binding" },
    { path = "b/middle.d.tl", text = "--- A table.\n--- @kind binding\nlocal record R end\n", kind = "binding" },
    -- Only the doc block that opens the file declares it: a line after code, in a string or in a function's doc does not.
    { path = "b/last.d.tl", text = "local record R end\n--- @kind binding", kind = "decl" },
    { path = "b/after_blank.d.tl", text = "--- A table.\n\n--- @kind binding\nlocal record R end\n", kind = "decl" },
    { path = "b/string.d.tl", text = "local s = [[\n--- @kind binding\n]]\n", kind = "decl" },
    { path = "b/mixed.d.tl",
      text = "--- A table.\n-- a note\n--- @kind binding\nlocal record R end\n",
      kind = "binding" },
    { path = "b/no_newline.d.tl", text = "--- @kind binding", kind = "binding" },
    { path = "b/inside.d.tl",
      text = "-- see --- @kind binding for what it means\nlocal record R end\n",
      kind = "decl" },
    { path = "b/after.d.tl", text = "--- @kind binding \nlocal record R end\n", kind = "decl" },
    { path = "b/other.d.tl", text = "--- @kind bindings\nlocal record R end\n", kind = "decl" },
    { path = "b/plain.d.tl", text = "local record R end\n", kind = "decl" },
    { path = "b/module.tl", text = "--- @kind binding\nreturn 1\n", kind = "module" },
    { path = "b/test_test.tl", text = "--- @kind binding\n", kind = "test" },
    -- A file saved with CR LF line ends declares it as one with LF does, in the view and in Teal.
    { path = "b/crlf.d.tl", text = "--- A table.\r\n--- @kind binding\r\nlocal record R end\r\n", kind = "binding" },
    { path = "b/crlf_last.d.tl", text = "--- A table.\r\n--- @kind binding\r\n", kind = "binding" },
    { path = "b/crlf_late.d.tl", text = "local record R end\r\n--- @kind binding\r\n", kind = "decl" },
    { path = "b/crlf_after.d.tl", text = "--- @kind binding \r\nlocal record R end\r\n", kind = "decl" },
    -- Only a declaration claims it, and a declaration that is a test's still does.
    { path = "b/helper_test.d.tl", text = "--- @kind binding\nlocal record R end\n", kind = "binding" },
    -- The language's own declarations say so as a binding does: a line of the opening doc block, of its own.
    { path = "b/language.d.tl", text = "--- @kind language\ndo\nend\n", kind = "language" },
    { path = "b/language_after_note.d.tl", text = "-- The prelude.\n--- @kind language\ndo\nend\n", kind = "language" },
    { path = "b/language_crlf.d.tl", text = "--- @kind language\r\ndo\r\nend\r\n", kind = "language" },
    { path = "b/language_late.d.tl", text = "do\nend\n--- @kind language\n", kind = "decl" },
    { path = "b/language_trailing.d.tl", text = "--- @kind language \ndo\nend\n", kind = "decl" },
    { path = "b/language_module.tl", text = "--- @kind language\nreturn 1\n", kind = "module" },
    { path = "b/unknown_kind.d.tl", text = "--- @kind module\nlocal record R end\n", kind = "decl" },
  }
  local db = assert(Sqlite.memory())
  assert(Sqlite.run(db, "CREATE TABLE files (path TEXT PRIMARY KEY, sha256 TEXT, data BLOB) WITHOUT ROWID"))
  for _, statement in ipairs(analysis_schema.statements) do assert(Sqlite.run(db, statement)) end
  for _, case in ipairs(cases) do
    assert(Sqlite.run(db, "INSERT INTO files (path, sha256, data) VALUES (?1, 'h', ?2)",
      { { text = case.path }, { text = case.text } }))
  end
  local rows = assert(Sqlite.text_rows(db, "SELECT file, kind FROM inputs"))
  local said: mut {string: string} = {}
  for _, row in ipairs(rows) do said[row:text(1)] = row:text(2) end
  for _, case in ipairs(cases) do
    local path, text, wanted = case.path, case.text, case.kind
    assert(said[path] == wanted, path .. ": the view says " .. tostring(said[path]) .. ", wanted " .. wanted)
    assert(analysis_schema.kind_of(path, text) == wanted, path .. ": Teal says " .. analysis_schema.kind_of(path, text))
    assert(analysis_schema.is_declaration(wanted) == (wanted == "decl" or wanted == "binding" or wanted == "language"))
  end
end

--- The kinds a declaration may name itself by are listed once: the tags the docs leave out, the files the language's kind is
--- allowed for, and the lines a generator and a file are written with.
local function test_the_kinds_a_declaration_may_name_are_one_list(_: string)
  assert(analysis_schema.binding_tag() == "--- @kind binding" and analysis_schema.language_tag() == "--- @kind language")
  assert(table.concat(analysis_schema.kind_tags(), "|") == "--- @kind binding|--- @kind language")
  assert(analysis_schema.declares_language("--- @kind language\n") and not analysis_schema.declares_language("--- @kind binding\n"))
  assert(analysis_schema.declares_binding("--- @kind binding\n") and not analysis_schema.declares_binding("--- @kind language\n"))
  assert(analysis_schema.is_language_file("lang/prelude.d.tl") and analysis_schema.is_language_file("lang/stdlib.d.tl"))
  assert(not analysis_schema.is_language_file("lang/other.d.tl") and not analysis_schema.is_language_file("x/lang/stdlib.d.tl"))
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
  local kinds = { "decl", "module", "main", "test", "example", "vendor", "binding", "language", "" }
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
  assert(selected(analysis_schema.declaration("kind")) == selected("kind IN ('decl', 'binding', 'language')"))
  assert(selected(analysis_schema.not_declaration("kind")) == selected("kind NOT IN ('decl', 'binding', 'language')"))
  assert(selected(analysis_schema.not_declaration("kind") .. " AND kind <> 'vendor'") ==
      selected("kind NOT IN ('decl', 'binding', 'language', 'vendor')"))
  for _, kind in ipairs(kinds) do
    assert(analysis_schema.is_declaration(kind) == (kind == "decl" or kind == "binding" or kind == "language"), kind)
  end
end

--- The `--- @public` line is read as the binding line is: on a line of its own, with LF or CR LF, not inside another
--- line or with anything after it.
local function test_the_public_line_is_read_on_a_line_of_its_own()
  assert(analysis_schema.declares_public("--- A module.\n--- @public\nlocal x = 1\n"))
  assert(analysis_schema.declares_public("--- A module.\r\n--- @public\r\nlocal x = 1\r\n"))
  assert(analysis_schema.declares_public("--- @public"))
  -- Only in the doc block that opens the file.
  assert(not analysis_schema.declares_public("local x = 1\n--- @public\n"))
  assert(not analysis_schema.declares_public("--- A module.\n\n--- @public\nlocal x = 1\n"))
  assert(not analysis_schema.declares_public("local s = [[\n--- @public\n]]\n"))
  assert(analysis_schema.declares_public("--- A module.\n-- a note\n--- @public\nlocal x = 1\n"))
  assert(not analysis_schema.declares_public("-- see --- @public for what it means\n"))
  assert(not analysis_schema.declares_public("--- @public \n"))
  assert(not analysis_schema.declares_public("--- @publicly\n"))
  assert(not analysis_schema.declares_public("--- @kind binding\n"))
end

--- Test support is a file of the top-level `test/` directory, whatever its name; a `test/` further down is not.
local function test_support_is_the_top_level_test_directory()
  assert(analysis_schema.is_support("test/portable/tool.tl"))
  assert(analysis_schema.is_support("test/helper.tl"))
  assert(not analysis_schema.is_support("cosmic/test/helper.tl"))
  assert(not analysis_schema.is_support("testdata/x.tl"))
  assert(not analysis_schema.is_support("tests/x.tl"))
end

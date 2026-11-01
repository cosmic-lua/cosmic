--- What cosmic's own build does with the stubs ([`build.syntax_stub`]) of its
--- standard library: the tool it writes carries each, a stub that types
--- its module otherwise than the source fails the build, and a projection
--- missing one is refused. The fixture is a tree [`build.tree`] takes for
--- cosmic's own.
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local Ast = require("lang.ast")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")
local build_paths = require("build.paths")
local identity = require("build.identity")
local importer = require("build.importer")
local stub = require("build.syntax_stub")
local work = require("build.work")
local writer = require("build.writer")

Test.policy{ grants = { { path = "lang/prelude.d.tl", letters = "r" }, { path = "lang/stdlib.d.tl", letters = "r" } } }

local thing <const> = table.concat({
  "--- A thing.",
  "local record thing",
  "  record Box",
  "    n: integer",
  "  end",
  "end",
  "function thing.box(n: integer): thing.Box",
  "  return { n = n }",
  "end",
  "return thing",
  "",
}, "\n")

--- A tree [`build.tree`] takes for cosmic's own, at a new directory, with
--- one standard-library module, staged and parsed: its working handle
--- and the compiler identity a build of it keys on.
local function own_tree(tmp: string, source?: string, underived?: boolean): work.Handle, string
  local root = tmp .. "/tree"
  for _, dir in ipairs({ "core", "build", "cosmic" }) do
    assert(Fs.mkdirs(root .. "/" .. dir))
  end
  assert(Fs.write(root .. "/build/importer.tl", "local record importer\nend\nreturn importer\n"))
  assert(Fs.write(root .. "/cosmic/thing.tl", source or thing))
  assert(Fs.mkdirs(root .. "/lang"))
  assert(Fs.write(root .. "/build/ceilings.txt", "[checked]\n"))
  assert(Fs.write(root .. "/lang/prelude.d.tl", (assert(Fs.read("lang/prelude.d.tl")))))
  assert(Fs.write(root .. "/lang/stdlib.d.tl", (assert(Fs.read("lang/stdlib.d.tl")))))
  local handle = assert(work.open(root))
  assert(work.stage(handle, { own = true }))
  if underived == true then
    return handle, "stub-tree-test"
  end
  assert(importer.derive(handle))
  local identities = assert(identity.record_identities(handle.db))
  return handle, identities.compiler
end

--- [`stub.made`] for the duration of `run`, with the stub of
--- cosmic/thing.tl typing `Box.n` as a string, so a tree `run` stages and
--- parses carries that stub.
local function with_a_wrong_stub(run: function())
  local made = stub.made
  stub.made = function(chunk: Ast.Chunk, every?: boolean): stub.Made
    local right = made(chunk, every)
    return { text = (right.text:gsub("n: integer", "n: string")), pruned = right.pruned }
  end
  local ok, raised = pcall(function(): string
    run()
    return ""
  end)
  stub.made = made
  assert(ok, raised)
end

local function test_the_tool_carries_each_standard_module_s_stub(tmp: string)
  local handle, tool = own_tree(tmp)
  local result = assert(importer.compile(handle, tool))
  local dir = assert(build_paths.prepare(handle.root))
  assert(writer.write_result(handle, dir .. "/cosmic.db", result))
  assert(work.close(handle))
  assert(writer.carried(dir .. "/cosmic.db", tmp .. "/carried.db"))
  local db = assert(Sqlite.open(tmp .. "/carried.db"))
  local rows = assert(Sqlite.text_rows(db,
    "SELECT path, CAST(inflate(source) AS TEXT) FROM stubs ORDER BY path"))
  assert(db:close())
  assert(#rows == 1 and rows[1]:text(1) == "cosmic.thing",
    "the stubs carried are those of the standard library's modules alone")
  local parsed = Parser.parse(Lexer.lex(thing, "cosmic/thing.tl"), "cosmic/thing.tl", "tl")
  assert(#parsed.errors == 0)
  assert(rows[1]:text(2) == stub.made(parsed.chunk).text, rows[1]:text(2))
end

--- The places ([`build.syntax_places`]) of the standard library's modules are in the projection and in the tool, for
--- `cosmic lsp`'s go to definition in a project; the tree's other modules, which the working database holds places of
--- too, have none there.
local function test_the_tool_carries_the_places_of_each_standard_module_alone(tmp: string)
  local handle, tool = own_tree(tmp)
  local held = assert(Sqlite.text_rows(handle.db,
    "SELECT count(*) FROM places p JOIN inputs i ON i.source_hash = p.source_hash WHERE i.path = 'build.importer'"))
  assert(assert(held[1]):text(1) ~= "0", "the working database places the tree's other module")
  local result = assert(importer.compile(handle, tool))
  local dir = assert(build_paths.prepare(handle.root))
  assert(writer.write_result(handle, dir .. "/cosmic.db", result))
  assert(work.close(handle))
  assert(writer.carried(dir .. "/cosmic.db", tmp .. "/carried.db"))
  for _, path in ipairs({ dir .. "/cosmic.db", tmp .. "/carried.db" }) do
    local db = assert(Sqlite.open(path))
    local modules = assert(Sqlite.text_rows(db, "SELECT DISTINCT module FROM places"))
    assert(#modules == 1 and assert(modules[1]):text(1) == "cosmic.thing", path)
    local rows = assert(Sqlite.text_rows(db,
      "SELECT line, column, length FROM places WHERE module = 'cosmic.thing' AND symbol = 'thing.Box.n'"))
    local row = assert(rows[1], path .. ": no place of thing.Box.n")
    assert(row:text(1) == "4" and row:text(2) == "5" and row:text(3) == "1",
      row:text(1) .. ":" .. row:text(2) .. "+" .. row:text(3))
    assert(db:close())
  end
end

--- The members ([`build.syntax_members`]) of the standard library's modules, with the docs of their symbols, are in the
--- projection and in the tool, for `cosmic lsp`'s completion in a project; the tree's other modules have none there.
local function test_the_tool_carries_the_members_of_each_standard_module_alone(tmp: string)
  local handle, tool = own_tree(tmp)
  local held = assert(Sqlite.text_rows(handle.db,
    "SELECT count(*) FROM members m JOIN inputs i ON i.source_hash = m.source_hash WHERE i.path = 'build.importer'"))
  assert(assert(held[1]):text(1) ~= "0", "the working database holds the tree's other module's members")
  local result = assert(importer.compile(handle, tool))
  local dir = assert(build_paths.prepare(handle.root))
  assert(writer.write_result(handle, dir .. "/cosmic.db", result))
  assert(work.close(handle))
  assert(writer.carried(dir .. "/cosmic.db", tmp .. "/carried.db"))
  for _, path in ipairs({ dir .. "/cosmic.db", tmp .. "/carried.db" }) do
    local db = assert(Sqlite.open(path))
    local modules = assert(Sqlite.text_rows(db, "SELECT DISTINCT module FROM members"))
    assert(#modules == 1 and assert(modules[1]):text(1) == "cosmic.thing", path)
    local rows = assert(Sqlite.text_rows(db,
      "SELECT kind, scope, type FROM members WHERE module = 'cosmic.thing' AND owner = 'thing.Box' AND name = 'n'"))
    local row = assert(rows[1], path .. ": no member n of thing.Box")
    assert(row:text(1) == "field" and row:text(3) == "integer", row:text(1) .. ":" .. row:text(3))
    local made = assert(Sqlite.text_rows(db,
      "SELECT kind, type FROM members WHERE module = 'cosmic.thing' AND owner = 'thing' AND name = 'box'"))
    assert(assert(made[1], path .. ": no function box"):text(2) == "function(n: integer): thing.Box")
    assert(db:close())
  end
end

local function test_a_stub_that_types_its_module_otherwise_fails_the_build(tmp: string)
  with_a_wrong_stub(function()
    local handle, tool = own_tree(tmp)
    local result, trouble = importer.compile(handle, tool)
    assert(result ~= nil, trouble)
    local refused = table.concat(result.refused, "\n")
    assert(refused:find("cosmic/thing.tl: the stub", 1, true) ~= nil and
        refused:find("types it differently", 1, true) ~= nil, refused)
    assert(work.close(handle))
  end)
end

--- A stale tool rebuilding itself compiles unjudged: it keeps a module
--- its own build.syntax_stub refuses, for the tool it builds to judge.
local function test_an_unjudged_build_keeps_a_module_whose_stub_it_refuses(tmp: string)
  with_a_wrong_stub(function()
    local handle, tool = own_tree(tmp)
    local result, trouble = importer.compile(handle, tool, true)
    assert(result ~= nil, trouble)
    assert(work.close(handle))
  end)
end

local function test_a_projection_missing_a_stub_is_refused(tmp: string)
  local handle, tool = own_tree(tmp)
  local result = assert(importer.compile(handle, tool))
  assert(handle.db:exec("DELETE FROM stubs WHERE source_hash IN " ..
      "(SELECT source_hash FROM inputs WHERE path = 'cosmic.thing')"))
  local dir = assert(build_paths.prepare(handle.root))
  local written, trouble = writer.write_result(handle, dir .. "/cosmic.db", result)
  assert(not written and trouble:find("cosmic.thing: the projection holds no stub", 1, true) ~= nil,
    trouble)
  local _, _ = work.close(handle)
end

--- A global a standard-library module declares would reach a project
--- through a require that a stub of a module requiring it may leave out,
--- which the check of that stub, run where the global is declared already,
--- could not see, so the build refuses it as it does in any module.
local function test_a_standard_module_declaring_a_global_fails_the_build(tmp: string)
  local handle, tool = own_tree(tmp, "global record G\n  n: integer\nend\n" .. thing, true)
  local result, trouble = importer.compile(handle, tool)
  assert(result ~= nil, trouble)
  local refused = table.concat(result.refused, "\n")
  assert(refused:find("cosmic/thing.tl:1:1: `global` declares a global", 1, true) ~= nil, refused)
  assert(work.close(handle))
end

--- A standard-library module that returns a name whose type is inferred fails the build: a project's checker would read
--- all of its statements for the type, as its stub would have to keep them. The checker refuses the return before the stub
--- is made ([`build.syntax_stub`]'s `pruned` is true of every module it passes).
local function test_a_standard_module_with_no_declaration_only_stub_fails_the_build(tmp: string)
  local handle, tool = own_tree(tmp, "local thing = { n = 1 }\nreturn thing\n")
  local result, trouble = importer.compile(handle, tool)
  assert(result ~= nil, trouble)
  local refused = table.concat(result.refused, "\n")
  assert(refused:find("cosmic/thing.tl", 1, true) ~= nil and refused:find("export_not_declared", 1, true) ~= nil, refused)
  assert(work.close(handle))
end

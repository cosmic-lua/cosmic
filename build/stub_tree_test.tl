--- What cosmic's own build does with the stubs ([`build.stub`]) of its
--- standard library: the tool it writes carries each, a stub that types
--- its module otherwise than the source fails the build, and a projection
--- missing one is refused. The fixture is a tree [`build.tree`] takes for
--- cosmic's own.
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local ast = require("build.ast")
local build_paths = require("build.paths")
local identity = require("build.identity")
local importer = require("build.importer")
local stub = require("build.stub")
local teal = require("build.teal")
local work = require("build.work")
local writer = require("build.writer")

local built = assert(teal.load())

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
local function own_tree(tmp: string, source?: string): work.Handle, string
  local root = tmp .. "/tree"
  for _, dir in ipairs({ "core", "build", "cosmic" }) do
    assert(Fs.mkdirs(root .. "/" .. dir))
  end
  assert(Fs.write(root .. "/build/importer.tl", "local record importer\nend\nreturn importer\n"))
  assert(Fs.write(root .. "/cosmic/thing.tl", source or thing))
  local handle = assert(work.open(root))
  assert(work.stage(handle, true))
  assert(importer.derive(handle, true))
  local identities = assert(identity.record_identities(handle.db))
  return handle, identities.compiler
end

--- [`stub.made`] for the duration of `run`, with the stub of
--- cosmic/thing.tl typing `Box.n` as a string, so a tree `run` stages and
--- parses carries that stub.
local function with_a_wrong_stub(run: function())
  local made = stub.made
  stub.made = function(parsed: ast.Parsed, every?: boolean): stub.Made
    local right = made(parsed, every)
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
  assert(rows[1]:text(2) == stub.made((assert(ast.parse(built, thing, "cosmic/thing.tl")))).text,
    rows[1]:text(2))
end

local function test_a_stub_that_types_its_module_otherwise_fails_the_build(tmp: string)
  with_a_wrong_stub(function()
    local handle, tool = own_tree(tmp)
    local result, trouble = importer.compile(handle, tool)
    assert(result == nil and trouble:find("cosmic/thing.tl: the stub", 1, true) ~= nil and
        trouble:find("types it differently", 1, true) ~= nil, trouble)
    assert(work.close(handle))
  end)
end

--- A stale tool rebuilding itself compiles unjudged: it keeps a module
--- its own build.stub refuses, for the tool it builds to judge.
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
  local handle, tool = own_tree(tmp, "global record G\n  n: integer\nend\n" .. thing)
  local result, trouble = importer.compile(handle, tool)
  assert(result == nil and trouble:find("cosmic/thing.tl:1:1: a global is not allowed in a cosmic build",
    1, true) ~= nil, trouble)
  assert(work.close(handle))
end

--- A standard-library module whose stub would keep every statement -- the
--- name it returns is a local whose type is inferred -- fails the build: a
--- project's checker would read all of it.
local function test_a_standard_module_with_no_declaration_only_stub_fails_the_build(tmp: string)
  local handle, tool = own_tree(tmp, "local thing = { n = 1 }\nreturn thing\n")
  local result, trouble = importer.compile(handle, tool)
  assert(result == nil and trouble:find("cosmic/thing.tl: its stub keeps every statement", 1, true) ~= nil,
    trouble)
  assert(work.close(handle))
end

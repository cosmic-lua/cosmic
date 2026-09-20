--- Regression test for the fixed `build.importer` bug: `requires_of`
--- used to find every `require(...)` in a source file's raw TEXT via a
--- regex, which could not tell real code from a string literal or a
--- comment. This proves the AST-based fix does not count a
--- `require("cosmic.<m>")` that only appears as text inside either,
--- while a genuine top-level require is still found.
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local docs = require("build.docs")
local importer = require("build.importer")
local teal = require("build.teal")
local work = require("build.work")
local writer = require("build.writer")

local built, load_trouble = teal.load()
if built == nil then
  error("could not load the compiler: " .. tostring(load_trouble))
end

--- Writes every entry of `files` (filename -> source) into a fresh
--- one-off project directory under `/tmp`, named after `case` and a random
--- suffix so a quickly reused process ID cannot pick up a prior run's cache.
local function write_fixture(case: string, files: {string:string}): string | nil, string
  local root, trouble = Fs.mkdtemp("cosmic-importer-test-" .. case .. "-")
  if root == nil then
    return nil, trouble
  end
  for filename, source in pairs(files) do
    local ok: boolean
    ok, trouble = Fs.write(root .. "/" .. filename, source)
    if not ok then
      return nil, trouble
    end
  end
  return root, ""
end

--- Builds the fixture project at `root` and returns the `requires` of
--- whichever compiled module has import path `path`.
local function requires_of_fixture(root: string, path: string): {string} | nil, string
  local handle, open_trouble = work.open(root)
  if handle == nil then
    return nil, open_trouble
  end
  local staged, stage_trouble = work.stage(handle, false)
  if staged == nil then
    work.close(handle)
    return nil, stage_trouble
  end
  local env, env_trouble = teal.environment_for(built, handle)
  if env == nil then
    work.close(handle)
    return nil, env_trouble
  end
  local result, compile_trouble = importer.compile(handle, built, env, "importer-test")
  work.close(handle)
  if result == nil then
    return nil, compile_trouble
  end
  for _, m in ipairs(result.modules) do
    if m.path == path then
      return m.requires
    end
  end
  return nil, path .. ": not found among compiled modules"
end

--- Stages and compiles one fixture run. Reopening the same root keeps its
--- working database, which lets a test exercise the real warm cache.
local function compile_fixture(root: string): importer.Result | nil, string
  local handle, open_trouble = work.open(root)
  if handle == nil then
    return nil, open_trouble
  end
  local staged, stage_trouble = work.stage(handle, false)
  if staged == nil then
    work.close(handle)
    return nil, stage_trouble
  end
  local env, env_trouble = teal.environment_for(built, handle)
  if env == nil then
    work.close(handle)
    return nil, env_trouble
  end
  local result, compile_trouble = importer.compile(handle, built, env,
    "declaration-cache-test")
  work.close(handle)
  return result, compile_trouble
end

--- A declaration is the source the checker uses for an imported module,
--- including when an implementation with the same import path exists. An
--- edit that changes its public type must invalidate a warm dependent.
local function test_declaration_edit_invalidates_a_warm_dependent()
  local root, write_trouble = write_fixture("declaration-cache", {
    ["main.tl"] = table.concat({
      'local type Types = require("types")',
      "local value: number = 42",
      "local thing: Types.Thing = { value = value }",
      "return thing",
      "",
    }, "\n"),
    ["types.tl"] = "local record Types\n  record Thing\n    value: number\n  end\nend\nreturn Types\n",
    ["types.d.tl"] = "local record Types\n  record Thing\n    value: number\n  end\nend\nreturn Types\n",
  })
  assert(root ~= nil, "could not write fixture: " .. tostring(write_trouble))
  assert(compile_fixture(root))
  assert(Fs.write(root .. "/types.d.tl",
    "local record Types\n  record Thing\n    value: string\n  end\nend\nreturn Types\n"))
  local result, trouble = compile_fixture(root)
  assert(result == nil, "a warm compile reused code checked against the old declaration")
  assert(trouble:find("string", 1, true) ~= nil,
    "the changed declaration did not reach the checker: " .. trouble)
end

--- Type-only imports participate in the same transitive closure. The main
--- module does not name `types`, but changing that declaration must still
--- invalidate `helper` and then main in a warm database.
local function test_declaration_edit_invalidates_transitive_type_only_dependents()
  local root, write_trouble = write_fixture("transitive-declaration-cache", {
    ["main.tl"] = 'local helper = require("helper")\nreturn helper.make()\n',
    ["helper.tl"] = table.concat({
      'local type Types = require("types")',
      "local record helper",
      "  make: function(): Types.Thing",
      "end",
      "function helper.make(): Types.Thing",
      "  return { value = 42 }",
      "end",
      "return helper",
      "",
    }, "\n"),
    ["types.d.tl"] = "local record Types\n  record Thing\n    value: number\n  end\nend\nreturn Types\n",
  })
  assert(root ~= nil, "could not write fixture: " .. tostring(write_trouble))
  assert(compile_fixture(root))
  assert(Fs.write(root .. "/types.d.tl",
    "local record Types\n  record Thing\n    value: string\n  end\nend\nreturn Types\n"))
  local result, trouble = compile_fixture(root)
  assert(result == nil, "a warm compile missed a transitive declaration edit")
  assert(trouble:find("string", 1, true) ~= nil,
    "the transitive declaration did not reach the checker: " .. trouble)
end

--- The declaration controls checking, but the implementation still controls
--- what a test loads. Changing only that implementation must move the test's
--- key so a previously passing verdict is not reused.
local function test_implementation_edit_invalidates_a_declared_dependent()
  local root, write_trouble = write_fixture("declared-implementation-cache", {
    ["dep.tl"] = "return { value = 1 }\n",
    ["dep.d.tl"] = "local record Dep\n  value: number\nend\nreturn Dep\n",
    ["main_test.tl"] = table.concat({
      'local dep = require("dep")',
      "local function test_value()",
      "  assert(dep.value == 1)",
      "end",
      "",
    }, "\n"),
  })
  assert(root ~= nil, "could not write fixture: " .. tostring(write_trouble))
  assert(compile_fixture(root))
  assert(Fs.write(root .. "/dep.tl", "return { value = 2 }\n"))
  local result, trouble = compile_fixture(root)
  assert(result ~= nil, "the edited fixture did not compile: " .. tostring(trouble))
  assert(result.compiled == 2,
    "the implementation edit left its declared dependent cached")
end

--- Mutually recursive declaration types are valid input to the checker. A
--- cache key closes over the graph without rejecting that cycle itself.
local function test_declaration_dependency_keys_allow_cycles()
  local root, write_trouble = write_fixture("declaration-cycle", {
    ["main.tl"] = table.concat({
      'local type A = require("a")',
      "return function(value: A.Value): number",
      "  return value.n",
      "end",
      "",
    }, "\n"),
    ["a.d.tl"] = table.concat({
      'local type B = require("b")',
      "local record A",
      "  record Value",
      "    n: number",
      "    peer: B.Value",
      "  end",
      "end",
      "return A",
      "",
    }, "\n"),
    ["b.d.tl"] = table.concat({
      'local type A = require("a")',
      "local record B",
      "  record Value",
      "    n: number",
      "    peer: A.Value",
      "  end",
      "end",
      "return B",
      "",
    }, "\n"),
  })
  assert(root ~= nil, "could not write fixture: " .. tostring(write_trouble))
  local result, trouble = compile_fixture(root)
  assert(result ~= nil, "declaration cycle was refused: " .. tostring(trouble))
end

--- A `require("cosmic.hidden_dep")` sitting inside a comment or a
--- string literal is not a real import: `requires_of` finds no
--- `require` call at all in this source, even though the raw bytes
--- carry that exact text twice. A regex over source TEXT, with no
--- notion of a comment or a string literal, would match both
--- occurrences and wrongly report `cosmic.hidden_dep` as a dependency.
local function test_ignores_a_require_inside_a_comment_and_a_string()
  local source = table.concat({
    '-- require("cosmic.hidden_dep") is only text in this comment.',
    'local _sample = "require(\\"cosmic.hidden_dep\\")"',
    "local record thing",
    "end",
    "return thing",
    "",
  }, "\n")
  local root, write_trouble = write_fixture("comment-and-string",
    { ["main.tl"] = source })
  assert(root ~= nil, "could not write fixture: " .. tostring(write_trouble))
  local requires, trouble = requires_of_fixture(root, "main")
  assert(requires ~= nil, "compile failed: " .. tostring(trouble))
  assert(#requires == 0,
    "expected no requires, got " .. #requires .. ": " .. table.concat(requires, ", "))
end

--- A genuine top-level require of a real sibling module is still
--- found -- the fix above does not simply stop finding requires at all.
local function test_finds_a_real_top_level_require()
  local root, write_trouble = write_fixture("real-require", {
    ["main.tl"] = 'local dep = require("real_dep")\nreturn dep\n',
    ["real_dep.tl"] = "local record real_dep\nend\nreturn real_dep\n",
  })
  assert(root ~= nil, "could not write fixture: " .. tostring(write_trouble))
  local requires, trouble = requires_of_fixture(root, "main")
  assert(requires ~= nil, "compile failed: " .. tostring(trouble))
  assert(#requires == 1, "expected 1 require, got " .. #requires)
  assert(requires[1] == "real_dep", "got: " .. tostring(requires[1]))
end

--- The tool's hash over a tree, staged fresh: each call is its own
--- run, so a file that has gone since the last call is gone from the
--- fingerprints too.
local function boot_hash_of(root: string): string
  local handle = assert(work.open(root))
  assert(work.stage(handle, true))
  local fingerprint = assert(work.fingerprint(handle))
  work.close(handle)
  return fingerprint.boot
end

--- The compiler identity is what turns source into bytecode: the Teal
--- compiler's and Lua's pins and patches, and the build's own modules
--- in the importer's closure. The standard library the importer runs on
--- is not in it, so an edit there does not recompile the world.
local function test_compiler_identity_follows_the_compiler_not_the_stdlib()
  local root = "/tmp/cosmic-importer-test-identity-" .. tostring(Proc.pid())
  for _, dir in ipairs({ "build", "core", "cosmic", "cmd/cosmic", "patch/tl",
                         "patch/lua", "vendor/tl", "vendor/lua", "bin" }) do
    assert(Fs.mkdirs(root .. "/" .. dir))
  end
  assert(Fs.write(root .. "/vendor/tl/PIN", "version 1"))
  assert(Fs.write(root .. "/vendor/lua/PIN", "version 1"))
  assert(Fs.write(root .. "/patch/tl/01.txt", "a record"))
  assert(Fs.write(root .. "/cosmic/fs.tl", "local record Fs\nend\nreturn Fs\n"))
  local function identities(): {string}
    local handle = assert(work.open(root))
    assert(work.stage(handle, true))
    local found = assert(work.identities(handle))
    work.close(handle)
    return { found.compiler, found.runtime }
  end
  local original = identities()
  assert(Fs.write(root .. "/cosmic/fs.tl", "local record Fs\nend\nreturn Fs\n-- edited\n"))
  local after_stdlib = identities()
  assert(after_stdlib[1] == original[1], "a stdlib edit moved the compiler identity")
  assert(after_stdlib[2] == original[2], "a stdlib edit moved the runtime identity")
  assert(Fs.write(root .. "/patch/tl/01.txt", "another record"))
  local after_patch = identities()
  assert(after_patch[1] ~= original[1], "a compiler patch did not move the compiler identity")
  assert(after_patch[2] ~= original[2], "a compiler patch did not move the runtime identity")
end

--- Embedded library code and tests must invalidate the self-tree guard,
--- just as native code and the compiler's patched sources do. A
--- vendored tree counts through its pin and the records that patch it:
--- it is never edited in place, so its contents are not walked.
local function test_boot_hash_tracks_embedded_inputs()
  local root = "/tmp/cosmic-importer-test-boot-hash-" .. tostring(Proc.pid())
  for _, dir in ipairs({ "build", "core", "cosmic", "cmd/cosmic", "patch/tl", "vendor/tl", "bin" }) do
    assert(Fs.mkdirs(root .. "/" .. dir))
  end
  local paths = {
    "build/main.tl", "core/main.c", "cosmic/example.tl",
    "cosmic/example_test.tl", "patch/tl/example.patch", "vendor/tl/PIN",
    "cmd/cosmic/main.tl", "build.zig", "build.zig.zon", "bin/zig", "bin/zig.pin",
  }
  for _, path in ipairs(paths) do
    assert(Fs.write(root .. "/" .. path, "original"))
  end
  local original = assert(boot_hash_of(root))
  assert(boot_hash_of(root) == original)
  for _, path in ipairs(paths) do
    assert(Fs.write(root .. "/" .. path, "changed"))
    assert(boot_hash_of(root) ~= original, "missed changed input: " .. path)
    assert(Fs.write(root .. "/" .. path, "original"))
    assert(boot_hash_of(root) == original)
  end
  -- Generated output must not make a freshly built tool stale.
  assert(Fs.mkdirs(root .. "/o"))
  assert(Fs.write(root .. "/o/output", "generated"))
  assert(boot_hash_of(root) == original)
  assert(Fs.write(root .. "/cosmic/added.tl", "new module"))
  assert(boot_hash_of(root) ~= original, "missed added module")
  assert(Fs.remove(root .. "/cosmic/added.tl"))
  assert(boot_hash_of(root) == original)
  -- A vendored tree's own files are reached through its pin, never
  -- edited in place, so a stray write there is not an input.
  assert(Fs.write(root .. "/vendor/tl/tl.lua", "edited in place"))
  assert(boot_hash_of(root) == original, "walked into a vendored tree")
end

--- A tree that is not cosmic's own can `require` the standard library
--- and be checked against it: the binary carries every `cosmic.*`
--- source and declaration, and the checker is answered from those
--- rows for a name the tree itself does not hold.
local function test_types_the_standard_library_from_the_binary()
  local root, write_trouble = write_fixture("stdlib", {
    ["main.tl"] = table.concat({
      'local Fs = require("cosmic.fs")',
      "local function exists(path: string): boolean",
      "  return Fs.exists(path)",
      "end",
      "return exists",
      "",
    }, "\n"),
  })
  assert(root ~= nil, "could not write fixture: " .. tostring(write_trouble))
  local requires, trouble = requires_of_fixture(root, "main")
  assert(requires ~= nil, "compile failed: " .. tostring(trouble))
  assert(#requires == 1 and requires[1] == "cosmic.fs",
    "expected cosmic.fs, got " .. table.concat(requires, ", "))
end

--- Project projections retain resolved references to bundled modules even
--- though those targets are absent from the project's own build plan.
local function test_project_keeps_uses_of_bundled_symbols()
  local root = assert(write_fixture("stdlib-uses", {
    ["main.tl"] = table.concat({
      'local disk = require("cosmic.fs")',
      "local function check(path: string): boolean",
      "  return disk.exists(path)",
      "end",
      "return check",
      "",
    }, "\n"),
  }))
  local handle = assert(work.open(root))
  assert(work.stage(handle, false))
  local env = assert(teal.environment_for(built, handle))
  local result = assert(importer.compile(handle, built, env, "importer-test"))
  assert(writer.write_result(handle, root .. "/o/cosmic.db", result))
  local shipped = assert(Sqlite.open(root .. "/o/cosmic.db", false))
  local rows = assert(Sqlite.text_rows(shipped,
    "SELECT module, symbol, from_module, line FROM uses ORDER BY module, symbol"))
  assert(#rows == 1, tostring(#rows))
  assert(rows[1][1] == "cosmic.fs" and rows[1][2] == "exists")
  assert(rows[1][3] == "main" and rows[1][4] == "3")
  local databases: {Sqlite.Handle} = { shipped }
  for _, database in ipairs(Store.databases()) do
    databases[#databases + 1] = database
  end
  local effective = assert(docs.view(databases))
  local definition = assert(docs.lookup(effective, "Fs.exists"))
  assert(#definition == 1 and definition[1].module == "cosmic.fs")
  local uses = assert(docs.uses(effective, "Fs.exists"))
  local found_main = false
  for _, use in ipairs(uses) do
    if use.from_module == "main" and use.line == 3 then found_main = true end
  end
  assert(found_main, "effective uses dropped the project's bundled reference")
  assert(shipped:close())
  work.close(handle)
end

--- The compiler identity closes over what `build.importer` requires, so
--- it is the same whether the working database is fresh or has parsed
--- the tree before -- a boot on an empty `o/` must key its modules
--- exactly as a warm one does, or the two ship different databases.
local function test_compiler_identity_is_the_same_on_a_fresh_database()
  local root = "/tmp/cosmic-importer-test-fresh-identity-" .. tostring(Proc.pid())
  for _, dir in ipairs({ "build", "core", "cosmic", "cmd/cosmic", "patch/tl",
                         "patch/lua", "vendor/tl", "vendor/lua", "bin" }) do
    assert(Fs.mkdirs(root .. "/" .. dir))
  end
  assert(Fs.write(root .. "/vendor/tl/PIN", "version 1"))
  assert(Fs.write(root .. "/vendor/lua/PIN", "version 1"))
  assert(Fs.write(root .. "/build/helper.tl",
    "local record helper\nend\nreturn helper\n"))
  assert(Fs.write(root .. "/build/importer.tl",
    "local helper = require(\"build.helper\")\nlocal record importer\nend\n" ..
    "importer.helper = helper\nreturn importer\n"))
  local function identity(): string
    local handle = assert(work.open(root))
    assert(work.stage(handle, true))
    assert(importer.derive(handle, true, built))
    local found = assert(work.identities(handle))
    work.close(handle)
    return found.compiler
  end
  local fresh = identity()
  local warm = identity()
  assert(warm == fresh, "a second open of the same tree moved the compiler identity")
  assert(Fs.write(root .. "/build/helper.tl",
    "local record helper\nend\nreturn helper\n-- edited\n"))
  assert(identity() ~= fresh,
    "an edit to a module the compiler requires did not move its identity")
end

--- The Lua a module compiles to keeps the line numbers of the Teal it
--- came from: an uncaught error names a Lua line, and the runtime
--- reads that line straight out of the Teal source, so the two must
--- agree on every line a declaration sits on -- however a doc comment
--- or a wrapped signature moved things above it.
local function test_generated_lua_keeps_teal_line_numbers()
  local root = "/tmp/cosmic-importer-test-lines-" .. tostring(Proc.pid())
  assert(Fs.mkdirs(root))
  local source = table.concat({
    "--- A module whose lines are known.",
    "---",
    "--- Three lines of comment, then a blank.",
    "",
    "local record lines",
    "end",
    "",
    "--- Adds, on line eight.",
    "function lines.add(a: integer,",
    "                   b: integer): integer",
    "  return a + b",
    "end",
    "",
    "function lines.fail(): boolean, string",
    "  return nil, \"line fifteen fails\"",
    "end",
    "",
    "return lines",
  }, "\n") .. "\n"
  assert(Fs.write(root .. "/lines.tl", source))
  local handle = assert(work.open(root))
  assert(work.stage(handle, false))
  local env = assert(teal.environment_for(built, handle))
  local result, compile_trouble = importer.compile(handle, built, env, "importer-test")
  assert(result ~= nil, tostring(compile_trouble))
  local lua: string = nil
  for _, m in ipairs(result.modules) do
    if m.path == "lines" then
      lua = m.lua
    end
  end
  work.close(handle)
  assert(lua ~= nil, "lines did not compile")
  local generated: {string} = {}
  for line in (lua .. "\n"):gmatch("(.-)\n") do
    generated[#generated + 1] = line
  end
  assert(generated[9]:find("function lines.add", 1, true), "line 9: " .. generated[9])
  assert(generated[11]:find("return a + b", 1, true), "line 11: " .. generated[11])
  assert(generated[15]:find("line fifteen fails", 1, true), "line 15: " .. generated[15])
end

--- What a parse derived -- docs, requires, tests, the catalog -- is
--- keyed by the source it came from and found again while that source
--- stands. It is right only while the code that derived it stands too:
--- when the analyzer's identity moves, every derived row is forgotten
--- and every source is seen again, so an extractor that learns to see
--- something new sees it in old sources as well.
local function test_a_changed_analyzer_forgets_what_it_derived()
  local root = "/tmp/cosmic-importer-test-analyzer-" .. tostring(Proc.pid())
  for _, dir in ipairs({ "build", "core", "cosmic", "cmd/cosmic", "patch/tl",
                         "patch/lua", "vendor/tl", "vendor/lua", "bin" }) do
    assert(Fs.mkdirs(root .. "/" .. dir))
  end
  assert(Fs.write(root .. "/vendor/tl/PIN", "version 1"))
  assert(Fs.write(root .. "/vendor/lua/PIN", "version 1"))
  assert(Fs.write(root .. "/cosmic/thing.tl",
    "--- A thing.\nlocal record Thing\nend\nreturn Thing\n"))
  local function derived_with(boot_hash: string, plant: boolean): integer
    local handle = assert(work.open(root))
    assert(work.stage(handle, true))
    assert(Sqlite.run(handle.db,
      "INSERT OR REPLACE INTO meta (key, value) VALUES ('boot_hash', ?1)",
      { { text = boot_hash } }))
    if plant then
      -- Under the real source's hash, so only the analyzer sweep, and
      -- not the ordinary collection of rows no input refers to, can
      -- remove it.
      assert(Sqlite.run(handle.db,
        "INSERT INTO docs (source_hash, ordinal, symbol, source_symbol, " ..
        "exported, kind, signature, text, line) SELECT source_hash, 99, " ..
        "'Planted', 'Planted', 0, 'record', '', '', 1 " ..
        "FROM inputs WHERE path = 'cosmic.thing'"))
    end
    assert(importer.derive(handle, true, built))
    local rows = assert(Sqlite.text_rows(handle.db,
      "SELECT count(*) FROM docs WHERE symbol = 'Planted'"))
    work.close(handle)
    return math.tointeger(tonumber(rows[1][1])) or -1
  end
  assert(derived_with("tool-one", false) == 0)
  -- The same analyzer: a planted row survives, as any derived row does.
  assert(derived_with("tool-one", true) == 1, "the same analyzer forgot its rows")
  -- A different analyzer: everything derived is gone and re-derived.
  assert(derived_with("tool-two", false) == 0, "a changed analyzer kept stale rows")
end

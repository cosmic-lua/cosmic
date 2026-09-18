--- End-to-end proof that a `doc/guides/*.md` file becomes an ordinary,
--- runnable `kind = "test"` module through the public pipeline alone:
--- `build.importer.compile` over a fixture tree, never `build.doctest`
--- itself (private to `build/doctest/`; `build/doctest/markdown_test.tl`
--- and `build/doctest/generate_test.tl` cover its own two halves).
--- These fixtures stick to plain Teal -- no `cosmic.*` call -- because a
--- throwaway root has no `cosmic/` tree of its own for the checker's
--- `require` path to resolve a real module's types against; `doc/guides/
--- quickstart.md` in the real tree is what proves a `cosmic.*`-using
--- example, file= blocks included, since it compiles inside the one
--- root that already has cosmic/'s declarations.
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local importer = require("build.importer")
local teal = require("build.teal")

local type Module = importer.Module

local built, load_trouble = teal.load()
if built == nil then
  error("could not load the compiler: " .. tostring(load_trouble))
end

local function doc(parts: {string}): string
  return table.concat(parts, "\n") .. "\n"
end

local matching_doc = doc({
  "# Fixture",
  "",
  "```teal",
  'print("hello")',
  "```",
  "",
  "```output",
  "hello",
  "```",
})

local mismatching_doc = doc({
  "# Fixture",
  "",
  "```teal",
  'print("hello")',
  "```",
  "",
  "```output",
  "goodbye",
  "```",
})

local compile_only_doc = doc({
  "# Fixture",
  "",
  "```teal",
  "print(1 + 1)",
  "```",
})

local skip_doc = doc({
  "# Fixture",
  "",
  "```teal skip=intended",
  'print("not yet")',
  "```",
})

local sh_doc = doc({
  "# Fixture",
  "",
  "```sh",
  "echo hi",
  "```",
  "",
  "```output",
  "hi",
  "```",
})

--- Writes one `doc/guides/fixture.md` into a fresh one-off project
--- root, named after `case` so two fixtures in the same run never
--- collide.
local function write_fixture(case: string, content: string): string | nil, string
  local root = "/tmp/cosmic-doctest-test-" .. case .. "-" .. tostring(Proc.pid())
  local made, trouble = Fs.mkdirs(root .. "/doc/guides")
  if not made then
    return nil, trouble
  end
  local ok, write_trouble = Fs.write(root .. "/doc/guides/fixture.md", content)
  if not ok then
    return nil, write_trouble
  end
  return root, ""
end

local function compile_fixture(root: string): importer.Result | nil, string
  local env, env_trouble = teal.environment_for(built, root)
  if env == nil then
    return nil, env_trouble
  end
  return importer.compile(root, built, env, "doctest-test")
end

local function find_module(result: importer.Result, path: string): Module | nil
  for _, m in ipairs(result.modules) do
    if m.path == path then
      return m
    end
  end
  return nil
end

--- Loads one compiled module's Lua (the test tail already appended,
--- exactly the shape `build.test` itself loads) and returns the table
--- `require` would hand the runner.
local function load_module(m: Module): {string:any}
  local chunk, load_err = load(m.lua, "@" .. m.path, "t")
  assert(chunk ~= nil, "load failed: " .. tostring(load_err))
  return chunk() as {string:any}
end

local function fresh_tmp(): string
  local tmp, trouble = Fs.mkdtemp("cosmic-doctest-test-")
  assert(tmp ~= nil, "could not make a temp dir: " .. tostring(trouble))
  return tmp
end

local function test_an_output_matching_example_actually_passes()
  local root, write_trouble = write_fixture("match", matching_doc)
  assert(root ~= nil, "could not write fixture: " .. tostring(write_trouble))
  local result, trouble = compile_fixture(root)
  assert(result ~= nil, "compile failed: " .. tostring(trouble))
  local m = find_module(result, "doc.guides.fixture")
  assert(m ~= nil, "doc.guides.fixture was not among the compiled modules")
  assert(#m.tests == 1 and m.tests[1] == "test_1",
    "expected exactly test_1, got " .. table.concat(m.tests, ","))
  local mod = load_module(m)
  local fn = mod.test_1 as function(any...): (any...)
  local ok, err = pcall(fn, fresh_tmp())
  assert(ok, "expected the matching example to pass, got: " .. tostring(err))
end

local function test_an_output_mismatching_example_fails_clearly()
  local root, write_trouble = write_fixture("mismatch", mismatching_doc)
  assert(root ~= nil, "could not write fixture: " .. tostring(write_trouble))
  local result, trouble = compile_fixture(root)
  assert(result ~= nil, "compile failed: " .. tostring(trouble))
  local m = find_module(result, "doc.guides.fixture")
  assert(m ~= nil, "doc.guides.fixture was not among the compiled modules")
  local mod = load_module(m)
  local fn = mod.test_1 as function(any...): (any...)
  local ok, err = pcall(fn, fresh_tmp())
  assert(not ok, "expected the mismatching example to fail")
  local message = tostring(err)
  assert(message:find("doc/guides/fixture.md", 1, true) ~= nil,
    "expected the failure to name the doc, got: " .. message)
  assert(message:find("did not match", 1, true) ~= nil,
    "expected the failure to say the output did not match, got: " .. message)
end

local function test_a_no_output_example_compiles_but_is_never_run()
  local root, write_trouble = write_fixture("compile-only", compile_only_doc)
  assert(root ~= nil, "could not write fixture: " .. tostring(write_trouble))
  local result, trouble = compile_fixture(root)
  assert(result ~= nil, "compile failed: " .. tostring(trouble))
  local m = find_module(result, "doc.guides.fixture")
  assert(m ~= nil, "doc.guides.fixture was not among the compiled modules")
  assert(#m.tests == 0, "expected no tests, got " .. #m.tests)
  assert(m.source:find("local function example_1", 1, true) ~= nil,
    "expected example_1 in the generated source:\n" .. m.source)
  -- `with_test_tail` appends a `return` only when `m.tests` is
  -- non-empty, so a module with none returns nothing at all: nothing
  -- outside this file could ever reach `example_1` to call it.
  local chunk, load_err = load(m.lua, "@" .. m.path, "t")
  assert(chunk ~= nil, "load failed: " .. tostring(load_err))
  local produced: any = chunk()
  assert(produced == nil,
    "a module with no runnable examples should return nothing, got: " ..
    tostring(produced))
end

local function test_a_skip_block_compiles_and_defines_nothing()
  local root, write_trouble = write_fixture("skip", skip_doc)
  assert(root ~= nil, "could not write fixture: " .. tostring(write_trouble))
  local result, trouble = compile_fixture(root)
  assert(result ~= nil, "compile failed: " .. tostring(trouble))
  local m = find_module(result, "doc.guides.fixture")
  assert(m ~= nil, "doc.guides.fixture was not among the compiled modules")
  assert(#m.tests == 0, "expected no tests, got " .. #m.tests)
  assert(m.source:find("skipped: intended", 1, true) ~= nil,
    "expected the skip's own reason in the generated source:\n" .. m.source)
end

local function test_an_sh_block_is_refused_at_compile_time()
  local root, write_trouble = write_fixture("sh", sh_doc)
  assert(root ~= nil, "could not write fixture: " .. tostring(write_trouble))
  local result, trouble = compile_fixture(root)
  assert(result == nil, "expected the sh-block doc to be refused")
  assert(trouble:find("doc/guides/fixture.md", 1, true) ~= nil,
    "expected the refusal to name the doc, got: " .. trouble)
  assert(trouble:find("sh blocks are not supported yet", 1, true) ~= nil,
    "expected the refusal to name sh as unsupported, got: " .. trouble)
end

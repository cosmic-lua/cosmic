--- Regression test for the fixed `build.importer` bug: `requires_of`
--- used to find every `require(...)` in a source file's raw TEXT via a
--- regex, which could not tell real code from a string literal or a
--- comment. This proves the AST-based fix does not count a
--- `require("cosmic.<m>")` that only appears as text inside either,
--- while a genuine top-level require is still found.
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local importer = require("build.importer")
local teal = require("build.teal")

local built, load_trouble = teal.load()
if built == nil then
  error("could not load the compiler: " .. tostring(load_trouble))
end

--- Writes every entry of `files` (filename -> source) into a fresh
--- one-off project directory under `/tmp`, named after `case` so two
--- fixtures in the same test run never collide, and returns its root.
local function write_fixture(case: string, files: {string:string}): string | nil, string
  local root = "/tmp/cosmic-importer-test-" .. case .. "-" .. tostring(Proc.pid())
  local made, trouble = Fs.mkdirs(root)
  if not made then
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
  local env, env_trouble = teal.environment_for(built, root)
  if env == nil then
    return nil, env_trouble
  end
  local result, compile_trouble = importer.compile(root, built, env, "importer-test")
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

--- Compiles the fixture project at `root`, whole.
local function compile_fixture(root: string): importer.Result | nil, string
  local env, env_trouble = teal.environment_for(built, root)
  if env == nil then
    return nil, env_trouble
  end
  return importer.compile(root, built, env, "importer-test")
end

--- Every `cmd/<name>/main.tl` is a binary of its own, named by its
--- directory, and the result lists them all in name order -- not only
--- whichever main the import order happened to reach last.
local function test_every_cmd_directory_is_a_binary()
  local main = "local function main(_argv: {integer:string}): integer\n" ..
    "  return 0\nend\nreturn main\n"
  local root, write_trouble = write_fixture("binaries", {
    ["lib.tl"] = "local record lib\nend\nreturn lib\n",
  })
  assert(root ~= nil, "could not write fixture: " .. tostring(write_trouble))
  for _, name in ipairs({ "zeta", "alpha", "mid" }) do
    local made, mkdir_trouble = Fs.mkdirs(root .. "/cmd/" .. name)
    assert(made, tostring(mkdir_trouble))
    local ok, trouble = Fs.write(root .. "/cmd/" .. name .. "/main.tl", main)
    assert(ok, tostring(trouble))
  end
  local result, trouble = compile_fixture(root)
  assert(result ~= nil, "compile failed: " .. tostring(trouble))
  assert(#result.binaries == 3, "expected 3 binaries, got " .. #result.binaries)
  local expected = { "alpha", "mid", "zeta" }
  for i, name in ipairs(expected) do
    local binary = result.binaries[i]
    assert(binary.name == name, "binary " .. i .. ": got " .. binary.name)
    assert(binary.main == "cmd." .. name .. ".main",
      "binary " .. name .. ": got main " .. binary.main)
  end
end

--- A tree with no `cmd/` defines no binaries, and that is no error:
--- a library is a tree too.
local function test_a_tree_without_cmd_defines_no_binaries()
  local root, write_trouble = write_fixture("no-binaries", {
    ["lib.tl"] = "local record lib\nend\nreturn lib\n",
  })
  assert(root ~= nil, "could not write fixture: " .. tostring(write_trouble))
  local result, trouble = compile_fixture(root)
  assert(result ~= nil, "compile failed: " .. tostring(trouble))
  assert(#result.binaries == 0, "expected none, got " .. #result.binaries)
end

--- `cmd/a.b/main.tl` would import as `cmd.a.b.main`, which is where
--- `cmd/a/b/main.tl` sits, so a binary's name may not hold a dot.
local function test_refuses_a_binary_name_with_a_dot()
  local root, write_trouble = write_fixture("dotted-binary", {
    ["lib.tl"] = "local record lib\nend\nreturn lib\n",
  })
  assert(root ~= nil, "could not write fixture: " .. tostring(write_trouble))
  local made, mkdir_trouble = Fs.mkdirs(root .. "/cmd/a.b")
  assert(made, tostring(mkdir_trouble))
  local ok, failure = Fs.write(root .. "/cmd/a.b/main.tl", "return 0\n")
  assert(ok, tostring(failure))
  local result, trouble = compile_fixture(root)
  assert(result == nil, "expected a refusal")
  assert(trouble:find("cmd/a.b/main.tl", 1, true) ~= nil,
    "the refusal should name the file: " .. trouble)
end

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
local work = require("build.work")

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

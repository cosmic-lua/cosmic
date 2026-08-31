local bytecode = require("_make.bytecode")
local check = require("cosmic.check")
local fs = require("cosmic.fs")
local proc = require("cosmic.proc")

--- Where to stage scratch files: each test gets its own TEST_TMPDIR.
local function tmp(name: string): string
  return fs.join(os.getenv("TEST_TMPDIR") or ".", name)
end

--- The runtime to dump with. `compile_staged` takes the artifact's base;
--- here the running binary stands in for it, which is the point of the
--- comparison below -- one Lua, two dumpers, identical bytes.
local function runtime(): string
  local self, err = proc.interpreter()
  assert(self, "cannot find this interpreter: " .. tostring(err))
  return self
end

--- `compile_staged`'s converter is `dump` transcribed into a program the
--- base runtime runs. The two live in different processes and cannot
--- share code, so nothing but a test keeps them in step: run both over
--- the same source on the SAME runtime and require identical bytes. A
--- drift in shebang handling, chunkname, or the strip flag fails here.
local function test_staged_matches_dump()
  local src = "local M = {}\nfunction M.f(a, b) return a + b end\nreturn M\n"
  local dir = tmp("staged")
  assert(fs.make_dirs(fs.join(dir, "cosmic")))
  local stored = "cosmic/sample.lua"
  assert(fs.write(fs.join(dir, stored), src))

  local ok, cerr = bytecode.compile_staged(runtime(), dir, {stored})
  assert(ok, "compile_staged failed: " .. tostring(cerr))

  local staged = check.must(fs.read(fs.join(dir, stored)))
  local direct = check.must(bytecode.dump(src, "/zip/" .. stored))
  assert(staged == direct,
    "compile_staged and dump disagree: " .. #staged .. " vs " .. #direct .. " bytes")
end

--- Both dumpers blank a leading shebang rather than failing on it, so a
--- module that doubles as a script stages like any other.
local function test_staged_handles_shebang()
  local src = "#!/usr/bin/env lua\nreturn 7\n"
  local dir = tmp("shebang")
  assert(fs.make_dirs(dir))
  local stored = "script.lua"
  assert(fs.write(fs.join(dir, stored), src))

  local ok, cerr = bytecode.compile_staged(runtime(), dir, {stored})
  assert(ok, "compile_staged failed: " .. tostring(cerr))

  local staged = check.must(fs.read(fs.join(dir, stored)))
  local direct = check.must(bytecode.dump(src, "/zip/" .. stored))
  assert(staged == direct, "shebang handling differs between the two dumpers")
end

--- The staged bytes must be bytecode, not the source passed through --
--- the failure that a silently skipped conversion would look like.
local function test_staged_is_bytecode()
  local dir = tmp("isbytecode")
  assert(fs.make_dirs(dir))
  assert(fs.write(fs.join(dir, "m.lua"), "return 1\n"))
  assert(bytecode.compile_staged(runtime(), dir, {"m.lua"}))
  local staged = check.must(fs.read(fs.join(dir, "m.lua")))
  assert(staged:sub(1, 4) == "\27Lua",
    "staged file is not bytecode: " .. staged:sub(1, 16))
end

--- An empty payload is a no-op, not a spawn: a project with no modules
--- must not need a runtime at all.
local function test_no_modules_is_a_noop()
  local ok, err = bytecode.compile_staged("/nonexistent/runtime", tmp("empty"), {})
  assert(ok, "empty payload should succeed without spawning: " .. tostring(err))
end

--- A source the runtime cannot load fails the build loudly, naming the
--- chunk, rather than staging something unloadable into the artifact.
local function test_unloadable_source_fails()
  local dir = tmp("bad")
  assert(fs.make_dirs(dir))
  assert(fs.write(fs.join(dir, "bad.lua"), "this is not lua ((\n"))
  local ok, err = bytecode.compile_staged(runtime(), dir, {"bad.lua"})
  assert(not ok, "a syntactically invalid module must not compile")
  assert(err and err:find("bytecode", 1, true),
    "error should name the stage: " .. tostring(err))
end

--- A runtime that is not there fails before any module is touched, and
--- says which path it could not use. This is the copy step rather than
--- the spawn: the runtime is staged as data and has to be copied and
--- made executable first, so a bad path never reaches `child.run`.
local function test_missing_runtime_fails()
  local dir = tmp("noruntime")
  assert(fs.make_dirs(dir))
  assert(fs.write(fs.join(dir, "m.lua"), "return 1\n"))
  local ok, err = bytecode.compile_staged("/nonexistent/runtime", dir, {"m.lua"})
  assert(not ok, "a missing runtime must fail the stage")
  assert(err and err:find("/nonexistent/runtime", 1, true),
    "error should name the runtime: " .. tostring(err))
  local staged = check.must(fs.read(fs.join(dir, "m.lua")))
  assert(staged == "return 1\n", "a failed run must leave the source untouched")
end

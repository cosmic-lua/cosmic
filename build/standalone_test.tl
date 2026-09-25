--- `cosmic --standalone`: one file checked, compiled and run against
--- the binary's own standard library, with no tree around it.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local standalone = require("build.standalone")
local sys = require("cosmic.sys")
local observations = require("build.filesystem_observations")

-- What these tests start is this very program.
observations.confine({ reads = observations.itself() })

--- `standalone.compile` with its cache in the test's own directory, not
--- this user's: a read of that one is no input a verdict can hold.
local function compile(tmp: string, file: string, source: string): standalone.Main | nil, string
  return standalone.compile(file, source, { XDG_CACHE_HOME = tmp .. "/cache" })
end

local function test_a_file_compiles_against_the_standard_library(tmp: string)
  local chunk = assert(compile(tmp, "x.tl", [[
local Fs = require("cosmic.fs")
return function(argv: {string}): integer
  return #argv + Fs.stdout
end
]]))
  local main = assert(standalone.entry(chunk()))
  assert(main({ "a", "b" }) == 3)
end

local function test_only_the_standard_library_can_be_required(tmp: string)
  local chunk, trouble = compile(tmp, "x.tl", 'local w = require("build.work")\nreturn w\n')
  assert(chunk == nil)
  assert(trouble:find("x.tl:1:", 1, true) ~= nil, trouble)
  assert(trouble:find("build.work", 1, true) ~= nil, trouble)
end

local function test_a_type_error_is_reported_with_its_place(tmp: string)
  local chunk, trouble = compile(tmp, "bad.tl", "local x: integer = \"no\"\nreturn x\n")
  assert(chunk == nil)
  assert(trouble:find("bad.tl:1:", 1, true) ~= nil, trouble)
end

--- A standalone file reaching for a removed library is told, for the
--- field it used, what to write instead.
local function test_a_removed_field_names_its_replacement(tmp: string)
  local chunk, trouble = compile(tmp, "old.tl",
    'return function(): integer\n  io.stderr:write("x")\n  return 0\nend\n')
  assert(chunk == nil)
  assert(trouble:find("old.tl:2:3: unknown variable: io -- io.stderr is not available: " ..
    "use Fs.stderr, a descriptor: Fs.put(Fs.stderr, text)", 1, true) ~= nil, trouble)
end

--- A member a `cosmic.*` module no longer has is told, under the alias
--- the file gave the module, what to write instead.
local function test_a_removed_member_names_its_replacement(tmp: string)
  local chunk, trouble = compile(tmp, "old.tl",
    'local Digest = require("cosmic.hash")\nreturn Digest.hex("x")\n')
  assert(chunk == nil)
  assert(trouble:find("old.tl:2:15: invalid key 'hex' in record 'Digest' of type Digest " ..
    "-- Digest.hex was removed: use Codec.hex(digest)", 1, true) ~= nil, trouble)
end

--- A `<const>` binding, and a second alias of it, are the module still.
local function test_a_removed_member_is_named_through_const_and_alias(tmp: string)
  local chunk, trouble = compile(tmp, "old.tl",
    'local Zip <const> = require("cosmic.zip")\nlocal Z = Zip\n' ..
    'return Z.list("a.zip")\n')
  assert(chunk == nil)
  assert(trouble:find("old.tl:3:10: invalid key 'list' in record 'Z' of type Zip " ..
    "-- Z.list was removed: use Archive.list(path)", 1, true) ~= nil, trouble)
end

--- A type a `cosmic.*` module no longer declares is told its new name,
--- under the alias the file gave the module; a type the module never
--- declared is told nothing more.
local function test_a_renamed_type_names_its_replacement(tmp: string)
  local chunk, trouble = compile(tmp, "old.tl",
    'local Z <const> = require("cosmic.zip")\n' ..
    'local function f(r: Z.ZipReader): integer\n  return r and 1 or 0\nend\n' ..
    'return f\n')
  assert(chunk == nil)
  assert(trouble:find("old.tl:2:21: unknown type Z.ZipReader " ..
    "-- Z.ZipReader was removed: use Zip.Reader", 1, true) ~= nil, trouble)
  chunk, trouble = compile(tmp, "new.tl",
    'local Zip = require("cosmic.zip")\n' ..
    'local function f(r: Zip.Nothing): integer\n  return r and 1 or 0\nend\n' ..
    'return f\n')
  assert(chunk == nil)
  assert(trouble:find("unknown type Zip.Nothing", 1, true) ~= nil, trouble)
  assert(trouble:find("was removed", 1, true) == nil, trouble)
  -- `list` is a removed function, never a type: nothing is offered.
  chunk, trouble = compile(tmp, "fn.tl",
    'local Zip = require("cosmic.zip")\n' ..
    'local function f(r: Zip.list): integer\n  return r and 1 or 0\nend\n' ..
    'return f\n')
  assert(chunk == nil)
  assert(trouble:find("unknown type Zip.list", 1, true) ~= nil, trouble)
  assert(trouble:find("was removed", 1, true) == nil, trouble)
end

--- A record of the file's own named like a module's alias is not that
--- module: no replacement is offered for its missing field.
local function test_a_shadowing_record_is_not_told_a_replacement(tmp: string)
  local chunk, trouble = compile(tmp, "old.tl",
    'local Zip = require("cosmic.zip")\nlocal record R\n  x: integer\nend\n' ..
    'local function f(Zip: R): integer\n  return Zip.list\nend\n' ..
    'return { f = f, zip = Zip }\n')
  assert(chunk == nil)
  assert(trouble:find("invalid key 'list' in record 'Zip' of type R", 1, true) ~= nil, trouble)
  assert(trouble:find("was removed", 1, true) == nil, trouble)
end

local function test_a_record_with_main_is_an_entry_point()
  local function main(): integer
    return 7
  end
  assert(standalone.entry({ main = main }) == main)
  assert(standalone.entry(main) == main)
  assert(standalone.entry({ other = main }) == nil)
  assert(standalone.entry(42) == nil)
end

--- End to end, from a directory holding no tree: the file gets its own
--- path at argv[0] and what follows it, its exit code is the process's,
--- and nothing is written beside it -- no `o/`.
local function test_a_run_writes_nothing_and_passes_its_arguments(tmp: string)
  local script = tmp .. "/script.tl"
  assert(Fs.write(script, [[
local Fs = require("cosmic.fs")
local record Script
  main: function({string}): integer
end
Script.main = function(argv: {string}): integer
  Fs.put(Fs.stdout, argv[0] .. "|" .. table.concat(argv, ",") .. "\n")
  return 5
end
return Script
]]))
  local cosmic = assert(Proc.executable())
  local result = assert(Child.run({ cosmic, "--standalone", script, "one", "two" }, {
    cwd = tmp, stdout = "capture", stderr = "capture", timeout_ms = 30000,
  }))
  assert(result.code == 5, tostring(result.stderr))
  assert(result.stdout == script .. "|one,two\n", tostring(result.stdout))
  local names = assert(Fs.list(tmp))
  assert(#names == 1 and names[1] == "script.tl", "a standalone run wrote beside the file")
end

--- The compile cache is trusted when read back, so it is kept only in
--- a directory no one else can write: never a `/tmp` fallback when no
--- cache home is set, and not in one others could have planted Lua in.
local function test_the_compile_cache_is_kept_only_where_others_cannot_write(tmp: string)
  local script = tmp .. "/script.tl"
  assert(Fs.write(script, "return function(_argv: {string}): integer return 3 end\n"))
  local cosmic = assert(Proc.executable())
  local function run(env: {string:string}): integer
    local result = assert(Child.run({ cosmic, "--standalone", script }, {
      env = env, stdout = "capture", stderr = "capture", timeout_ms = 30000,
    }))
    return result.code
  end
  local cache = tmp .. "/cache"
  assert(run({ XDG_CACHE_HOME = cache }) == 3)
  local kept = assert(Fs.list(cache .. "/cosmic/standalone"))
  assert(#kept == 1, tostring(#kept))
  local st = assert(Fs.stat(cache .. "/cosmic/standalone/" .. kept[1]))
  assert(st.mode & 0x1ff == 0x180, tostring(st.mode))
  -- a planted file in a directory others can write is never run
  assert(Fs.write(cache .. "/cosmic/standalone/" .. kept[1], "return function() return 9 end"))
  assert(sys.chmod(cache .. "/cosmic/standalone", 0x1ff))
  assert(run({ XDG_CACHE_HOME = cache }) == 3)
  -- with no cache home at all, it still runs, compiling afresh
  assert(run({}) == 3)
end

--- What main returns is judged as a file run's is: a whole number
--- outside 0-255, text or a float that is not whole exits 2, the
--- complaint naming the file rather than cmd.cosmic.main; one that has
--- a whole value is that value.
local function test_a_main_that_returns_no_exit_status_is_refused(tmp: string)
  local cosmic = assert(Proc.executable())
  local function run(returned: string): Child.Result
    local script = tmp .. "/script.tl"
    assert(Fs.write(script, "return function(_argv: {string}): any\n  return " ..
      returned .. "\nend\n"))
    return (assert(Child.run({ cosmic, "--standalone", script }, {
      env = { XDG_CACHE_HOME = tmp .. "/cache" },
      stdout = "capture", stderr = "capture", timeout_ms = 30000,
    })))
  end
  for returned, shown in pairs({ ["300"] = "300", ["\"three\""] = "\"three\"",
      ["1.5"] = "1.5" } as {string:string}) do
    local result = run(returned)
    assert(result.code == 2, returned .. " exited " .. tostring(result.code) .. ": " ..
      tostring(result.stderr))
    local complaint = "cosmic: " .. tmp .. "/script.tl returned " .. shown ..
      ", not an exit status 0-255"
    assert(tostring(result.stderr):find(complaint, 1, true) ~= nil, tostring(result.stderr))
  end
  local whole = run("4.0")
  assert(whole.code == 4, tostring(whole.stderr))
end

local function test_a_run_without_a_file_is_a_usage_error()
  local cosmic = assert(Proc.executable())
  local result = assert(Child.run({ cosmic, "--standalone" }, {
    stdout = "capture", stderr = "capture", timeout_ms = 30000,
  }))
  assert(result.code == 2)
  assert(tostring(result.stderr):find("usage", 1, true) ~= nil)
end

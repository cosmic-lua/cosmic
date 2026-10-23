--- Proves `cosmic build` writes a portable executable: the one file that
--- carries a core for every target, made of the running tool's own prefix,
--- and what reads one back. It needs a tool of every core
--- (`bin/zig build boot -Dboot-cores=all`): a bare boot leaves placeholders
--- where the other cores go, and `cosmic build` refuses to make a program of
--- them (`embed_test.tl` proves it), so these are skipped there, naming
--- `all_cores`, and CI, whose every leg promises it, fails the run that
--- skips them. The programs `--host` writes are in `embed_tool_test.tl` and
--- the data a refresh puts in either layout in `refresh_store_test.tl`.

local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local artifact = require("build.artifact")
local embed = require("build.embed")
local invoke = require("build.invoke")
local refresh = require("build.refresh")
local Test = require("cosmic.test")
local String = require("cosmic.string")
local build_paths = require("build.paths")

--- This program's database, which every executable's is joined from
--- (`store`: [`embed.database`] reads every `cosmic.*` module's rows), the
--- vendored bundle a refresh reads, and the tool itself.
Test.policy{
  profiles = { "cosmic" },
  grants = { { path = "o/bin", letters = "rx" }, { path = "o/cosmic.db", letters = "r" },
    { path = "vendor/cacert/", letters = "r" } },
  requires = { "all_cores" },
}

local main_source = [[
local Fs = require("cosmic.fs")
local greet = require("greet")

return function(argv: {string}): integer
  Fs.put(Fs.stdout, greet.hello(argv[1] or "world") .. "\n")
  return #argv
end
]]

local greet_source = [[
local record greet
end

function greet.hello(name: string): string
  return "hello, " .. name
end

return greet
]]

--- Writes the fixture project under `root`, with `names` as the programs it
--- holds beside `hello`.
local function write_project(root: string, names?: {string})
  assert(Fs.mkdirs(root .. "/cmd/hello"))
  assert(Fs.write(root .. "/cmd/hello/main.tl", main_source))
  assert(Fs.write(root .. "/greet.tl", greet_source))
  for _, name in ipairs(names or {}) do
    assert(Fs.mkdirs(root .. "/cmd/" .. name))
    assert(Fs.write(root .. "/cmd/" .. name .. "/main.tl", "return function(): integer return 0 end\n"))
  end
end

--- `root`'s build directory ([`build.paths`]).
local function build_dir(root: string): string
  return (assert(build_paths.prepare(root)))
end

local function test_a_project_becomes_an_executable(tmp: string)
  write_project(tmp)
  local names, trouble = embed.tree(tmp)
  assert(names ~= nil, trouble)
  assert(#names == 1 and names[1] == "hello")

  local out = build_dir(tmp) .. "/bin/hello"
  local st = assert(Fs.stat(out))
  assert(st.mode & 0x49 == 0x49, "the executable bit is set for everyone")
  local bytes = assert(Fs.read(out))
  local prefix = assert(artifact.trusted_prefix())
  assert(bytes:sub(1, 10) == "#!/bin/sh\n",
    "the portable file has its script entry")
  assert(String.starts_with(bytes, prefix),
    "the portable file reuses the exact retained prefix")
  assert(not artifact.host_only(prefix), "the prefix holds a core for every target")
  local database = assert(embed.database(build_dir(tmp) .. "/cosmic.db", "cmd.hello.main"))
  assert(bytes:sub(#prefix + 1, #prefix + #database) == database,
    "the database behind the prefix is the one a host program carries")
end

--- `cosmic build` names each portable program it wrote, and a path narrows
--- it to the programs under it.
local function test_build_writes_the_portable_programs_under_a_path(tmp: string)
  write_project(tmp, { "bye" })
  local built = invoke.run({ "build", "./cmd/bye/" }, { cwd = tmp,
    env = { COSMIC_BUILD_CACHE = "0", COSMIC_BUILD_HOME = assert(Env.get("COSMIC_BUILD_HOME")) } })
  assert(built.code == 0, built.stdout .. built.stderr)
  local bin = build_dir(tmp) .. "/bin"
  assert(built.stdout == bin .. "/bye\n", built.stdout)
  assert(Fs.exists(bin .. "/hello") ~= true, "a program outside the path was written")
  assert(String.starts_with(assert(Fs.read(bin .. "/bye")), "#!/bin/sh\n"))
end

--- Refreshing a portable program with the bundle it carries makes it again,
--- byte for byte, as it makes a host program: the launcher and every core
--- stay as they were.
local function test_a_portable_program_is_refreshed_as_it_was(tmp: string)
  write_project(tmp)
  assert(embed.tree(tmp))
  local path = build_dir(tmp) .. "/bin/hello"
  local cacert: refresh.Dataset | nil
  for _, dataset in ipairs(refresh.datasets) do
    if dataset.name == "cacert" then cacert = dataset end
  end
  local out = tmp .. "/refreshed"
  local lines = assert(refresh.binary(path, out, { assert(cacert) },
    { cacert = "vendor/cacert/certdata.txt" }))
  local first = assert(lines[1])
  assert(first:find("(as it was)", 1, true) ~= nil, first)
  assert(Fs.read(out) == Fs.read(path), "a refresh to the carried release changed the program")
end

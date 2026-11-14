--- `cosmic build` on a tree that writes no executable -- a library, or
--- cosmic's own tree -- and a core that holds no program. None of these
--- copies this program's database into one, so none needs `tool`: the
--- bare core is the running one, read through [`artifact.trusted_core`]
--- and keyed with the runtime's identity, as [`core/boot_test.tl`]'s is.
--- The executables it writes are proved in `embed_tool_test.tl`.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local artifact = require("build.artifact")
local embed = require("build.embed")
local tree = require("build.tree")
local Clock = require("cosmic.clock")
local support = require("build.test_support_fixture")

local greet_source = [[
local record greet
end

function greet.hello(name: string): string
  return "hello, " .. name
end

return greet
]]

local function test_a_tree_without_a_main_builds_and_writes_nothing(tmp: string)
  assert(Fs.write(tmp .. "/greet.tl", greet_source))
  local names, trouble = embed.tree(tmp)
  assert(names ~= nil, trouble)
  assert(#names == 0, "a library tree has no executable to write")
  local database_exists, exists_trouble = Fs.exists(support.build_dir(tmp) .. "/cosmic.db")
  assert(database_exists ~= nil, exists_trouble)
  assert(database_exists, "but it was built")
  assert(Fs.exists(support.build_dir(tmp) .. "/bin") == false)
end

local function test_cosmic_s_own_tree_is_refused(tmp: string)
  assert(Fs.mkdirs(tmp .. "/core"))
  assert(Fs.mkdirs(tmp .. "/build"))
  assert(Fs.write(tmp .. "/build/importer.tl", "return {}\n"))
  local names, trouble = embed.tree(tmp, nil, nil, nil, (assert(tree.built_from(tmp))))
  assert(names == nil)
  assert(trouble:find("bin/zig build boot", 1, true) ~= nil, trouble)
end

--- In cosmic's own tree the program is the tool: its path in the tree's build directory is answered, and `out`
--- is given a copy of it, executable, in a directory made for it.
local function test_cosmic_s_own_tool_is_named_and_copied(tmp: string)
  local root = tmp .. "/tree"
  assert(Fs.mkdirs(root))
  local tool = support.build_dir(root) .. "/bin/cosmic"
  assert(Fs.mkdirs(Fs.dirname(tool)))
  assert(Fs.write(tool, "#!/bin/sh\necho the tool\n", 0x1ed))
  local named, trouble = embed.own_tool(root)
  assert(named == tool, trouble)
  assert(Fs.exists(root .. "/cosmic") == false, "with no out, nothing is written")
  local out = tmp .. "/dist/nested"
  local again, copy_trouble = embed.own_tool(root, out)
  assert(again == tool, copy_trouble)
  assert(assert(Fs.read(out .. "/cosmic")) == assert(Fs.read(tool)), "the copy differs from the tool")
  assert(assert(Fs.stat(out .. "/cosmic")).mode & 0x49 == 0x49, "the copy is not executable")
end

--- A tree no boot has written a tool for names none, says which boot writes it, and writes no copy.
local function test_cosmic_s_own_tree_with_no_tool_names_the_boot(tmp: string)
  local root = tmp .. "/tree"
  assert(Fs.mkdirs(root))
  local out = tmp .. "/dist"
  local named, trouble = embed.own_tool(root, out)
  assert(named == nil, "a tool was named where there is none")
  assert(trouble:find(support.build_dir(root) .. "/bin/cosmic", 1, true) ~= nil and
      trouble:find("bin/zig build boot", 1, true) ~= nil, trouble)
  assert(Fs.exists(out) == false, "a directory was made for a copy that was not written")
end

--- A tool booted for the host's core alone makes no portable program: it
--- would run on this host only, and nothing would say so. It names the boot
--- that carries every core and the `--host` it can do; any other prefix is
--- given as it is (`embed_portable_tool_test.tl` proves a tool of every
--- core makes a program of it), and one there is none of says why.
local function test_a_host_only_tool_refuses_to_make_a_portable_program()
  local records = "1\t1\trelease\tx86_64-linux-musl\tLinux\tx86_64\n" ..
    "2\t1\trelease\taarch64-linux-musl\tLinux\taarch64\n"
  local own = "\127ELF a core of this host"
  local whole = assert(artifact.prefix(records, { ["x86_64-linux-musl"] = own,
    ["aarch64-linux-musl"] = "\127ELF a core of another" }))
  local only = assert(artifact.prefix(records, { ["x86_64-linux-musl"] = own,
    ["aarch64-linux-musl"] = artifact.placeholder("aarch64-linux-musl") }))
  assert(embed.portable_prefix(whole, "") == whole, "a prefix of every core was refused")
  local prefix, trouble = embed.portable_prefix(only, "")
  assert(prefix == nil, "a host-only tool gave a prefix")
  assert(trouble:find("-Dboot-cores=all", 1, true) ~= nil, trouble)
  assert(trouble:find("--host", 1, true) ~= nil, trouble)
  local none, why = embed.portable_prefix(nil, "no retained portable artifact")
  assert(none == nil and why == "no retained portable artifact", why)
end

local function run_program(path: string): Child.Result
  return (assert(Child.run({ path }, {
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) })))
end

--- A core started on its own, with no program inside and no tree to
--- boot, says so and exits rather than running anything.
local function test_a_bare_core_refuses_to_run(tmp: string)
  local core = assert(artifact.trusted_core())
  local path = tmp .. "/cosmic-core"
  assert(Fs.write(path, core.bytes, 0x1ed))
  local r = run_program(path)
  assert(r.code == 2, "exit " .. tostring(r.code))
  assert((assert(r.stderr)):find("no database attached", 1, true), tostring(r.stderr))
end

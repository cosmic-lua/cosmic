--- bin/cosmic, the checkout's entrypoint, run in a checkout of its own
--- whose bootstrap, resolver, bin/zig and tool are shell stand-ins, so
--- what is held is the entrypoint's own part: the tool it runs is the one
--- the resolver names, in the caller's directory, with the arguments and
--- exit status passed through, and a boot where there is none.
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")

--- The two scripts under test; the system's paths, for the shell they
--- run in and the commands they call.
Test.policy{
  profiles = { "system" },
  grants = {
    { path = "bin/cosmic", letters = "r" },
    { path = "bin/cosmic-bootstrap", letters = "r" },
    { path = "/bin/sh", letters = "r" },
  },
  env = { "PATH" },
  requires = { "path:/bin/sh" },
}

--- A checkout at `tmp/a tree` (a space in its path, so a word split
--- anywhere shows), holding the entrypoint and the bootstrap script, and
--- a stand-in for the bootstrap cosmic that answers the resolver's
--- question as build/paths.tl does today: `<root>/o`. Its bin/zig
--- records how it was called and, unless `BOOT_FAILS` is set, writes the
--- tool; the tool prints its directory and arguments and exits with
--- `TOOL_STATUS`.
local function checkout(tmp: string): string, string
  -- Physical, as the stand-ins' `pwd -P` print it.
  local root = assert(Fs.absolute(tmp)) .. "/a tree"
  assert(Fs.mkdirs(root .. "/bin") and Fs.mkdirs(root .. "/build") and Fs.mkdirs(root .. "/sub/dir"))
  for _, name in ipairs({ "cosmic", "cosmic-bootstrap" }) do
    assert(Fs.write(root .. "/bin/" .. name, (assert(Fs.read("bin/" .. name))), 0x1ed))
  end
  assert(Fs.write(root .. "/build/paths.tl", "-- read by the stand-in, never run\n"))
  local bootstrap = tmp .. "/bootstrap cosmic"
  assert(Fs.write(bootstrap, [[#!/bin/sh
[ "$1" = --standalone ] && [ "$2" = "$3/build/paths.tl" ] && [ "$#" -eq 3 ] || exit 64
printf '%s/o\n' "$3"
]], 0x1ed))
  assert(Fs.write(root .. "/bin/zig", [[#!/bin/sh
printf '%s|%s\n' "$(pwd -P)" "$*" >> "$ZIG_CALLS"
echo 'boot: what zig says'
[ -z "${BOOT_FAILS:-}" ] || exit 5
mkdir -p o/bin
cat > o/bin/cosmic <<'EOF'
#!/bin/sh
printf 'tool in %s:' "$(pwd -P)"
for word in "$@"; do printf ' [%s]' "$word"; done
echo
exit "${TOOL_STATUS:-0}"
EOF
chmod +x o/bin/cosmic
]], 0x1ed))
  return root, bootstrap
end

--- Runs `root`'s bin/cosmic with `args` in `cwd`, with `extra` in its
--- environment.
local function run(tmp: string, root: string, bootstrap: string, cwd: string,
                   args: {string}, extra?: {string:string}): Child.Result
  local env: {string:string} = {
    PATH = assert(Env.get("PATH")), COSMIC_BOOTSTRAP = bootstrap, ZIG_CALLS = tmp .. "/zig calls",
  }
  for name, value in pairs(extra or {}) do env[name] = value end
  local argv = { root .. "/bin/cosmic" }
  for _, word in ipairs(args) do argv[#argv + 1] = word end
  local result, trouble = Child.run(argv, { cwd = cwd, env = env, stdout = "capture",
    stderr = "capture", timeout_ns = Clock.seconds(20) })
  return (assert(result, trouble))
end

local function zig_calls(tmp: string): string
  return Fs.read(tmp .. "/zig calls") or ""
end

--- With no tool, it boots from the tree's root, the boot's output on
--- stderr alone, then runs the tool in the caller's directory with the
--- arguments as given and answers its exit status; with the tool there,
--- it boots no more.
local function test_it_boots_once_then_runs_the_tool_where_it_was_called(tmp: string)
  local root, bootstrap = checkout(tmp)
  local cwd = root .. "/sub/dir"
  local result = run(tmp, root, bootstrap, cwd, { "fix", "two words", "" }, { TOOL_STATUS = "7" })
  assert(result.code == 7, tostring(result.stderr))
  assert(result.stdout == "tool in " .. cwd .. ": [fix] [two words] []\n", tostring(result.stdout))
  assert(tostring(result.stderr):find("boot: what zig says", 1, true), tostring(result.stderr))
  assert(zig_calls(tmp) == root .. "|build boot\n", zig_calls(tmp))
  local again = run(tmp, root, bootstrap, root, { "test" })
  assert(again.code == 0 and again.stdout == "tool in " .. root .. ": [test]\n", tostring(again.stdout))
  assert(again.stderr == "", tostring(again.stderr))
  assert(zig_calls(tmp) == root .. "|build boot\n", zig_calls(tmp))
end

--- COSMIC_AUTO_BOOT=0 refuses to boot, exiting 3 and saying how to.
local function test_it_refuses_to_boot_under_cosmic_auto_boot_0(tmp: string)
  local root, bootstrap = checkout(tmp)
  local result = run(tmp, root, bootstrap, root, { "test" }, { COSMIC_AUTO_BOOT = "0" })
  assert(result.code == 3, tostring(result.stderr))
  assert(result.stdout == "", tostring(result.stdout))
  assert(tostring(result.stderr):find("COSMIC_AUTO_BOOT=0", 1, true) and
      tostring(result.stderr):find("bin/zig build boot", 1, true), tostring(result.stderr))
  assert(zig_calls(tmp) == "", zig_calls(tmp))
end

--- A boot that fails is answered with its status, and no tool runs.
local function test_a_failed_boot_answers_its_status(tmp: string)
  local root, bootstrap = checkout(tmp)
  local result = run(tmp, root, bootstrap, root, { "test" }, { BOOT_FAILS = "1" })
  assert(result.code == 5, tostring(result.stderr))
  assert(result.stdout == "", tostring(result.stdout))
  assert(tostring(result.stderr):find("bin/zig build boot failed (status 5)", 1, true),
    tostring(result.stderr))
end

--- The bootstrap refuses the entrypoint as its stand-in, which would ask
--- itself where the tool is without end.
local function test_the_entrypoint_is_no_bootstrap_stand_in(tmp: string)
  local root, _ = checkout(tmp)
  local result = run(tmp, root, root .. "/bin/cosmic", root, { "test" })
  assert(result.code == 1, tostring(result.stderr))
  assert(tostring(result.stderr):find("is this checkout's entrypoint", 1, true), tostring(result.stderr))
  assert(zig_calls(tmp) == "", zig_calls(tmp))
end

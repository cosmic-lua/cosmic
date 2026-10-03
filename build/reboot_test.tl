local Fs = require("cosmic.fs")
local Store = require("cosmic.store")
local type Log = require("cosmic.log")
local reboot = require("build.reboot")
local rebuild_lock = require("build.rebuild_lock")
local stand_in = require("build.stand_in")
local verdict = require("build.verdict")
local work = require("build.work")

--- A core change boots unless COSMIC_AUTO_BOOT is "0".
local function test_auto_boot_unless_told_not_to()
  assert(reboot.auto_boot({}))
  assert(reboot.auto_boot({ COSMIC_AUTO_BOOT = "1" }))
  assert(not reboot.auto_boot({ COSMIC_AUTO_BOOT = "0" }))
end

--- A tree whose bin/zig is a stand-in that records how it was run and
--- exits with `status`.
local function tree_with_zig(tmp: string, status: integer): string
  local root = tmp .. "/tree"
  assert(Fs.mkdirs(root .. "/bin"))
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  assert(stand_in.place(probe, root .. "/bin/zig",
    "write $DIR/ran $@\nprint built\nexit " .. tostring(status)))
  return root
end

--- A boot that fails is reported, not re-entered.
local function test_boot_into_reports_a_failed_boot(tmp: string)
  local root = tree_with_zig(tmp, 1)
  local trouble = reboot.boot_into(root, { [0] = "cosmic", "test" }, {})
  assert(trouble:find("bin/zig build boot failed", 1, true), trouble)
  assert(Fs.read(root .. "/bin/ran") == "build boot\n")
end

--- The boot a run holding the rebuild lock starts is handed that lock
--- (build/zig.tl takes it otherwise, and would wait on its parent for
--- good); one started by a run that holds none is handed nothing.
local function test_boot_into_hands_on_the_lock_it_holds(tmp: string)
  local root = tmp .. "/tree"
  assert(Fs.mkdirs(root .. "/bin") and Fs.mkdirs(root .. "/o"))
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  assert(stand_in.place(probe, root .. "/bin/zig",
    "write $DIR/handed [$COSMIC_REBUILD_LOCK_HANDED]\nexit 1"))
  local _ = reboot.boot_into(root, { [0] = "cosmic", "test" }, {})
  assert(Fs.read(root .. "/bin/handed") == "[]\n", Fs.read(root .. "/bin/handed"))
  assert(rebuild_lock.take(root, 0, "test") == "held")
  local trouble = reboot.boot_into(root, { [0] = "cosmic", "test" }, {})
  rebuild_lock.release()
  assert(trouble:find("bin/zig build boot failed", 1, true), trouble)
  assert(Fs.read(root .. "/bin/handed") == "[" .. root .. "/o/rebuild.lock]\n",
    Fs.read(root .. "/bin/handed"))
end

--- After a boot, the tool it wrote is what runs the command again; one
--- that is not there is reported rather than silently skipped.
local function test_boot_into_enters_the_booted_tool(tmp: string)
  local root = tree_with_zig(tmp, 0)
  local trouble = reboot.boot_into(root, { [0] = "cosmic", "test" }, {})
  assert(Fs.read(root .. "/bin/ran") == "build boot\n")
  assert(trouble ~= "", "boot_into returned without a reason")
end

--- A tool still stale after its own boot refuses instead of booting
--- again. Its bin/zig cannot start, so no stand-in need be built: a
--- boot would have been refused with another reason.
local function test_boot_into_boots_once(tmp: string)
  local root = tmp .. "/tree"
  assert(Fs.mkdirs(root .. "/bin"))
  assert(Fs.write(root .. "/bin/zig", "#!/nonexistent/interpreter\n", 0x1ed))
  local trouble = reboot.boot_into(root, { [0] = "cosmic", "test" },
    { COSMIC_REBOOTED = "1" })
  assert(trouble == "the tool is still stale after a reboot", trouble)
end

--- The tree's compiler has moved from the tool's when their identities
--- differ; an identity that could not be taken, on either side, is no
--- evidence of a move.
local function test_compiler_moved_compares_identities()
  assert(reboot.compiler_moved("old", "new"))
  assert(not reboot.compiler_moved("same", "same"))
  assert(not reboot.compiler_moved(nil, "new"))
  assert(not reboot.compiler_moved("old", nil))
  assert(not reboot.compiler_moved(nil, nil))
end

-- TODO: `into`'s second answer, its nil fallback for the tree's compiler
-- identity and `guard`'s passing it to `rebuild_failed` are untested here
-- (forcing `moved` to false would pass): add a ci/fixtures/self_rebuild_test.tl
-- case that stages a tree whose compiler module changed and whose rebuild
-- fails with the stale tool, asserting a boot is attempted, and exit 3 with
-- COSMIC_AUTO_BOOT=0.

--- A rebuild whose compile failed because the compiler moved boots, as a
--- core change does, and re-enters the tool the boot wrote.
local function test_rebuild_failed_boots_when_the_compiler_moved(tmp: string)
  local root = tree_with_zig(tmp, 1)
  local code = reboot.rebuild_failed(root, { [0] = "cosmic", "test" },
    "checker: T (unresolved generic)", true, {})
  assert(code == 3, code)
  assert(Fs.read(root .. "/bin/ran") == "build boot\n")
end

--- A boot that then fails says the compile failure it was to mend, which
--- would otherwise be lost to the boot's own trouble.
local function test_rebuild_failed_says_the_compile_failure_of_a_failed_boot(tmp: string)
  local root = tree_with_zig(tmp, 1)
  local said: {string} = {}
  local log = verdict.log
  local complain = log.complain
  log.complain = function(_: Log.Logger, line: string): boolean, string
    table.insert(said, line)
    return true, ""
  end
  local ran, code = pcall(reboot.rebuild_failed, root, { [0] = "cosmic", "test" },
    "checker: T (unresolved generic)", true, {})
  log.complain = complain
  assert(ran, tostring(code))
  assert(code == 3, tostring(code))
  local all = table.concat(said, "\n")
  assert(all:find("checker: T (unresolved generic)", 1, true), all)
  assert(all:find("bin/zig build boot failed", 1, true), all)
end

--- A failure while the compiler has not moved is the tree's own error:
--- nothing boots.
local function test_rebuild_failed_does_not_boot_while_the_compiler_stands(tmp: string)
  local root = tree_with_zig(tmp, 0)
  local code = reboot.rebuild_failed(root, { [0] = "cosmic", "test" },
    "a type error in the tree", false, {})
  assert(code == 3, code)
  assert(Fs.read(root .. "/bin/ran") == nil, "a failure of the tree's own booted")
end

--- COSMIC_AUTO_BOOT=0 refuses, exit 3, in place of the boot.
local function test_rebuild_failed_refuses_when_told_not_to_boot(tmp: string)
  local root = tree_with_zig(tmp, 0)
  local code = reboot.rebuild_failed(root, { [0] = "cosmic", "test" },
    "checker: T (unresolved generic)", true, { COSMIC_AUTO_BOOT = "0" })
  assert(code == 3, code)
  assert(Fs.read(root .. "/bin/ran") == nil, "booted although told not to")
end

--- Only a binary under the tree's o/ is its own tool, judged by the
--- path it was started as, its directory resolved: a link into o/ from
--- outside is outside, a name in o/ is inside even when the file is gone
--- (renamed or removed while it runs), and a directory link into o/
--- counts. A tree with no o/ has no tool of its own to judge.
local function test_own_tool_is_a_binary_under_the_trees_outputs(tmp: string)
  local root = tmp .. "/tree"
  assert(Fs.mkdirs(root .. "/o/bin"))
  assert(Fs.mkdirs(root .. "/o/sanitized/bin"))
  assert(Fs.mkdirs(tmp .. "/elsewhere"))
  for _, path in ipairs({ root .. "/o/bin/cosmic",
      root .. "/o/sanitized/bin/cosmic", tmp .. "/elsewhere/cosmic" }) do
    assert(Fs.write(path, "binary", 0x1ed))
  end
  assert(Fs.symlink(root .. "/o/bin/cosmic", tmp .. "/elsewhere/into"))
  assert(Fs.symlink(root .. "/o/bin", tmp .. "/bin-link"))
  local cases: {string:boolean} = {
    [root .. "/o/bin/cosmic"] = true,
    [root .. "/o/sanitized/bin/cosmic"] = true,
    [root .. "/o/bin/gone"] = true,
    [tmp .. "/bin-link/cosmic"] = true,
    [tmp .. "/elsewhere/into"] = false,
    [tmp .. "/elsewhere/cosmic"] = false,
  }
  for path, want in pairs(cases) do
    local own, trouble = reboot.own_tool(root, path)
    assert(own == want, path .. ": " .. tostring(own) .. " " .. trouble)
  end
  local none, missing = reboot.own_tool(tmp .. "/elsewhere", tmp .. "/elsewhere/cosmic")
  assert(none == nil and missing:find("/elsewhere/o", 1, true), missing)
end

--- A tool carries a tree's code when every module and main of the tree
--- is one it carries with the same source ([`reboot.carries_tree_code`]),
--- whatever its fingerprint says: a tree of this binary's own
--- build.bind does, and not once that source is edited, nor once the
--- tree holds a module the binary does not carry. A tree with no module
--- proves nothing.
local function test_carries_tree_code_compares_every_module(tmp: string)
  local function carries(): boolean
    local handle = assert(work.open(tmp))
    assert(work.stage(handle, true))
    local answer = reboot.carries_tree_code(handle)
    assert(work.close(handle))
    return answer
  end
  assert(Fs.mkdirs(tmp .. "/build"))
  assert(not carries(), "a tree with no module carried the tree's code")
  local source = assert(Store.source("build.bind"))
  assert(Fs.write(tmp .. "/build/bind.tl", source))
  assert(carries(), "the binary's own build.bind did not carry the tree's code")
  assert(Fs.write(tmp .. "/build/bind_test.tl", "local function test_nothing() end\n"))
  assert(carries(), "a test module, which no tool carries, was held against it")
  assert(Fs.write(tmp .. "/build/bind.tl", source .. "-- edited\n"))
  assert(not carries(), "an edited module carried the tree's code")
  assert(Fs.write(tmp .. "/build/bind.tl", source))
  assert(Fs.write(tmp .. "/build/nowhere.tl", "return {}\n"))
  assert(not carries(), "a module the binary does not carry carried the tree's code")
end

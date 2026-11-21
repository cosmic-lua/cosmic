--- A tool of a checkout's build directory run in a project outside that
--- checkout (`bin/cosmic x.tl` from a scratch project) is held to the
--- checkout first: a file run and `cosmic test` there, whose own guards
--- hold the tool to cosmic's own tree alone, are checked by dispatch
--- ([`reboot.checkout_exit`]). What the check does in-process is
--- build/reboot_test.tl's.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local artifact = require("build.artifact")
local paths = require("build.paths")
local this_program = require("build.this_program")
local tree = require("build.tree")

--- The program itself, rewritten as a host program of its core that
--- records another checkout as the one it was built from.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

--- This program as a host program of its own core, written at `path`,
--- recording `built_from` as the checkout it was built from, as a boot
--- of that checkout records it.
local function tool_of(path: string, built_from: string, scratch: string)
  local parts = assert(artifact.split((assert(Fs.read((assert(Proc.executable())))))))
  assert(Fs.write(scratch, parts.database))
  local db = assert(Sqlite.open(scratch, { writable = true }))
  assert(Sqlite.run(db, "INSERT OR REPLACE INTO meta (key, value) VALUES ('built_from', ?1)",
    { { text = built_from } }))
  assert(db:close())
  local database = assert(Fs.read(scratch))
  assert(Fs.remove(scratch))
  assert(Fs.mkdirs(Fs.dirname(path)))
  assert(Fs.write(path, assert(artifact.host_program(assert(artifact.trusted_core()), database)), 0x1ed))
end

--- Runs `program` with `words` in `root`, booting nothing
--- (`COSMIC_AUTO_BOOT=0`) and unsandboxed, as a sandbox nested in this
--- test's own may be refused: its exit status and what it said.
local function invoke(program: string, root: string, tmp: string, words: {string}): integer, string, string
  local env = this_program.environment()
  env["COSMIC_AUTO_BOOT"] = "0"
  env["COSMIC_TEST_SANDBOX"] = "0"
  env["COSMIC_VERDICT_CACHE"] = "0"
  env["TMPDIR"] = tmp
  local argv: mut {string} = { program }
  for _, word in ipairs(words) do argv[#argv + 1] = word end
  local result = assert(Child.run(argv, { cwd = root, env = env, stdout = "capture", stderr = "capture",
    process_group = true, timeout_ns = Clock.seconds(120) }))
  return result.code or -1, result.stdout or "", result.stderr or ""
end

--- A tool of a checkout whose core it is older than (a scratch checkout
--- here, whose core/ is not the one the tool was built of) refuses a file
--- run and `cosmic test` in a project outside the checkout, saying to
--- boot, where it ran the project's file and tests before. The same tool
--- copied out of the build directory is no checkout's own, and runs them.
local function test_a_project_run_holds_the_checkouts_tool_to_the_checkout(tmp: string)
  local checkout = tmp .. "/checkout"
  assert(Fs.mkdirs(checkout .. "/core"))
  assert(Fs.mkdirs(checkout .. "/build"))
  assert(Fs.write(checkout .. "/build/importer.tl", "return {}\n"))
  local project = tmp .. "/project"
  assert(Fs.mkdirs(project))
  assert(Fs.write(project .. "/x.tl", 'print("x ran")\n'))
  assert(Fs.write(project .. "/x_test.tl", "local function test_x()\n  assert(true)\nend\n"))
  local built_from = assert(tree.built_from(checkout))
  local own = paths.resolve(checkout).tool
  tool_of(own, built_from, tmp .. "/own.db")
  local copy = tmp .. "/elsewhere/cosmic"
  tool_of(copy, built_from, tmp .. "/copy.db")

  for _, words in ipairs({ { "x.tl" }, { "test" } }) do
    local what = table.concat(words, " ")
    local code, out, err = invoke(own, project, tmp, words)
    assert(code == 3, what .. ": a project run went on with a tool older than its checkout (exit " ..
        tostring(code) .. ")\n" .. out .. err)
    assert(err:find("the tool is stale; run bin/zig build boot", 1, true), what .. ": " .. err)
    assert(not out:find("x ran", 1, true), what .. ": " .. out)
  end

  local ran, ran_out, ran_err = invoke(copy, project, tmp, { "x.tl" })
  assert(ran == 0 and ran_out == "x ran\n", tostring(ran) .. "\n" .. ran_out .. ran_err)
  local tested, tested_out, tested_err = invoke(copy, project, tmp, { "test" })
  assert(tested == 0, tostring(tested) .. "\n" .. tested_out .. tested_err)
end

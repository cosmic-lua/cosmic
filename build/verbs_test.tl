--- Command lines that dispatch refuses or runs in this process
--- (`build.invoke`), starting nothing and reading nothing of this
--- program beyond their module's closure: a mistyped verb, a worker's
--- mode, which is main's and not dispatch's, and `-e`'s chunk.
--- build/verbs_tool_test.tl holds every verb to the command-line
--- contract.

local Fs = require("cosmic.fs")
local invoke = require("build.invoke")

--- Runs `cosmic <args>` in `dir`, in this process, as
--- build/verbs_tool_test.tl's `cosmic` runs every command line that
--- needs no process of its own.
local function cosmic(dir: string, args: {string}): invoke.Result
  return invoke.run(args, { cwd = dir })
end

local function test_a_mistyped_verb_is_named(tmp: string)
  local result = cosmic(tmp, { "tset" })
  local err = result.stderr or ""
  assert(result.code == 2, err)
  -- The whole of stderr: one line, prefixed once.
  assert(err == "cosmic: no such verb or file: tset; see `cosmic help`\n", err)
end

--- A test's worker is cosmic's main's to start (cmd/cosmic/main.tl),
--- ahead of build.dispatch, so a worker loads none of it: run
--- in-process (`build.invoke`), which is dispatch alone, `test
--- --worker` is `test` refusing an option it does not know.
local function test_dispatch_starts_no_worker(tmp: string)
  for _, mode in ipairs({ "--worker", "--worker-no-tool" }) do
    local result = invoke.run({ "test", mode, tmp, "a_test", "test_a", tmp .. "/tmp",
      tmp .. "/children" }, { cwd = tmp })
    local err = result.stderr or ""
    assert(result.code == 2, err)
    assert(err:find("no such option: " .. mode, 1, true), err)
  end
end

local function test_e_runs_a_lua_chunk(tmp: string)
  local said = cosmic(tmp, { "-e", "print(...)", "a", "b c" })
  assert(said.code == 0, said.stderr)
  assert(said.stdout == "a\tb c\n", said.stdout)
  assert(cosmic(tmp, { "-e", "return 3" }).code == 3)
  local raised = cosmic(tmp, { "-e", "error('boom')" })
  assert(raised.code == 1 and raised.stdout == "", raised.stdout)
  assert((raised.stderr or ""):find("-e:1: boom", 1, true), raised.stderr)
  local broken = cosmic(tmp, { "-e", "x =" })
  assert(broken.code == 1, broken.stderr)
  local bare = cosmic(tmp, { "-e" })
  assert(bare.code == 2, bare.stderr)
  assert((bare.stderr or ""):find("usage: cosmic -e", 1, true), bare.stderr)
  assert(cosmic(tmp, { "-e", "return nil" }).code == 0)
  assert(cosmic(tmp, { "-e", "return 3.0" }).code == 3)
  assert(cosmic(tmp, { "-e", "return 255" }).code == 255)
  for chunk, shown in pairs({ ["256"] = "256", ["-1"] = "-1", ["1.5"] = "1.5", ["true"] = "true",
    ["'text'"] = '"text"', ["{}"] = "table: " } as {string:string}) do
    local refused = cosmic(tmp, { "-e", "return " .. chunk })
    assert(refused.code == 2, chunk .. ": " .. tostring(refused.code))
    assert((refused.stderr or ""):find("-e returned " .. shown, 1, true), refused.stderr)
    assert((refused.stderr or ""):find("not an exit status 0-255", 1, true), refused.stderr)
  end
  local nothing, _ = Fs.exists(tmp .. "/o")
  assert(nothing == false, "-e wrote under o/")
end

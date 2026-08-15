#!/usr/bin/env cosmic
-- Tests for the RECIPE LINE: `cosmic -c '<line>'`, which is the SHELL
-- half of the same driver (`SHELL := cosmic`, make's default
-- `.SHELLFLAGS` already `-c`). One line, split on whitespace, run as
-- argv through the modes table its sibling exercises directly.
--
-- init_test.tl tests what each VERB does, given arguments; this file
-- tests what happens to a LINE on the way to a verb -- parse, refuse,
-- fence, announce, dispatch. The two files share only the binary
-- under test.

local child = require("cosmic.child")
local env = require("cosmic.env")
local fs = require("cosmic.fs")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"
local test_bin = fs.join(os.getenv("TEST_BIN") or "", "cosmic")

--- Run one recipe line, optionally overriding variables in the child's
--- environment.
---
--- The override exists because a test about the FENCE cannot inherit
--- the developer's opinion of it: `COSMIC_FENCE=0` is a supported way
--- to work, and a run under it would otherwise turn the fence tests
--- from assertions into failures. A test that needs the fence on says
--- so rather than hoping.
local function run_recipe(line: string,
    overrides?: {string: string}): integer, string, string
  local opts: child.Options = {}
  if overrides ~= nil then
    local envlist: {string} = {}
    for _, entry in ipairs(env.list()) do
      local name = entry:match("^([^=]+)=")
      if name == nil or overrides[name] == nil then
        envlist[#envlist + 1] = entry
      end
    end
    for name, value in pairs(overrides) do
      envlist[#envlist + 1] = name .. "=" .. value
    end
    opts.env = envlist
  end
  local r, rerr = child.run({test_bin, "-c", line}, opts)
  if r == nil then
    return 1, "", tostring(rerr)
  end
  local code = 1
  if r.code ~= nil then
    code = r.code
  end
  return code, r.stdout, r.stderr
end

local function test_recipe_dispatches()
  local src = fs.join(tmpdir, "recipe-src.txt")
  local dst = fs.join(tmpdir, "recipe/out.txt")
  assert(fs.write(src, "hello\n"))
  local code, _out, err = run_recipe("copy " .. src .. " " .. dst)
  assert(code == 0, "recipe copy failed (" .. tostring(code) .. "): " .. err)
  assert(fs.read(dst) == "hello\n", "recipe reaches the same modes table")
end
test_recipe_dispatches()

-- record grades a result THIS run wrote, never a stale one. When its
-- scratch directory cannot be made -- here a plain file sits where the
-- directory goes -- record must FAIL, not exit 0 on the `.got` a green
-- previous run left behind. `COSMIC_FENCE=0` so this exercises record's
-- own guard, not the fence derivation.
local function test_record_does_not_grade_a_stale_got()
  local out = fs.join(tmpdir, "rec-stale")
  assert(fs.write(out .. ".got", "0")) -- a passing result from "before"
  assert(fs.write(out .. ".tmp.d", "")) -- a file where the scratch dir goes
  local code, _o, err = run_recipe("record " .. out .. " " .. test_bin,
    {["COSMIC_FENCE"] = "0"})
  assert(code ~= 0,
    "record must fail when it cannot run, not pass on a stale .got: " ..
    tostring(code) .. " " .. err)
end
test_record_does_not_grade_a_stale_got()

-- A fence that cannot be DERIVED fails the step rather than waving it
-- through: dispatching would run the step with no Landlock at all. The
-- blocker is a regular file, so the derivation's makedirs hits ENOTDIR.
--
-- `COSMIC_FENCE=1` explicitly: with the fence off there is no
-- derivation to fail, so an ambient `COSMIC_FENCE=0` would make this
-- report a failure where it means "not applicable". Needs no kernel
-- support either way -- the refusal is in the derivation, before any
-- sandbox call.
local function test_recipe_refuses_a_step_whose_fence_cannot_be_derived()
  local blocker = fs.join(tmpdir, "fence-blocker.txt")
  assert(fs.write(blocker, "not a directory\n"))
  local doomed = fs.join(blocker, "nope", "out.txt")
  local code, out, err = run_recipe("write-list " .. doomed .. " item",
    {COSMIC_FENCE = "1"})
  assert(code ~= 0, "a step with no derivable fence must fail, got 0")
  assert(err:find("cannot create", 1, true), "expected it named: " .. err)
  assert(not out:find("write-list", 1, true), "not announced: " .. out)
end
test_recipe_refuses_a_step_whose_fence_cannot_be_derived()

local function test_recipe_strips_the_sentinel()
  -- Generated recipes end in `;` so make routes them through SHELL at
  -- all: without it make execs the line itself and cosmic never sees
  -- it. The `;` is make's, not the verb's, so it must not reach argv.
  local src = fs.join(tmpdir, "sentinel-src.txt")
  local dst = fs.join(tmpdir, "sentinel/out.txt")
  assert(fs.write(src, "sentinel\n"))
  local code, _out, err = run_recipe("copy " .. src .. " " .. dst .. " ;")
  assert(code == 0, "a sentinel line must run (" .. tostring(code) .. "): " .. err)
  assert(fs.read(dst) == "sentinel\n", "sentinel stripped before dispatch")
end
test_recipe_strips_the_sentinel()

local function test_recipe_refuses_shell()
  -- A shell would treat these as a redirect and a command separator. As
  -- argv they would be inert literals, so the failure this prevents is
  -- silent: the line does something other than it looks like.
  local marker = fs.join(tmpdir, "recipe-pwned")
  local code, _out, err = run_recipe("copy a b ; touch " .. marker)
  assert(code ~= 0, "a shell metacharacter must fail the line")
  assert(err:match("argv, not shell"), "expected the argv/shell message, got: " .. err)
  assert(not fs.stat(marker), "nothing after ';' may run")

  code, _out, err = run_recipe("write-list " .. fs.join(tmpdir, "r.txt") .. " > x")
  assert(code ~= 0, "a redirect must fail the line")
  assert(err:match("argv, not shell"), "expected the argv/shell message, got: " .. err)
end
test_recipe_refuses_shell()

-- Globs matter for the same reason: they are exactly what makes make
-- hand a line to SHELL, so a recipe carrying one DOES reach cosmic,
-- where it is taken as a literal argv word. `remove o/*.tmp` exits 0
-- having deleted nothing -- `remove` is rm -f, and a file literally
-- named `*.tmp` is already missing. A line that reports success having
-- done nothing is the failure the refusal exists to close.
--
-- Nothing legitimate is refused: the validator already bars every one
-- of these characters from a PATH, so a glob in a recipe word cannot
-- be a filename this build system would build.
local function test_recipe_refuses_globs()
  local victim = fs.join(tmpdir, "glob-victim.tmp")
  assert(fs.write(victim, "still here\n"))
  local code, _out, err = run_recipe("remove " .. fs.join(tmpdir, "*.tmp"))
  assert(code ~= 0, "a glob must fail the line, not match nothing")
  assert(err:match("argv, not shell"),
    "expected the argv/shell message, got: " .. err)
  assert(fs.is_file(victim), "and nothing may be deleted on the way")

  for _, ch in ipairs({"?", "[", "]", "~", "^", "!", "#"}) do
    local c = select(1, run_recipe("copy a" .. ch .. " b"))
    assert(c ~= 0, "a line carrying '" .. ch .. "' must be refused")
  end
end
test_recipe_refuses_globs()

local function test_recipe_unknown_verb()
  local code, _out, err = run_recipe("rm -rf " .. tmpdir)
  assert(code ~= 0, "a verb outside the vocabulary must fail")
  assert(err:match("unknown verb 'rm'"), "expected the verb named, got: " .. err)
  -- the whole vocabulary is one line, so the message can carry it
  assert(err:match("copy") and err:match("verdict"),
    "expected the vocabulary listed, got: " .. err)
  assert(fs.stat(tmpdir), "an unknown verb runs nothing at all")
end
test_recipe_unknown_verb()

local function test_recipe_blank_is_a_noop()
  -- make hands us no blank lines, but a variable that expanded to
  -- nothing looks like one; a shell would do nothing, so do nothing.
  local code = run_recipe("   ")
  assert(code == 0, "a blank recipe line succeeds")
end
test_recipe_blank_is_a_noop()

-- exec: the one door out of the vocabulary, and it opens only onto
-- bytes already under the build root.
local function run_recipe_env(line: string, root: string): integer, string, string
  local envlist: {string} = {}
  for _, entry in ipairs(env.list()) do
    if not entry:match("^COSMIC_EXEC_ROOT=") then
      envlist[#envlist + 1] = entry
    end
  end
  envlist[#envlist + 1] = "COSMIC_EXEC_ROOT=" .. root
  local r, rerr = child.run({test_bin, "-c", line}, {env = envlist})
  if r == nil then
    return 1, "", tostring(rerr)
  end
  local code = 1
  if r.code ~= nil then
    code = r.code
  end
  return code, r.stdout, r.stderr
end

-- The program's arguments travel through the same whitespace split as
-- the verb, so they cannot carry shell characters either: `-e print(42)`
-- is refused for its parentheses. Scripts keep this test's own argv to
-- paths and flags, which is what a real recipe passes.
local function write_script(name: string, body: string): string
  local path = fs.join(tmpdir, name)
  assert(fs.write(path, body))
  return path
end

local function test_exec_runs_bytes_under_the_root()
  local root = fs.dirname(fs.absolute_path(test_bin))
  local script = write_script("exec-print.lua", "print('42')\n")
  local code, out, err = run_recipe_env(
    "exec " .. test_bin .. " " .. script, root)
  assert(code == 0, "exec under the root failed (" .. tostring(code) .. "): " .. err)
  assert(out:match("42"), "expected the program's own output, got: " .. out)
end
test_exec_runs_bytes_under_the_root()

local function test_exec_refuses_outside_the_root()
  -- /bin/sh exists and is executable; being outside the root is the
  -- only reason it must not run.
  local code, _out, err = run_recipe_env("exec /bin/sh -c true", tmpdir)
  assert(code ~= 0, "a program outside the build root must be refused")
  assert(err:match("not under the build root"), "expected the root named, got: " .. err)
end
test_exec_refuses_outside_the_root()

-- The root check has to resolve SYMLINKS, not just normalize `..`.
-- abspath refuses a path that climbs out lexically, but the kernel
-- follows links at spawn -- so a symlink like `o/tool -> /bin/echo`
-- can have an abspath under the root that passes the prefix test
-- while resolving to the host binary. Resolving the ROOT this way too
-- is what makes "exec resolves only to pinned bytes under o/, never
-- PATH" an enforced claim rather than merely a stated one.
local function test_exec_refuses_a_symlink_out_of_the_root()
  local root = fs.join(tmpdir, "exec-root")
  assert(fs.remove_all(root))
  assert(fs.make_dirs(root))
  local link = fs.join(root, "escape")
  assert(fs.symlink("/bin/sh", link))
  local code, _out, err = run_recipe_env("exec " .. link .. " -c true", root)
  assert(code ~= 0, "a symlink out of the root must be refused")
  assert(err:match("not under the build root"),
    "expected the root named, got: " .. err)
  assert(err:match("resolves to"),
    "and where it actually resolved to, got: " .. err)
end
test_exec_refuses_a_symlink_out_of_the_root()

-- The other direction, because refusing everything would also pass the
-- test above: a link INSIDE the root still runs.
--
-- The root is BUILT here, not borrowed from the repo. Pointing at the
-- real `o/bin/` and dropping a symlink beside the binary under test
-- is a test writing into the tree's build output -- and the fence
-- denies exactly that. A test may write its own scratch and nothing
-- else, so the program is a copy and the link is beside the copy.
local function test_exec_allows_a_symlink_inside_the_root()
  local root = fs.join(tmpdir, "exec-linked-root")
  assert(fs.remove_all(root))
  assert(fs.make_dirs(root))
  local prog = fs.join(root, "prog")
  assert(fs.copy(test_bin, prog))
  assert(fs.set_mode(prog, tonumber("755", 8) as integer)) -- cast: octal is integral
  local script = write_script("exec-linked.lua", "print('linked')\n")
  local link = fs.join(root, "exec-alias")
  assert(fs.symlink("prog", link))
  local code, out, err = run_recipe_env("exec " .. link .. " " .. script, root)
  assert(code == 0, "a link inside the root must still run: " .. err)
  assert(out:match("linked"), "expected the program's output, got: " .. out)
end
test_exec_allows_a_symlink_inside_the_root()

local function test_exec_never_searches_path()
  -- `sh` resolves through PATH for a shell; for exec it is just a
  -- relative path that is not under the root, so it cannot run.
  local code, _out, err = run_recipe_env("exec sh -c true", tmpdir)
  assert(code ~= 0, "a bare program name must not be found on PATH")
  assert(err:match("not under the build root"), "expected the root named, got: " .. err)
end
test_exec_never_searches_path()

local function test_exec_reports_a_missing_program()
  local code, _out, err = run_recipe_env(
    "exec " .. fs.join(tmpdir, "absent") .. " x", tmpdir)
  assert(code ~= 0, "a missing program must fail")
  assert(err:match("no such file"), "expected a missing-file message, got: " .. err)
end
test_exec_reports_a_missing_program()

local function test_exec_passes_through_the_exit_code()
  local root = fs.dirname(fs.absolute_path(test_bin))
  local script = write_script("exec-exit.lua", "os.exit(3)\n")
  local code = run_recipe_env("exec " .. test_bin .. " " .. script, root)
  assert(code == 3, "expected the program's own exit code, got " .. tostring(code))
end
test_exec_passes_through_the_exit_code()

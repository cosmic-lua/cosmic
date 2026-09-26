--- `cosmic test --audit`: every test run, and what each read beyond its
--- default and declared inputs (`build.test_inputs`) named, module by
--- module, with the declaration that would hold it.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local observations = require("build.filesystem_observations")
local test = require("build.test")
local test_inputs = require("build.test_inputs")
local type positions = require("build.positions")

-- What these tests start is this very program.
observations.confine({ reads = observations.itself() })

--- Runs `cosmic test --audit` on `root`, answering whether it passed and
--- what it printed.
local function audit(root: string, output: string): boolean, string
  local fd = assert(Fs.open_write(output))
  local result, trouble = Child.run({ assert(Proc.executable()), "test", "--audit" }, {
    cwd = root, env = observations.environment(), stdout = fd, stderr = fd,
    process_group = true, timeout_ms = 60000,
  })
  assert(Fs.close(fd))
  local text = assert(Fs.read(output))
  assert(result ~= nil, tostring(trouble) .. text)
  return result.ok, text
end

--- A project whose test reads its helper's source, which its import
--- closure holds; a file of the tree it declares or not, as `declared`
--- says; and a file that is not there, which no sandbox would show it
--- either.
local function project(root: string, declared: boolean)
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.mkdirs(root .. "/data"))
  assert(Fs.write(root .. "/data/extra.txt", "extra\n"))
  assert(Fs.write(root .. "/suite/helper.tl", "return { answer = 42 }\n"))
  assert(Fs.write(root .. "/suite/reads_test.tl", table.concat({
    'local Fs = require("cosmic.fs")',
    'local helper = require("suite.helper")',
    declared and 'local Test = require("cosmic.test")' or "",
    declared and 'Test.needs { reads = { "data/" } }' or "",
    "local function test_reads()",
    "  assert(helper.answer == 42)",
    '  assert(Fs.read("suite/helper.tl") ~= nil)',
    '  assert(Fs.read("data/extra.txt") == "extra\\n")',
    '  assert(Fs.read("data/missing.txt") == nil)',
    "end",
  }, "\n") .. "\n"))
end

--- The audit fails a run whose test read a file it does not declare,
--- naming it and the declaration that would hold it, and passes once the
--- test declares it.
local function test_an_undeclared_read_fails_the_audit_until_it_is_declared(tmp: string)
  local root = tmp .. "/project"
  project(root, false)
  local ok, text = audit(root, tmp .. "/first.out")
  assert(not ok, text)
  assert(text:find("audit: suite.reads_test (suite/reads_test.tl): 1 of 1 tests read " ..
    "what they do not declare\n  test_reads:\n    reads        data/extra.txt\n" ..
    '  declare: Test.needs { reads = { "data/extra.txt" } }\n', 1, true), text)
  assert(not text:find("helper.tl", 1, true) and not text:find("missing", 1, true), text)
  assert(text:find("test: PASS", 1, true), text)
  project(root, true)
  ok, text = audit(root, tmp .. "/second.out")
  assert(ok, text)
  assert(text:find("audit: 1 tests read only their inputs\n", 1, true), text)
end

--- What `test.audited` holds a test's observations to: its effective
--- inputs, and nothing of its own directory, a directory it made, or
--- the tree's directories above an input.
local function test_audited_names_what_the_inputs_do_not_hold(tmp: string)
  local root = assert(Fs.absolute(tmp)) .. "/root"
  local scratch = assert(Fs.absolute(tmp)) .. "/scratch"
  local m: positions.Module = { path = "a.thing_test", file = "a/thing_test.tl", kind = "test",
    requires = {}, tests = { "test_x" } }
  local effective = test_inputs.effective(m, { [m.path] = m }, {})
  -- An open is judged by what is there now, which it does not record.
  assert(Fs.mkdirs(root .. "/o/bin"))
  for _, file in ipairs({ "/a/thing_test.tl", "/o/bin/cosmic", "/o/cosmic.db" }) do
    assert(Fs.mkdirs((root .. file):match("^(.*)/")))
    assert(Fs.write(root .. file, "x"))
  end
  local found = test.audited(root, scratch, effective, {
    { kind = "o", path = root .. "/a/thing_test.tl", answer = "" },
    { kind = "s", path = root .. "/a", answer = "ok 1 2 dir" },
    { kind = "d", path = root .. "/a", answer = "ok" },
    { kind = "o", path = scratch .. "/tmp/x", answer = "" },
    { kind = "m", path = "/made", answer = "" },
    { kind = "s", path = "/made/y", answer = "ok 1 2 file" },
    { kind = "s", path = "/etc/hosts", answer = "ok 1 2 file" },
    { kind = "s", path = "/nowhere", answer = "error 00 2" },
    { kind = "e", path = "TMPDIR", answer = "absent" },
    { kind = "e", path = "USER", answer = "absent" },
    { kind = "e", path = "\0environ", answer = "hash" },
    { kind = "p", path = "/bin/sh", answer = "" },
    { kind = "x", path = "http://127.0.0.1:1/", answer = "" },
    { kind = "x", path = "fd 5", answer = "" },
    { kind = "o", path = root .. "/o/bin/cosmic", answer = "" },
    { kind = "o", path = root .. "/o/cosmic.db", answer = "" },
    { kind = "o", path = root .. "/o/cosmic.db-journal", answer = "" },
  }, {})
  local said: {string} = {}
  for _, finding in ipairs(found) do said[#said + 1] = finding.field .. " " .. finding.value end
  assert(table.concat(said, "\n") == table.concat({
    "reads a",
    "host /etc/hosts",
    "env USER",
    "env *",
    "processes /bin/sh",
    "network http://127.0.0.1:1/",
    "processes unobservable: fd 5",
    "tool o/bin/cosmic",
    "store o/cosmic.db",
  }, "\n"), table.concat(said, "\n"))
end

--- A read through a link in the test's own directory is judged by
--- where the link leads: out of it, the read is of what it leads to,
--- which a sandbox would not show undeclared. A stat of a directory
--- above the test's own, or the tree, is on the way to them.
local function test_a_link_in_the_tests_own_directory_that_leads_out_is_named(tmp: string)
  local base = assert(Fs.absolute(tmp))
  local root, scratch, outside = base .. "/root", base .. "/scratch", base .. "/outside"
  assert(Fs.mkdirs(root))
  assert(Fs.mkdirs(scratch))
  assert(Fs.mkdirs(outside))
  assert(Fs.write(outside .. "/f", "x"))
  local m: positions.Module = { path = "a.thing_test", file = "a/thing_test.tl", kind = "test",
    requires = {}, tests = { "test_x" } }
  local effective = test_inputs.effective(m, { [m.path] = m }, {})
  local found = test.audited(root, scratch, effective, {
    { kind = "r", path = scratch .. "/l", answer = outside .. "/f" },
    { kind = "o", path = scratch .. "/l", answer = "" },
    { kind = "s", path = base, answer = "ok 1 2 dir" },
    { kind = "l", path = "/", answer = "ok 1 2 dir" },
    { kind = "a", path = base, answer = "" },
  }, {})
  local said: {string} = {}
  for _, finding in ipairs(found) do said[#said + 1] = finding.field .. " " .. finding.value end
  assert(table.concat(said, "\n") == "host " .. outside .. "/f", table.concat(said, "\n"))
  -- A listing of a directory above them reads more than the way there.
  found = test.audited(root, scratch, effective,
    { { kind = "d", path = base, answer = "ok" } }, {})
  assert(#found == 1 and found[1].field == "host" and found[1].value == base)
end

--- A `needs` call the build did not read from the source -- reached
--- another way than a top-level call on a local bound to
--- `require("cosmic.test")` -- fails its module's load when it runs,
--- naming what it was handed and what the build read.
local function test_a_needs_call_the_build_did_not_read_fails_the_load(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.write(root .. "/suite/dynamic_test.tl", table.concat({
    'require("cosmic.test").needs { tool = true }',
    "local function test_x() end",
  }, "\n") .. "\n"))
  local ok, text = audit(root, tmp .. "/dynamic.out")
  assert(not ok, text)
  assert(text:find("the module failed to load: its cosmic.test needs call was handed what " ..
    "the build did not read", 1, true), text)
  assert(text:find("  handed:\n    tool\ttrue\n  read:\n    nothing", 1, true), text)
end

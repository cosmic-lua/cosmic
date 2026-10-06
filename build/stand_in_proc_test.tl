--- [`build/stand_in.tl`]'s `status-field`, which reads its own line of
--- /proc/self/status: a host with a /proc (`requires`). The rest of its
--- verbs are in build/stand_in_test.tl.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Test = require("cosmic.test")
local stand_in = require("build.stand_in")

Test.policy{ requires = { "proc" } }

--- `status-field` answers its own line of /proc/self/status, and fails on
--- a field the file lacks.
local function test_status_field_reads_its_line_of_proc_self_status(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local field = assert(Child.run({ probe, "status-field SigIgn; status-field NoSuchField" },
    { env = {}, stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) }))
  assert(field.code == 1, tostring(field.code))
  assert(assert(field.stdout):match("^SigIgn:%s*%x+\n$"), field.stdout)
end

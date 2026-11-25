--- [`cosmic.fake`]'s `status-field`, which reads its own line of
--- /proc/self/status: a host with a /proc (`requires`). The rest of its
--- verbs are in cosmic/fake_test.tl.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Test = require("cosmic.test")
local Fake = require("cosmic.fake")

Test.policy{ requires = { "proc" } }

--- `status-field` prints its own line of /proc/self/status, and fails on
--- a field the file lacks.
local function test_status_field_reads_its_line_of_proc_self_status(tmp: string)
  local probe = assert(Fake.build(tmp .. "/fake"))
  local field = assert(Child.run({ probe, "status-field SigIgn; status-field NoSuchField" },
    { env = {}, stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) }))
  assert(field.code == 1, tostring(field.code))
  assert(assert(field.stdout):match("^SigIgn:%s*%x+\n$"), field.stdout)
end

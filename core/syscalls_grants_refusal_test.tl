--- A Landlock ruleset applies without making a user namespace: its
--- child reports the absent program only after being restricted.

local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local type _ = require("cosmic.child")

Test.policy{ requires = { "landlock" } }

local function test_a_grants_ruleset_is_applied_before_an_absent_program_is_refused(tmp: string)
  local path = tmp .. "/absent"
  local pid, why, errno = require("cosmic.internal.process").spawn(path, { path }, nil, nil, nil, nil, nil,
    false, nil, { grants = {} })
  assert(pid == nil and errno == sys.ENOENT and why == "No such file or directory", why)
end

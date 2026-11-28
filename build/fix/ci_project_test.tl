--- What [`build.fix.ci_project`] says once the checks of `ci/` are done.

local CiProject = require("build.fix.ci_project")

--- The line that says the checks passed names how long the run waited for them, which is what they cost it, and not
--- the time since they started, which is mostly the tree's own checks they ran beside.
local function test_the_ci_line_names_the_wait_and_not_the_time_since_the_start()
  local findings, passed = CiProject.finish({ names = {}, handles = {}, refused = { "ci/: a check did not start" } })
  assert(#findings == 1 and findings[1] == "ci/: a check did not start", table.concat(findings, "\n"))
  local line = passed[#passed] or ""
  assert(line:find("the run waited %d+ ms for them after its own$") ~= nil, line)
  assert(line:find("after they started", 1, true) == nil, line)
end

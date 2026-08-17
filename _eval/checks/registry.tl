--- The one place every task id is wired to its functional check
--- implementation (_eval/checks/<id>.tl) -- shared by score.tl, which
--- scores real run dirs, and checks_test.tl, which exercises each
--- check directly against its own fixtures, so the two lists cannot
--- silently drift apart.
local record checks_registry
  type CheckFn = function(string): (integer, {string})
  CHECKS: {string: CheckFn}
end

local M: checks_registry = {
  CHECKS = {
    ["json-cli"] = require("_eval.checks.json-cli").check,
    ["module-tests"] = require("_eval.checks.module-tests").check,
    ["sqlite-indexer"] = require("_eval.checks.sqlite-indexer").check,
    ["child-tcp"] = require("_eval.checks.child-tcp").check,
    ["text-report"] = require("_eval.checks.text-report").check,
    ["multi-module-build"] = require("_eval.checks.multi-module-build").check,
    ["contained-task"] = require("_eval.checks.contained-task").check,
  },
}

return M

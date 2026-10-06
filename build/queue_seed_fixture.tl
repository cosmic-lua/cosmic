--- What build/queue_seed_test.tl and build/queue_seed_jq_test.tl share of
--- .github/scripts/queue-seed.sh: where it is, the commit and queue branch
--- their runs name, and the filters it hands `gh api --jq`, as it writes
--- them. Test support.

local Fs = require("cosmic.fs")

local record queue_seed_fixture
  --- The script, by its whole path: a process a test starts elsewhere
  --- finds it.
  SCRIPT: string
  SHA: string
  QUEUE: string
  RUNS_FILTER: string
  ARTIFACTS_FILTER: string
  AHEAD_RUNS_FILTER: string
  JOBS_FILTER: string
end

queue_seed_fixture.SCRIPT = assert(Fs.absolute(".github/scripts/queue-seed.sh"))
queue_seed_fixture.SHA = "0123456789abcdef0123456789abcdef01234567"
queue_seed_fixture.QUEUE = "gh-readonly-queue/main/pr-7-fedcba"
queue_seed_fixture.RUNS_FILTER = [[.workflow_runs[] | "\(.id) \(.status) \(.conclusion // "none") \(.head_sha) \(.head_branch) \(.html_url)"]]
queue_seed_fixture.ARTIFACTS_FILTER = ".artifacts[] | select(.expired | not) | .name"
queue_seed_fixture.AHEAD_RUNS_FILTER = [[.workflow_runs[] | select(.event == "merge_group") | "\(.id) \(.status) \(.head_sha) \(.head_branch)"]]
queue_seed_fixture.JOBS_FILTER = [[.jobs[] | "\(.status) \(.started_at // "" | if . == "" then "none" else fromdateiso8601 end) \(if (env.SUITE_STEP // "") == "" then "-" elif any(.steps[]?; .name == env.SUITE_STEP and (.status == "in_progress" or .status == "completed")) then "reached" else "before" end) \(.name)"]]

return queue_seed_fixture

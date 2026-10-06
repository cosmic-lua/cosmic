--- What build/commit_verdicts_test.tl and build/commit_verdicts_jq_test.tl
--- share of .github/scripts/merge-base.sh and
--- .github/scripts/prune-commit-verdicts.sh: where they are, the commits
--- their runs name, the filters they hand `gh api --jq` as they write them,
--- and a run of one against a fake `gh`. Test support.

local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Time = require("cosmic.time")

local record commit_verdicts_fixture
  --- The scripts, by their whole paths: a process a test starts elsewhere
  --- finds them.
  MERGE_BASE: string
  PRUNE: string
  SHA: string
  BASE: string
  BASE_FILTER: string
  PRUNE_FILTER: string
  COMPILES_FILTER: string
  --- Runs `script` with `env` against a fake `gh` answering `answer`,
  --- refusing to delete the ids of `refuse`.
  run: function(tmp: string, script: string, env: {string: string}, answer: string, refuse?: {string}):
    commit_verdicts_fixture.Ran
  --- What a run wrote to $GITHUB_OUTPUT, the calls it made to `gh`, and
  --- what it said.
  record Ran
    output: string
    calls: string
    said: string
  end
  --- The ids `calls` deleted, in order.
  deleted: function(calls: string): string
end

commit_verdicts_fixture.MERGE_BASE = assert(Fs.absolute(".github/scripts/merge-base.sh"))
commit_verdicts_fixture.PRUNE = assert(Fs.absolute(".github/scripts/prune-commit-verdicts.sh"))
commit_verdicts_fixture.SHA = "0123456789abcdef0123456789abcdef01234567"
commit_verdicts_fixture.BASE = "fedcba9876543210fedcba9876543210fedcba98"
commit_verdicts_fixture.BASE_FILTER = ".merge_base_commit.sha"
commit_verdicts_fixture.PRUNE_FILTER = [[.actions_caches[] | select(.key | test(\"-sha-[0-9a-f]{40}\$\")) | select((.created_at | sub(\"[.][0-9]+\"; \"\") | fromdateiso8601) < $cutoff) | .id]]
commit_verdicts_fixture.COMPILES_FILTER = [[.actions_caches[] | select(.key | startswith(\"compiles-branch-\")) | select((.created_at | sub(\"[.][0-9]+\"; \"\") | fromdateiso8601) < $cutoff) | .id]]

--- A fake `gh`: `api [--paginate] URL --jq FILTER` answers the file
--- `answer` through FILTER, or fails where it holds FAIL; `api -X DELETE
--- URL` succeeds but for a URL ending in an id listed in `refuse`. Each
--- call's arguments are logged to `calls`.
local FAKE <const> = [[#!/bin/sh
echo "$*" >> "$FAKE/calls"
[ "$1" = api ] || { echo "fake gh: $*" >&2; exit 2; }
shift
if [ "$1" = -X ]; then
  [ "$2" = DELETE ] || exit 2
  ! grep -qx "${3##*/}" "$FAKE/refuse" 2>/dev/null
  exit
fi
[ "$1" != --paginate ] || shift
[ "$2" = --jq ] && [ $# -eq 3 ] || { echo "fake gh: $*" >&2; exit 2; }
[ "$(cat "$FAKE/answer")" != FAIL ] || exit 1
jq -r "$3" "$FAKE/answer"
]]

local runs = 0

--- The text of a file the script may not have written, "" for none.
local function read(path: string): string
  local text, _ = Fs.read(path)
  return text or ""
end

function commit_verdicts_fixture.run(tmp: string, script: string, env: {string: string}, answer: string,
                                     refuse?: {string}): commit_verdicts_fixture.Ran
  runs = runs + 1
  local dir = tmp .. "/run-" .. runs
  assert(Fs.mkdirs(dir .. "/bin"))
  assert(Fs.write(dir .. "/bin/gh", FAKE))
  assert(Fs.chmod(dir .. "/bin/gh", 493))
  assert(Fs.write(dir .. "/answer", answer))
  assert(Fs.write(dir .. "/refuse", table.concat(refuse or {}, "\n") .. "\n"))
  local full: {string: string} = {
    PATH = dir .. "/bin:" .. (Env.get("PATH") or "/usr/bin:/bin"), FAKE = dir,
    GITHUB_OUTPUT = dir .. "/output", REPOSITORY = "o/r",
  }
  for name, value in pairs(env) do full[name] = value end
  local result = assert(Child.run({ "/bin/sh", script }, { env = full, cwd = dir,
    stdout = "capture", stderr = "capture", timeout_ns = Time.seconds(30) }))
  local said = (result.stdout or "") .. (result.stderr or "")
  assert(result.code == 0, "the script failed the job: " .. said)
  return { output = read(dir .. "/output"), calls = read(dir .. "/calls"), said = said }
end

function commit_verdicts_fixture.deleted(calls: string): string
  local ids: {string} = {}
  for id in calls:gmatch("api %-X DELETE repos/o/r/actions/caches/(%d+)\n") do
    ids[#ids + 1] = id
  end
  return table.concat(ids, " ")
end

return commit_verdicts_fixture

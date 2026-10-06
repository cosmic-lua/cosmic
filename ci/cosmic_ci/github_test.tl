--- The live host of cosmic_ci/github.tl: what it asks of `gh` and of
--- `git`, against a `gh` that prints canned answers (a script of the
--- test's own) and a recorded git.
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Github = require("cosmic_ci.github")
local Test = require("cosmic.test")
local Time = require("cosmic.time")

--- The system's `sh`, which the stand-in `gh` runs.
Test.policy{
  profiles = { "system" },
  env = { "PATH" },
}

--- A `gh` that logs its arguments and the token it was given to
--- `$DIR/calls`, then answers by its last argument: a path ending in
--- `/pages` prints two pages as `--slurp` gathers them, `/slow` outlasts
--- any timeout, `/fail` fails, `/junk` prints no JSON, and any other
--- prints one object.
local GH <const> = [[#!/bin/sh
echo "$GH_TOKEN $*" >> "$DIR/calls"
for last; do :; done
case $last in
  */pages) echo '[{"actions_caches":[{"id":1}]},{"actions_caches":[{"id":2}]}]' ;;
  */slow) sleep 5 ;;
  */fail) echo "boom" >&2; exit 1 ;;
  */junk) echo "not json" ;;
  *) echo '{"merge_base_commit":{"sha":"abc"}}' ;;
esac
]]

local function path(): string
  return Env.get("PATH") or "/usr/bin:/bin"
end

--- The live host with a `gh` on its PATH that answers as GH does, and
--- the file its calls are logged to.
local function host_with_gh(tmp: string): Github.Host, string
  assert(Fs.mkdirs(tmp .. "/bin"))
  assert(Fs.write(tmp .. "/bin/gh", GH, 493))
  local env: {string: string} = { PATH = tmp .. "/bin:" .. path(), DIR = tmp, GH_TOKEN = "secret" }
  return Github.live(env), tmp .. "/calls"
end

--- A lookup runs `gh api PATH` with the token the environment holds, and
--- answers the object it printed; a listing run with `--paginate --slurp`
--- answers every page it printed.
local function test_a_lookup_runs_gh_api_and_decodes_its_answer(tmp: string)
  local host, calls = host_with_gh(tmp)
  local pages, why = host.fetch("repos/o/r/compare/main...x", false, 30)
  assert(pages ~= nil, why)
  local page = pages[1] as {string: any}
  assert(#pages == 1 and (page.merge_base_commit as {string: string}).sha == "abc")
  pages, why = host.fetch("repos/o/r/actions/caches/pages", true, 30)
  assert(pages ~= nil and #pages == 2, why)
  assert(Fs.read(calls) == "secret api repos/o/r/compare/main...x\n" ..
      "secret api --paginate --slurp repos/o/r/actions/caches/pages\n", Fs.read(calls))
end

--- A `gh` that fails, prints no JSON, or outlasts its time fails the
--- lookup, naming why, and one that is not there does.
local function test_a_lookup_that_fails_answers_nil(tmp: string)
  local host = host_with_gh(tmp)
  for _, case in ipairs({ { path = "x/fail", why = "failed" }, { path = "x/junk", why = "x/junk" },
      { path = "x/slow", why = "timed out" } }) do
    local started = Time.monotonic_ns()
    local pages, why = host.fetch(case.path, false, 1)
    assert(pages == nil and why:find(case.why, 1, true), case.path .. ": " .. why)
    assert(Time.monotonic_ns() - started < Time.seconds(4), case.path .. " waited out its command")
  end
  local pages, why = host.fetch("x/junk", true, 30)
  assert(pages == nil and why:find("x/junk", 1, true), why)
  local bare = Github.live({ PATH = "" })
  pages, why = bare.fetch("repos/o/r", false, 1)
  assert(pages == nil and why == "no gh on PATH", why)
end

--- A delete is `gh api -X DELETE PATH`, and fails where gh does.
local function test_a_delete_runs_gh_api_x_delete(tmp: string)
  local host, calls = host_with_gh(tmp)
  assert(host.delete("repos/o/r/actions/caches/7", 30))
  assert(Fs.read(calls) == "secret api -X DELETE repos/o/r/actions/caches/7\n")
  local deleted, why = host.delete("repos/o/r/actions/caches/fail", 30)
  assert(deleted == false and why:find("failed", 1, true), why)
end

--- The harness moved where git answers 1 to a diff of build/harness_epoch.tl,
--- by the path from the repository's root, which the driver, run in ci/,
--- needs. A base git does not hold, any other status, and no git at all are
--- no sign that it moved. (A recorded git stands in: no test runs the host's.)
local function test_the_harness_moved_is_gits_answer()
  local base = string.rep("a", 40)
  local function moved(known: integer | nil, diff: integer | nil): boolean, {string}
    local lines: {string} = {}
    local answer = Github.harness_moved(function(argv: {string}): integer | nil
      lines[#lines + 1] = table.concat(argv, " ")
      return argv[1] == "cat-file" and known or diff
    end, base)
    return answer, lines
  end
  local answer, lines = moved(0, 1)
  assert(answer and lines[1] == "cat-file -e " .. base .. "^{commit}" and
      lines[2] == "diff --quiet " .. base .. " HEAD -- :/build/harness_epoch.tl", table.concat(lines, "\n"))
  assert(not moved(0, 0), "an unchanged harness moved")
  assert(not moved(0, 2) and not moved(0, nil), "a refused diff moved the harness")
  answer, lines = moved(128, 1)
  assert(not answer and #lines == 1, "a base git lacks moved the harness")
  assert(not moved(nil, 1), "no git moved the harness")
end

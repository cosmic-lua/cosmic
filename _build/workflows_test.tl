#!/usr/bin/env cosmic
--- reads: .github/workflows
-- Ratchets over the workflow files themselves.
--
-- CI's environment is a build input, pinned three times over: a
-- digest-pinned container (because an OS image roll moved the coverage
-- floor), `--privileged` (because the sandbox tests need a kernel that
-- will actually enforce), and a non-root builder (because tests skip
-- differently as root). All three pins are per-JOB — container config is
-- job-level in GitHub Actions, there is no anchor and no shared block —
-- so each is written once per lane and copies drift. Copies of a pin
-- achieve the opposite of a visible, reviewable edit: a bump that misses
-- one site leaves lanes running DIFFERENT environments, silently, which
-- is the leak the pin exists to prevent.
--
-- So the copies stay and a test makes them agree.
--
-- The privilege and identity pins are the ones whose loss is invisible:
-- an unprivileged lane cannot enforce Landlock, and a root lane skips
-- what it cannot restrict. Both turn `_cli/fence_test.tl`'s real-denial
-- assertion and the quicksand tests into no-ops, and a gate reports a
-- skip it was not told about as a pass. A lane that stops testing what
-- it was built to test stays green either way.

local check = require("cosmic.check")
local fs = require("cosmic.fs")

local WORKFLOWS < const > = ".github/workflows"

--- Every workflow file, in path order.
--- @return {string} Paths relative to the repo root
local function workflows(): {string}
  local found = check.must(fs.find(WORKFLOWS, {glob = "*.yml"}))
  table.sort(found)
  assert(#found > 0, "no workflows found under " .. WORKFLOWS)
  return found
end

--- Lines of a file that start with `key` once trimmed, with their
--- 1-based line numbers.
--- @param path string File to read
--- @param key string The leading token, e.g. "image:"
--- @return {{integer, string}} Line number and trimmed text
local function lines_with(path: string, key: string): {{integer, string}}
  local out: {{integer, string}} = {}
  local n = 0
  for line in check.must(fs.read(path)):gmatch("([^\n]*)\n?") do
    n = n + 1
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed:sub(1, #key) == key then
      out[#out + 1] = {n, trimmed}
    end
  end
  return out
end

--- The body of one step in a workflow: from the line whose trimmed text
--- is `- name: <name>` up to (not including) the next line at that same
--- indentation. Scanned line by line, the same technique `jobs_in` uses
--- and for the same reason: step names contain `-`, which is a
--- quantifier in a Lua pattern, so building a pattern out of the name
--- would silently match the wrong block.
--- @param path string The workflow file
--- @param name string The step's `name:` text, unquoted
--- @return string The step's lines, including its own `- name:` line
local function step_body(path: string, name: string): string
  local target = "- name: " .. name
  local indent: string = nil
  local body: {string} = {}
  for line in check.must(fs.read(path)):gmatch("([^\n]*)\n?") do
    local lead = line:match("^(%s*)%- ")
    if indent then
      if lead == indent then
        break
      end
      body[#body + 1] = line
    else
      local trimmed = line:match("^%s*(.-)%s*$")
      if trimmed == target then
        indent = lead
        body[#body + 1] = line
      end
    end
  end
  assert(indent, path .. ": step '" .. name .. "' not found")
  return table.concat(body, "\n")
end

--- The body of one job in a workflow: from the line whose text is
--- `  <name>:` up to (not including) the next line at that depth or
--- shallower. Job-wide rather than step-wide because `step_body` keys
--- on `- name:` and a bare `- uses:` step carries none — the peers
--- lane's `actions/download-artifact` step is one, so nothing
--- step-scoped can read it.
---
--- Scanned line by line rather than matched, the same technique
--- `jobs_in` uses and for the same reason: a job name may contain `-`,
--- which is a quantifier in a Lua pattern, so building a pattern out
--- of the name would silently match the wrong block.
--- @param path string The workflow file
--- @param name string The job's key under `jobs:`
--- @return string The job's lines, including its own `<name>:` line
local function job_body(path: string, name: string): string
  local body: {string} = {}
  local in_jobs = false
  local found = false
  for line in check.must(fs.read(path)):gmatch("([^\n]*)\n?") do
    if found then
      if line:match("^%S") or line:match("^  %S") then
        break
      end
      body[#body + 1] = line
    elseif line:match("^jobs:%s*$") then
      in_jobs = true
    elseif in_jobs and line:match("^  ([%w_%-]+):%s*$") == name then
      found = true
      body[#body + 1] = line
    end
  end
  assert(found, path .. ": job '" .. name .. "' not found")
  return table.concat(body, "\n")
end

-- One distinct container reference across every workflow. This is the
-- assertion the six copies exist for: they are only "a visible pin per
-- lane" if they are the same pin.
local function test_one_container_image_across_every_workflow()
  local seen: {string: string} = {}
  local count = 0
  for _, path in ipairs(workflows()) do
    for _, hit in ipairs(lines_with(path, "image:")) do
      count = count + 1
      local first = seen[hit[2]]
      seen[hit[2]] = first or (path .. ":" .. hit[1])
    end
  end
  assert(count > 1, "expected several pinned container lines, saw " .. count)
  local distinct: {string} = {}
  for image, where in pairs(seen) do
    distinct[#distinct + 1] = where .. "  " .. image
  end
  table.sort(distinct)
  assert(#distinct == 1,
    "every workflow must name the SAME container digest; a bump that " ..
    "misses a site leaves lanes on skewed environments. Found " ..
    #distinct .. ":\n  " .. table.concat(distinct, "\n  "))
end

-- And the digest is a digest: a tag would make the pin decorative.
local function test_the_image_is_pinned_by_digest()
  for _, path in ipairs(workflows()) do
    for _, hit in ipairs(lines_with(path, "image:")) do
      assert(hit[2]:find("@sha256:%x+"),
        path .. ":" .. hit[1] .. ": the container must be pinned by " ..
        "digest, not by tag: " .. hit[2])
    end
  end
end

-- Every job that runs build machinery runs it in that container. Named
-- rather than derived because "runs build machinery" is a judgement:
-- the cross-OS smoke matrix deliberately does NOT (real macOS and
-- Windows runners are its entire point), and a job added without a
-- decision here is a job whose environment nobody chose. Keyed by
-- `<workflow file>:<job>`, not bare job name — a future job that merely
-- reuses the name `smoke` in another workflow is a fresh decision, not
-- an inherited exemption.
local UNCONTAINERISED < const >: {string: string} = {
  ["pr.yml:smoke"] =
  "the cross-OS matrix: native macOS/Windows runners are the point",
  ["release.yml:release"] =
  "no build machinery: artifact download + `gh release create`",
  ["release.yml:peers"] =
  "peer versions are the runner image's: the pinned container has no node and no go",
}

-- What a lane pins about its environment, per job.
local record Job
  name: string
  where: string
  containerised: boolean
  options: string
  makes_a_builder: boolean
  drops_to_builder: boolean
end

--- Every job in a workflow, with the environment pins it declares.
---
--- Scanned line by line rather than matched: a job name may contain `-`
--- (`smoke-build`), which is a quantifier in a Lua pattern, so building
--- a pattern out of the name silently matches the wrong block.
--- @param path string The workflow file
--- @return {string: Job} Job name to what that job pins
local function jobs_in(path: string): {string: Job}
  local out: {string: Job} = {}
  local in_jobs = false
  local in_container = false
  local current: Job = nil
  local n = 0
  for line in check.must(fs.read(path)):gmatch("([^\n]*)\n?") do
    n = n + 1
    if line:match("^jobs:%s*$") then
      in_jobs = true
    elseif line:match("^%S") then
      in_jobs = false
      in_container = false
      current = nil
    elseif in_jobs then
      local name = line:match("^  ([%w_%-]+):%s*$")
      if name then
        current = {
          name = name,
          where = path .. ":" .. n,
          containerised = false,
          options = "",
          makes_a_builder = false,
          drops_to_builder = false,
        }
        out[name] = current
        in_container = false
      elseif current then
        if line:match("^    container:%s*$") then
          current.containerised = true
          in_container = true
        elseif line:match("^    %S") then
          -- A sibling key at the job's own depth closes the container
          -- block, so a step's `options:` is never read as the
          -- container's.
          in_container = false
        end
        if in_container then
          local options = line:match("^      options:%s*(.-)%s*$")
          if options then
            current.options = options
          end
        end
        if line:find("useradd", 1, true) and line:find("builder", 1, true) then
          current.makes_a_builder = true
        end
        if line:find("runuser -u builder", 1, true) then
          current.drops_to_builder = true
        end
      end
    end
  end
  return out
end

--- The jobs that declare a container, across every workflow.
--- @return {Job} In no particular order
local function containerised_jobs(): {Job}
  local out: {Job} = {}
  for _, path in ipairs(workflows()) do
    for _, job in pairs(jobs_in(path)) do
      if job.containerised then
        out[#out + 1] = job
      end
    end
  end
  return out
end

local function test_every_build_job_is_containerised()
  local jobs = 0
  for _, path in ipairs(workflows()) do
    for name, job in pairs(jobs_in(path)) do
      jobs = jobs + 1
      local key = fs.basename(path) .. ":" .. name
      if UNCONTAINERISED[key] then
        assert(not job.containerised, path .. ": job '" .. name ..
          "' is recorded as uncontainerised (" .. UNCONTAINERISED[key] ..
          ") but declares a container")
      else
        assert(job.containerised, path .. ": job '" .. name .. "' runs " ..
          "outside the pinned container. Either give it the same " ..
          "container block, or record why it is exempt in " ..
          "UNCONTAINERISED here — an unpinned environment is a build " ..
          "input nobody chose")
      end
    end
  end
  -- Not a job-count ratchet — lanes merge and split deliberately. This
  -- catches the scanner finding nothing, which would make the loop above
  -- vacuously green.
  assert(jobs >= 4, "expected the workflow jobs to be found, saw " .. jobs)
end

-- One distinct `options:` across every containerised lane, by the same
-- argument as the image: copies are only a per-lane pin if they agree.
-- Checked as the whole line rather than as a `--privileged` substring,
-- so a flag added to one lane and not the others fails here too.
local function test_one_container_options_across_every_workflow()
  local seen: {string: string} = {}
  local jobs = containerised_jobs()
  for _, job in ipairs(jobs) do
    seen[job.options] = seen[job.options] or (job.where .. " (" .. job.name .. ")")
  end
  local distinct: {string} = {}
  for options, where in pairs(seen) do
    distinct[#distinct + 1] = where .. "  options: " .. options
  end
  table.sort(distinct)
  assert(#jobs > 1, "expected several containerised lanes, saw " .. #jobs)
  assert(#distinct == 1,
    "every containerised lane must declare the SAME container options; " ..
    "a lane on different options is a lane testing a different " ..
    "environment. Found " .. #distinct .. ":\n  " ..
    table.concat(distinct, "\n  "))
end

-- And those options grant the privilege the sandbox tests need. Without
-- it Landlock cannot enforce, `_cli/fence_test.tl`'s denial assertion
-- takes its no-Landlock path, and the quicksand tests cannot unshare or
-- mount — so the lane goes green having tested nothing it exists for.
local function test_the_container_is_privileged()
  for _, job in ipairs(containerised_jobs()) do
    assert(job.options:find("--privileged", 1, true),
      job.where .. ": job '" .. job.name .. "' runs unprivileged, so its " ..
      "sandbox tests degrade to no-ops and report as passes: " ..
      "options: " .. job.options)
  end
end

-- Every containerised lane makes a non-root builder AND runs its build
-- machinery as that user. Both halves, because either alone is the
-- failure: a lane that creates `builder` and keeps running as root has
-- a decorative pin, and `runuser` without the user is a lane that does
-- not start. Root skips what it cannot restrict, and a gate reports an
-- unannounced skip as a pass.
local function test_every_containerised_job_drops_to_a_non_root_builder()
  for _, job in ipairs(containerised_jobs()) do
    assert(job.makes_a_builder, job.where .. ": job '" .. job.name ..
      "' declares no non-root builder (`useradd … builder`), so it runs " ..
      "as root and its enforcement tests skip rather than enforce")
    assert(job.drops_to_builder, job.where .. ": job '" .. job.name ..
      "' never drops to the builder (`runuser -u builder`), so the " ..
      "identity it prepared is not the one the gate runs under")
  end
end

-- The perf lane's compare exit status must actually reach the step: it
-- arrives through `| tee`, and a pipeline's status is tee's without
-- `pipefail`, so a one-token edit that drops it could turn the lane's
-- one signal -- a red run on a reproduced regression -- into a quiet
-- green without any other test noticing.
local function test_the_perf_lane_compare_propagates_its_verdict()
  local path = WORKFLOWS .. "/perf.yml"
  local body = step_body(path, "compare against the latest release")
  assert(body:find("pipefail", 1, true),
    path .. ": the compare step must run under `pipefail` — the compare's " ..
    "status arrives through `| tee`, and a pipeline's status is tee's " ..
    "without it")
  assert(body:find('exit "$rc"', 1, true),
    path .. ": the compare step must propagate the compare's exit code " ..
    "via `exit \"$rc\"`")
  assert(not body:find("|| true", 1, true),
    path .. ": the compare step must not swallow its exit code with `|| true`")
  assert(not body:find("continue-on-error", 1, true),
    path .. ": the compare step must not disable failure with " ..
    "`continue-on-error`")
  assert(body:find("perf-compare: SKIP", 1, true),
    path .. ": the bootstrap path (no baseline yet) must still succeed")
end

--- The perf lane's compare is only a compare if both sides run the SAME
--- instrument. Run the release binary bare and it answers `_perf.*`
--- from its own embedded copy, so the baseline number describes that
--- release's scenarios rather than this tree's — and a `_perf`
--- signature change becomes unlandable in one PR. The step must
--- therefore measure the baseline through `_perf/baserun.tl`, whose
--- `--modules` root scopes the tree to `_perf` alone, and must not
--- carry the bare form beside it.
local function test_the_perf_lane_baseline_runs_the_trees_perf()
  local path = WORKFLOWS .. "/perf.yml"
  local body = step_body(path, "compare against the latest release")
  assert(body:find("_perf/baserun.tl", 1, true),
    path .. ": the compare step must measure the baseline through " ..
    "`_perf/baserun.tl`, or the previous binary answers `_perf.*` from " ..
    "its own embed and the two sides are measured by different instruments")
  assert(not body:find("cosmic-lua _perf/run.tl", 1, true),
    path .. ": the bare baseline invocation `cosmic-lua _perf/run.tl` " ..
    "must not survive — it is the shape `_perf/baserun.tl` replaces")
  assert(body:find("--baseline-bin", 1, true),
    path .. ": the gate still needs `--baseline-bin` so a flagged " ..
    "regression re-measures both sides")
end

-- The release publishes whatever the perf lane reads (D44): the compare
-- lives in perf.yml and nothing in release.yml measures speed or
-- branches on a perf verdict. A step that quietly reintroduced either
-- would put the daily release back behind a noise-prone gate, so the
-- absence is ratcheted by name.
local function test_the_release_does_not_gate_on_perf()
  local path = WORKFLOWS .. "/release.yml"
  local body = job_body(path, "build")
  for _, needle in ipairs({"_perf/gate.tl", "_perf/run.tl", "perf_gate",
      "PERF_GATE", "selfcheck.json"}) do
    assert(not body:find(needle, 1, true),
      path .. ": the `build` job must not carry `" .. needle .. "` — the " ..
      "perf compare runs in perf.yml and never gates a release")
  end
  local contents = check.must(fs.read(path))
  assert(not contents:find("perf_gate", 1, true),
    path .. ": no `perf_gate` dispatch input — there is no perf gate to " ..
    "disable")
end

-- The peer table is measured by running the peer harness bare, so
-- `_perf.*` resolves from the measured binary's own /zip rather than
-- from the checkout. Sound only because that binary is this run's own
-- candidate: `needs: build`, and the `cosmic-lua` artifact the `build`
-- job uploaded. Point the lane at a published release instead and the
-- harness doing the measuring becomes that release's, while the table
-- still reads as a report on this tree -- a skew with no symptom.
local function test_the_peers_lane_measures_this_runs_own_binary()
  local path = WORKFLOWS .. "/release.yml"
  local body = job_body(path, "peers")
  assert(body:find("needs: build", 1, true),
    path .. ": the `peers` job must declare `needs: build`, or the " ..
    "binary it measures is not this run's candidate and the bare peer " ..
    "harness run reports a stale embedded instrument as this tree's")
  assert(body:find("name: cosmic-lua", 1, true),
    path .. ": the `peers` job must download the `cosmic-lua` artifact " ..
    "the `build` job uploaded — that artifact is what makes the " ..
    "measured binary this checkout's own, and its embedded `_perf` ours")
  assert(body:find("_perf/peers/run.tl", 1, true),
    path .. ": the `peers` job must run the tree's peer harness " ..
    "`_perf/peers/run.tl`; without it the lane publishes no peer table")
  assert(not body:find("_perf/baseline.tl", 1, true),
    path .. ": the `peers` job has ONE cosmic subject measured against " ..
    "CPython, Node and Go — there is no second cosmic instrument to " ..
    "hold fixed, so a baseline runner has no place in this lane")
  assert(not body:find("gh release download", 1, true),
    path .. ": the `peers` job must not take its binary from a " ..
    "published release — the bare harness run would then measure that " ..
    "release's embedded `_perf`, not this checkout's")
  local build = job_body(path, "build")
  assert(build:find("name: cosmic-lua", 1, true),
    path .. ": the `build` job must upload the `cosmic-lua` artifact " ..
    "the `peers` job downloads, or the two lanes are not the one binary")
end

print("all workflow ratchet tests passed")

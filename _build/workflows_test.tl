#!/usr/bin/env cosmic
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
  local found = check.must(fs.collect(WORKFLOWS, "*.yml"))
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
test_one_container_image_across_every_workflow()

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
test_the_image_is_pinned_by_digest()

-- Every job that runs build machinery runs it in that container. Named
-- rather than derived because "runs build machinery" is a judgement:
-- the cross-OS smoke matrix deliberately does NOT (real macOS and
-- Windows runners are its entire point), and a job added without a
-- decision here is a job whose environment nobody chose.
local UNCONTAINERISED < const >: {string: string} = {
  ["smoke"] = "the cross-OS matrix: native macOS/Windows runners are the point",
  ["release"] = "no build machinery: artifact download + `gh release create`",
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
      if UNCONTAINERISED[name] then
        assert(not job.containerised, path .. ": job '" .. name ..
          "' is recorded as uncontainerised (" .. UNCONTAINERISED[name] ..
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
test_every_build_job_is_containerised()

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
test_one_container_options_across_every_workflow()

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
test_the_container_is_privileged()

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
test_every_containerised_job_drops_to_a_non_root_builder()

print("all workflow ratchet tests passed")

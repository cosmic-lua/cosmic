#!/usr/bin/env cosmic
-- Ratchets over the workflow files themselves.
--
-- CI's environment is a build input, pinned twice over: a digest-pinned
-- container (because an OS image roll moved the coverage floor)
-- and a non-root builder (because tests skip differently as root). Both
-- pins are per-JOB — container config is job-level in GitHub Actions,
-- there is no anchor and no shared block — so the pin is written once
-- per lane and copies drift. Copies of a digest achieve the opposite of
-- a visible, reviewable edit: a bump that misses one site leaves lanes
-- running DIFFERENT environments, silently, which is the leak the pin
-- exists to prevent.
--
-- So the copies stay and a test makes them agree.

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

--- Whether each job in a workflow declares a container, by job name.
---
--- Scanned line by line rather than matched: a job name may contain `-`
--- (`smoke-build`), which is a quantifier in a Lua pattern, so building
--- a pattern out of the name silently matches the wrong block.
--- @param path string The workflow file
--- @return {string: boolean} Job name to whether it declares a container
local function job_containers(path: string): {string: boolean}
  local out: {string: boolean} = {}
  local in_jobs = false
  local current: string = nil
  for line in check.must(fs.read(path)):gmatch("([^\n]*)\n?") do
    if line:match("^jobs:%s*$") then
      in_jobs = true
    elseif line:match("^%S") then
      in_jobs = false
      current = nil
    elseif in_jobs then
      local name = line:match("^  ([%w_%-]+):%s*$")
      if name then
        current = name
        out[current] = false
      elseif current and line:match("^    container:%s*$") then
        out[current] = true
      end
    end
  end
  return out
end

local function test_every_build_job_is_containerised()
  local jobs = 0
  for _, path in ipairs(workflows()) do
    for name, containerised in pairs(job_containers(path)) do
      jobs = jobs + 1
      if UNCONTAINERISED[name] then
        assert(not containerised, path .. ": job '" .. name ..
          "' is recorded as uncontainerised (" .. UNCONTAINERISED[name] ..
          ") but declares a container")
      else
        assert(containerised, path .. ": job '" .. name .. "' runs " ..
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

print("all workflow ratchet tests passed")

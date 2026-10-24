--- The variables that name a CI run, its runner or its container rather
--- than anything a test is given, which a gating suite's workers are not
--- given (cosmic_ci.orchestration's `forget_run`): each of `exact`, and
--- each that begins with one of `prefixes` -- GitHub's, and the driver's
--- own switches -- but those of `kept`. `exact` holds systemd's per-unit
--- ones where a runner is a service, CI, and the container's HOSTNAME
--- (its ID, new every job); `kept` holds COSMIC_CI_REQUIRE_SANDBOX,
--- which a test reads (build/sandboxed_verdicts_test.tl).
---
--- Data alone, in run_names.json beside this module: the tree's own
--- build/ci_tree_test.tl, which cannot require a module of ci/, reads it
--- to find a tree source that names one of them.
local DataPath = require("cosmic_ci.data_path")
local Fs = require("cosmic.fs")
local Shape = require("cosmic.shape")

local record RunNames
  --- What run_names.json holds.
  record Names
    exact: {string}
    prefixes: {string}
    kept: {string}
  end
  --- The names the file lists. Raises where it cannot be read.
  names: function(): Names
end

local DATA <const> = Shape.record_of("RunNames.Names")

--- What has been read of the file: the data once it is.
local record Read
  data?: RunNames.Names
end

local read: Read = {}

function RunNames.names(): RunNames.Names
  local held = read.data
  if held ~= nil then return held end
  local path = DataPath.of("run_names.json")
  local text, why = Fs.read(path)
  assert(text ~= nil, why)
  local decoded, trouble = DATA:decode_into(text)
  assert(decoded ~= nil, path .. ": " .. trouble)
  read.data = decoded
  return decoded
end

return RunNames

local fs = require("cosmic.fs")
local check = require("cosmic.check")
local stage = require("_eval.stage")

local EXPECTED_IDS < const >: {string} = {
  "json-cli",
  "module-tests",
  "sqlite-indexer",
  "child-tcp",
  "text-report",
  "multi-module-build",
  "contained-task",
}

local VALID_STATUS < const >: {string: boolean} = {proven = true, new = true}

local function test_manifest_parses()
  local manifest = check.must(stage.load_manifest(stage.MANIFEST_PATH))
  assert(manifest.version == 1, "expected version 1, got " .. tostring(manifest.version))
  assert(#manifest.tasks == #EXPECTED_IDS,
    "expected " .. #EXPECTED_IDS .. " tasks, got " .. #manifest.tasks)
end
test_manifest_parses()

local function test_ids_in_order()
  local manifest = check.must(stage.load_manifest(stage.MANIFEST_PATH))
  for i, task in ipairs(manifest.tasks) do
    assert(task.id == EXPECTED_IDS[i],
      "task " .. i .. ": expected id " .. EXPECTED_IDS[i] .. ", got " .. tostring(task.id))
  end
end
test_ids_in_order()

local function test_statuses_are_valid()
  local manifest = check.must(stage.load_manifest(stage.MANIFEST_PATH))
  for _, task in ipairs(manifest.tasks) do
    assert(VALID_STATUS[task.status],
      task.id .. ": status must be proven or new, got " .. tostring(task.status))
  end
end
test_statuses_are_valid()

local function test_metrics_are_nonempty()
  local manifest = check.must(stage.load_manifest(stage.MANIFEST_PATH))
  for _, task in ipairs(manifest.tasks) do
    assert(#task.metrics > 0, task.id .. ": metrics must not be empty")
  end
end
test_metrics_are_nonempty()

local function test_brief_paths_exist()
  local manifest = check.must(stage.load_manifest(stage.MANIFEST_PATH))
  for _, task in ipairs(manifest.tasks) do
    assert(fs.is_file(task.brief),
      task.id .. ": brief path does not exist: " .. tostring(task.brief))
  end
end
test_brief_paths_exist()

local function test_missing_file_errors()
  local manifest, err = stage.load_manifest("_eval/no-such-suite.tl")
  assert(manifest == nil, "missing suite file should not parse")
  assert(err ~= nil and #err > 0, "missing suite file should report an error")
end
test_missing_file_errors()

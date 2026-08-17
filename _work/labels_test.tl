#!/usr/bin/env cosmic
local labels = require("_work.labels")
local model = require("_work.model")

local type Issue = model.Issue

local function test_labels_of_phase_only()
  local i: Issue = {phase = "ready"}
  local names = labels.labels_of(i)
  assert(#names == 1, "expected 1 label, got " .. tostring(#names))
  assert(names[1] == "work:ready", "got: " .. names[1])
end
test_labels_of_phase_only()

local function test_labels_of_markers_ride_along()
  local i: Issue = {phase = "plan", epic = true, enable = true}
  local names = labels.labels_of(i)
  assert(table.concat(names, " ") == "work:plan work:epic work:enable",
    "got: " .. table.concat(names, " "))
end
test_labels_of_markers_ride_along()

local function test_labels_of_round_trips_through_the_read_half()
  local i: Issue = {phase = "plan", finding = true, enable = true}
  local names = labels.labels_of(i)
  assert(model.phase_of(names) == "plan", "the phase reads back")
  assert(model.has_marker(names, "finding"), "the finding marker reads back")
  assert(model.has_marker(names, "enable"), "the enable marker reads back")
  assert(not model.has_marker(names, "epic"), "an unset marker stays off")
end
test_labels_of_round_trips_through_the_read_half()

local function test_every_label_written_is_in_the_vocabulary()
  local known: {string: boolean} = {}
  for _, l in ipairs(labels.LABELS) do
    known[l.name] = true
  end
  local i: Issue = {phase = "check", epic = true, finding = true, enable = true}
  for _, name in ipairs(labels.labels_of(i)) do
    assert(known[name], name .. " is written but not in LABELS, so init never "
      .. "creates it")
  end
end
test_every_label_written_is_in_the_vocabulary()

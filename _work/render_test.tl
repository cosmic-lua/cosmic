#!/usr/bin/env cosmic
local render = require("_work.render")
local model = require("_work.model")
local time = require("cosmic.time")

local type Issue = model.Issue

local function plain(n: integer): Issue
  return {number = n, title = "issue " .. tostring(n)}
end

local function epic(n: integer): Issue
  return {number = n, title = "epic " .. tostring(n), epic = true}
end

local function finding(n: integer, created_at?: string): Issue
  return {number = n, title = "finding " .. tostring(n), finding = true,
    created_at = created_at}
end

local function test_exempt_suffix_zero_when_nothing_exempt()
  local list = {plain(1), plain(2)}
  assert(render.exempt_suffix(list, "plan") == "",
    "no epics or findings should render no suffix")
  assert(render.exempt_suffix({}, "plan") == "", "an empty phase renders no suffix")
end
test_exempt_suffix_zero_when_nothing_exempt()

local function test_exempt_suffix_single_class()
  local list = {plain(1), epic(2), epic(3)}
  assert(render.exempt_suffix(list, "plan") == " (+2 epics)",
    "got: " .. render.exempt_suffix(list, "plan"))
end
test_exempt_suffix_single_class()

local function test_exempt_suffix_single_class_findings_only()
  local list = {plain(1), finding(2), finding(3), finding(4)}
  assert(render.exempt_suffix(list, "plan") == " (+3 findings)",
    "got: " .. render.exempt_suffix(list, "plan"))
end
test_exempt_suffix_single_class_findings_only()

local function test_exempt_suffix_multi_class()
  local list: {Issue} = {}
  for n = 1, 7 do
    list[#list + 1] = epic(n)
  end
  for n = 100, 108 do
    list[#list + 1] = finding(n)
  end
  assert(render.exempt_suffix(list, "plan") == " (+7 epics, +9 findings)",
    "got: " .. render.exempt_suffix(list, "plan"))
end
test_exempt_suffix_multi_class()

local function test_exempt_suffix_only_binds_the_exempted_phase()
  local list = {epic(1), finding(2)}
  assert(render.exempt_suffix(list, "ready") == "",
    "only plan exempts anything today, so ready renders no suffix")
end
test_exempt_suffix_only_binds_the_exempted_phase()

local function test_finding_pressure_zero()
  assert(render.finding_pressure({plain(1), epic(2)}) == "  findings: 0",
    "got: " .. render.finding_pressure({plain(1), epic(2)}))
end
test_finding_pressure_zero()

local function test_finding_pressure_counts_and_ages_the_oldest()
  local five_days_ago = time.format_iso8601((time.now()) - 5 * 86400)
  local right_now = time.format_iso8601((time.now()))
  local list = {finding(1, five_days_ago), finding(2, right_now)}
  local line = render.finding_pressure(list)
  assert(line == "  findings: 2 (oldest 5d old)", "got: " .. line)
end
test_finding_pressure_counts_and_ages_the_oldest()

--- `finding_pressure` trusts the caller's ordering (the doc comment
--- requires oldest-first) rather than comparing dates itself, so the
--- FIRST finding in the list is the one aged — even when a later entry
--- is chronologically older.
local function test_finding_pressure_ages_list_order_not_true_oldest()
  local one_day_ago = time.format_iso8601(time.now() - 1 * 86400)
  local thirty_days_ago = time.format_iso8601(time.now() - 30 * 86400)
  local newer_but_first = finding(1, one_day_ago)
  local older_but_second = finding(2, thirty_days_ago)
  local line = render.finding_pressure({newer_but_first, older_but_second})
  assert(line == "  findings: 2 (oldest 1d old)", "got: " .. line)
end
test_finding_pressure_ages_list_order_not_true_oldest()

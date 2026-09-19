local Coverage = require("cosmic.coverage")

local function test_distinct_long_strings_with_same_source_merge_hits()
  local name = "coverage.same." .. string.rep("long", 40)
  local first = assert(load("local n = 1\nreturn n", "@" .. name, "t"))
  assert(first() == 1)
  local before = Coverage.snapshot()
  local second = assert(load(string.rep("\n", 8192) .. "local n = 2\nreturn n", "@" .. name, "t"))
  assert(second() == 2)
  local after = Coverage.snapshot()
  assert(after[name][1] == true)
  assert(after[name][8193] == true, "equal source names must union their hits")
  assert(before[name][8193] == nil, "snapshots must not acquire later hits")
  after[name][1] = nil
  after[name] = {}
  assert(Coverage.snapshot()[name][1] == true, "snapshot mutation must not change collection")
end

local function test_source_identity_survives_collection_and_stack_reuse()
  for i = 1, 40 do
    local name = "coverage.retained." .. tostring(i) .. string.rep("long", 40)
    local probe = assert(load("return 42", "@" .. name, "t"))
    assert(probe() == 42)
    -- Previous closures are unreachable; only their source names stay rooted.
    -- Long source strings are not interned; cached pointers must stay rooted.
    collectgarbage("collect")
  end
  collectgarbage("collect")
  local hits = Coverage.snapshot()
  for i = 1, 40 do
    local name = "coverage.retained." .. tostring(i) .. string.rep("long", 40)
    assert(hits[name][1] == true, "collected chunks must retain their source identity")
  end
end

local coroutine_probe = assert(load(table.concat({
  "while true do",
  "  coroutine.yield(42)",
  "end",
}, "\n"), "@coverage.coroutine.sessions", "t"))
local shared_thread = coroutine.create(coroutine_probe)

local function check_fresh_session_and_coroutine()
  local before = Coverage.snapshot()
  assert(before["coverage.coroutine.sessions"] == nil, "a session must start with no previous hits")
  local ok, value = coroutine.resume(shared_thread)
  assert(ok and value == 42, "a coroutine must survive collector session changes")
  local after = Coverage.snapshot()
  assert(after["coverage.coroutine.sessions"][2] == true)
end

local function test_first_coroutine_session()
  check_fresh_session_and_coroutine()
end

local function test_second_coroutine_session()
  check_fresh_session_and_coroutine()
end

local function test_coverage_does_not_retain_captured_values()
  local probe = assert(load(table.concat({
    "local weak = setmetatable({}, {__mode = 'v'})",
    "do",
    "  local payload = {}",
    "  weak[1] = payload",
    "  local env = {payload = payload}",
    "  local closure = assert(load('return payload', '@coverage.capture.' .. string.rep('long', 40), 't', env))",
    "  assert(closure() == payload)",
    "end",
    "collectgarbage('collect')",
    "collectgarbage('collect')",
    "assert(weak[1] == nil, 'coverage must not retain a closure environment')",
  }, "\n"), "@coverage.capture.check", "t"))
  probe()
end

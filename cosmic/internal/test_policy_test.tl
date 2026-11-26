--- Tests of [`cosmic.internal.test_policy`]: what a policy stands for, read
--- directly. cosmic/test_policy_test.tl holds the build's read and the
--- harness's to the same cases.

local TestPolicy = require("cosmic.internal.test_policy")

local function test_an_empty_policy_stands_for_nothing()
  local found = assert(TestPolicy.declared({}))
  assert(#found.reads == 0 and #found.host == 0 and #found.caches == 0 and #found.parent == 0)
  assert(not (found.tool or found.lua or found.nests or found.noexec or found.store or found.system))
  assert(found.timeout == nil)
end

local function test_the_profile_cosmic_is_lua_alone_and_tool_with_the_grant_of_o_bin()
  assert(assert(TestPolicy.declared({ profiles = { "cosmic" } })).lua)
  local tool = assert(TestPolicy.declared({ profiles = { "cosmic" },
    grants = { { path = "o/bin", letters = "rx" } } }))
  assert(tool.tool and not tool.lua)
  local _, why = TestPolicy.declared({ grants = { { path = "o/bin", letters = "rx" } } })
  assert(why:find("beside the profile", 1, true), why)
end

local function test_proc_is_read_in_host_after_the_grants()
  local found = assert(TestPolicy.declared({ profiles = { "proc" },
    grants = { { path = "/etc/hosts", letters = "r" }, { path = "a", letters = "r" } } }))
  assert(table.concat(found.host, ",") == "/etc/hosts,/proc", table.concat(found.host, ","))
  assert(table.concat(found.reads, ",") == "a")
end

local function test_a_cache_is_held_to_the_names_the_caller_knows()
  local policy: TestPolicy.Policy = { grants = { { path = "/cache/zig", letters = "rwxc" } } }
  assert(table.concat(assert(TestPolicy.declared(policy)).caches, ",") == "zig")
  local _, why = TestPolicy.declared(policy, function(name: string): string
    return if name == "zig" then "no such cache" else "" end
  end)
  assert(why == "grants[1].path /cache/zig: no such cache", why)
  local _, empty = TestPolicy.declared({ grants = { { path = "/cache/", letters = "rwxc" } } })
  assert(empty:find("names no cache", 1, true), empty)
end

local function test_any_limit_is_not_yet_taken_and_none_is_no_limit()
  assert(TestPolicy.declared({ limits = {} }))
  local _, why = TestPolicy.declared({ limits = { processes = 4 } })
  assert(why:find("^limits is not yet taken"), why)
end

local function test_a_timeout_is_held_to_an_hour()
  assert(assert(TestPolicy.declared({ timeout = 3600 })).timeout == 3600)
  for _, seconds in ipairs({ 0, 3601 }) do
    local _, why = TestPolicy.declared({ timeout = seconds })
    assert(why == TestPolicy.timeout_refused(), why)
  end
end

local function test_the_fields_are_named_and_kinded()
  assert(TestPolicy.kind_of("grants") == "grants" and TestPolicy.kind_of("nope") == nil)
  assert(TestPolicy.field_list():find("^cpu_features, env, grants, "), TestPolicy.field_list())
end

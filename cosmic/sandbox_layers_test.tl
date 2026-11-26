--- What [`Sandbox.layers`] (cosmic/sandbox/init.tl, cosmic/sandbox/policy.tl's
--- [`rules.layers`]) tells of the layers [`Sandbox.restrict`] would hold a
--- process to, with nothing applied: the Landlock paths, the seccomp groups,
--- the exec filter and the rlimits, and a refusal for what only a child can
--- be held to. A child's are cosmic/child_layers_test.tl's.

local Array = require("cosmic.array")
local Sandbox = require("cosmic.sandbox")
local Test = require("cosmic.test")

--- The layers of `policy`, which must be ones a restriction takes; ends
--- the test on macOS, where a Seatbelt profile holds the process and
--- there are no layers to tell.
local function layers_of(policy: Sandbox.Policy): Sandbox.Layers
  if Sandbox.on_macos() then
    Test.skip("a Seatbelt profile holds a process on macOS, which has no layers to tell")
  end
  local layers, why = Sandbox.layers(policy)
  assert(layers ~= nil, why)
  return layers
end

--- A policy of paths and calls is a ruleset and a filter: no exec where no
--- grant gives `x`, and nothing of a child's.
local function test_paths_and_calls_are_a_ruleset_and_a_filter()
  local layers = layers_of({ grants = { { path = "/srv", letters = "r" }, { calls = "fork" } } })
  local first = Array.at(layers.landlock, 1)
  assert(#layers.landlock == 1 and first.path == "/srv" and first.letters == "r")
  assert(#layers.calls == 1 and Array.at(layers.calls, 1) == "fork" and #layers.boot == 0)
  assert(layers.exec_refused and #layers.sockets == 0 and #layers.namespaces == 0)
  assert(not layers.root and #layers.relay == 0 and #layers.loopback == 0)
  assert(layers.rlimits["core"] == 0 and layers.rlimits["nofile"] ~= nil and layers.rlimits["cpu"] == nil)
end

--- One grant of `x`, wherever it is, leaves the exec filter out.
local function test_a_grant_of_x_leaves_the_exec_filter_out()
  local layers = layers_of({ grants = { { path = "/srv", letters = "r" }, { path = "/usr/bin/git", letters = "rx" } } })
  assert(not layers.exec_refused)
  assert(layers_of({}).exec_refused)
end

--- The limits are the rlimits by restriction's names, beside the defaults.
local function test_the_limits_are_rlimits_beside_the_defaults()
  local layers = layers_of({ limits = { cpu_seconds = 5, file_bytes = 0, open_files = 64 } })
  assert(layers.rlimits["cpu"] == 5 and layers.rlimits["fsize"] == 0 and layers.rlimits["nofile"] == 64)
  assert(layers.rlimits["core"] == 0)
end

--- The policy is merged first: a profile is its paths, and grants of one
--- path are one, their letters joined.
local function test_the_policy_is_merged_first()
  local profiled = layers_of({ grants = { { profile = "proc" } } })
  local first = Array.at(profiled.landlock, 1)
  assert(first.path:find("^/proc") ~= nil, first.path)
  local joined = layers_of({ grants = { { path = "/b", letters = "r" }, { path = "/a", letters = "w" },
    { path = "/a", letters = "r" } } })
  local a = Array.at(joined.landlock, 1)
  assert(#joined.landlock == 2 and a.path == "/a" and a.letters == "rw")
end

--- What a restriction refuses, this refuses in its words: a policy the
--- merge refuses, and what only a child can be held to.
local function test_what_a_restriction_refuses_is_refused()
  if Sandbox.on_macos() then
    local held, seatbelt = Sandbox.layers({})
    assert(held == nil and tostring(seatbelt):find("Seatbelt", 1, true) ~= nil, seatbelt)
    return
  end
  local none, why = Sandbox.layers({ grants = { { profile = "nosuch" } } })
  assert(none == nil and tostring(why):find("^sandbox: ") ~= nil and tostring(why):find("nosuch", 1, true) ~= nil, why)
  local child_only: {Sandbox.Policy} = { { grants = { { connect = "api.github.com:443" } } },
    { isolate = { "proc" } }, { grants = { { loopback = "127.0.0.2" } } }, { setup = { tmp = true } },
    { grants = { { path = "/run/app.sock", letters = "u" } } } }
  for _, policy in ipairs(child_only) do
    local refused, refusal = Sandbox.layers(policy)
    assert(refused == nil and tostring(refusal):find("^sandbox: restrict: ") ~= nil, refusal)
  end
end

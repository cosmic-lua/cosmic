#!/usr/bin/env cosmic
--- reads: _make/lockdir.tl
--- Deterministic coverage for lockdir's publication and generation rules.
local child = require("cosmic.child")
local fs = require("cosmic.fs")
local lockdir = require("_make.lockdir")
local time = require("cosmic.time")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"
local cosmic = fs.absolute_path(fs.join(os.getenv("TEST_BIN") or "", "cosmic"))

local function scratch(name: string): string
  local root = fs.join(tmpdir, "lockdir-" .. name)
  assert(fs.remove_all(root))
  assert(fs.make_dirs(root))
  return root
end

local function wait_for(path: string, what: string)
  local deadline = time.monotonic_ms() + 5000
  while not fs.is_present(path) do
    assert(time.monotonic_ms() < deadline, "timed out waiting for " .. what)
    assert(time.sleep_ms(10))
  end
end

local function sibling_names(parent: string): {string}
  local d = assert(fs.open_dir(parent))
  local result: {string} = {}
  while true do
    local name = d:read()
    if not name then break end
    if name ~= "." and name ~= ".." then result[#result + 1] = name end
  end
  d:close()
  table.sort(result)
  return result
end

local function test_round_trip_and_input_bounds()
  local root = scratch("round")
  local path = fs.join(root, "writer.lock")
  local got = lockdir.try_acquire(path, string.rep("p", 4096))
  assert(got.state == "owned" and got.token ~= "")
  local seen = lockdir.observe(path)
  assert(seen.state == "present" and seen.token == got.token)
  assert(seen.payload == string.rep("p", 4096))
  assert(lockdir.retire(path, got.token))
  assert(lockdir.observe(path).state == "vacant")

  assert(lockdir.try_acquire(path, string.rep("x", 4097)).state == "error")
  assert(lockdir.try_acquire("relative-lock", "").state == "error")
  assert(lockdir.try_acquire("", "").state == "error")
  assert(not lockdir.retire(path, "not-a-uuid"))
  assert(lockdir.observe(path).state == "vacant")
end

local function test_malformed_destinations_are_preserved()
  local root = scratch("malformed")
  local path = fs.join(root, "writer.lock")
  assert(fs.write(path, "ordinary file"))
  assert(lockdir.observe(path).state == "error")
  assert(lockdir.try_acquire(path, "new").state == "error")
  assert(fs.read(path) == "ordinary file")
  assert(fs.remove(path))

  local target = fs.join(root, "target")
  assert(fs.make_dirs(target))
  assert(fs.write(fs.join(target, "keep"), "unchanged"))
  assert(fs.symlink(target, path))
  assert(lockdir.observe(path).state == "error")
  assert(lockdir.try_acquire(path, "new").state == "error")
  assert(fs.read(fs.join(target, "keep")) == "unchanged")
  assert(fs.remove(path))

  assert(fs.make_dirs(path))
  assert(fs.write(fs.join(path, "not-an-owner"), "malformed"))
  assert(lockdir.observe(path).state == "error")
  assert(lockdir.try_acquire(path, "new").state == "busy")
  assert(fs.read(fs.join(path, "not-an-owner")) == "malformed")
  assert(fs.remove(fs.join(path, "not-an-owner")))
  local outside = fs.join(root, "outside-owner")
  assert(fs.write(outside, "not-followed"))
  assert(fs.symlink(outside, fs.join(path, "owner-550e8400-e29b-41d4-a716-446655440000")))
  assert(lockdir.observe(path).state == "error")
  assert(fs.read(outside) == "not-followed")
end

local function test_busy_publish_keeps_everything_else()
  local root = scratch("busy")
  local path = fs.join(root, "writer.lock")
  local unrelated = fs.join(root, "unrelated")
  assert(fs.write(unrelated, "byte-identical"))
  local first = lockdir.try_acquire(path, "first")
  assert(first.state == "owned")
  local before = sibling_names(root)
  local second = lockdir.try_acquire(path, "second")
  assert(second.state == "busy" and second.token == "")
  local after = sibling_names(root)
  assert(table.concat(before, "\n") == table.concat(after, "\n"),
    "failed private candidate must be removed")
  local seen = lockdir.observe(path)
  assert(seen.state == "present" and seen.token == first.token and seen.payload == "first")
  assert(fs.read(unrelated) == "byte-identical")
end

local function test_stale_retirement_and_empty_replacement()
  local root = scratch("stale")
  local path = fs.join(root, "writer.lock")
  local a = lockdir.try_acquire(path, "A")
  assert(a.state == "owned")
  local one, two = lockdir.observe(path), lockdir.observe(path)
  assert(one.state == "present" and two.state == "present")
  assert(lockdir.retire(path, one.token))
  local b = lockdir.try_acquire(path, "B")
  assert(b.state == "owned")
  assert(lockdir.retire(path, two.token), "absent old token is success")
  local after = lockdir.observe(path)
  assert(after.state == "present" and after.token == b.token and after.payload == "B")
  assert(lockdir.retire(path, b.token))

  local old = lockdir.try_acquire(path, "old")
  assert(old.state == "owned")
  assert(fs.remove(fs.join(path, "owner-" .. old.token))) -- deliberately retired, but still an empty dir
  local successor = lockdir.try_acquire(path, "new")
  assert(successor.state == "owned")
  assert(not fs.remove_dir(path), "a late empty-directory reaper cannot remove successor")
  local final = lockdir.observe(path)
  assert(final.state == "present" and final.token == successor.token and final.payload == "new")
end

local function test_independent_claim_and_dead_holder_remain()
  local root = scratch("independent")
  local left, right = fs.join(root, "left.lock"), fs.join(root, "right.lock")
  local a, b = lockdir.try_acquire(left, "left"), lockdir.try_acquire(right, "right")
  assert(a.state == "owned" and b.state == "owned" and a.token ~= b.token)
  assert(lockdir.observe(left).payload == "left")
  assert(lockdir.observe(right).payload == "right")
  local dead = fs.join(root, "dead.lock")
  local script = fs.join(root, "dead-claimer.lua")
  assert(fs.write(script, [[
local lockdir = require("_make.lockdir")
local got = lockdir.try_acquire(arg[1], "dead")
assert(got.state == "owned")
]]))
  local h = assert(child.start({cosmic, script, dead}, {cwd = root}))
  assert(assert(h:wait(5000)).ok)
  -- No PID, age, or process probe is hidden here: an exited claimer's
  -- on-disk generation remains until an authorized retirement.
  assert(lockdir.observe(dead).state == "present")
end

local function test_two_children_contend_then_loser_acquires()
  local root = scratch("children")
  local path = fs.join(root, "writer.lock")
  local program = [[
local fs = require("cosmic.fs")
local lockdir = require("_make.lockdir")
local time = require("cosmic.time")
local root, path, name = arg[1], arg[2], arg[3]
local function await(file)
  local deadline = time.monotonic_ms() + 5000
  while not fs.is_present(file) do
    if time.monotonic_ms() >= deadline then os.exit(2) end
    assert(time.sleep_ms(10))
  end
end
assert(fs.write(fs.join(root, "ready-" .. name), "ready"))
await(fs.join(root, "go"))
local got = lockdir.try_acquire(path, name)
assert(fs.write(fs.join(root, "result-" .. name), got.state .. ":" .. got.token))
await(fs.join(root, "release"))
if got.state == "owned" then assert(lockdir.retire(path, got.token)) end
]]
  local script = fs.join(root, "claimer.lua")
  assert(fs.write(script, program))
  local a <close> = assert(child.start({cosmic, script, root, path, "a"}, {cwd = root}))
  local b <close> = assert(child.start({cosmic, script, root, path, "b"}, {cwd = root}))
  wait_for(fs.join(root, "ready-a"), "child a ready")
  wait_for(fs.join(root, "ready-b"), "child b ready")
  assert(fs.write(fs.join(root, "go"), "go"))
  wait_for(fs.join(root, "result-a"), "child a result")
  wait_for(fs.join(root, "result-b"), "child b result")
  local ra = assert(fs.read(fs.join(root, "result-a")))
  local rb = assert(fs.read(fs.join(root, "result-b")))
  assert((ra:find("owned:", 1, true) ~= nil) ~= (rb:find("owned:", 1, true) ~= nil),
    "exactly one child owns the claim: " .. ra .. ", " .. rb)
  assert(fs.write(fs.join(root, "release"), "release"))
  assert(assert(a:wait(5000)).ok, "child a must finish")
  assert(assert(b:wait(5000)).ok, "child b must finish")
  local loser = lockdir.try_acquire(path, "after")
  assert(loser.state == "owned", "loser can acquire after winner retires")
end

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
  local original_write = fs.write
  local private_seen = false
  fs.write = function(candidate_owner: string, data: string, opts?: fs.WriteOptions): boolean, string
    if candidate_owner:find(".writer.lock.candidate-", 1, true) then
      private_seen = true
      assert(fs.is_dir(fs.dirname(candidate_owner)), "candidate directory is private but complete later")
      assert(not fs.is_present(candidate_owner), "candidate is empty before owner write")
      local public = lockdir.observe(path)
      assert(public.state == "present" and public.token == first.token,
        "the published owner remains the only public generation")
    end
    return original_write(candidate_owner, data, opts)
  end
  local second = lockdir.try_acquire(path, "second")
  fs.write = original_write
  assert(private_seen, "second claimant constructs a private empty candidate")
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
  assert(lockdir.retire(path, successor.token))

  -- Retire itself must leave a successor that publishes just after its
  -- owner unlink. Recursive retirement would delete this generation.
  local interleaved = lockdir.try_acquire(path, "interleaved A")
  assert(interleaved.state == "owned")
  local owner = fs.join(path, "owner-" .. interleaved.token)
  local original_remove = fs.remove
  local successor_token = ""
  fs.remove = function(probe: string): boolean, string
    local ok, err = original_remove(probe)
    if probe == owner and ok then
      local raced = lockdir.try_acquire(path, "interleaved B")
      assert(raced.state == "owned")
      successor_token = raced.token
    end
    return ok, err
  end
  assert(lockdir.retire(path, interleaved.token))
  fs.remove = original_remove
  local survived = lockdir.observe(path)
  assert(survived.state == "present" and survived.token == successor_token
    and survived.payload == "interleaved B", "retire must not recursively remove successor")
end

local function test_terminal_errno_and_turnover_classification()
  local root = scratch("ENOENT-terminal")
  local token = "550e8400-e29b-41d4-a716-446655440000"
  local parent_file = fs.join(root, "ENOENT-parent")
  assert(fs.write(parent_file, "preserved"))
  local blocked = fs.join(parent_file, "lock")
  assert(lockdir.observe(blocked).state == "error", "ENOTDIR is not vacancy")
  assert(not lockdir.retire(blocked, token), "ENOTDIR is not absent retirement")

  local empty = fs.join(root, "empty")
  assert(fs.make_dir(empty))
  assert(fs.set_mode(root, fs.octal("500")))
  local absent_ok = lockdir.retire(empty, token)
  assert(fs.set_mode(root, fs.octal("700")))
  assert(absent_ok and fs.is_dir(empty), "absent token must not attempt rmdir")

  local eacces = fs.join(root, "ENOTEMPTY-lock")
  local owned = lockdir.try_acquire(eacces, "owner")
  assert(owned.state == "owned")
  assert(fs.set_mode(root, fs.octal("500")))
  local retired = lockdir.retire(eacces, owned.token)
  assert(fs.set_mode(root, fs.octal("700")))
  assert(not retired, "terminal EACCES is not ENOTEMPTY")

  for _, phase in ipairs({"stat", "read"}) do
    local path = fs.join(root, "turnover-" .. phase)
    local a = lockdir.try_acquire(path, "A")
    assert(a.state == "owned")
    local owner = fs.join(path, "owner-" .. a.token)
    local b_token = ""
    local intercepted = false
    if phase == "stat" then
      local original = fs.stat_link
      fs.stat_link = function(probe: string): fs.Stat | nil, string
        if probe == owner and not intercepted then
          intercepted = true
          assert(lockdir.retire(path, a.token))
          local b = lockdir.try_acquire(path, "B")
          assert(b.state == "owned")
          b_token = b.token
        end
        return original(probe)
      end
      local observed = lockdir.observe(path)
      fs.stat_link = original
      assert(observed.state == "changed", "turnover before owner stat is changed")
    else
      local original = fs.read
      fs.read = function(probe: string): string | nil, string
        if probe == owner and not intercepted then
          intercepted = true
          assert(lockdir.retire(path, a.token))
          local b = lockdir.try_acquire(path, "B")
          assert(b.state == "owned")
          b_token = b.token
        end
        return original(probe)
      end
      local observed = lockdir.observe(path)
      fs.read = original
      assert(observed.state == "changed", "turnover before owner read is changed")
    end
    assert(lockdir.observe(path).token == b_token, "successor remains observed generation")
  end

  local path = fs.join(root, "turnover-recheck-disappears")
  local a = lockdir.try_acquire(path, "A")
  assert(a.state == "owned")
  local owner = fs.join(path, "owner-" .. a.token)
  local original_read, original_open = fs.read, fs.open_dir
  local b_token = ""
  local turnover = false
  fs.read = function(probe: string): string | nil, string
    if probe == owner then
      assert(lockdir.retire(path, a.token))
      local b = lockdir.try_acquire(path, "B")
      assert(b.state == "owned")
      b_token = b.token
      turnover = true
    end
    return original_read(probe)
  end
  fs.open_dir = function(probe: string): fs.Dir | nil, string
    if probe == path and turnover then
      turnover = false
      assert(lockdir.retire(path, b_token))
    end
    return original_open(probe)
  end
  local observed = lockdir.observe(path)
  fs.read, fs.open_dir = original_read, original_open
  assert(observed.state == "changed", "disappearance during turnover recheck is changed")
end

local function test_cleanup_error_is_not_contention()
  local root = scratch("ENOENT-cleanup")
  local path = fs.join(root, "writer.lock")
  assert(lockdir.try_acquire(path, "A").state == "owned")
  local original_move = fs.move
  local candidate = ""
  fs.move = function(src: string, dst: string): boolean, string
    local ok, err = original_move(src, dst)
    assert(not ok, "existing owner makes publication fail")
    candidate = src
    assert(fs.set_mode(candidate, fs.octal("500")))
    return ok, err
  end
  local called, got = pcall(lockdir.try_acquire, path, "B")
  fs.move = original_move
  assert(called and got.state == "error", "cleanup EACCES is not busy")
  assert(fs.is_dir(candidate), "reported cleanup error leaves only private candidate")
  assert(fs.set_mode(candidate, fs.octal("700")))
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
  local h <close> = assert(child.start({cosmic, script, dead}, {cwd = root}))
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
local result = fs.join(root, "result-" .. name)
local complete = fs.join(root, ".result-" .. name .. ".complete")
assert(fs.write(complete, got.state .. ":" .. got.token))
assert(fs.move(complete, result))
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
  local sa = ra:match("^([^:]+):")
  local sb = rb:match("^([^:]+):")
  assert((sa == "owned" and sb == "busy") or (sa == "busy" and sb == "owned"),
    "exactly one child owns and the other is busy: " .. ra .. ", " .. rb)
  assert(fs.write(fs.join(root, "release"), "release"))
  assert(assert(a:wait(5000)).ok, "child a must finish")
  assert(assert(b:wait(5000)).ok, "child b must finish")
  local loser = lockdir.try_acquire(path, "after")
  assert(loser.state == "owned", "loser can acquire after winner retires")
end

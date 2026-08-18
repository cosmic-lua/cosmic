--- Tests for _perf.peers.peers that need no peer toolchain: registry
--- integrity, the exact-match check, staging a script (no execution),
--- and probing a nonexistent executable.

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local peers = require("_perf.peers.peers")

local function test_registry_has_four_peers_in_fixed_order()
  assert(#peers.PEERS == 4, "expected 4 peers, got " .. #peers.PEERS)
  local ids: {string} = {}
  for i, p in ipairs(peers.PEERS) do
    ids[i] = p.id
  end
  assert(ids[1] == "cosmic-lua", "cosmic-lua must be first, got " .. ids[1])
  assert(ids[2] == "cpython", "expected cpython second, got " .. ids[2])
  assert(ids[3] == "node", "expected node third, got " .. ids[3])
  assert(ids[4] == "go", "expected go fourth, got " .. ids[4])
end
test_registry_has_four_peers_in_fixed_order()

local function test_registry_ids_are_unique()
  local seen: {string: boolean} = {}
  for _, p in ipairs(peers.PEERS) do
    assert(not seen[p.id], "duplicate peer id: " .. p.id)
    seen[p.id] = true
  end
end
test_registry_ids_are_unique()

local function test_registry_sources_print_expected()
  for _, p in ipairs(peers.PEERS) do
    assert(p.source:find(peers.EXPECT, 1, true) ~= nil,
      p.id .. ": source does not print " .. peers.EXPECT)
  end
end
test_registry_sources_print_expected()

local function test_check_stdout_accepts_exact_match()
  local ok, err = peers.check_stdout("perf-hello")
  assert(ok, tostring(err))
end
test_check_stdout_accepts_exact_match()

local function test_check_stdout_rejects_empty()
  local ok = peers.check_stdout("")
  assert(not ok, "empty stdout must not pass")
end
test_check_stdout_rejects_empty()

local function test_check_stdout_rejects_wrong_text()
  local ok = peers.check_stdout("hello")
  assert(not ok, "wrong text must not pass")
end
test_check_stdout_rejects_wrong_text()

local function test_check_stdout_rejects_extra_text()
  local ok = peers.check_stdout("perf-hello extra")
  assert(not ok, "trailing extra text must not pass")
end
test_check_stdout_rejects_extra_text()

--- Only the peers with no build step: stage() never executes anything
--- for them, so this needs no peer toolchain.
local function test_stage_writes_script_peers_without_executing()
  local dir = os.getenv("TEST_TMPDIR") or os.getenv("TMPDIR") or "/tmp"
  for _, p in ipairs(peers.PEERS) do
    if p.build_argv == nil then
      local path, err = peers.stage(dir, p)
      assert(path ~= nil, p.id .. ": stage failed: " .. tostring(err))
      assert(path == fs.join(dir, p.script),
        p.id .. ": expected " .. fs.join(dir, p.script) .. ", got " .. tostring(path))
      local content = check.must(fs.read(path))
      assert(content == p.source, p.id .. ": staged content does not match source")
    end
  end
end
test_stage_writes_script_peers_without_executing()

local function test_probe_missing_executable_returns_nil_with_reason()
  local bogus: peers.Peer = {
    id = "bogus", label = "bogus", exe = "cosmic-no-such-peer-exe",
    probe_argv = {"cosmic-no-such-peer-exe", "--version"},
    script = "bogus.txt", source = "unused", build_argv = nil,
    run_argv = function(_: string, _: string): {string} return {} end,
  }
  local version, err = peers.probe(bogus)
  assert(version == nil, "expected nil version for a missing executable")
  assert(err ~= nil and #err > 0, "expected a nonempty reason")
end
test_probe_missing_executable_returns_nil_with_reason()

print("all peers registry tests passed")

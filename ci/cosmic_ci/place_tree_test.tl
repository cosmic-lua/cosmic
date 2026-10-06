--- `place-tree`, which moves CI's checkout to a path the commit and the
--- leg choose: the same two choose the same path, so a re-run meets it
--- again, and another leg, or another commit, chooses another -- but on
--- a gating run of a leg keyed by declarations, whose keys hold the
--- path, the leg alone chooses it. The path is always one directory
--- beside the workspace, so actions/cache's paths relative to the
--- workspace resolve through it. The names are checked against vectors
--- recorded from the original shell implementation.
local Fs = require("cosmic.fs")
local PlaceTree = require("cosmic_ci.place_tree")

local SHA <const> = "2896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d"

--- What `--name` printed, as recorded from the original shell
--- implementation's own `sh` run, for each
--- commit, leg, event and declared-keys setting, a line each:
--- `sha leg event declared name`.
local GOLDEN <const> = [[
2896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d linux-x86_64 push 0 4d4cb15
2896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d linux-x86_64 push 1 fe2
2896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d linux-x86_64 merge_group 0 4d4cb15
2896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d linux-x86_64 merge_group 1 fe2
2896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d linux-x86_64 schedule 0 4d4cb15
2896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d linux-x86_64 schedule 1 4d4cb15
2896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d macos-aarch64 push 0 d6fcdf8905febf878725
2896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d macos-aarch64 push 1 74209ba790f5a50d
2896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d macos-aarch64 merge_group 0 d6fcdf8905febf878725
2896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d macos-aarch64 merge_group 1 74209ba790f5a50d
2896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d macos-aarch64 schedule 0 d6fcdf8905febf878725
2896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d macos-aarch64 schedule 1 d6fcdf8905febf878725
2896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d alpine-x86_64 push 0 a72867a26a
2896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d alpine-x86_64 push 1 3198b9c843a0ff7f7
2896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d alpine-x86_64 merge_group 0 a72867a26a
2896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d alpine-x86_64 merge_group 1 3198b9c843a0ff7f7
2896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d alpine-x86_64 schedule 0 a72867a26a
2896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d alpine-x86_64 schedule 1 a72867a26a
2896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d fuzz push 0 8641
2896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d fuzz push 1 fd0f3c713ecfee
2896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d fuzz merge_group 0 8641
2896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d fuzz merge_group 1 fd0f3c713ecfee
2896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d fuzz schedule 0 8641
2896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d fuzz schedule 1 8641
2896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d checked push 0 67fd
2896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d checked push 1 9f4e350de302ae5cfdd
2896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d checked merge_group 0 67fd
2896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d checked merge_group 1 9f4e350de302ae5cfdd
2896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d checked schedule 0 67fd
2896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d checked schedule 1 67fd
0896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d linux-x86_64 push 0 8960401a4176
0896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d linux-x86_64 push 1 fe2
0896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d linux-x86_64 merge_group 0 8960401a4176
0896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d linux-x86_64 merge_group 1 fe2
0896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d linux-x86_64 schedule 0 8960401a4176
0896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d linux-x86_64 schedule 1 8960401a4176
0896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d macos-aarch64 push 0 fcf6317db6b5400c48a047
0896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d macos-aarch64 push 1 74209ba790f5a50d
0896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d macos-aarch64 merge_group 0 fcf6317db6b5400c48a047
0896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d macos-aarch64 merge_group 1 74209ba790f5a50d
0896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d macos-aarch64 schedule 0 fcf6317db6b5400c48a047
0896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d macos-aarch64 schedule 1 fcf6317db6b5400c48a047
0896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d alpine-x86_64 push 0 716c81fc
0896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d alpine-x86_64 push 1 3198b9c843a0ff7f7
0896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d alpine-x86_64 merge_group 0 716c81fc
0896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d alpine-x86_64 merge_group 1 3198b9c843a0ff7f7
0896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d alpine-x86_64 schedule 0 716c81fc
0896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d alpine-x86_64 schedule 1 716c81fc
0896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d fuzz push 0 3ac219dfaa24f2fa
0896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d fuzz push 1 fd0f3c713ecfee
0896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d fuzz merge_group 0 3ac219dfaa24f2fa
0896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d fuzz merge_group 1 fd0f3c713ecfee
0896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d fuzz schedule 0 3ac219dfaa24f2fa
0896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d fuzz schedule 1 3ac219dfaa24f2fa
0896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d checked push 0 651fca60e3128cf
0896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d checked push 1 9f4e350de302ae5cfdd
0896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d checked merge_group 0 651fca60e3128cf
0896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d checked merge_group 1 9f4e350de302ae5cfdd
0896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d checked schedule 0 651fca60e3128cf
0896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d checked schedule 1 651fca60e3128cf
ffffffffffffffffffffffffffffffffffffffff linux-x86_64 push 0 ab27b9b7d2
ffffffffffffffffffffffffffffffffffffffff linux-x86_64 push 1 fe2
ffffffffffffffffffffffffffffffffffffffff linux-x86_64 merge_group 0 ab27b9b7d2
ffffffffffffffffffffffffffffffffffffffff linux-x86_64 merge_group 1 fe2
ffffffffffffffffffffffffffffffffffffffff linux-x86_64 schedule 0 ab27b9b7d2
ffffffffffffffffffffffffffffffffffffffff linux-x86_64 schedule 1 ab27b9b7d2
ffffffffffffffffffffffffffffffffffffffff macos-aarch64 push 0 5512e9a3b07789580
ffffffffffffffffffffffffffffffffffffffff macos-aarch64 push 1 74209ba790f5a50d
ffffffffffffffffffffffffffffffffffffffff macos-aarch64 merge_group 0 5512e9a3b07789580
ffffffffffffffffffffffffffffffffffffffff macos-aarch64 merge_group 1 74209ba790f5a50d
ffffffffffffffffffffffffffffffffffffffff macos-aarch64 schedule 0 5512e9a3b07789580
ffffffffffffffffffffffffffffffffffffffff macos-aarch64 schedule 1 5512e9a3b07789580
ffffffffffffffffffffffffffffffffffffffff alpine-x86_64 push 0 80a1ec65c2d2a470c8
ffffffffffffffffffffffffffffffffffffffff alpine-x86_64 push 1 3198b9c843a0ff7f7
ffffffffffffffffffffffffffffffffffffffff alpine-x86_64 merge_group 0 80a1ec65c2d2a470c8
ffffffffffffffffffffffffffffffffffffffff alpine-x86_64 merge_group 1 3198b9c843a0ff7f7
ffffffffffffffffffffffffffffffffffffffff alpine-x86_64 schedule 0 80a1ec65c2d2a470c8
ffffffffffffffffffffffffffffffffffffffff alpine-x86_64 schedule 1 80a1ec65c2d2a470c8
ffffffffffffffffffffffffffffffffffffffff fuzz push 0 1dbf6c22f3d1a4d8e17cb8
ffffffffffffffffffffffffffffffffffffffff fuzz push 1 fd0f3c713ecfee
ffffffffffffffffffffffffffffffffffffffff fuzz merge_group 0 1dbf6c22f3d1a4d8e17cb8
ffffffffffffffffffffffffffffffffffffffff fuzz merge_group 1 fd0f3c713ecfee
ffffffffffffffffffffffffffffffffffffffff fuzz schedule 0 1dbf6c22f3d1a4d8e17cb8
ffffffffffffffffffffffffffffffffffffffff fuzz schedule 1 1dbf6c22f3d1a4d8e17cb8
ffffffffffffffffffffffffffffffffffffffff checked push 0 322e3b17c5eaead
ffffffffffffffffffffffffffffffffffffffff checked push 1 9f4e350de302ae5cfdd
ffffffffffffffffffffffffffffffffffffffff checked merge_group 0 322e3b17c5eaead
ffffffffffffffffffffffffffffffffffffffff checked merge_group 1 9f4e350de302ae5cfdd
ffffffffffffffffffffffffffffffffffffffff checked schedule 0 322e3b17c5eaead
ffffffffffffffffffffffffffffffffffffffff checked schedule 1 322e3b17c5eaead
]]

--- A host over `env`, collecting what it prints and warns.
local function host(env: {string:string}): PlaceTree.Host, {string}, {string}
  local out: {string} = {}
  local err: {string} = {}
  return {
    env = env,
    print = function(line: string) out[#out + 1] = line end,
    warn = function(line: string) err[#err + 1] = line end,
  }, out, err
end

--- The environment of a run of `event` whose leg is keyed by declarations
--- where `declared` is "1", for a checkout at `workspace` where given.
local function environment(sha: string, leg: string, event?: string, declared?: string,
                           workspace?: string): {string:string}
  return { GITHUB_SHA = sha, COSMIC_WORKER = leg, GITHUB_EVENT_NAME = event or "push",
    COSMIC_CI_DECLARED_KEYS = declared or "0", GITHUB_WORKSPACE = workspace }
end

--- The name `--name` prints for the inputs.
local function name(sha: string, leg: string, event?: string, declared?: string): string
  local given, out = host(environment(sha, leg, event, declared))
  assert(PlaceTree.run(given, "--name") == 0)
  assert(#out == 1)
  return out[1]
end

local function test_names_match_the_recorded_vectors()
  local count = 0
  for sha, leg, event, declared, expected in GOLDEN:gmatch("(%x+) (%S+) (%S+) (%d) (%x+)\n") do
    assert(name(sha, leg, event, declared) == expected,
      sha .. " " .. leg .. " " .. event .. " " .. declared .. ": " .. name(sha, leg, event, declared))
    count = count + 1
  end
  assert(count == 90, tostring(count))
end

local function test_the_same_commit_and_leg_name_the_same_path()
  local first = name(SHA, "linux-x86_64")
  assert(first == name(SHA, "linux-x86_64"), first)
  -- One name, of one to 24 hex digits.
  assert(#first >= 1 and #first <= 24 and first:match("^%x+$") ~= nil, first)
end

local LEGS <const> = { "linux-x86_64", "linux-aarch64", "macos-aarch64", "alpine-x86_64", "fuzz", "checked" }

local function test_every_commit_and_leg_names_one_directory_of_its_own_length()
  local lengths: {integer: boolean} = {}
  local distinct = 0
  for n = 0, 15 do
    local sha = string.format("%x", n) .. SHA:sub(2)
    for _, leg in ipairs(LEGS) do
      local named = name(sha, leg)
      assert(named:match("^%x+$") ~= nil and #named <= 24, sha .. " " .. leg .. " names " .. named)
      if not lengths[#named] then distinct = distinct + 1 end
      lengths[#named] = true
    end
  end
  -- The name's length varies too, not only its digits.
  assert(distinct >= 8, "only " .. distinct .. " lengths in 96 names")
end

local function test_another_leg_or_commit_names_another_path()
  local here = name(SHA, "linux-x86_64")
  for _, leg in ipairs(LEGS) do
    assert(leg == "linux-x86_64" or name(SHA, leg) ~= here, leg .. " names " .. here .. " too")
  end
  assert(name("0" .. SHA:sub(2), "linux-x86_64") ~= here, "another commit names " .. here)
end

--- A gating run (a push, the merge queue) of a leg keyed by declared
--- inputs, whose keys hold the tree's path, names one path for every
--- commit, the leg's own; its scheduled or a manual run, and every run
--- of any other leg, names one by the commit.
local function test_a_gating_run_keyed_by_declarations_names_the_legs_path()
  local other = "0" .. SHA:sub(2)
  for _, event in ipairs({ "push", "merge_group" }) do
    local here = name(SHA, "macos-aarch64", event, "1")
    assert(name(other, "macos-aarch64", event, "1") == here, event .. ": the commit moved it")
    assert(name(SHA, "macos-x86_64", event, "1") ~= here, event .. ": another leg names " .. here)
    assert(#here >= 1 and #here <= 24 and here:match("^%x+$") ~= nil, here)
    -- Not keyed by declarations, the commit chooses it still.
    assert(name(other, "macos-aarch64", event, "0") ~= name(SHA, "macos-aarch64", event, "0"),
      event .. ": a leg not keyed by declarations kept its path")
  end
  for _, event in ipairs({ "schedule", "workflow_dispatch" }) do
    assert(name(other, "macos-aarch64", event, "1") ~= name(SHA, "macos-aarch64", event, "1"),
      event .. ": the commit did not move it")
    assert(name(SHA, "macos-aarch64", event, "1") == name(SHA, "macos-aarch64", event, "0"),
      event .. ": the keys moved it")
  end
end

local function test_a_missing_input_is_refused()
  local given, out, err = host({ GITHUB_SHA = SHA })
  assert(PlaceTree.run(given, "--name") == 2)
  assert(#out == 0 and err[1] == "place-tree: COSMIC_WORKER is not set", tostring(err[1]))
  given, out, err = host({ COSMIC_WORKER = "fuzz", GITHUB_SHA = "" })
  assert(PlaceTree.run(given, "") == 2)
  assert(err[1] == "place-tree: GITHUB_SHA is not set", tostring(err[1]))
  -- Naming the path needs no workspace, placing it does.
  given, out, err = host(environment(SHA, "fuzz"))
  assert(PlaceTree.run(given, "") == 2)
  assert(#out == 0 and err[1] == "place-tree: GITHUB_WORKSPACE is not set", tostring(err[1]))
end

--- Runs `mode` for a checkout at `workspace`, asserting it succeeds, and
--- answers the lines it printed.
local function place(workspace: string, mode: string, leg?: string, declared?: string): {string}
  local given, out, err = host(environment(SHA, leg or "linux-x86_64", "push", declared, workspace))
  assert(PlaceTree.run(given, mode) == 0, table.concat(err, "\n"))
  assert(#err == 0)
  return out
end

--- Everything under `root`, a line each: a link with its target, a
--- directory, or a file with its contents.
local function layout(root: string): string
  local lines: {string} = {}
  local function walk(relative: string)
    for _, entry in ipairs((assert(Fs.list(root .. relative)))) do
      local path = relative .. "/" .. entry
      local target = Fs.readlink(root .. path)
      if target then
        lines[#lines + 1] = path .. " -> " .. target
      elseif Fs.is_dir(root .. path) then
        lines[#lines + 1] = path .. "/"
        walk(path)
      else
        lines[#lines + 1] = path .. " = " .. assert(Fs.read(root .. path))
      end
    end
  end
  walk("")
  return table.concat(lines, "\n")
end

--- A checkout at `<root>/cosmic`, beside a file of its parent's.
local function checkout(): string, string
  local root = assert(Fs.mkdtemp("cosmic-place-tree-test-"))
  assert(Fs.mkdirs(root .. "/cosmic/ci"))
  assert(Fs.write(root .. "/cosmic/ci/driver.tl", "driver\n"))
  assert(Fs.write(root .. "/beside", "beside\n"))
  return root, root .. "/cosmic"
end

local function test_a_restore_after_a_move_gives_the_checkout_back()
  local root, workspace = checkout()
  local before = layout(root)
  local relative = name(SHA, "linux-x86_64")
  local out = place(workspace, "")
  assert(out[1] == "the tree is at " .. root .. "/" .. relative .. " (commit " .. SHA ..
      ", leg linux-x86_64)", out[1])
  assert(Fs.readlink(workspace) == relative, layout(root))
  assert(Fs.read(workspace .. "/ci/driver.tl") == "driver\n", layout(root))
  out = place(workspace, "--restore")
  assert(out[1] == "the tree is back at " .. workspace .. " from " .. root .. "/" .. relative, out[1])
  assert(layout(root) == before, layout(root))
  -- Again, as a step that runs twice would.
  assert(#place(workspace, "--restore") == 0)
  assert(layout(root) == before, layout(root))
  assert(Fs.remove_tree(root))
end

local function test_a_restore_with_nothing_moved_changes_nothing()
  local root, workspace = checkout()
  local before = layout(root)
  assert(#place(workspace, "--restore") == 0)
  assert(layout(root) == before, layout(root))
  assert(Fs.remove_tree(root))
end

local function test_a_restore_after_a_move_stopped_halfway_finishes_it()
  local root, workspace = checkout()
  local before = layout(root)
  place(workspace, "")
  -- The link removed, the tree not yet moved back.
  assert(Fs.remove(workspace))
  place(workspace, "--restore")
  assert(layout(root) == before, layout(root))
  assert(Fs.remove_tree(root))
end

local function test_a_restore_refuses_a_link_to_another_name()
  local root, workspace = checkout()
  place(workspace, "")
  local relative = assert(Fs.readlink(workspace))
  assert(Fs.remove(workspace))
  assert(Fs.symlink("other", workspace))
  local given, out, err = host(environment(SHA, "linux-x86_64", "push", "0", workspace))
  assert(PlaceTree.run(given, "--restore") == 1)
  assert(#out == 0 and err[1] == "place-tree: " .. workspace .. " links to other, not " .. relative,
    tostring(err[1]))
  assert(Fs.readlink(workspace) == "other")
  assert(Fs.remove_tree(root))
end

--- A runner's layout: the workspace at <work>/cosmic/cosmic and the
--- runner's temporary directory at <work>/_temp.
local function runner(): string, string
  local root = assert(Fs.mkdtemp("cosmic-place-tree-test-"))
  assert(Fs.mkdirs(root .. "/_temp/zig-build"))
  assert(Fs.write(root .. "/_temp/zig-build/entry", "entry\n"))
  assert(Fs.mkdirs(root .. "/cosmic/cosmic/ci"))
  assert(Fs.write(root .. "/cosmic/cosmic/ci/driver.tl", "driver\n"))
  return root, root .. "/cosmic/cosmic"
end

local function test_a_moved_tree_sits_beside_the_workspace_where_its_relative_paths_resolve()
  for _, leg in ipairs(LEGS) do
    local root, workspace = runner()
    place(workspace, "", leg)
    local relative = name(SHA, leg)
    assert(Fs.readlink(workspace) == relative, layout(root))
    assert(Fs.read(root .. "/cosmic/" .. relative .. "/ci/driver.tl") == "driver\n", layout(root))
    -- As actions/cache names the runner's temp directory for
    -- `tar -C $GITHUB_WORKSPACE`: the kernel climbs from the link's
    -- target, which is as deep as the workspace, so it reaches the same
    -- _temp.
    assert(Fs.read(workspace .. "/../../_temp/zig-build/entry") == "entry\n",
      leg .. ": " .. layout(root))
    place(workspace, "--restore", leg)
    assert(Fs.readlink(workspace) == nil and Fs.read(workspace .. "/ci/driver.tl") == "driver\n",
      layout(root))
    assert(Fs.remove_tree(root))
  end
end

--- A gating run keyed by declarations moves the tree to the leg's own
--- path, and back.
local function test_a_gating_run_keyed_by_declarations_moves_the_tree_to_the_legs_path()
  local root, workspace = checkout()
  local before = layout(root)
  local out = place(workspace, "", "macos-aarch64", "1")
  assert(out[1]:find(", a gating run keyed by the path)", 1, true), out[1])
  assert(Fs.readlink(workspace) == name("0" .. SHA:sub(2), "macos-aarch64", "push", "1"),
    layout(root))
  place(workspace, "--restore", "macos-aarch64", "1")
  assert(layout(root) == before, layout(root))
  assert(Fs.remove_tree(root))
end

local function test_a_move_that_ran_already_moves_nothing()
  local root, workspace = checkout()
  place(workspace, "")
  local placed = layout(root)
  local out = place(workspace, "")
  assert(out[1] == "the tree is at " .. root .. "/" .. name(SHA, "linux-x86_64") .. " already", out[1])
  assert(layout(root) == placed, layout(root))
  place(workspace, "--restore")
  assert(Fs.remove_tree(root))
end

local function test_a_move_onto_an_existing_directory_is_refused()
  local root, workspace = checkout()
  assert(Fs.mkdirs(root .. "/" .. name(SHA, "linux-x86_64")))
  local before = layout(root)
  local given, out, err = host(environment(SHA, "linux-x86_64", "push", "0", workspace))
  assert(PlaceTree.run(given, "") == 1)
  assert(#out == 0 and err[1]:find("exists already", 1, true), tostring(err[1]))
  assert(layout(root) == before, layout(root))
  assert(Fs.remove_tree(root))
end

local function test_the_command_refuses_both_options_and_an_extra_word()
  local both: {string:boolean} = { ["--name"] = true, ["--restore"] = true }
  assert(PlaceTree.command({ set = both, values = {}, all = {}, given = {}, words = {} }) == 2)
  assert(PlaceTree.command({ set = {}, values = {}, all = {}, given = {}, words = { "extra" } }) == 2)
end

--- .github/scripts/place-tree.sh, which moves CI's checkout to a path
--- the commit and the leg choose: the same two choose the same path, so
--- a re-run meets it again, and another leg, or another commit, chooses
--- another. The path is always one directory beside the workspace, so
--- actions/cache's paths relative to the workspace resolve through it.
local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")

--- The script under test, and the system's `sh` and tools, which run it.
Test.needs{ reads = { ".github/scripts/place-tree.sh" }, system = true }

-- By its whole path: a process the test starts elsewhere finds it.
local SCRIPT <const> = assert(Fs.absolute(".github/scripts/place-tree.sh"))

--- The path the script names for `sha` and `leg`, under the workspace's
--- parent.
local function name(sha: string, leg: string): string
  local env: {string:string} = { PATH = Env.get("PATH") or "/usr/bin:/bin",
    GITHUB_SHA = sha, COSMIC_WORKER = leg }
  local result = assert(Child.run({ "/bin/sh", SCRIPT, "--name" },
    { env = env, stdout = "capture", stderr = "capture", timeout_ms = 30000 }))
  assert(result.ok, (result.stdout or "") .. (result.stderr or ""))
  return ((result.stdout or ""):gsub("\n$", ""))
end

local SHA <const> = "2896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d"

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

local function test_a_missing_input_is_refused()
  local result = assert(Child.run({ "/bin/sh", SCRIPT, "--name" },
    { env = { PATH = Env.get("PATH") or "/usr/bin:/bin", GITHUB_SHA = SHA },
      stdout = "capture", stderr = "capture", timeout_ms = 30000 }))
  assert(result.code == 2 and (result.stderr or ""):find("COSMIC_WORKER", 1, true), result.stderr)
end

--- Runs the script with `argument` for a checkout at `workspace`,
--- asserting it succeeds.
local function place(workspace: string, argument?: string, leg?: string): string
  local env: {string:string} = { PATH = Env.get("PATH") or "/usr/bin:/bin",
    GITHUB_SHA = SHA, COSMIC_WORKER = leg or "linux-x86_64", GITHUB_WORKSPACE = workspace }
  local argv = { "/bin/sh", SCRIPT }
  if argument then argv[#argv + 1] = argument end
  local result = assert(Child.run(argv,
    { env = env, stdout = "capture", stderr = "capture", timeout_ms = 30000 }))
  assert(result.ok, (result.stdout or "") .. (result.stderr or ""))
  return result.stderr or ""
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
  place(workspace)
  assert(Fs.readlink(workspace) == name(SHA, "linux-x86_64"), layout(root))
  assert(Fs.read(workspace .. "/ci/driver.tl") == "driver\n", layout(root))
  place(workspace, "--restore")
  assert(layout(root) == before, layout(root))
  -- Again, as a step that runs twice would.
  place(workspace, "--restore")
  assert(layout(root) == before, layout(root))
  assert(Fs.remove_tree(root))
end

local function test_a_restore_with_nothing_moved_changes_nothing()
  local root, workspace = checkout()
  local before = layout(root)
  place(workspace, "--restore")
  assert(layout(root) == before, layout(root))
  assert(Fs.remove_tree(root))
end

local function test_a_restore_after_a_move_stopped_halfway_finishes_it()
  local root, workspace = checkout()
  local before = layout(root)
  place(workspace)
  -- The link removed, the tree not yet moved back.
  assert(Fs.remove(workspace))
  place(workspace, "--restore")
  assert(layout(root) == before, layout(root))
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
    place(workspace, nil, leg)
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

local function test_a_move_that_ran_already_moves_nothing()
  local root, workspace = checkout()
  place(workspace)
  local placed = layout(root)
  place(workspace)
  assert(layout(root) == placed, layout(root))
  place(workspace, "--restore")
  assert(Fs.remove_tree(root))
end

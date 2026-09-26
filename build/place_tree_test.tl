--- .github/scripts/place-tree.sh, which moves CI's checkout to a path
--- the commit and the leg choose: the same two choose the same path, so
--- a re-run meets it again, and another leg, or another commit, chooses
--- another.
local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local observations = require("build.filesystem_observations")

-- By its whole path: a confined process starts in the test's directory.
local SCRIPT <const> = assert(Fs.absolute(".github/scripts/place-tree.sh"))

-- The script and the shell tools it runs, which `system` holds.
observations.confine({ reads = { SCRIPT } })

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
  -- One to three names, each one to 24 hex digits.
  local count = 0
  for part in first:gmatch("[^/]+") do
    count = count + 1
    assert(#part >= 1 and #part <= 24 and part:match("^%x+$") ~= nil, first)
  end
  assert(count >= 1 and count <= 3, first)
end

local function test_another_leg_or_commit_names_another_path()
  local here = name(SHA, "linux-x86_64")
  for _, leg in ipairs({ "linux-aarch64", "macos-aarch64", "alpine-x86_64", "fuzz" }) do
    assert(name(SHA, leg) ~= here, leg .. " names " .. here .. " too")
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
local function place(workspace: string, argument?: string)
  local env: {string:string} = { PATH = Env.get("PATH") or "/usr/bin:/bin",
    GITHUB_SHA = SHA, COSMIC_WORKER = "linux-x86_64", GITHUB_WORKSPACE = workspace }
  local argv = { "/bin/sh", SCRIPT }
  if argument then argv[#argv + 1] = argument end
  local result = assert(Child.run(argv,
    { env = env, stdout = "capture", stderr = "capture", timeout_ms = 30000 }))
  assert(result.ok, (result.stdout or "") .. (result.stderr or ""))
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

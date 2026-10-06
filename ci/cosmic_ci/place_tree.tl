--- Moves the checkout to a path of this commit's and this leg's own (or
--- the leg's alone, for the gating run below), for a job that builds or
--- tests the tree, as the user the job's steps run as:
---
---     driver.tl place-tree             move the checkout there
---     driver.tl place-tree --name      only say where, under
---                                      $GITHUB_WORKSPACE's parent
---     driver.tl place-tree --restore   move it back, if it moved
---
--- A test must not depend on where the tree is (AGENTS.md): a verdict is
--- shared between checkouts, which key an in-tree path by its name under
--- the tree. So the tree moves beside $GITHUB_WORKSPACE, to a directory
--- whose name, its length and its digits, a sha256 of the commit
--- ($GITHUB_SHA) and the leg ($COSMIC_WORKER) chooses. A re-run of a
--- commit meets the same path, so a failure it finds is found again; a
--- new commit meets a new one, so a test that turns on the tree's
--- absolute path fails some run rather than none. The log names the
--- inputs and the path, and `--name` with the same ones gives it again.
---
--- But for a gating run ($GITHUB_EVENT_NAME push or merge_group) of a
--- leg whose workers run unsandboxed, keyed by what their tests declare
--- ($COSMIC_CI_DECLARED_KEYS=1, the macOS leg): there the leg alone
--- chooses the name. Such a worker sees the tree where it is, so its key
--- holds the tree's path (build/declared_key.tl's `Spec.tree`): a path
--- that moved with every commit would run every test there on every
--- commit, and a path that stays cannot let a verdict stand where the
--- test would fail, since a test is keyed by where it ran. What a moving
--- path still catches there, a test that turns on the path at all, the
--- scheduled run's path, chosen by the commit, catches.
---
--- Only the name varies, never the depth: the tree is always one
--- directory below $GITHUB_WORKSPACE's parent, as deep as the workspace
--- itself. actions/cache names a path outside the workspace, such as
--- $RUNNER_TEMP (<work>/_temp beside <work>/<repo>/<repo>), relative to
--- $GITHUB_WORKSPACE (`../../_temp/...`, by `path.relative`) and archives
--- it with `tar -C $GITHUB_WORKSPACE`, which enters the link: from a tree
--- any deeper, `../..` names a directory under <work>/<repo> instead, and
--- the save finds nothing. At depth one it names <work> as it would
--- unmoved, so the saves run with the tree moved. That costs nothing a
--- varied depth would catch: the absolute path still moves by commit and
--- leg, which is what fails a test that depends on it, and a sandboxed
--- worker sees the tree at /tree wherever it is.
---
--- $GITHUB_WORKSPACE becomes a link to it, relative so it resolves both
--- in a job container and on its host: what a job reads from there (a
--- local action, a later step's working directory) is the tree, and
--- whatever resolves the path -- the driver's root
--- (ci/cosmic_ci/context.tl), a process's working directory -- is the new
--- one. So it moves only what is under $GITHUB_WORKSPACE's parent, which
--- the job's user owns.
---
--- The job's last step, whatever came before it, runs `--restore`, which
--- puts the tree back at $GITHUB_WORKSPACE before the post steps run: the
--- checkout's resolves the path too, and a git that finds a repository
--- at a path other than the one it was told is safe refuses it (git
--- 2.43's "dubious ownership"), which leaves the checkout's credentials
--- in its config. It removes the link, and changes nothing when the tree
--- never moved, or is back already, so it can run twice, or after a move
--- that stopped halfway.
---
--- The driver runs from the tree it moves: the rename leaves its open
--- files and working directory where they were, and nothing it writes
--- (ci/o's databases and lock) is keyed by the tree's path.
local Flags = require("cosmic.flags")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")

local record PlaceTree
  --- What the command asks of the world, as one record a test replaces:
  --- the environment, a line on standard output and one on standard
  --- error. The tree's links and directories are the real file system's.
  record Host
    env: {string:string}
    print: function(line: string)
    warn: function(line: string)
  end
  --- The command's options, as [`Flags.parse`] reads a spec.
  spec: {string:boolean | Flags.Option}
  --- The directory name for the commit and leg `env` holds, and the
  --- reason it was chosen, for the log; nil and why where an input is
  --- unset.
  name: function(env: {string:string}): string | nil, string
  --- Runs the command: `mode` is "", "--name" or "--restore". Answers the
  --- exit status: 2 for a missing input, 1 for a workspace linked
  --- elsewhere or a move that failed.
  run: function(host: Host, mode: string): integer
  --- `driver.tl place-tree`, in the process's environment.
  command: function(got: Flags.Parsed): integer
end

PlaceTree.spec = {
  ["--name"] = { about = "only print the directory name under the workspace's parent" },
  ["--restore"] = { about = "move the tree back to the workspace, if it moved" },
}

local USAGE <const> = "usage: place-tree [--name | --restore]"

--- The digest of `text` as 64 hex digits.
local function digest(text: string): string
  return Hash.hex_sha256(text)
end

function PlaceTree.name(env: {string:string}): string | nil, string
  local sha, worker = env.GITHUB_SHA or "", env.COSMIC_WORKER or ""
  if sha == "" then return nil, "place-tree: GITHUB_SHA is not set" end
  if worker == "" then return nil, "place-tree: COSMIC_WORKER is not set" end
  -- TODO: put a space in a name too, to catch a path left unquoted, once
  -- ci/run-local runs the driver from a path with one (its drop_env is
  -- split on spaces) and shows its phases take it: the suite itself does.
  local seed, chosen: string, string
  local event = env.GITHUB_EVENT_NAME or ""
  if env.COSMIC_CI_DECLARED_KEYS == "1" and (event == "push" or event == "merge_group") then
    seed = digest("leg " .. worker .. "\n")
    chosen = "leg " .. worker .. ", a gating run keyed by the path"
  else
    seed = digest("commit " .. sha .. "\nleg " .. worker .. "\n")
    chosen = "commit " .. sha .. ", leg " .. worker
  end
  -- The first byte of the seed, as two hex digits, sets the length.
  local length = (math.tointeger(tonumber(seed:sub(1, 2), 16)) as integer) % 24 + 1
  return digest(seed .. " 1\n"):sub(1, length), chosen
end

function PlaceTree.run(host: PlaceTree.Host, mode: string): integer
  local relative, chosen = PlaceTree.name(host.env)
  if relative == nil then
    host.warn(chosen)
    return 2
  end
  if mode == "--name" then
    host.print(relative)
    return 0
  end
  local workspace = host.env.GITHUB_WORKSPACE or ""
  if workspace == "" then
    host.warn("place-tree: GITHUB_WORKSPACE is not set")
    return 2
  end
  local tree = Fs.dirname(workspace) .. "/" .. relative
  local link = Fs.readlink(workspace)

  if mode == "--restore" then
    if link ~= nil then
      if link ~= relative then
        host.warn("place-tree: " .. workspace .. " links to " .. link .. ", not " .. relative)
        return 1
      end
      local removed, why = Fs.remove(workspace)
      if not removed then
        host.warn("place-tree: " .. why)
        return 1
      end
    end
    if not Fs.exists(workspace) and Fs.is_dir(tree) then
      local moved, why = Fs.rename(tree, workspace)
      if not moved then
        host.warn("place-tree: " .. why)
        return 1
      end
      host.print("the tree is back at " .. workspace .. " from " .. tree)
    end
    return 0
  end

  -- Placed already, as by a step that runs twice: nothing to move.
  if link == relative then
    host.print("the tree is at " .. tree .. " already")
    return 0
  end
  -- The rename would replace an empty directory already at `tree`.
  if Fs.exists(tree) then
    host.warn("place-tree: " .. tree .. " exists already")
    return 1
  end
  local moved, why = Fs.rename(workspace, tree)
  if not moved then
    host.warn("place-tree: " .. why)
    return 1
  end
  local made, trouble = Fs.symlink(relative, workspace)
  if not made then
    host.warn("place-tree: " .. trouble)
    return 1
  end
  host.print("the tree is at " .. tree .. " (" .. chosen .. ")")
  return 0
end

function PlaceTree.command(got: Flags.Parsed): integer
  local given = got.set
  local live: PlaceTree.Host = {
    env = Env.all(),
    print = function(line: string) local _, _ = Fs.put(Fs.stdout, line .. "\n") end,
    warn = function(line: string) local _, _ = Fs.put(Fs.stderr, line .. "\n") end,
  }
  if #got.words > 0 or (given["--name"] and given["--restore"]) then
    live.warn(USAGE)
    return 2
  end
  return PlaceTree.run(live, given["--name"] and "--name" or given["--restore"] and "--restore" or "")
end

return PlaceTree

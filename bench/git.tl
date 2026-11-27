--- cosmic.git on a real repository: `bin/cosmic bench/git.tl [name...]`, from the top of a checkout, or with
--- GIT_BENCH_REPO naming one. It times opening the repository, `status` (the index against HEAD and the worktree,
--- and the untracked walk), `log`, resolving a revision, reading one object from a pack and one tree, and an add
--- and a commit in a small repository of its own. Where a git program is on PATH, a `git ...` case beside each
--- that has one runs the same work through it, and its ratio is printed: a child's start is part of its time, as
--- it is part of a script's that runs git.
local Bench = require("bench.harness")
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Git = require("cosmic.git")
local Proc = require("cosmic.proc")

local root = Env.get("GIT_BENCH_REPO") or "."
local found, _ = Proc.find("git")
local git_program: string? = found

--- Runs the git program in `dir` with no user or system config, and returns what it printed.
local function git(dir: string, args: {string}): string
  local argv: mut {string} = { git_program!, "-C", dir }
  for _, word in ipairs(args) do argv[#argv + 1] = word end
  local result = assert(Child.run(argv, { stdout = "capture", stderr = "stdout",
    env = { PATH = Env.get("PATH") or "/usr/bin:/bin", HOME = Env.get("HOME") or "/", GIT_CONFIG_NOSYSTEM = "1",
      GIT_CONFIG_GLOBAL = "/dev/null", LC_ALL = "C" },
    timeout_ns = Clock.seconds(60) }))
  assert(result.ok, table.concat(args, " ") .. ": " .. tostring(result.stdout))
  return result.stdout!
end

local repo = assert(Git.open(root))
local bench = Bench.new("git")

--- A case of cosmic.git. Where git is on PATH and `args` are given, a case of the git program comes first, and
--- this case's ratio to it is printed.
local function pair(name: string, run: function(), args?: {string}, options?: Bench.Options)
  local opts: Bench.Options = options or {}
  if git_program ~= nil and args ~= nil then
    bench.case("git " .. name, function(n: integer)
      for _ = 1, n do git(root, args) end
    end)
    opts = { setup = opts.setup, bytes = opts.bytes, baseline = "git " .. name }
  end
  bench.case(name, function(n: integer)
    for _ = 1, n do run() end
  end, opts)
end

pair("open", function() assert(Git.open(root)) end)
pair("rev HEAD~10", function() assert(repo:rev("HEAD~10")) end, { "rev-parse", "HEAD~10" })
pair("log 200", function() assert(repo:log({ limit = 200 })) end, { "log", "-200", "--format=%H" })
pair("status", function() assert(repo:status()) end, { "status", "--porcelain=v1", "-uall" })

-- An old commit's tree and one of its blobs: in a gc'd repository both are in a pack, most likely as deltas.
local old_tree = ""
local old_blob = ""
pair("read tree", function() assert(repo:tree(old_tree)) end, nil, { setup = function()
  local commits = assert(repo:log({ limit = 100 }))
  old_tree = commits[#commits]!.tree
  for _, entry in ipairs(assert(repo:tree(old_tree))) do
    if entry.mode == "100644" then old_blob = entry.oid end
  end
  assert(old_blob ~= "", "the old tree holds no file")
end })
pair("read blob", function() assert(repo:read(old_blob)) end, nil, { setup = function()
  if old_blob == "" then
    local commits = assert(repo:log({ limit = 100 }))
    for _, entry in ipairs(assert(repo:tree(commits[#commits]!.tree))) do
      if entry.mode == "100644" then old_blob = entry.oid end
    end
  end
end })

-- An add and a commit of one changed file, in a repository of 100 files that the git program makes for it.
local small = ""
local small_repo: Git.Repo? = nil
local edits = 0
if git_program ~= nil then
  bench.case("add + commit", function(n: integer)
    local r = small_repo!
    for _ = 1, n do
      edits = edits + 1
      assert(Fs.write(small .. "/f1.txt", "edit " .. tostring(edits) .. "\n"))
      assert(r:add({ "f1.txt" }))
      assert(r:commit({ message = "edit", author = { name = "Bench", email = "bench@example.com", time = 0,
        tz = "+0000" } }))
    end
  end, { setup = function()
    small = assert(Fs.mkdtemp("git-bench-"))
    for i = 1, 100 do
      assert(Fs.write(small .. "/f" .. tostring(i) .. ".txt", "file " .. tostring(i) .. "\n"))
    end
    git(small, { "init", "-q", "-b", "main" })
    git(small, { "add", "." })
    git(small, { "-c", "user.name=Bench", "-c", "user.email=bench@example.com", "commit", "-qm", "first" })
    small_repo = assert(Git.open(small))
  end })
end

return function(argv: {string}): integer
  return bench.main(argv)
end

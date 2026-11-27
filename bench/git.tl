--- cosmic.git on a real repository: `bin/cosmic bench/git.tl [name...]`, from the top of a checkout, or with
--- GIT_BENCH_REPO naming one. It times opening the repository, `status` (the index against HEAD and the worktree,
--- and the untracked walk), `log`, resolving a revision, reading one object from a pack and one tree, and an add
--- and a commit in a small repository of its own, made from testdata/git/scratch. It runs no git program.
local Bench = require("bench.harness")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Git = require("cosmic.git")

local root = Env.get("GIT_BENCH_REPO") or "."
local repo = assert(Git.open(root))
local bench = Bench.new("git")
local who: Git.Person = { name = "Bench", email = "bench@example.com", time = 0, tz = "+0000" }

local function case(name: string, run: function(), options?: Bench.Options)
  bench.case(name, function(n: integer)
    for _ = 1, n do run() end
  end, options)
end

case("open", function() assert(Git.open(root)) end)
case("rev HEAD~10", function() assert(repo:rev("HEAD~10")) end)
case("log 200", function() assert(repo:log({ limit = 200 })) end)
case("status", function() assert(repo:status()) end)

-- An old commit's tree and one of its blobs: in a gc'd repository both are in a pack, most likely as deltas.
local old_tree = ""
local old_blob = ""
local function find_old()
  if old_blob ~= "" then return end
  local commits = assert(repo:log({ limit = 100 }))
  old_tree = commits[#commits]!.tree
  for _, entry in ipairs(assert(repo:tree(old_tree))) do
    if entry.mode == "100644" then old_blob = entry.oid end
  end
  assert(old_blob ~= "", "the old tree holds no file")
end
case("read tree", function() assert(repo:tree(old_tree)) end, { setup = find_old })
case("read blob", function() assert(repo:read(old_blob)) end, { setup = find_old })

-- An add and a commit of one changed file, in a copy of testdata/git/scratch with 100 files more.
local small = ""
local small_repo: Git.Repo? = nil
local edits = 0
case("add + commit", function()
  local r = small_repo!
  edits = edits + 1
  assert(Fs.write(small .. "/f1.txt", "edit " .. tostring(edits) .. "\n"))
  assert(r:add({ "f1.txt" }))
  assert(r:commit({ message = "edit", author = who, committer = who }))
end, { setup = function()
  small = assert(Fs.mkdtemp("git-bench-")) .. "/repo"
  assert(Fs.copy_tree("testdata/git/scratch", small))
  assert(Fs.rename(small .. "/dotgit", small .. "/.git"))
  local r = assert(Git.open(small))
  local paths: mut {string} = {}
  for i = 1, 100 do
    local path = "f" .. tostring(i) .. ".txt"
    assert(Fs.write(small .. "/" .. path, "file " .. tostring(i) .. "\n"))
    paths[#paths + 1] = path
  end
  assert(r:add(paths))
  assert(r:commit({ message = "first", author = who, committer = who }))
  small_repo = r
end })

return function(argv: {string}): integer
  return bench.main(argv)
end

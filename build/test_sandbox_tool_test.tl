--- `cosmic test`'s sandboxed worker (build/test_sandbox.tl): a worker's
--- whole plan, made and read without starting a worker, and the one
--- `host` path a run refuses before it starts any. These declare `tool`:
--- a plan reads this program, since it gives a worker the program's own
--- paths and so stats them (build.confine's `worker_unveil`), and the run
--- that refuses a path starts it. They need no sandbox, so they run
--- wherever the program does; what a run of workers under one sees is in
--- `test_sandbox_run_tool_test.tl`.

local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local sys = require("cosmic.sys")
local this_program = require("build.this_program")
local test_inputs = require("build.test_inputs")
local test_sandbox = require("build.test_sandbox")
local fixture = require("build.test_sandbox_fixture")
local Test = require("cosmic.test")
local build_paths = require("build.paths")
local confine = require("build.confine")

--- What a worker's plan gives it of the host, the program the run that
--- refuses a path starts, and roots of their own for the workers of that
--- run (`nests`), which a host that refuses them runs unsandboxed.
Test.policy{
  profiles = { "cosmic" },
  grants = { { path = "o/bin", letters = "rx" } },
  promises = { "nest" },
}

--- `root`'s build directory ([`build.paths`]), made, with `root` made
--- first where it is not there yet.
local function build_dir(root: string): string
  assert(Fs.mkdirs(root))
  return (assert(build_paths.prepare(root)))
end

--- An `Effective` holding `files` of the tree, and what of it `reads` names
--- (none for nil), and nothing else declared.
local function effective(files: {string}, reads?: {string}): test_inputs.Effective
  local out: test_inputs.Effective = { files = {}, reads = reads or {}, host = {}, env = {},
    network = {}, tool = false, store = false }
  for _, file in ipairs(files) do out.files[file] = true end
  return out
end

--- Makes `tmp`/scratch, a scratch directory laid out as build.test's
--- `scratch` lays one out -- `real`, and `tmp` a link to it -- and
--- answers it. A plan takes that layout as given: where it runs its
--- worker as a user of its own, it hands it and `real` to that user.
local function scratch_in(tmp: string): string
  local scratch = tmp .. "/scratch"
  assert(Fs.mkdirs(scratch .. "/real"))
  assert(Fs.symlink("real", scratch .. "/tmp"))
  return scratch
end

--- Whether `list` holds `value`.
local function holds(list: {string}, value: string): boolean
  for _, each in ipairs(list) do
    if each == value then return true end
  end
  return false
end

--- A path a bind of another shows already, at the same place and as
--- the same file, is not bound again on top of it -- a mount point that
--- would be the host's own file, which a rename over it fails -- but
--- one a link on the way leads elsewhere is: the other's bind leaves
--- the link, which the sandbox would follow to what it does not have.
local function test_a_path_another_bind_shows_is_not_bound_again(tmp: string)
  local root, scratch, dir = tmp .. "/root", scratch_in(tmp), tmp .. "/host"
  for _, made in ipairs({ build_dir(root), root .. "/data", dir, tmp .. "/elsewhere" }) do
    assert(Fs.mkdirs(made))
  end
  assert(Fs.write(build_dir(root) .. "/cosmic.db", "x"))
  assert(Fs.write(root .. "/data/x.tl", "x"))
  assert(Fs.write(tmp .. "/elsewhere/y.tl", "y"))
  assert(sys.symlink(tmp .. "/elsewhere/y.tl", root .. "/data/y.tl"))
  assert(Fs.write(dir .. "/given", "h"))
  local inputs = effective({ "data/x.tl", "data/y.tl" })
  inputs.reads = { "data" }
  inputs.host = { dir, dir .. "/given" }
  local plan = test_sandbox.plan(root, scratch, inputs, {})
  local unveil = assert(plan.sandbox.unveil)
  assert(holds(unveil.reads, root .. "/data") and (unveil.at or {})[root .. "/data"] == "/tree/data")
  assert(not holds(unveil.reads, root .. "/data/x.tl") and (unveil.at or {})[root .. "/data/x.tl"] == nil)
  assert(holds(unveil.reads, root .. "/data/y.tl") and
      (unveil.at or {})[root .. "/data/y.tl"] == "/tree/data/y.tl")
  assert(holds(unveil.reads, dir) and not holds(unveil.reads, dir .. "/given"))
end

--- Makes `count` files of the closure beneath `root`/`dir`, and a file
--- beside them that is not, `notes.txt`; answers the closure's paths.
local function closure_files(root: string, dir: string, count: integer): {string}
  assert(Fs.mkdirs(root .. "/" .. dir .. "/deeper"))
  assert(Fs.write(root .. "/" .. dir .. "/notes.txt", "not of the closure"))
  local files: {string} = {}
  for i = 1, count do
    -- One of every ten beneath a directory of its own: a copy keeps it there.
    local file = string.format("%s/%sm%03d.tl", dir, i % 10 == 0 and "deeper/" or "", i)
    assert(Fs.write(root .. "/" .. file, "return " .. tostring(i)))
    files[#files + 1] = file
  end
  return files
end

--- A closure whose files, each a path of its own, are more paths than a
--- sandbox holds is given in fewer: the files beneath a directory as one
--- copy of them alone, at that directory's place in /tree, holding each
--- of them at its path and nothing beside them (a file the key does not
--- hold). Its scratch directory is the host's then, since a copy is a
--- directory, and it says so. Each directory and file of a copy is
--- readable by anyone, whatever the umask, as a worker run as a user of
--- its own reads the tree. Given nowhere to make a copy, the plan is over
--- the most, as every plan past it was.
local function test_a_closure_past_the_most_paths_is_given_as_copies(tmp: string)
  local root, scratch, copies = tmp .. "/root", scratch_in(tmp), tmp .. "/copies"
  assert(Fs.write(build_dir(root) .. "/cosmic.db", "x"))
  local files = closure_files(root, "many", confine.unveil_max + 40)
  for _, file in ipairs(closure_files(root, "few", 1)) do files[#files + 1] = file end
  local kept: {string:test_sandbox.Plan} = {}
  local umask = sys.umask(0x3f)
  local planned, why = pcall(function()
    kept["plan"] = test_sandbox.plan(root, scratch, effective(files), {}, nil, nil, copies)
  end)
  sys.umask(umask)
  assert(planned, tostring(why))
  local plan = assert(kept["plan"])
  assert(plan.trouble == "", plan.trouble)
  assert(plan.over == 0, "over by " .. tostring(plan.over))
  local unveil = assert(plan.sandbox.unveil)
  local at = unveil.at or {}
  assert(#unveil.reads + #(unveil.writes or {}) <= confine.unveil_max)
  local copy: string | nil = nil
  for _, path in ipairs(unveil.reads) do
    if at[path] == "/tree/many" then copy = path end
    assert(not Fs.within(path, root .. "/many"), path .. " is given beside its copy")
  end
  local given = assert(copy, "no copy of many/ is given")
  assert(Fs.within(given, copies), given)
  local held = assert(Fs.walk(given))
  assert(#held == confine.unveil_max + 40, tostring(#held))
  for _, file in ipairs(files) do
    if file:sub(1, 5) == "many/" then
      assert(Fs.read(given .. file:sub(5)) == Fs.read(root .. "/" .. file), file)
    end
  end
  assert(Fs.exists(given .. "/notes.txt") ~= true, "a file the key does not hold is given")
  for _, dir in ipairs({ given, given .. "/deeper" }) do
    assert((assert(sys.stat(dir)).mode & 0x1ff) == 0x1ed, dir)
  end
  for _, file in ipairs(held) do
    assert((assert(sys.stat(given .. "/" .. file)).mode & 0x1ff) == 0x1a4, file)
  end
  -- The one file of few/ saves no path as a copy, and stays its own.
  assert(holds(unveil.reads, root .. "/few/m001.tl") and at[root .. "/few/m001.tl"] == "/tree/few/m001.tl")
  assert(not plan.own_scratch, plan.why_shared)
  assert(plan.why_shared:find("beneath many are given as a copy", 1, true) ~= nil, plan.why_shared)
  local nowhere = test_sandbox.plan(root, scratch, effective(files), {})
  assert(nowhere.over > 0)
end

--- The grants a start takes are its plan's paths, the sandbox's own /tmp
--- where its scratch directory is its own, and the sandbox's own /proc, which
--- the start counts too: a closure one file short of the most paths a
--- sandbox unveils is past them, and is given as copies so the start's
--- grants fit.
local function test_a_closure_is_counted_as_a_start_counts_its_grants(tmp: string)
  local root, scratch, copies = tmp .. "/root", scratch_in(tmp), tmp .. "/copies"
  assert(Fs.write(build_dir(root) .. "/cosmic.db", "x"))
  local bare = test_sandbox.plan(root, scratch, effective({}), {}, nil, nil, copies)
  assert(bare.own_scratch and #(assert(bare.sandbox.unveil).writes or {}) == 0)
  local base = #assert(bare.sandbox.unveil).reads
  -- Its paths and its /tmp: as many as a sandbox unveils, before /proc.
  local files = closure_files(root, "many", confine.unveil_max - 1 - base)
  local plan = test_sandbox.plan(root, scratch, effective(files), {}, nil, nil, copies)
  assert(plan.trouble == "" and plan.over == 0, plan.trouble)
  local unveil = assert(plan.sandbox.unveil)
  local grants = #unveil.reads + #(unveil.writes or {}) + (plan.own_scratch and 1 or 0)
  assert(grants + 1 <= confine.unveil_max, tostring(grants) .. " grants and /proc")
  assert(not plan.own_scratch, "no copy was made")
  local nowhere = test_sandbox.plan(root, scratch, effective(files), {})
  assert(nowhere.over == 1, tostring(nowhere.over))
end

--- A worker that runs on a sealed database is counted with the core and the
--- database its start grants beside its policy: a closure that fits
--- without them is given as copies where the worker is sealed, so its
--- start does not unveil more paths than it takes.
local function test_a_sealed_worker_is_counted_with_its_start_s_grants(tmp: string)
  local root, scratch, copies = tmp .. "/root", scratch_in(tmp), tmp .. "/copies"
  assert(Fs.write(build_dir(root) .. "/cosmic.db", "x"))
  local bare = test_sandbox.plan(root, scratch, effective({}), {}, nil, nil, copies, true)
  assert(bare.own_scratch)
  -- Its paths and its /tmp: as many as a policy holds, but for the two.
  local count = (confine.unveil_max - 1) - (#assert(bare.sandbox.unveil).reads + 1)
  local files = closure_files(root, "many", count)
  local plain = test_sandbox.plan(root, scratch, effective(files), {}, nil, nil, copies)
  assert(plain.trouble == "" and plain.over == 0 and #(plain.copied or {}) == 0, plain.trouble)
  local sealed = test_sandbox.plan(root, scratch, effective(files), {}, nil, nil, copies, true)
  assert(sealed.trouble == "" and sealed.over == 0, sealed.trouble)
  assert(#(sealed.copied or {}) > 0, "no copy was made")
  local unveil = assert(sealed.sandbox.unveil)
  local grants = #unveil.reads + #(unveil.writes or {}) + (sealed.own_scratch and 1 or 0) + 2
  assert(grants + 1 <= confine.unveil_max, tostring(grants) .. " grants and /proc")
  local nowhere = test_sandbox.plan(root, scratch, effective(files), {}, nil, nil, nil, true)
  assert(nowhere.over == 2, tostring(nowhere.over))
end

--- Within the most paths a sandbox holds, each file of the closure is a
--- path of its own, and nothing is copied. A guard that the copies are
--- only for a plan past the most: it fails where every plan is copied,
--- and passes with no copies at all.
local function test_a_closure_within_the_most_paths_is_given_file_by_file(tmp: string)
  local root, scratch, copies = tmp .. "/root", scratch_in(tmp), tmp .. "/copies"
  assert(Fs.write(build_dir(root) .. "/cosmic.db", "x"))
  local files = closure_files(root, "many", 20)
  local plan = test_sandbox.plan(root, scratch, effective(files), {}, nil, nil, copies)
  assert(plan.trouble == "" and plan.over == 0, plan.trouble)
  local unveil = assert(plan.sandbox.unveil)
  for _, file in ipairs(files) do
    assert(holds(unveil.reads, root .. "/" .. file) and
        (unveil.at or {})[root .. "/" .. file] == "/tree/" .. file, file)
  end
  assert(plan.own_scratch and plan.why_shared == "", plan.why_shared)
  assert(Fs.exists(copies) ~= true, "a copy is made for a plan that fits")
  local unchanged = test_sandbox.plan(root, scratch, effective(files), {})
  assert(#assert(unchanged.sandbox.unveil).reads == #unveil.reads)
end

--- Makes `count` files of the closure directly beneath `root`/`dir`;
--- answers their paths.
local function spread(root: string, dir: string, count: integer): {string}
  assert(Fs.mkdirs(root .. "/" .. dir))
  local files: {string} = {}
  for i = 1, count do
    local file = string.format("%s/m%03d.tl", dir, i)
    assert(Fs.write(root .. "/" .. file, "return " .. tostring(i)))
    files[#files + 1] = file
  end
  return files
end

--- `list` and `more` joined, as a list of its own.
local function joined(list: {string}, more: {string}): {string}
  local out: {string} = {}
  for _, part in ipairs({ list, more }) do
    for _, each in ipairs(part) do out[#out + 1] = each end
  end
  return out
end

--- Whether the places in /tree a plan gives a copy beneath `copies` at
--- are `want`, in any order.
local function copied_at(plan: test_sandbox.Plan, copies: string, want: {string}): boolean
  local unveil = assert(plan.sandbox.unveil)
  local count = 0
  for _, path in ipairs(unveil.reads) do
    if Fs.within(path, copies) then
      count = count + 1
      if not holds(want, (unveil.at or {})[path] or path) then return false end
    end
  end
  return count == #want
end

--- A file the module declares it reads beside the closure's, in the
--- directory a copy would give, is copied with them, since its key holds
--- it by its contents too: a directory that holds one stays a copy's, and
--- the test starts.
local function test_a_declared_file_beside_the_closure_is_copied_with_it(tmp: string)
  local root, scratch, copies = tmp .. "/root", scratch_in(tmp), tmp .. "/copies"
  assert(Fs.write(build_dir(root) .. "/cosmic.db", "x"))
  local inputs = effective(spread(root, "suite", confine.unveil_max + 20), { "suite/data.txt" })
  assert(Fs.write(root .. "/suite/data.txt", "data"))
  local plan = test_sandbox.plan(root, scratch, inputs, {}, nil, nil, copies)
  assert(plan.trouble == "" and plan.over == 0, plan.trouble .. " over " .. tostring(plan.over))
  assert(copied_at(plan, copies, { "/tree/suite" }))
  local unveil = assert(plan.sandbox.unveil)
  assert(not holds(unveil.reads, root .. "/suite/data.txt"))
  for _, path in ipairs(unveil.reads) do
    if (unveil.at or {})[path] == "/tree/suite" then
      assert(Fs.read(path .. "/data.txt") == "data")
    end
  end
end

--- A file the module declares it reads that is run keeps its own path,
--- which grants it `x`, and is not copied; nor is a directory it is in,
--- which would bind it inside a copy. The next directory that is free of
--- it is copied instead.
local function test_a_file_that_is_run_is_not_copied(tmp: string)
  local root, scratch, copies = tmp .. "/root", scratch_in(tmp), tmp .. "/copies"
  assert(Fs.write(build_dir(root) .. "/cosmic.db", "x"))
  local half = (confine.unveil_max + 10) // 2
  local inputs = effective(joined(spread(root, "suite/a", half), spread(root, "suite/b", half)),
    { "suite/a/tool.sh" })
  local tool = root .. "/suite/a/tool.sh"
  assert(Fs.write(tool, "#!/bin/sh\n"))
  assert(Fs.chmod(tool, 0x1ed))
  local plan = test_sandbox.plan(root, scratch, inputs, {}, nil, nil, copies)
  assert(plan.trouble == "" and plan.over == 0, plan.trouble .. " over " .. tostring(plan.over))
  local unveil = assert(plan.sandbox.unveil)
  assert(holds(unveil.reads, tool) and (unveil.at or {})[tool] == "/tree/suite/a/tool.sh" and
      plan.runs[tool] == true)
  assert(copied_at(plan, copies, { "/tree/suite/b" }))
  assert(holds(unveil.reads, root .. "/suite/a/m001.tl"))
end

--- A directory any other path is given in, beneath or above, is not
--- copied: a directory the module declares it reads is bound whole, and a
--- copy around it would bind it inside the copy. A directory beside it
--- is copied instead.
local function test_a_directory_another_path_is_given_in_is_not_copied(tmp: string)
  local root, scratch, copies = tmp .. "/root", scratch_in(tmp), tmp .. "/copies"
  assert(Fs.write(build_dir(root) .. "/cosmic.db", "x"))
  local half = (confine.unveil_max + 10) // 2
  local inputs = effective(joined(spread(root, "suite/a", half), spread(root, "suite/b", half)),
    { "suite/data" })
  assert(Fs.mkdirs(root .. "/suite/data"))
  assert(Fs.write(root .. "/suite/data/f", "f"))
  local plan = test_sandbox.plan(root, scratch, inputs, {}, nil, nil, copies)
  assert(plan.trouble == "" and plan.over == 0, plan.trouble .. " over " .. tostring(plan.over))
  local unveil = assert(plan.sandbox.unveil)
  assert(holds(unveil.reads, root .. "/suite/data") and
      (unveil.at or {})[root .. "/suite/data"] == "/tree/suite/data")
  assert(copied_at(plan, copies, { "/tree/suite/a" }))
end

--- Of two directories one beneath the other, only one is copied: the
--- other's files are in its copy already, and a copy of it would be bound
--- inside the first. The next directory apart from both is copied
--- instead, where one is not enough.
local function test_nested_directories_are_not_both_copied(tmp: string)
  local root, scratch, copies = tmp .. "/root", scratch_in(tmp), tmp .. "/copies"
  assert(Fs.write(build_dir(root) .. "/cosmic.db", "x"))
  local most = confine.unveil_max
  local files = joined(spread(root, "a/sub", most + most // 2), spread(root, "a", most // 2))
  files = joined(files, spread(root, "b", most))
  local plan = test_sandbox.plan(root, scratch, effective(files), {}, nil, nil, copies)
  assert(plan.trouble == "" and plan.over == 0, plan.trouble .. " over " .. tostring(plan.over))
  assert(copied_at(plan, copies, { "/tree/a", "/tree/b" }))
end

--- A copy that fails part-way leaves the plan's paths as they were, each
--- file at its place in /tree, says why, and leaves no copy behind: a file
--- whose copy's path is too long for the host.
local function test_a_copy_that_fails_leaves_the_paths_as_they_were(tmp: string)
  local root, scratch = tmp .. "/root", scratch_in(tmp)
  local copies = tmp .. "/" .. string.rep("c", 250) .. "/" .. string.rep("d", 250)
  assert(Fs.write(build_dir(root) .. "/cosmic.db", "x"))
  -- Beneath many/, short enough at its place in the tree, too long in a
  -- copy: its path in the tree comes within 50 of the host's bound on a
  -- path (PATH_MAX: Linux's 4096, macOS's 1024), and a copy's
  -- directory is 500 longer than the tree's.
  local bound = assert(sys.uname()).sysname == "Linux" and 4096 or 1024
  local deep = "many"
  local room = bound - 50 - #(root .. "/many/f.tl")
  while room > 1 do
    local width = room - 1
    if width > 200 then width = 200 end
    deep = deep .. "/" .. string.rep("p", width)
    room = room - width - 1
  end
  assert(Fs.mkdirs(root .. "/" .. deep))
  assert(Fs.write(root .. "/" .. deep .. "/f.tl", "f"))
  local files = joined(spread(root, "many", confine.unveil_max + 20), { deep .. "/f.tl" })
  local plan = test_sandbox.plan(root, scratch, effective(files), {}, nil, nil, copies)
  assert(plan.trouble:find("copied to fewer paths", 1, true) ~= nil, plan.trouble)
  local unveil = assert(plan.sandbox.unveil)
  for _, file in ipairs(files) do
    assert(holds(unveil.reads, root .. "/" .. file) and
        (unveil.at or {})[root .. "/" .. file] == "/tree/" .. file, file)
  end
  assert(#(plan.copied or {}) == 0)
  assert(#(assert(Fs.list(copies))) == 0, "a failed copy is left")
end

--- The program is named in the worker's build directory, its bin/cosmic,
--- where it is the tree's own tool by where each resolves -- a tree here
--- whose tool leads to this program -- and where this program
--- is a portable artifact, whose relaunch names the path; a worker whose
--- module declares `tool` then has it there alone, with the rest of
--- its bin, not at its own name. In another tree it keeps its own name
--- -- but where that is beneath /tree, as this worker's is sandboxed,
--- where the other's worker has a tree of its own: there it has it at
--- /program/<its name>. A worker that is not a tool keeps the
--- runner's name, which it has no way to read.
local function test_the_tree_s_own_program_is_named_in_the_tree(tmp: string)
  local other, tree, scratch = tmp .. "/other", tmp .. "/tree", scratch_in(tmp)
  for _, made in ipairs({ build_dir(other) .. "/bin", build_dir(tree) .. "/bin" }) do
    assert(Fs.mkdirs(made))
  end
  assert(Fs.write(build_dir(other) .. "/bin/cosmic", "p"))
  local inputs = effective({})
  inputs.tool = true
  local relaunch, _ = Proc.relaunch()
  local executable, _ = Proc.executable()
  if relaunch == nil or relaunch.argv[2] ~= "--artifact" or executable == nil then
    assert(test_sandbox.plan(other, scratch, inputs, {}).program == nil)
    return -- no portable artifact to name
  end
  local elsewhere = test_sandbox.plan(other, scratch, inputs, {})
  if Fs.within(executable, "/tree") or Fs.within(executable, Fs.dirname(test_sandbox.output)) then
    local placed = "/program/" .. Fs.basename(executable)
    assert(elsewhere.program == placed, tostring(elsewhere.program))
    assert((assert(elsewhere.sandbox.unveil).at or {})[executable] == placed)
  else
    assert(elsewhere.program == nil, tostring(elsewhere.program))
  end
  assert(holds(assert(elsewhere.sandbox.unveil).reads, executable))
  assert(sys.symlink(executable, build_dir(tree) .. "/bin/cosmic"))
  local plan = test_sandbox.plan(tree, scratch, inputs, {})
  assert(plan.program == test_sandbox.output .. "/bin/cosmic", tostring(plan.program))
  -- A worker that is not a tool keeps the runner's name.
  local plain = test_sandbox.plan(tree, scratch, effective({}), {})
  assert(plain.program == nil, tostring(plain.program))
  local unveil = assert(plan.sandbox.unveil)
  assert(holds(unveil.reads, build_dir(tree) .. "/bin") and (unveil.at or {})[build_dir(tree) .. "/bin"] ==
      test_sandbox.output .. "/bin")
  assert(not holds(unveil.reads, executable), executable .. " is given at its own name")
end

--- A worker is given the tree's store, its closure's files and what its
--- module declares of the tree, each at its name under /tree; its
--- scratch directory to write, at [`test_sandbox.scratch`]; the host
--- files it declares at their own names; and no network but its own
--- loopback. A path that is not there is not given: a read of it finds
--- nothing either way.
local function test_a_plan_gives_the_tree_at_tree_and_the_scratch_at_its_padded_name(tmp: string)
  local root, scratch, dir = tmp .. "/root", scratch_in(tmp), tmp .. "/host"
  for _, made in ipairs({ build_dir(root), root .. "/a", root .. "/data", dir }) do
    assert(Fs.mkdirs(made))
  end
  assert(Fs.write(build_dir(root) .. "/cosmic.db", "x"))
  for _, file in ipairs({ "a/x.tl", "data/f" }) do
    assert(Fs.write(root .. "/" .. file, "x"))
  end
  local host = dir .. "/given"
  assert(Fs.write(host, "h"))
  local inputs = effective({ "a/x.tl", "a/missing.tl" })
  inputs.reads = { "data/", "../outside" }
  inputs.host = { host }
  local plan = test_sandbox.plan(root, scratch, inputs, {})
  local unveil = assert(plan.sandbox.unveil)
  assert(plan.over == 0 and plan.sandbox.offline == true)
  assert(holds(unveil.reads, build_dir(root) .. "/cosmic.db") and
      (unveil.at or {})[build_dir(root) .. "/cosmic.db"] == test_sandbox.output .. "/cosmic.db")
  assert(holds(unveil.reads, root .. "/a/x.tl") and (unveil.at or {})[root .. "/a/x.tl"] == "/tree/a/x.tl")
  assert(holds(unveil.reads, root .. "/data") and (unveil.at or {})[root .. "/data"] == "/tree/data")
  assert(not holds(unveil.reads, root .. "/a/missing.tl"))
  for _, path in ipairs(unveil.reads) do
    assert(path:find("outside", 1, true) == nil, "a read that climbs out of the tree: " .. path)
  end
  assert(holds(unveil.reads, host) and (unveil.at or {})[host] == nil)
  assert(#(unveil.writes or {}) == 1 and (unveil.writes or {})[1] == scratch and
      (unveil.at or {})[scratch] == test_sandbox.scratch)
  assert(plan.trouble == "", plan.trouble)
  -- The runtime's own paths (/dev/null: a path that is not there is not
  -- given), but not the system's own, which it is not given undeclared,
  -- nor the host's /proc, which a policy's sandbox has one of its own for.
  assert(holds(unveil.reads, "/dev/null") and not holds(unveil.reads, "/proc"))
  assert(not holds(unveil.reads, "/usr"))
  -- Declaring `system` gives the system's own paths too: see
  -- build/test_sandbox_system_test.tl, whose worker has them to give.
  -- Given the store of its closure, a worker has it at its build
  -- directory's cosmic.db in
  -- the projection's place, which it has nowhere; declaring `store`
  -- keeps the projection.
  assert(Fs.mkdirs(build_dir(root) .. "/stores"))
  local closure_store = build_dir(root) .. "/stores/closure.db"
  assert(Fs.write(closure_store, "c"))
  local closed = test_sandbox.plan(root, scratch, inputs, {}, closure_store)
  assert((assert(closed.sandbox.unveil).at or {})[closure_store] == test_sandbox.output .. "/cosmic.db" and
      not holds(assert(closed.sandbox.unveil).reads, build_dir(root) .. "/cosmic.db"))
  inputs.store = true
  local whole = test_sandbox.plan(root, scratch, inputs, {}, closure_store)
  assert((assert(whole.sandbox.unveil).at or {})[build_dir(root) .. "/cosmic.db"] == test_sandbox.output .. "/cosmic.db" and
      not holds(assert(whole.sandbox.unveil).reads, closure_store))
  inputs.store = false
  -- A declared path not there yet is given nothing.
  inputs.reads = { "data/", "later/x" }
  local later = test_sandbox.plan(root, scratch, inputs, {})
  assert(not holds(assert(later.sandbox.unveil).reads, root .. "/later/x"))
  inputs.reads = { "data/", "../outside" }
  -- A declared cache is given to write at its own name, made first.
  inputs.cache_paths = { tmp .. "/caches/zig-global" }
  local cached = test_sandbox.plan(root, scratch, inputs, {})
  assert(cached.trouble == "", cached.trouble)
  assert(holds(assert(cached.sandbox.unveil).writes or {}, tmp .. "/caches/zig-global") and
      (assert(cached.sandbox.unveil).at or {})[tmp .. "/caches/zig-global"] == nil)
  assert(Fs.exists(tmp .. "/caches/zig-global"))
  -- A file a declared cache holds is given through the cache alone, not
  -- bound again on top of it: there its mount point would be the host's
  -- own file, and a mount onto one renamed over as it is made fails
  -- the worker's start (the stamp beside this program's core, in the
  -- cores directory the `bootstrap` cache is).
  local stamp = tmp .. "/caches/cores/.verified-core"
  assert(Fs.mkdirs(tmp .. "/caches/cores"))
  assert(Fs.write(stamp, "s"))
  inputs.host = { stamp }
  inputs.cache_paths = { tmp .. "/caches/cores" }
  local nested = test_sandbox.plan(root, scratch, inputs, {})
  assert(nested.trouble == "", nested.trouble)
  assert(holds(assert(nested.sandbox.unveil).writes or {}, tmp .. "/caches/cores") and
      not holds(assert(nested.sandbox.unveil).reads, stamp))
  -- The `bootstrap` cache: cores of its own, made in its scratch
  -- directory before it starts -- a ruleset that holds it walks what is
  -- there then -- and named to it, not the host's, which the cores
  -- directory this program's core is in stays.
  inputs.caches, inputs.cache_paths = { "bootstrap" }, { tmp .. "/caches/cores" }
  local own_cores = test_sandbox.plan(root, scratch, inputs, { COSMIC_PORTABLE_CACHE =
      tmp .. "/caches/cores" })
  assert(own_cores.trouble == "", own_cores.trouble)
  assert(own_cores.env.COSMIC_PORTABLE_CACHE == test_sandbox.scratch .. "/cores",
    tostring(own_cores.env.COSMIC_PORTABLE_CACHE))
  local cores = assert(sys.stat(scratch .. "/cores"))
  assert(cores.kind == "dir" and cores.mode & 511 == 448, tostring(cores.mode))
  assert(not holds(assert(own_cores.sandbox.unveil).writes or {}, tmp .. "/caches/cores") and
      holds(assert(own_cores.sandbox.unveil).reads, stamp))
  inputs.caches, inputs.cache_paths = {}, {}
  local alone = test_sandbox.plan(root, scratch, inputs, {})
  assert(holds(assert(alone.sandbox.unveil).reads, stamp))
  inputs.host = { host }
  -- A host path where the sandbox has its own -- its scratch directory,
  -- or above it, or /tmp or /tree themselves -- cannot be given, and
  -- is named as declared.
  for _, own in ipairs({ scratch .. "/x", tmp, "/tmp", "/tree", "/" }) do
    inputs.host = { own }
    local refused = test_sandbox.plan(root, scratch, inputs, {})
    assert(refused.trouble:find(string.format("Test.policy grant of the host path %q: ", own),
      1, true) and
        refused.trouble:find("is where its sandbox has", 1, true), own .. ": " .. refused.trouble)
  end
  -- And by where it resolves: a link to the scratch directory.
  assert(Fs.symlink(scratch, tmp .. "/to-scratch"))
  inputs.host = { tmp .. "/to-scratch" }
  local linked = test_sandbox.plan(root, scratch, inputs, {})
  assert(linked.trouble:find("is where its sandbox has its scratch directory", 1, true),
    linked.trouble)
  inputs.host = { host }
  assert(test_sandbox.plan(root, scratch, inputs, {}).trouble == "")
  -- Offline, whatever it declares: the loopback addresses it may
  -- declare, its own loopback answers.
  for _, hosts in ipairs({ "", "127.0.0.1 127.0.0.2" }) do
    inputs.network = {}
    for name in hosts:gmatch("%S+") do inputs.network[name] = true end
    local planned = test_sandbox.plan(root, scratch, inputs, {})
    assert(planned.sandbox.offline == true, hosts)
  end
  inputs.network = {}
  inputs.tool = true
  local tooled = test_sandbox.plan(root, scratch, inputs, {})
  -- No o/bin here to give.
  assert(not holds(assert(tooled.sandbox.unveil).reads, build_dir(root) .. "/bin"))
end

--- Runs `cosmic test --all` on `root` with `env`, answering what it
--- printed and whether it passed.
local function run(root: string, output: string, env: {string:string}): string, boolean
  local ran = fixture.run(root, output, env)
  return ran.text, ran.ok
end

--- End to end: a `host` path that is the tree's fails each of its tests
--- before it starts, naming it, sandboxed or not.
local function test_a_host_path_that_is_the_trees_is_refused_in_either_mode(tmp: string)
  local base = assert(Fs.absolute(tmp))
  local root, product = base .. "/root", base .. "/product"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.mkdirs(product))
  assert(Fs.write(product .. "/given.txt", "given"))
  assert(Fs.write(product .. "/sibling.txt", "sibling"))
  local env = this_program.environment()
  env.COSMIC_VERDICT_CACHE = "0"
  env.COSMIC_TEST_ALL = nil
  env.COSMIC_SANDBOX = nil
  env.COSMIC_TEST_SANDBOX = nil
  -- The tree's: refused before the test starts, in either mode.
  fixture.host_test(root, product, root .. "/suite/given.txt")
  for _, mode in ipairs({ "0", "" }) do
    env.COSMIC_TEST_SANDBOX = mode ~= "" and mode or nil
    local inside, inside_ok = run(root, tmp .. "/inside" .. mode, env)
    assert(not inside_ok and inside:find(root .. "/suite/given.txt is the tree's", 1, true) and
        not inside:find("read|", 1, true), inside)
    assert(not inside:find("could not be supervised", 1, true), inside)
  end
end

--- End to end, the half of a sandboxed run's checks that needs no sandbox:
--- with the switch off (`COSMIC_TEST_SANDBOX=0`) a worker reads all of the
--- tree and the host but only the variables it declares, and the run says
--- it is keyed by what it declares and shares no verdict. Then, where this
--- platform gives no sandbox at all, the run says so and runs its workers
--- unsandboxed, and with the switch on it fails. A platform that gives one
--- returns here: its runs are `test_sandbox_run_tool_test.tl`'s
--- (`requires`), which a host with none does not run.
local function test_an_unsandboxed_run_reads_the_tree_and_a_platform_with_no_sandbox_says_so(tmp: string)
  local root, hidden = tmp .. "/root", tmp .. "/hidden"
  fixture.view_suite(tmp, root, hidden)
  local env = this_program.environment()
  env.COSMIC_VERDICT_CACHE = "0"
  env.COSMIC_TEST_ALL = nil
  env.COSMIC_SANDBOX = nil
  env.DECLARED_VAR = "d"
  env.UNDECLARED_VAR = "u"
  local real_root = assert(Fs.absolute(root))
  env.COSMIC_TEST_SANDBOX = "0"
  local text, ok = run(root, tmp .. "/plain", env)
  assert(not ok, text)
  assert(text:find("; unsandboxed (COSMIC_TEST_SANDBOX=0), keyed by declared inputs, " ..
      "sharing no verdicts\n", 1, true), text)
  assert(text:find("rerun: COSMIC_TEST_SANDBOX=0 cosmic test suite/view_test.tl:test_view", 1,
    true), text)
  local seen = text:match("seen|([^\n]*)|end")
  assert(seen ~= nil, text)
  local fields: {string} = {}
  for field in (seen .. "|"):gmatch("([^|]*)|") do fields[#fields + 1] = field end
  assert(fields[1] == real_root and fields[3] == "declared" and fields[4] == "undeclared" and
      fields[5] == "true" and fields[6] == "d" and fields[7] == "nil" and
      fields[8] == "declaredundeclared/d/", seen)
  -- Branches on the platform: where it can sandbox, the run does, and that
  -- is checked by the module that requires a nest.
  if assert(sys.uname()).sysname == "Linux" then return end
  env.COSMIC_TEST_SANDBOX = nil
  text, ok = run(root, tmp .. "/sandboxed", env)
  assert(not ok, text)
  -- And why, in the summary.
  assert(text:find("; unsandboxed, as no worker can be sandboxed here (", 1, true) and
      text:find("), keyed by declared inputs, sharing no verdicts\n", 1, true), text)
  -- Required, the run fails instead.
  env.COSMIC_TEST_SANDBOX = "1"
  local required: string | nil = nil
  required, ok = run(root, tmp .. "/required", env)
  assert(not ok and required:find("COSMIC_TEST_SANDBOX=1, but no worker can be sandboxed here",
    1, true), required)
end

--- The sandbox a test's processes run in (build.confine): what a
--- sandboxed worker is given, and where a path leads as the sandbox
--- binds it.

local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local confine = require("build.confine")
local sandbox_skip = require("build.sandbox_skip")
local observations = require("build.filesystem_observations")
local stand_in = require("build.stand_in")
local this_program = require("build.this_program")
local type raw_process = require("cosmic.internal.process")

-- TODO: declare /proc for Linux alone once a declaration can name a
-- host path per platform (a `host` entry for Linux and one for macOS):
-- macOS has no /proc, so there this declares a path that is not there,
-- which gives and keys nothing but says what the tests need wrongly.
--- What a sandboxed worker of this very program reads: /proc, where the
--- stand-in it starts finds itself, and the program itself, which its
--- tests start again as that worker; and `nests`, since they confine
--- what they start in a root of its own.
Test.needs{
  host = { "/proc" },
  env = { "COSMIC_SANDBOX" },
  tool = true,
  nests = true,
}

local type Searcher = function(string): any, any

--- A stand-in program built under `tmp` (build/stand_in.tl), which runs
--- the script its first argument holds: a static executable that reads
--- only itself (and /proc, where it finds itself), so one confined needs
--- nothing of the system's own.
local function probe_in(tmp: string): string
  return (assert(stand_in.build(tmp .. "/stand-in")))
end

--- The raw process table build.confine stands in for the spawn of, as
--- `require` hands it to its loader.
local function raw_process_table(): raw_process
  for _, searcher in ipairs(package.searchers as {Searcher}) do -- cast: searchers' loaders take an extra
    local loader, extra = searcher("build.confine")
    if type(loader) == "function" and type(extra) == "table" then
      return extra as raw_process -- cast: the table core/process.h defines
    end
  end
  error("build.confine is handed no raw table")
end

--- What a sandboxed worker's chunk says: whether its
--- /proc is a procfs of its own pid namespace (which has no /proc/sys)
--- or the host's; whether its core found the stamp beside it in the
--- cache that spares hashing it again; and what a grandchild it
--- confines to the first path `...` names reads of that path and of the
--- second, which it was not given. The grandchild is the stand-in named
--- third, and it also gets /proc to find itself.
local worker_chunk <const> = [==[
local sys = require("cosmic.sys")
local given, hidden, probe = ...
local said = { sys.stat("/proc/sys") == nil and "own-proc" or "host-proc" }
local core = assert(sys.readlink("/proc/self/exe"))
local directory, name = core:match("^(.*)/(core%-[^/]*)$")
if directory == nil then
  said[#said + 1] = "uncached"
else
  local st = assert(sys.stat(core))
  local fd = sys.open(directory .. "/.verified-" .. name, sys.O_RDONLY)
  local line = fd ~= nil and sys.read(fd, 96) or ""
  said[#said + 1] = line == string.format("%d|%d|%d|%d\n", st.size, st.ino, st.mtime, st.ctime)
    and "stamped" or "unstamped"
end
local process
for _, searcher in ipairs(package.searchers) do
  local loader, extra = searcher("cosmic.child")
  if type(loader) == "function" and type(extra) == "table" then process = extra end
end
local reads = { given, probe, "/proc" }
local report = assert(sys.open(given .. "/../report", sys.O_CREAT | sys.O_RDWR | sys.O_TRUNC, 420))
local pid, trouble, errno = process.spawn(probe, { probe,
  "cat " .. given .. "/f; print; present " .. hidden .. "/f && print hidden-seen || print hidden-absent" },
  {}, "/", nil, report, report, false, nil, { unveil = { reads = reads }, offline = true })
if pid == nil then
  said[#said + 1] = "refused " .. tostring(sys.errno_name(errno)) .. ": " .. trouble
else
  said[#said + 1] = "exited " .. process.waitpid(pid, false).code
  said[#said + 1] = sys.pread(report, 4096, 0)
end
print(table.concat(said, "\n"))
]==]

--- The descriptors [`this_program.program`] hands its child, as
--- [`process.spawn`] takes them: each a descriptor of this process, as
--- the relaunch's are, and none "capture", which only [`cosmic.child`]
--- reads.
local function spawn_fds(started: this_program.Program): {integer:integer}
  local fds: {integer:integer} = {}
  for number, fd in pairs(started.options.fds) do
    if fd is integer then
      fds[number] = fd
    else
      error("descriptor " .. tostring(number) .. " is " .. fd .. ", which spawn cannot hand on")
    end
  end
  return fds
end

--- Runs `worker_chunk` in a worker of this very program sandboxed to
--- `worker_unveil`'s paths, as a worker whose module declares nothing
--- of the system's is (the chunk starts a stand-in, in `tmp`, its
--- scratch), in `tmp`: the lines it said, or nil where there is no
--- portable artifact to start again, or no sandbox to be had.
local function sandboxed_worker(tmp: string): {string} | nil
  if Proc.relaunch() == nil then return nil end -- no portable artifact to start again
  local probe = probe_in(tmp)
  local given, hidden = tmp .. "/given", tmp .. "/hidden"
  for _, dir in ipairs({ given, hidden }) do assert(Fs.mkdirs(dir)) end
  assert(Fs.write(given .. "/f", "in"))
  assert(Fs.write(hidden .. "/f", "secret"))
  local tree = assert(sys.getcwd())
  local unveil = confine.worker_unveil(tree, tree, tmp)
  -- Given no environment but the relaunch's, as `cosmic test` gives
  -- its worker none but what it pins.
  local worker = this_program.program({ "-e", worker_chunk, given, hidden, probe }, { env = {} })
  local argv, opts = worker.argv, worker.options
  local output = assert(sys.open(tmp .. "/said", sys.O_CREAT | sys.O_RDWR | sys.O_TRUNC, 420))
  local process = raw_process_table()
  local pid, trouble, errno = process.spawn(argv[1], argv, opts.env, tree, nil, output,
    output, false, spawn_fds(worker),
    { unveil = unveil, offline = true })
  if pid == nil then
    sys.close(output)
    sandbox_skip.refused("no sandbox for the worker: " .. tostring(trouble))
    -- Only as a kernel that cannot confine refuses, never for a path
    -- the set left out.
    assert(errno == sys.ENOSYS or errno == sys.EPERM or errno == sys.EACCES or
      errno == sys.EINVAL or errno == sys.ENOSPC, trouble)
    return nil
  end
  local status = assert(process.waitpid(pid, false))
  local said = assert(sys.pread(output, 65536, 0))
  sys.close(output)
  assert(status.code == 0, said)
  local lines: {string} = {}
  for line in said:gmatch("[^\n]+") do lines[#lines + 1] = line end
  return lines
end

--- A worker of this very program, sandboxed to `worker_unveil`'s paths
--- and no more, starts and finds the stamp that says its core was
--- verified (where the cache has one), so it hashes nothing again.
--- Having a procfs of its own, it can confine a process of its own to a
--- part of what it was given: that process reads its part and nothing
--- else.
---
--- Two cases end in a refusal instead. Where the kernel denies the
--- worker a procfs of its own (a container masking parts of /proc), its
--- /proc is the host's, read-only, so the process's uid_map write fails.
--- And a test run as root without CAP_SETFCAP, as in a sandboxed `cosmic
--- test` worker (build/test_sandbox.tl), starts the process as root
--- unmapped, which the kernel refuses a user namespace (core/syscalls.c's
--- `map_ids`).
local function test_a_worker_sandboxed_to_what_it_needs_starts_and_confines_its_own(tmp: string)
  local lines = sandboxed_worker(tmp)
  if lines == nil then return end
  local said = table.concat(lines, "\n")
  -- Whether the cache holds a stamp for the core, which the worker
  -- then has to find.
  local relaunch = assert(Proc.relaunch())
  local directory, name = relaunch.argv[1]:match("^(.*)/(core%-[^/]*)$")
  local stamped = directory ~= nil and sys.lstat(directory .. "/.verified-" .. name) ~= nil
  assert(not stamped or lines[2] == "stamped", said)
  -- Root that has given up CAP_SETFCAP (bit 31 of CapEff) -- as root
  -- in a sandbox has -- may not map root into a user namespace of its
  -- own, so its worker starts unmapped and cannot confine another.
  local status = Fs.read("/proc/self/status") or ""
  local effective = status:match("\nCapEff:%s*(%x+)") or "0"
  local capabilities = math.tointeger(tonumber(effective:sub(-8), 16)) or 0
  local inner_root = sys.getuid() == 0 and capabilities & (1 << 31) == 0
  if inner_root then
    assert(lines[3]:find("^refused EPERM") ~= nil, said)
  elseif confine.own_proc_given() then
    assert(lines[1] == "own-proc" and lines[3] == "exited 0" and lines[4] == "in" and
      lines[5] == "hidden-absent", said)
  else
    assert(lines[1] == "host-proc" and lines[3]:find("^refused EROFS") ~= nil, said)
  end
end

--- `resolution`, in Teal, resolves a path as the observation log's C
--- `resolve` does: through links, a missing name and all after it as
--- written, "." and ".." included, and each run of slashes as one.
-- TODO: compare against a Teal oracle of its own (the one
-- build/filesystem_observations_test.tl keeps, `resolved_before`) once
-- the log's C `resolve` goes (removing the observation log, step 5).
local function test_a_resolution_is_the_one_the_log_makes(tmp: string)
  local real = assert(sys.realpath(tmp))
  assert(Fs.mkdirs(real .. "/d/e"))
  assert(Fs.write(real .. "/d/f", "x"))
  assert(Fs.symlink(real .. "/d", real .. "/link"))
  assert(Fs.symlink("missing", real .. "/dangling"))
  assert(Fs.symlink("d/e", real .. "/relative"))
  assert(Fs.symlink(real .. "/loop-b", real .. "/loop-a"))
  assert(Fs.symlink(real .. "/loop-a", real .. "/loop-b"))
  local long = real .. "/" .. string.rep("n", 200)
  for _ = 1, 25 do long = long .. "/" .. string.rep("n", 200) end
  local paths: {string} = { "/", "//", "", "relative/path", "/nowhere/at/all", "/nowhere/..",
    tmp, tmp .. "/", tmp .. "//d///f", real .. "/link", real .. "/link/", real .. "/link/.",
    real .. "/link/..", real .. "/link/e/../f", real .. "/missing/../d/f", real .. "/d/f/",
    real .. "/d/f/g", real .. "/dangling", real .. "/dangling/x", real .. "/./d/./e",
    real .. "/link//", real .. "/relative/../f", real .. "/relative/missing/..", long,
    real .. "/loop-a", real .. "/loop-a/x", real .. "/d/f/x/..", real .. "/link/f/y",
    long .. "/../f" }
  for _, path in ipairs(paths) do
    local told, logged = confine.resolution(path), observations.resolution(path)
    assert(told == logged, path:sub(1, 80) .. ": " .. told:sub(1, 80) .. " ~= " ..
      logged:sub(1, 80))
  end
end

--- A stale tool, rebuilt from the tree it is stale against and re-entered.
---
--- Cosmic builds itself, so the tool is also an artifact of the tree. When
--- only Teal differs, it projects a new database, combines it with the exact
--- retained portable prefix, atomically replaces the same logical artifact,
--- and re-enters the original argv once; when the rebuilt tool's writer is
--- not the code that wrote its database, it writes that database again
--- itself and re-enters once more, so a rebuild lands on the bytes a boot
--- writes. When a core input differs, only zig
--- can rebuild it: the tool runs `bin/zig build boot` and re-enters the
--- original argv on the tool that boot wrote, unless `COSMIC_AUTO_BOOT=0`
--- says to refuse instead (`reboot.auto_boot`).
---
--- One rule for the working database's handle: a function here that is
--- handed it and stops the command -- `into` on every path,
--- `reboot.guard` whenever it answers an exit code -- closes it first;
--- only `reboot.guard`'s nil, "go on", hands it back open. A function
--- handed none, `reboot.boot_into`, needs it closed already.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local sys = require("cosmic.sys")
local artifact = require("build.artifact")
local importer = require("build.importer")
local shared_compiles = require("build.shared_compiles")
local teal = require("build.teal")
local tree = require("build.tree")
local work = require("build.work")
local writer = require("build.writer")
local log = require("build.verdict").log
local type compiler = require("build.compiler")

local record reboot
  --- How the tree stands against the running binary.
  enum State
    "fresh"
    "teal"
    "core"
  end
end

--- Set in the environment of the process a reboot enters, so a tool
--- still stale after one refuses rather than rebooting again: "1" after
--- a rebuild or a boot, "2" after the database is written again by the
--- rebuilt tool's own writer (`unsettled`).
local marker = "COSMIC_REBOOTED"

--- Whether the running binary's database was compiled or written by
--- other code than it carries: a stale tool rebuilding itself compiles
--- the tree and writes the new tool's database with its own compiler and
--- writer, and when either is not the tree's (`work.Identities`), the new
--- tool compiles and writes it again itself, once, so the tool a rebuild
--- leaves is the one a boot writes. A tool whose database names neither
--- was written by a binary from before they did, and is unsettled too.
local function unsettled(): boolean
  local written_by = Store.meta("written_by")
  local compiled_by = Store.meta("compiled_by")
  return written_by == nil or written_by ~= Store.meta("writer") or
    compiled_by == nil or compiled_by ~= Store.meta("compiler")
end

--- What a tool stale against the core says when it does not boot.
local core_refusal = "the tool is stale; run bin/zig build boot"

--- What a stale cosmic that is not the tree's own tool says: it neither
--- rebuilds itself nor boots the tree.
local foreign_refusal = "this cosmic is stale against the tree and is not " ..
  "the tree's own tool (under o/), so it will not rebuild itself; " ..
  "run bin/zig build boot and use o/bin/cosmic"

--- Whether the running binary is one this tree built: under `root/o`,
--- as o/bin/cosmic and the checked suite's o/sanitized one are. Only such
--- a tool rebuilds itself when stale, since a rebuild writes the tree's
--- tool over the path it was started as; any other cosmic run here -- a
--- release, the bootstrap cache's, one on PATH -- would be overwritten
--- with it. That path is judged where it names, its directory resolved
--- but not the name itself: a file renamed or removed while it runs is
--- still judged by where it was, and a link into o/ from elsewhere is
--- elsewhere, since the rebuild would replace the link, not o/'s tool.
--- `executable` is the path this process was started as by default.
-- TODO: refuse a host-built tool whose file was removed while it runs:
-- with no started-as path, Proc.executable falls back to /proc/self/exe,
-- which then reads ".../cosmic (deleted)", and a rebuild would write a
-- file of that name. Once Proc.executable says the file is gone, answer
-- nil for it here.
function reboot.own_tool(root: string, executable?: string): boolean | nil, string
  local running = executable
  if running == nil then
    local found, trouble = Proc.executable()
    if found == nil then
      return nil, trouble
    end
    running = found
  end
  local directory, directory_trouble = Fs.absolute(Fs.dirname(running))
  if directory == nil then
    return nil, directory_trouble
  end
  local outputs, outputs_trouble = Fs.absolute(root .. "/o")
  if outputs == nil then
    return nil, outputs_trouble
  end
  return Fs.within(directory .. "/" .. Fs.basename(running), outputs), ""
end

--- Whether a tool stale against the core boots it: unless
--- `COSMIC_AUTO_BOOT` is "0", which a caller that wants the refusal
--- (a fixture holding the artifact still, say) sets.
function reboot.auto_boot(environment?: {string:string}): boolean
  local value: string | nil
  if environment ~= nil then
    value = environment.COSMIC_AUTO_BOOT
  else
    value = sys.getenv("COSMIC_AUTO_BOOT")
  end
  return value ~= "0"
end

--- `argv` from slot 0 on, as a list to exec.
local function reentry(argv: {integer:string}): {string}
  local arguments: {string} = {}
  local at = 0
  while argv[at] ~= nil do
    arguments[#arguments + 1] = argv[at]
    at = at + 1
  end
  return arguments
end

--- Compares the tree's fingerprints with the running binary's.
local function state_of(handle: work.Handle): reboot.State | nil, string
  local fingerprint, trouble = work.record_fingerprint(handle)
  if fingerprint == nil then
    return nil, trouble
  end
  if fingerprint.boot == (Store.meta("boot_hash") or "") then
    return "fresh"
  end
  if fingerprint.image == (Store.meta("image_hash") or "") then
    return "teal"
  end
  return "core"
end

--- Closes `handle`, which the caller is giving up, and answers `trouble`.
local function closing(handle: work.Handle, trouble: string): string
  local _, _ = work.close(handle)
  return trouble
end

--- Why a rebuild (`into`, settling when `settle`) refuses in this
--- process, which a reboot has entered: nil when it may go on.
local function refusal(settle: boolean): string | nil
  local entered = sys.getenv(marker)
  if entered == nil or (settle and entered == "1") then
    return nil
  end
  if settle then
    return "the tool is still unsettled after a reboot"
  end
  return "the tool is still stale after a reboot"
end

--- Rebuilds the tool from the tree and replaces this process with it,
--- running `argv` again. Returns only when it cannot, saying why. It
--- takes `handle`, open and staged, and closes it on every path: before
--- it publishes the rebuilt tool, or on the way out of a failure.
--- `settle` rebuilds a fresh but `unsettled` tool, which a rebuild may
--- enter; anything else refuses once a reboot has entered this process.
local function into(handle: work.Handle, built: compiler,
                     argv: {integer:string}, settle: boolean): string
  local refused = refusal(settle)
  if refused ~= nil then
    return closing(handle, refused)
  end
  local prefix, prefix_trouble = artifact.trusted_prefix()
  if prefix == nil then
    return closing(handle, prefix_trouble)
  end
  local out, executable_trouble = Proc.executable()
  if out == nil then
    return closing(handle, executable_trouble)
  end

  -- A fresh checkout has no boot-populated compiler row in its working
  -- database yet. Preserve the exact compiler carried by the trusted running
  -- artifact so the rebuilt Cosmic remains able to rebuild again.
  local compiler_source, compiler_trouble = Store.source("vendor.tl")
  if compiler_source == nil then
    return closing(handle, "the compiler source is not in this binary: " .. compiler_trouble)
  end
  local kept, keep_trouble = work.put_compiler(handle, compiler_source)
  if not kept then
    return closing(handle, keep_trouble)
  end
  -- And the zones it carries, which only a boot reads from the tree.
  local databases = Store.databases()
  local zones, zones_trouble = work.zoneinfo_of(databases[#databases])
  if zones == nil then
    return closing(handle, "the zones in this binary: " .. zones_trouble)
  end
  local zoned, zoned_trouble = work.put_zoneinfo(handle, zones)
  if not zoned then
    return closing(handle, zoned_trouble)
  end

  -- Compiled by this tool's compiler and keyed by its identity, which is
  -- the tree's only when the compiler has not moved: a row this compiler
  -- made is never taken for the tree's compiler's. The tool that replaces
  -- this one carries the tree's identities, and compiles again itself
  -- whatever this compiler compiled (`unsettled`).
  local shared = shared_compiles.for_build()
  local derived, derive_trouble = importer.derive(handle, true, built, shared)
  local identities, identity_trouble: work.Identities, string = nil, derive_trouble
  if derived ~= nil then
    identities, identity_trouble = work.record_identities(handle)
  end
  if identities == nil then
    -- `compile` finishes the cache; here nothing will.
    if shared ~= nil then shared.finish() end
    return closing(handle, identity_trouble)
  end
  -- A fresh tool settling runs the tree's own code, so its compiler is
  -- the tree's, named as its own `work.compiler_identity` names it,
  -- which is what the tool it writes carries. The identity it carries
  -- itself was taken by the tool that wrote it, by that tool's code:
  -- where the two define the identity apart, keying by it would leave
  -- the tool written here as unsettled as this one. Only a tool whose
  -- recorded fingerprint is the tree's, by its own code, is known to run
  -- the tree's code.
  -- TODO: settle a commit that moves both the fingerprint's definition
  -- (build.work's `is_tool`, `tool_files`) and the identity's: the tool
  -- a stale tool rebuilds is then stale by its own code, so it settles on
  -- the "teal" path with no fingerprint of its own to prove it runs the
  -- tree's code, keys by the carried identity, and the tool it writes
  -- refuses as still unsettled (exit 3). A fix would prove it another
  -- way -- every module the tool carries against the staged tree's
  -- source hashes -- or have the stale tool record the fingerprint by
  -- the tree's own build.work, run from source.
  local tool = Store.meta("compiler") or ""
  if settle then
    local recorded, _ = work.recorded_boot_hash(handle)
    if recorded ~= nil and recorded == Store.meta("boot_hash") then
      tool = identities.compiler
    end
  end
  -- Unjudged: this tool's build.contracts, rules and exemptions alike,
  -- may be older than the tree's, so a module it refuses is built
  -- anyway, and the tool built here judges it again, by the tree's own,
  -- when it re-enters the command.
  local result, compile_trouble =
    importer.compile(handle, built, tool, true, shared)
  if result == nil then
    return closing(handle, compile_trouble)
  end
  local database_path = handle.root .. "/o/cosmic.db"
  local written, write_trouble =
    writer.write_result(handle, database_path, result)
  if not written then
    return closing(handle, write_trouble)
  end
  -- The running tool's own `writer.carried`, which may not be the
  -- tree's: the projection it carries is signed by that writer, and a
  -- tool it wrote whose writer differs writes itself again on re-entry
  -- (`unsettled`).
  local carried_path = handle.root .. "/o/carried.db"
  local carried, carry_trouble = writer.carried(database_path, carried_path)
  if not carried then
    return closing(handle, carry_trouble)
  end
  local database, read_trouble = Fs.read(carried_path)
  if database == nil then
    return closing(handle, read_trouble)
  end
  local closed, close_trouble = work.close(handle)
  if not closed then
    return close_trouble
  end
  local program, program_trouble = artifact.program(prefix, database)
  if program == nil then
    return program_trouble
  end
  local published, publish_trouble = Fs.write(out, program, 0x1ed)
  if not published then
    return publish_trouble
  end

  local environment = sys.environ()
  environment[marker] = settle and "2" or "1"
  local _, exec_trouble = Proc.exec(out, reentry(argv), environment)
  return exec_trouble
end

--- The lock a run holds from the moment it finds it must rebuild or
--- boot the tool until it re-enters the command on the tool it wrote,
--- or exits: two runs in one checkout that both find the tool stale --
--- an editor, a watcher and a terminal, say -- would otherwise rebuild
--- it at once: each writes o/cosmic.db and o/carried.db aside through
--- the same fixed `.building` name (`writer.write_result`,
--- `writer.carried`), which the other removes and writes into under it.
--- It is an SQLite write lock on an empty database,
--- `o/rebuild.lock`, which the system drops with the descriptor, so a
--- holder that dies or execs (SQLite opens it close-on-exec) never
--- leaves it held; a sandboxed test worker never takes it, since only
--- the tree's own tool (`reboot.own_tool`) rebuilds.
-- TODO: hold this with flock on o/rebuild.lock itself, once cosmic.sys
-- carries flock, rather than through an SQLite transaction nothing
-- writes.
-- TODO: have a boot run by hand (`bin/zig build boot`, build/zig.tl)
-- take this lock too, so a run rebuilding the tool and a boot in the
-- same checkout wait for one another; a boot this module starts
-- (`reboot.boot_into`) would be handed the lock its parent holds, as
-- an environment variable naming it, rather than wait for it.
local lock_name = "/o/rebuild.lock"

--- Where the holder writes its process id, for a waiting run to name it.
local holder_name = "/o/rebuild.lock.pid"

--- Where a holder sets aside the database of the tool under o/ to read
--- it (`replaced`).
local probe_name = "/o/rebuild.lock.probe"

--- How long a run waits for another's rebuild or boot before it refuses:
--- a cold boot on a loaded host takes minutes, not half an hour.
local lock_wait_ms <const> = 30 * 60 * 1000

--- The lock this process holds, kept here so it lives as long as the
--- process does, or until the exec that replaces it.
local held: Sqlite.Handle | nil = nil

--- The run holding the lock under `root`, as a waiting run names it,
--- read once this run has failed to take it. The file may still name
--- the run before, which a new holder has not yet written over: a pid
--- no process answers to, or this one's own (a holder that re-entered
--- this process), is left unnamed. One a holder in another pid
--- namespace wrote -- a container sharing the checkout -- names what
--- that namespace called it, not a process here.
local function holder(root: string): string
  local text, _ = Fs.read(root .. holder_name)
  local pid: integer | nil = nil
  if text ~= nil then
    pid = math.tointeger(tonumber(text:match("^(%d+)\n$")))
  end
  if pid ~= nil and pid ~= sys.getpid() then
    local alive, _ = sys.kill(pid, 0)
    if alive then
      return "another cosmic run (pid " .. tostring(pid) .. ")"
    end
  end
  return "another cosmic run"
end

--- The meta a tool's database carries that tells one written apart
--- from another.
local identity_keys <const> = { "projected", "written_by", "compiled_by",
  "boot_hash" }

--- Whether the program at `out` is no longer the one this process runs:
--- another run rebuilt the tool, and exec'd, between this run's start
--- and its taking the rebuild lock. Read from the database `out` carries,
--- set aside under o/ while this run holds the lock; anything that
--- cannot be read answers false, and this run rebuilds as it would have.
local function replaced(root: string, out: string): boolean
  local bytes, _ = Fs.read(out)
  if bytes == nil then
    return false
  end
  local parts, _ = artifact.split(bytes)
  if parts == nil then
    return false
  end
  local probe = root .. probe_name
  local written, _ = Fs.write(probe, parts.database)
  if not written then
    return false
  end
  local db, _ = Sqlite.open(probe)
  if db == nil then
    local _, _ = Fs.remove(probe)
    return false
  end
  local rows, _ = Sqlite.text_rows(db, "SELECT key, value FROM meta")
  local _, _ = db:close()
  local _, _ = Fs.remove(probe)
  if rows == nil then
    return false
  end
  local carried: {string:string} = {}
  for _, row in ipairs(rows) do
    carried[row[1]] = row[2]
  end
  -- The running tool's own, not a database a verb attached before
  -- `stale_exit` ran (o/cosmic.db, whose meta Store.meta finds first).
  local own: {string:string} = {}
  Store.alone(function()
    for _, key in ipairs(identity_keys) do
      own[key] = Store.meta(key)
    end
  end)
  for _, key in ipairs(identity_keys) do
    if carried[key] ~= own[key] then
      return true
    end
  end
  return false
end

--- What `take` found of the rebuild lock: this process holds it, or
--- another held it past the wait.
local enum Taken
  "held"
  "busy"
end

--- Takes the rebuild lock of `root`, waiting up to `wait_ms` for a run
--- that holds it. Answers "held" once this process holds it, "busy"
--- when SQLite could not begin the lock's transaction in that time --
--- another run holding it, since the file opened -- or nil and why when
--- the lock's file cannot be opened at all.
local function take(root: string, wait_ms: integer): Taken | nil, string
  if held ~= nil then
    return "held", ""
  end
  local db, open_trouble = Sqlite.open(root .. lock_name, true)
  if db == nil then
    return nil, root .. lock_name .. ": " .. open_trouble
  end
  local timed, time_trouble = db:exec("PRAGMA busy_timeout = " ..
    tostring(wait_ms))
  if not timed then
    local _, _ = db:close()
    return nil, root .. lock_name .. ": " .. time_trouble
  end
  local begun, _ = db:exec("BEGIN IMMEDIATE")
  if not begun then
    local _, _ = db:close()
    return "busy", ""
  end
  held = db
  local _, _ = Fs.write(root .. holder_name, tostring(sys.getpid()) .. "\n")
  return "held", ""
end

--- Lets go of the rebuild lock this process holds, if it holds it.
local function release()
  local lock = held
  held = nil
  if lock ~= nil then
    local _, _ = lock:close()
  end
end

--- Closes `handle` and replaces this process with the tool at `out`,
--- running `argv` again in this process's environment, its `marker`
--- as it was. Answers the exit code when it cannot.
local function reenter(handle: work.Handle, out: string,
                       argv: {integer:string}): integer
  local closed, close_trouble = work.close(handle)
  if not closed then
    log:complain(close_trouble)
    return 1
  end
  local _, exec_trouble = Proc.exec(out, reentry(argv), sys.environ())
  log:complain(exec_trouble)
  return 3
end

--- Before a run rebuilds or boots the tool, takes the rebuild lock, so
--- that only one run in a checkout does so at a time. Answers nil, the
--- lock held and `handle` still open, when this run is to go on and
--- rebuild. When another run holds the lock, this one closes `handle`
--- -- the holder needs the working database to finish -- says so,
--- waits for the holder to re-enter or exit, and replaces itself with
--- the tool now under o/, running `argv` again: it is fresh when the
--- holder's rebuild landed, and when it did not, that run takes the
--- lock and rebuilds itself. A run that takes the lock at once but
--- finds the tool under o/ is no longer the one it runs (`replaced`)
--- re-enters that tool too, rather than rebuild from an older one. A
--- re-entered run keeps `marker` as it was: a run a reboot entered that
--- waits on a rebuild that failed refuses rather than rebuild, so no
--- runs rebuild one after another for good. The caller makes the
--- `marker` refusal (`refusal`) before it comes here, so a run that
--- would refuse never waits.
--- Otherwise it has said why, closed `handle`, and answers the exit
--- code to return.
local function serialize(handle: work.Handle, root: string,
                         argv: {integer:string}): integer | nil
  -- Tried at once, while this run holds the working database: a run
  -- holding the lock may be waiting for that database, so this run
  -- waits for the lock only once it has closed it.
  local taken, trouble = take(root, 0)
  if taken == nil then
    log:complain(closing(handle, trouble))
    return 1
  end
  local out, executable_trouble = Proc.executable()
  if out == nil then
    log:complain(closing(handle, executable_trouble))
    return 1
  end
  if taken == "held" then
    if not replaced(root, out) then
      return nil
    end
    -- Another run's rebuild landed before this one took the lock: enter
    -- it rather than rebuild again from this older tool.
    release()
    log:complain("another cosmic run in this checkout rebuilt the tool; entering it")
    return reenter(handle, out, argv)
  end
  local closed, close_trouble = work.close(handle)
  if not closed then
    log:complain(close_trouble)
    return 1
  end
  local other = holder(root)
  log:complain(other .. " in this checkout is rebuilding the tool; waiting for it")
  local waited, wait_trouble = take(root, lock_wait_ms)
  if waited == nil then
    log:complain(wait_trouble)
    return 1
  end
  if waited == "busy" then
    log:complain(other .. " held the tool's rebuild lock past " ..
      tostring(lock_wait_ms // 60000) .. " minutes; stop it, or wait " ..
      "for it, and run this again")
    return 3
  end
  -- Released at once: the run entered below takes it again if it must.
  release()
  local _, exec_trouble = Proc.exec(out, reentry(argv), sys.environ())
  log:complain(exec_trouble)
  return 3
end

--- Rebuilds the core with `root/bin/zig build boot`, whose output goes to
--- stderr so a verb's own stdout stays its own, then replaces this process
--- with the tool the boot wrote, `root/o/bin/cosmic`, running `argv` again.
--- It is handed no handle: the caller closes its working database
--- first, since the boot writes it (`reboot.guard` does).
--- `environment` is what both run in, this process's by default.
--- Returns only when it cannot, saying why.
function reboot.boot_into(root: string, argv: {integer:string},
                          environment?: {string:string}): string
  environment = environment or sys.environ()
  if environment[marker] ~= nil then
    return "the tool is still stale after a reboot"
  end
  log:complain("the core is stale; running bin/zig build boot")
  local result, trouble = Child.run({ root .. "/bin/zig", "build", "boot" },
    { cwd = root, env = environment, stdout = 2 })
  if result == nil then
    return "bin/zig build boot: " .. trouble
  end
  if not result.ok then
    return "bin/zig build boot failed; fix what it reports and run this again"
  end
  environment[marker] = "1"
  local _, exec_trouble = Proc.exec(root .. "/o/bin/cosmic", reentry(argv),
    environment)
  return exec_trouble
end

--- The staleness guard every verb that builds the tree applies once
--- it has staged it, before it compiles anything: `cosmic <file.tl>`,
--- `cosmic test`, and through `reboot.stale_exit` the read-only verbs.
--- A stale tool would check and compile the tree with a checker the
--- tree no longer agrees with, and run embedded `cosmic.*` and `build.*`
--- code from an old tree. When only Teal moved, the tool rebuilds itself
--- and re-enters `argv`; when the C core moved, it has zig boot it,
--- unless `COSMIC_AUTO_BOOT=0` says to refuse. Only the tree's own tool
--- (`reboot.own_tool`) does either; another refuses with
--- `foreign_refusal`, rebuilding nothing. A fresh tool of the tree's
--- own whose database another writer wrote (`unsettled`) writes itself
--- again, as a rebuild does, and re-enters `argv`; so does one a
--- rebuild just wrote that is stale by its own code, which a rebuild
--- across a change to the fingerprint itself leaves. Each takes the
--- rebuild lock first (`serialize`): a run that finds another rebuilding
--- waits for it and re-enters `argv` on the tool it wrote.
---
--- `handle` is the working database of `root`, which must be cosmic's
--- own tree (`tree.is_own`), open and staged. Answers nil when the tool
--- is fresh, handing `handle` back open for the caller to go on with.
--- Otherwise it has said why on stderr and closed `handle`, and answers
--- the exit code the caller returns at once: 3 for a refusal, or a
--- rebuild or boot that failed, and 1 when the check itself failed.
--- @param argv the command line, re-entered after a rebuild
function reboot.guard(handle: work.Handle, root: string,
                      argv: {integer:string}): integer | nil
  local state, state_trouble = state_of(handle)
  if state == nil then
    log:complain(closing(handle, state_trouble))
    return 1
  end
  if state == "fresh" and not unsettled() then
    return nil
  end
  local own, own_tool_trouble = reboot.own_tool(root)
  if own == nil then
    log:complain(closing(handle, own_tool_trouble))
    return 1
  end
  if state == "fresh" then
    if not own then
      return nil
    end
    local refused = refusal(true)
    if refused ~= nil then
      log:complain(closing(handle, refused))
      return 3
    end
    local waited = serialize(handle, root, argv)
    if waited ~= nil then
      return waited
    end
    log:complain("the tool's database was built by other code than its own; building it again")
    log:complain(into(handle, teal.lazy(), argv, true))
    return 3
  end
  if not own then
    log:complain(closing(handle, foreign_refusal))
    return 3
  end
  if state == "core" then
    if not reboot.auto_boot() then
      log:complain(closing(handle, core_refusal))
      return 3
    end
    if sys.getenv(marker) ~= nil then
      log:complain(closing(handle, "the tool is still stale after a reboot"))
      return 3
    end
    local waited = serialize(handle, root, argv)
    if waited ~= nil then
      return waited
    end
    local closed, close_trouble = work.close(handle)
    if not closed then
      log:complain(close_trouble)
      return 1
    end
    log:complain(reboot.boot_into(root, argv))
    return 3
  end
  -- state == "teal"
  -- A rebuild records the tree's fingerprint by the rebuilding tool's
  -- own build.work, so when the tree moved what that fingerprint covers
  -- (`is_tool`, `record_fingerprint`) the tool it wrote is stale by its
  -- own code. build.work is in the writer's closure, so that tool is
  -- `unsettled` too: it builds itself again, once, as a fresh unsettled
  -- tool does, rather than refusing; `into` sets the marker to "2", so
  -- a tool stale after that refuses.
  local settle = sys.getenv(marker) == "1" and unsettled()
  local refused = refusal(settle)
  if refused ~= nil then
    log:complain(closing(handle, refused))
    return 3
  end
  local waited = serialize(handle, root, argv)
  if waited ~= nil then
    return waited
  end
  if settle then
    log:complain("the tool's database was built by other code than its own; building it again")
    log:complain(into(handle, teal.lazy(), argv, true))
    return 3
  end
  log:complain("the tool is stale; rebuilding it from the tree")
  log:complain(into(handle, teal.lazy(), argv, false))
  return 3
end

--- The staleness guard for a read-only verb -- `docs`, `uses`, `db`,
--- `help` -- that never compiles the tree itself but still runs
--- `build.*` Teal that this binary embedded at its own boot. Inside
--- cosmic's own tree, an edit to that Teal is otherwise invisible
--- until `bin/zig build boot`, where `AGENTS.md` (step 3) promises an
--- edit to Teal rebuilds on its own.
---
--- The fresh case -- overwhelmingly the common one for a read-only
--- verb run again and again while nothing changed -- never walks the
--- tree: `work.tool_moved` stats only the paths the last stage
--- already recorded under `tool`, and a file new to the tree does not
--- register there until something already known requires it, which
--- edits that known file and so moves its own stat; a row whose file
--- is gone fails its stat, counted as moved rather than told apart
--- from an edit. When nothing moved, the `boot_hash` that same last
--- stage recorded into `meta` (`work.recorded_boot_hash`) still
--- describes `tool` exactly, so it is read back rather than
--- recomputed. Only when something did move, or the database has no
--- recorded `boot_hash` yet (a fresh `o/`, or one nothing has staged
--- for), does this fall back to `work.stage`'s directory walk and
--- `reboot.guard` -- the same path `cosmic test` always takes.
---
--- Answers as `reboot.guard` does for the tree in the working
--- directory: nil to go on, when the tree is not cosmic's own or the
--- tool is fresh, or an exit code to return at once, having said why.
--- @param argv the command line, re-entered after a rebuild
function reboot.stale_exit(argv: {integer:string}): integer | nil
  local root, root_trouble = Fs.absolute(".")
  if root == nil then
    log:complain(root_trouble)
    return 1
  end
  local own_tree, own_trouble = tree.is_own(root)
  if own_tree == nil then
    log:complain(own_trouble)
    return 1
  end
  if not own_tree then
    return nil
  end
  local handle, open_trouble = work.open(root)
  if handle == nil then
    log:complain(open_trouble)
    return 1
  end

  local moved, moved_trouble = work.tool_moved(handle)
  if moved == nil then
    log:complain(closing(handle, moved_trouble))
    return 1
  end
  local fresh = false
  if not moved then
    local recorded, recorded_trouble = work.recorded_boot_hash(handle)
    if recorded == nil and recorded_trouble ~= "" then
      log:complain(closing(handle, recorded_trouble))
      return 1
    end
    fresh = recorded ~= nil and recorded == (Store.meta("boot_hash") or "")
    -- A tool that is not the tree's own never settles (`reboot.guard`),
    -- so only the tree's own is sent there to.
    if fresh and unsettled() then
      local own, _ = reboot.own_tool(root)
      fresh = own == false
    end
  end
  if not fresh then
    local staged, stage_trouble = work.stage(handle, own_tree)
    if staged == nil then
      log:complain(closing(handle, stage_trouble))
      return 1
    end
    local code = reboot.guard(handle, root, argv)
    if code ~= nil then
      return code
    end
  end
  local closed, close_trouble = work.close(handle)
  if not closed then
    log:complain(close_trouble)
    return 1
  end
  return nil
end

return reboot

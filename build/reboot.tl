--- A stale tool, rebuilt from the tree it is stale against and re-entered.
---
--- Cosmic builds itself, so the tool is also an artifact of the tree. When
--- only Teal differs, the tool projects a new database, combines it with
--- the exact retained portable prefix, atomically replaces the same
--- logical artifact, and re-enters the original argv once. When the
--- rebuilt tool's writer is not the code that wrote its database, that
--- tool writes the database again itself and re-enters once more, so a
--- rebuild lands on the bytes a boot writes. When a core input differs,
--- only zig can rebuild it: the tool runs `bin/zig build boot` and
--- re-enters the original argv on the tool that boot wrote, unless
--- `COSMIC_AUTO_BOOT=0` says to refuse instead ([`reboot.auto_boot`]).
--- A Teal rebuild whose compile fails after the compiler's own modules
--- moved is taken for a core change too: the stale tool's compiler cannot
--- be trusted to compile what the tree's now means
--- ([`reboot.rebuild_failed`]).
---
--- One rule for the working database's handle: a function here that is
--- handed it and stops the command -- `into` on every path,
--- [`reboot.guard`] whenever it answers an exit code -- closes it first;
--- only [`reboot.guard`]'s nil, "go on", hands it back open. A function
--- handed none, [`reboot.boot_into`], needs it closed already.

local build_paths = require("build.paths")
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Proc = require("cosmic.proc")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local sys = require("cosmic.sys")
local identity = require("build.identity")
local artifact = require("build.artifact")
local derivation = require("build.derivation")
local importer = require("build.importer")
local rebuild_lock = require("build.rebuild_lock")
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
--- code other than the compiler and writer it carries
--- ([`identity.Identities`]). A rebuild uses the stale tool's compiler and
--- writer, so the rebuilt tool compiles and writes its database once
--- more itself; then it matches what a boot writes. A database that
--- records neither identity is unsettled too.
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
--- a tool rebuilds itself when stale. A rebuild writes the tree's tool
--- over the path it was started as, so any other cosmic run here (a
--- release, the bootstrap cache's, one on PATH) would be overwritten.
--- The path is judged where it names: its directory is resolved but not
--- its name. A file renamed or removed while it runs is still judged by
--- where it was, and a link into o/ from elsewhere is elsewhere, since
--- a rebuild would replace the link, not o/'s tool. `executable` is the
--- path this process was started as, by default.
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
  local outputs, outputs_trouble = Fs.absolute(build_paths.required(root))
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

--- `argv` from slot 1 on, led by `program`, the path to exec, as the
--- list [`Proc.exec`] takes.
local function reentry(program: string, argv: {integer:string}): {string}
  local arguments: {string} = { program }
  local at = 1
  while argv[at] ~= nil do
    arguments[#arguments + 1] = argv[at]
    at = at + 1
  end
  return arguments
end

--- Compares the tree's fingerprints with the running binary's.
local function state_of(handle: work.Handle): reboot.State | nil, string
  local fingerprint, trouble = identity.record_fingerprint(handle.db)
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

--- Whether the running binary carries the tree's code: every module of
--- the tree in `handle`, open and staged, that a tool carries (its
--- modules and its main, not its tests, examples or declarations) is
--- one the binary carries, with the same source, and so is the Teal
--- compiler the tree holds (`vendor.tl`, origin 'vendor'). A tool that a
--- stale tool rebuilt from this tree does, though it may still be stale
--- by its own code, its fingerprint having been taken by the older
--- definition the stale tool ran. What it computes of the tree (the
--- fingerprint, the compiler's and the writer's identities) is then what
--- the tree's own code computes, and what a tool it writes carries.
--- False when any module is missing or differs, or the tree cannot be
--- read.
function reboot.carries_tree_code(handle: work.Handle): boolean
  local rows, _ = Sqlite.text_rows(handle.db,
    "SELECT path, source_hash FROM inputs WHERE (origin = 'tree' " ..
      "AND kind IN ('module', 'main')) OR origin = 'vendor' ORDER BY path")
  if rows == nil or #rows == 0 then
    return false
  end
  for _, row in ipairs(rows) do
    local source, _ = Store.source(row[1])
    if source == nil or Hash.hex_sha256(source) ~= row[2] then
      return false
    end
  end
  return true
end

--- Whether the compiler of the tree, whose identity is `wanted`
--- ([`identity.compiler_identity`]), is not the one the running tool
--- carries (`tool`). An identity that could not be taken (nil) is no
--- evidence of a move, on either side: a tool the guard rebuilds is one
--- this tree built and always records its compiler's, so a nil there is
--- a damaged database, whose failure is reported as the tree's own
--- rather than answered with a boot that would mend nothing.
function reboot.compiler_moved(tool: string | nil, wanted: string | nil): boolean
  return tool ~= nil and wanted ~= nil and tool ~= wanted
end

--- Rebuilds the tool from the tree and replaces this process with it,
--- running `argv` again. Returns only when it cannot, saying why, and
--- whether the failure was a compile that failed while the tree's
--- compiler differs from this tool's ([`reboot.compiler_moved`]), which
--- only a boot can mend ([`reboot.rebuild_failed`]). A `settle` is never
--- that: a boot it would start is refused by the `marker` it runs under,
--- and the rebuild it follows made the compiler this tool's. It takes `handle`, open and staged, and closes
--- it on every path: before it publishes the rebuilt tool, or on the way
--- out of a failure. `settle` rebuilds a fresh but `unsettled` tool,
--- which a rebuild may enter; anything else refuses once a reboot has
--- entered this process.
local function into(handle: work.Handle, built: compiler,
                    argv: {integer:string}, settle: boolean): string, boolean
  local refused = refusal(settle)
  if refused ~= nil then
    return closing(handle, refused), false
  end
  local prefix, prefix_trouble = artifact.trusted_prefix()
  if prefix == nil then
    return closing(handle, prefix_trouble), false
  end
  local out, executable_trouble = Proc.executable()
  if out == nil then
    return closing(handle, executable_trouble), false
  end

  -- A fresh checkout has no boot-populated compiler row in its working
  -- database yet. Preserve the exact compiler carried by the trusted running
  -- artifact so the rebuilt Cosmic remains able to rebuild again.
  local compiler_source, compiler_trouble = Store.source("vendor.tl")
  if compiler_source == nil then
    return closing(handle, "the compiler source is not in this binary: " .. compiler_trouble), false
  end
  local kept, keep_trouble = derivation.put_compiler(handle.db, compiler_source)
  if not kept then
    return closing(handle, keep_trouble), false
  end
  -- And the zones it carries, which only a boot reads from the tree.
  local databases = Store.databases()
  local zones, zones_trouble = work.zoneinfo_of(databases[#databases])
  if zones == nil then
    return closing(handle, "the zones in this binary: " .. zones_trouble), false
  end
  local zoned, zoned_trouble = work.put_zoneinfo(handle, zones)
  if not zoned then
    return closing(handle, zoned_trouble), false
  end

  -- Compiled by this tool's compiler and keyed by its identity, which is
  -- the tree's only when the compiler has not moved: a row this compiler
  -- made is never taken for the tree's compiler's. The tool that replaces
  -- this one carries the tree's identities, and compiles again itself
  -- whatever this compiler compiled (`unsettled`).
  -- A tool settling that carries the tree's code ([`carries_tree_code`])
  -- keys by the compiler identity its own [`identity.compiler_identity`]
  -- computes, which is what the tool it writes carries. The identity it
  -- carries was taken by the tool that wrote it, by that tool's code;
  -- where the two define the identity apart, keying by the carried one
  -- would leave the tool written here as unsettled as this one. A tool
  -- carries the tree's code when its recorded fingerprint is the tree's
  -- by its own code, and also when a stale tool rebuilt it across a
  -- change to the fingerprint's definition: it is stale by its own code,
  -- and settles on the "teal" path.
  local tree_code = false
  local tree_compiler: string | nil
  -- Unjudged: this tool's build.contracts, rules and exemptions alike,
  -- may be older than the tree's, so a module it refuses is built
  -- anyway, and the tool built here judges it again, by the tree's own,
  -- when it re-enters the command.
  local result, compile_trouble = importer.compile_tree(handle, built,
    function(recorded: identity.Identities): string, string
      tree_compiler = recorded.compiler
      local tool = Store.meta("compiler") or ""
      if settle then
        local boot_hash, _ = identity.recorded_boot_hash(handle.db)
        tree_code = (boot_hash ~= nil and boot_hash == Store.meta("boot_hash")) or
          reboot.carries_tree_code(handle)
        if tree_code then tool = recorded.compiler end
      end
      return tool, ""
    end, true, shared_compiles.for_build())
  if result == nil then
    -- The compiler of a tool settling is the tree's: it cannot have moved.
    if settle then
      return closing(handle, compile_trouble), false
    end
    -- The compile may have stopped before it recorded the tree's
    -- identities: take the compiler's from what is staged and parsed.
    -- That walk of `requires` may be partial; a truncated one differs
    -- from the tool's, so it errs toward a boot, never toward a miss.
    if tree_compiler == nil then
      local found, _ = identity.compiler_identity(handle.db)
      tree_compiler = found
    end
    return closing(handle, compile_trouble),
      reboot.compiler_moved(Store.meta("compiler"), tree_compiler)
  end
  local database_path = build_paths.required(handle.root) .. "/cosmic.db"
  local written, write_trouble =
    writer.write_result(handle, database_path, result, tree_code)
  if not written then
    return closing(handle, write_trouble), false
  end
  -- The running tool's own [`writer.carried`], which may not be the
  -- tree's: the projection it carries is signed by that writer, and a
  -- tool it wrote whose writer differs writes itself again on re-entry
  -- (`unsettled`).
  local carried_path = build_paths.required(handle.root) .. "/carried.db"
  local carried, carry_trouble = writer.carried(database_path, carried_path)
  if not carried then
    return closing(handle, carry_trouble), false
  end
  local database, read_trouble = Fs.read(carried_path)
  if database == nil then
    return closing(handle, read_trouble), false
  end
  local closed, close_trouble = work.close(handle)
  if not closed then
    return close_trouble, false
  end
  local program, program_trouble = artifact.program(prefix, database)
  if program == nil then
    return program_trouble, false
  end
  local published, publish_trouble = Fs.write(out, program, 0x1ed)
  if not published then
    return publish_trouble, false
  end

  local environment = sys.environ()
  environment[marker] = settle and "2" or "1"
  local _, exec_trouble = Proc.exec(reentry(out, argv), { env = environment })
  return exec_trouble, false
end

-- The rebuild lock ([`build.rebuild_lock`]) is held by a run from the
-- moment it finds it must rebuild or boot the tool until it re-enters
-- the command on the tool it wrote, or exits. A `cosmic test` run holds
-- it already, from its start, and a sandboxed test worker never takes
-- it, since only the tree's own tool ([`reboot.own_tool`]) rebuilds. A run
-- waits for its holder as long as it takes, as [`rebuild_lock.hold`]
-- does: that may be a whole `cosmic test` run, and a holder that dies
-- lets it go.

--- Where the holder of the rebuild lock sets aside the database of the
--- tool under o/ to read it (`replaced`).
local probe_name = "/rebuild.lock.probe"

--- The meta a tool's database carries that tells one written apart
--- from another: a rebuild moves `boot_hash` (the tree's, which is why it
--- rebuilt), and settling it moves `written_by` or `compiled_by`. The
--- projection's `projected` is no part of it, since a tool does not carry
--- it ([`build.writer`]'s `carried`).
local identity_keys <const> = { "written_by", "compiled_by", "boot_hash" }

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
  local probe = build_paths.required(root) .. probe_name
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
  -- [`stale_exit`] ran (o/cosmic.db, whose meta Store.meta finds first).
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
  local _, exec_trouble = Proc.exec(reentry(out, argv), { env = sys.environ() })
  log:complain(exec_trouble)
  return 3
end

--- Before a run rebuilds or boots the tool, takes the rebuild lock, so
--- that only one run in a checkout does so at a time. Answers nil, the
--- lock held and `handle` still open, when this run is to go on and
--- rebuild. Otherwise it has said why, closed `handle`, and answers the
--- exit code to return.
---
--- When another run holds the lock, this one closes `handle` (the holder
--- needs the working database to finish), says so, waits for the holder
--- to re-enter or exit, and replaces itself with the tool now under o/,
--- running `argv` again. That tool is fresh when the holder's rebuild
--- landed; when it did not, the re-entered run takes the lock and
--- rebuilds itself. A run that takes the lock at once but finds the tool
--- under o/ is no longer the one it runs (`replaced`) re-enters that
--- tool too, rather than rebuild from an older one.
---
--- A re-entered run keeps `marker` as it was: a run a reboot entered
--- that waits on a rebuild that failed refuses rather than rebuild, so
--- runs never rebuild one after another for good. The caller makes the
--- `marker` refusal (`refusal`) before it comes here, so a run that
--- would refuse never waits.
local function serialize(handle: work.Handle, root: string,
                         argv: {integer:string}): integer | nil
  -- Tried at once, while this run holds the working database: a run
  -- holding the lock may be waiting for that database, so this run
  -- waits for the lock only once it has closed it.
  local taken, trouble = rebuild_lock.take(root, 0, "rebuild")
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
    rebuild_lock.release()
    log:complain("another cosmic run in this checkout rebuilt the tool; entering it")
    return reenter(handle, out, argv)
  end
  local closed, close_trouble = work.close(handle)
  if not closed then
    log:complain(close_trouble)
    return 1
  end
  local waited, wait_trouble = rebuild_lock.wait(root, "rebuild",
    rebuild_lock.holder(root) .. "; waiting for it" .. rebuild_lock.suffix(root))
  if not waited then
    log:complain(wait_trouble)
    return 1
  end
  -- Released at once: the run entered below takes it again if it must.
  rebuild_lock.release()
  local _, exec_trouble = Proc.exec(reentry(out, argv), { env = sys.environ() })
  log:complain(exec_trouble)
  return 3
end

--- Rebuilds the core with `root/bin/zig build boot`, whose output goes to
--- stderr so a verb's own stdout stays its own, then replaces this process
--- with the tool the boot wrote, `root/o/bin/cosmic`, running `argv` again.
--- It is handed no handle: the caller closes its working database
--- first, since the boot writes it ([`reboot.guard`] does).
--- `environment` is what both run in, this process's by default.
--- Returns only when it cannot, saying why.
function reboot.boot_into(root: string, argv: {integer:string},
                          environment?: {string:string}): string
  environment = environment or sys.environ()
  if environment[marker] ~= nil then
    return "the tool is still stale after a reboot"
  end
  log:complain("the core is stale; running bin/zig build boot")
  -- The boot takes the rebuild lock (build/zig.tl), which a guard
  -- calling this holds: handed on, rather than waited for.
  local boot_environment = environment
  if rebuild_lock.holds(root) then
    boot_environment = rebuild_lock.hand(environment, root)
  end
  local result, trouble = Child.run({ root .. "/bin/zig", "build", "boot" },
    { cwd = root, env = boot_environment, stdout = 2 })
  if result == nil then
    return "bin/zig build boot: " .. trouble
  end
  if not result.ok then
    return "bin/zig build boot failed; fix what it reports and run this again"
  end
  environment[marker] = "1"
  local _, exec_trouble = Proc.exec(reentry(build_paths.required(root) .. "/bin/cosmic", argv),
    { env = environment })
  return exec_trouble
end

--- What a Teal rebuild does once it has failed with `trouble`; `moved`
--- is whether the failure was a compile that failed while the tree's
--- compiler differs from the tool's ([`reboot.compiler_moved`], the
--- second answer of `into`). Answers the exit code, having said why.
---
--- A failure while the compiler has not moved is the tree's own error,
--- and is said as it is. When it has, the tool's checker may simply not
--- understand what the tree's compiler modules now do (a stale tool's
--- answer for a call it has no rule for is `T (unresolved generic)`),
--- so no rebuild by it can finish and a boot is what mends it: the path
--- a core change takes, unless `COSMIC_AUTO_BOOT=0` says to refuse
--- ([`reboot.auto_boot`]). Only a failure boots, not every edit to a
--- compiler module, most of which change nothing a compile stores.
--- The caller has closed its working database ([`reboot.boot_into`]).
--- `environment` is what the boot runs in, this process's by default.
--- A boot that starts re-enters `argv` and does not return here.
function reboot.rebuild_failed(root: string, argv: {integer:string},
                               trouble: string, moved: boolean,
                               environment?: {string:string}): integer
  if not moved then
    log:complain(trouble)
    return 3
  end
  if not reboot.auto_boot(environment) then
    log:complain(trouble)
    log:complain(core_refusal)
    return 3
  end
  log:complain("the tool cannot compile the tree and its compiler has moved; " ..
      "booting it instead of rebuilding")
  local booted = reboot.boot_into(root, argv, environment)
  -- Only a boot that failed returns: the compile failure it was to mend
  -- is then the first thing the person needs.
  log:complain(trouble)
  log:complain(booted)
  return 3
end

--- The staleness guard every verb that builds the tree applies once
--- it has staged it, before it compiles anything: `cosmic <file.tl>`,
--- `cosmic test`, and through [`reboot.stale_exit`] the read-only verbs.
--- A stale tool would check and compile the tree with a checker the
--- tree no longer agrees with, and run embedded `cosmic.*` and `build.*`
--- code from an old tree. When only Teal moved, the tool rebuilds itself
--- and re-enters `argv`; when the C core moved, it has zig boot it,
--- unless `COSMIC_AUTO_BOOT=0` says to refuse; so does a rebuild whose
--- compile fails once the compiler's modules moved
--- ([`reboot.rebuild_failed`]). Only the tree's own tool
--- ([`reboot.own_tool`]) does either; another refuses with
--- `foreign_refusal`, rebuilding nothing. A fresh tool of the tree's
--- own whose database another writer wrote (`unsettled`) writes itself
--- again, as a rebuild does, and re-enters `argv`; so does one a
--- rebuild just wrote that is stale by its own code, which a rebuild
--- across a change to the fingerprint itself leaves. Each takes the
--- rebuild lock first (`serialize`): a run that finds another rebuilding
--- waits for it and re-enters `argv` on the tool it wrote.
---
--- `handle` is the working database of `root`, which must be cosmic's
--- own tree ([`tree.is_own`]), open and staged. Answers nil when the tool
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
    local trouble, _ = into(handle, teal.lazy(), argv, true)
    log:complain(trouble)
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
  -- own build.identity, so when the tree moved what that fingerprint covers
  -- (`is_tool`, `record_fingerprint`) the tool it wrote is stale by its
  -- own code. build.identity is in the writer's identity (`writer_roots`),
  -- so that tool is `unsettled` too: it builds itself again, once, as a
  -- fresh unsettled tool does, keyed and signed by what its own code,
  -- which is the tree's ([`carries_tree_code`]), takes of the tree, rather
  -- than refusing; `into` sets the marker to "2", so a tool stale after
  -- that refuses.
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
    local trouble, _ = into(handle, teal.lazy(), argv, true)
    log:complain(trouble)
    return 3
  end
  log:complain("the tool is stale; rebuilding it from the tree")
  local trouble, moved = into(handle, teal.lazy(), argv, false)
  return reboot.rebuild_failed(root, argv, trouble, moved)
end

--- The staleness guard for a read-only verb -- `docs`, `uses`, `db`,
--- `help` -- that never compiles the tree itself but still runs
--- `build.*` Teal that this binary embedded at its own boot. Inside
--- cosmic's own tree, an edit to that Teal is otherwise invisible
--- until `bin/zig build boot`, where `AGENTS.md` (step 3) promises an
--- edit to Teal rebuilds on its own.
---
--- The fresh case -- overwhelmingly the common one for a read-only
--- verb run again and again while nothing changed -- stats the tool's
--- recorded files and discovery directories ([`work.tool_moved`]). A
--- membership change takes the same full stage as an edit to a known file.
--- When neither moved, the `boot_hash` that same last stage recorded into
--- `meta` ([`identity.recorded_boot_hash`]) still describes `tool` exactly,
--- so it is read back rather than recomputed. Only when something moved,
--- or the database has no
--- recorded `boot_hash` yet (a fresh `o/`, or one nothing has staged
--- for), does this fall back to [`work.stage`]'s directory walk and
--- [`reboot.guard`] -- the same path `cosmic test` always takes.
---
--- Answers as [`reboot.guard`] does for the tree in the working
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
    local recorded, recorded_trouble = identity.recorded_boot_hash(handle.db)
    if recorded == nil and recorded_trouble ~= "" then
      log:complain(closing(handle, recorded_trouble))
      return 1
    end
    fresh = recorded ~= nil and recorded == (Store.meta("boot_hash") or "")
    -- A tool that is not the tree's own never settles ([`reboot.guard`]),
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

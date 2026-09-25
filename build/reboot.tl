--- A stale tool, rebuilt from the tree it is stale against and re-entered.
---
--- Cosmic builds itself, so the tool is also an artifact of the tree. When
--- only Teal differs, it projects a new database, combines it with the exact
--- retained portable prefix, atomically replaces the same logical artifact,
--- and re-enters the original argv once. When a core input differs, only zig
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
local Store = require("cosmic.store")
local sys = require("cosmic.sys")
local artifact = require("build.artifact")
local importer = require("build.importer")
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
--- still stale after one refuses rather than rebooting again.
local marker = "COSMIC_REBOOTED"

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
  local fingerprint, trouble = work.put_fingerprint(handle)
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

--- Rebuilds the tool from the tree and replaces this process with it,
--- running `argv` again. Returns only when it cannot, saying why. It
--- takes `handle`, open and staged, and closes it on every path: before
--- it publishes the rebuilt tool, or on the way out of a failure.
local function into(handle: work.Handle, built: compiler,
                     argv: {integer:string}): string
  if sys.getenv(marker) ~= nil then
    return closing(handle, "the tool is still stale after a reboot")
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

  -- Compiled and keyed as the tree's own work: the tool that replaces this one
  -- carries the tree's compiler identity, never the stale tool's identity.
  local derived, derive_trouble = importer.derive(handle, true, built)
  if not derived then
    return closing(handle, derive_trouble)
  end
  local identities, identity_trouble = work.put_identities(handle)
  if identities == nil then
    return closing(handle, identity_trouble)
  end
  -- Unjudged: this tool's build.contracts, rules and exemptions alike,
  -- may be older than the tree's, so a module it refuses is built
  -- anyway, and the tool built here judges it again, by the tree's own,
  -- when it re-enters the command.
  local result, compile_trouble =
    importer.compile(handle, built, identities.compiler, true)
  if result == nil then
    return closing(handle, compile_trouble)
  end
  local database_path = handle.root .. "/o/cosmic.db"
  local written, write_trouble =
    writer.write_result(handle, database_path, result)
  if not written then
    return closing(handle, write_trouble)
  end
  local database, read_trouble = Fs.read(database_path)
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
  environment[marker] = "1"
  local _, exec_trouble = Proc.exec(out, reentry(argv), environment)
  return exec_trouble
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
  local _, _ = Fs.put(Fs.stderr, "cosmic: the core is stale; running bin/zig build boot\n")
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
--- `foreign_refusal`, rebuilding nothing.
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
  if state == "fresh" then
    return nil
  end
  local own, own_tool_trouble = reboot.own_tool(root)
  if own == nil then
    log:complain(closing(handle, own_tool_trouble))
    return 1
  end
  if not own then
    log:complain(closing(handle, foreign_refusal))
    return 3
  end
  if state == "core" then
    local closed, close_trouble = work.close(handle)
    if not closed then
      log:complain(close_trouble)
      return 1
    end
    if not reboot.auto_boot() then
      log:complain(core_refusal)
      return 3
    end
    log:complain(reboot.boot_into(root, argv))
    return 3
  end
  -- state == "teal"
  log:complain("the tool is stale; rebuilding it from the tree")
  log:complain(into(handle, teal.lazy(), argv))
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

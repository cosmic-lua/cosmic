--- A stale tool, rebuilt from the tree it is stale against and re-entered.
---
--- Cosmic builds itself, so the tool is also an artifact of the tree. When
--- only Teal differs, it projects a new database, combines it with the exact
--- retained portable prefix, atomically replaces the same logical artifact,
--- and re-enters the original argv once. When a core input differs, only zig
--- can rebuild it: the tool runs `bin/zig build boot` and re-enters the
--- original argv on the tool that boot wrote, unless `COSMIC_AUTO_BOOT=0`
--- says to refuse instead (`reboot.auto_boot`).

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
  core_refusal: string
  foreign_refusal: string
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
reboot.core_refusal = "the tool is stale; run bin/zig build boot"

--- What a stale cosmic that is not the tree's own tool says: it neither
--- rebuilds itself nor boots the tree.
reboot.foreign_refusal = "this cosmic is stale against the tree and is not " ..
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
function reboot.state(handle: work.Handle): reboot.State | nil, string
  local fingerprint, trouble = work.fingerprint(handle)
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

--- Rebuilds the tool from the tree and replaces this process with it,
--- running `argv` again. Returns only when it cannot, saying why.
function reboot.into(handle: work.Handle, built: compiler,
                     argv: {integer:string}): string
  if sys.getenv(marker) ~= nil then
    return "the tool is still stale after a reboot"
  end
  local prefix, prefix_trouble = artifact.trusted_prefix()
  if prefix == nil then
    return prefix_trouble
  end
  local out, executable_trouble = Proc.executable()
  if out == nil then
    return executable_trouble
  end

  -- A fresh checkout has no boot-populated compiler row in its working
  -- database yet. Preserve the exact compiler carried by the trusted running
  -- artifact so the rebuilt Cosmic remains able to rebuild again.
  local compiler_source, compiler_trouble = Store.source("vendor.tl")
  if compiler_source == nil then
    return "the compiler source is not in this binary: " .. compiler_trouble
  end
  local kept, keep_trouble = work.put_compiler(handle, compiler_source)
  if not kept then
    return keep_trouble
  end

  -- Compiled and keyed as the tree's own work: the tool that replaces this one
  -- carries the tree's compiler identity, never the stale tool's identity.
  local derived, derive_trouble = importer.derive(handle, true, built)
  if not derived then
    return derive_trouble
  end
  local identities, identity_trouble = work.identities(handle)
  if identities == nil then
    return identity_trouble
  end
  -- Unjudged: this tool's build.contracts, rules and exemptions alike,
  -- may be older than the tree's, so a module it refuses is built
  -- anyway, and the tool built here judges it again, by the tree's own,
  -- when it re-enters the command.
  local result, compile_trouble =
    importer.compile(handle, built, identities.compiler, true)
  if result == nil then
    return compile_trouble
  end
  local database_path = handle.root .. "/o/cosmic.db"
  local written, write_trouble =
    writer.write_result(handle, database_path, result)
  if not written then
    return write_trouble
  end
  local database, read_trouble = Fs.read(database_path)
  if database == nil then
    return read_trouble
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
--- The caller has closed its working database, which the boot writes.
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

--- The staleness guard `cosmic <file.tl>` and `cosmic test` apply
--- before compiling, for a read-only verb -- `docs`, `uses`, `db`,
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
--- `reboot.state`'s full check -- the same path `cosmic test` always
--- takes.
---
--- Returns an exit code the caller should return immediately, with
--- `trouble` to report first when it is not empty. Returns `nil` to
--- say the caller may proceed as normal: either the tree is not
--- cosmic's own, or the tool was found fresh, so no rebuild happened. A
--- stale tool that is not the tree's own (`reboot.own_tool`) returns 3
--- with `reboot.foreign_refusal`, rebuilding nothing.
--- @param argv the command line, re-entered after a rebuild
-- TODO: answer a record (an exit code and its message) or nil, once the
-- callers are reworked around it: nil means "proceed" here, not a
-- failure, so this pair is not a value and its reason, and
-- build.contracts exempts it from the error-slot rules until then.
local function ensure(root: string, argv: {integer:string}): integer | nil, string
  local own_tree, own_trouble = tree.is_own(root)
  if own_tree == nil then
    return 1, own_trouble
  end
  if not own_tree then
    return nil, ""
  end
  local handle, open_trouble = work.open(root)
  if handle == nil then
    return 1, open_trouble
  end

  local moved, moved_trouble = work.tool_moved(handle)
  if moved == nil then
    local _, _ = work.close(handle)
    return 1, moved_trouble
  end
  if not moved then
    local recorded, recorded_trouble = work.recorded_boot_hash(handle)
    if recorded == nil and recorded_trouble ~= "" then
      local _, _ = work.close(handle)
      return 1, recorded_trouble
    end
    if recorded ~= nil and recorded == (Store.meta("boot_hash") or "") then
      local closed, close_trouble = work.close(handle)
      if not closed then
        return 1, close_trouble
      end
      return nil, ""
    end
  end

  local staged, stage_trouble = work.stage(handle, own_tree)
  if staged == nil then
    local _, _ = work.close(handle)
    return 1, stage_trouble
  end
  local state, state_trouble = reboot.state(handle)
  if state == nil then
    local _, _ = work.close(handle)
    return 1, state_trouble
  end
  if state == "fresh" then
    local closed, close_trouble = work.close(handle)
    if not closed then
      return 1, close_trouble
    end
    return nil, ""
  end
  local own, own_tool_trouble = reboot.own_tool(root)
  if own == nil then
    local _, _ = work.close(handle)
    return 1, own_tool_trouble
  end
  if not own then
    local _, _ = work.close(handle)
    return 3, reboot.foreign_refusal
  end
  if state == "core" then
    local closed, close_trouble = work.close(handle)
    if not closed then
      return 1, close_trouble
    end
    if not reboot.auto_boot() then
      return 3, reboot.core_refusal
    end
    return 3, reboot.boot_into(root, argv)
  end
  -- state == "teal"
  local _, _ = Fs.put(Fs.stderr, "cosmic: the tool is stale; rebuilding it from the tree\n")
  local built = teal.lazy()
  local reboot_trouble = reboot.into(handle, built, argv)
  return 3, reboot_trouble
end

--- The exit code a verb returns at once when the tool is older than the
--- tree in the working directory -- after a rebuild that failed, or a
--- refused boot, having said why -- or nil to go on. When the tool can
--- rebuild itself it does, and runs `argv` again rather than returning.
function reboot.stale_exit(argv: {integer:string}): integer | nil
  local root, root_trouble = Fs.absolute(".")
  if root == nil then
    log:complain(root_trouble)
    return 1
  end
  local code, trouble = ensure(root, argv)
  if code ~= nil and trouble ~= "" then
    log:complain(trouble)
  end
  return code
end

return reboot

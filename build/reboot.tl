--- A stale tool, rebuilt from the tree it is stale against and re-entered.
---
--- Cosmic builds itself, so the tool is also an artifact of the tree. When
--- only Teal differs, it projects a new database, combines it with the exact
--- retained portable prefix, atomically replaces the same logical artifact,
--- and re-enters the original argv once. Core-input changes still require Zig.

local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Store = require("cosmic.store")
local sys = require("cosmic.sys")
local artifact = require("build.artifact")
local importer = require("build.importer")
local teal = require("build.teal")
local work = require("build.work")
local writer = require("build.writer")
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
  local result, compile_trouble =
    importer.compile(handle, built, identities.compiler)
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

  local arguments: {string} = {}
  local at = 0
  while argv[at] ~= nil do
    arguments[#arguments + 1] = argv[at]
    at = at + 1
  end
  local environment = sys.environ()
  environment[marker] = "1"
  local _, exec_trouble = Proc.exec(out, arguments, environment)
  return exec_trouble
end

--- The staleness guard `cosmic <file.tl>` and `cosmic test` apply
--- before compiling, for a read-only verb -- `docs`, `uses`, `db`,
--- `help` -- that never compiles the tree itself but still runs
--- `build.*` Teal that this binary embedded at its own boot. Inside
--- cosmic's own tree, an edit to that Teal is otherwise invisible
--- until `bin/zig build boot`, the way `AGENTS.md`'s claim that "an
--- edit to Teal needs no boot" promises it should not be.
---
--- Returns an exit code the caller should return immediately, with
--- `trouble` to report first when it is not empty. Returns `nil` to
--- say the caller may proceed as normal: either the tree is not
--- cosmic's own, or the fingerprint check already found the tool
--- fresh, so no rebuild happened.
--- @param argv the command line, re-entered after a rebuild
function reboot.ensure(root: string, argv: {integer:string}): integer | nil, string
  local own_tree, own_trouble = importer.is_own_tree(root)
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
  local staged, stage_trouble = work.stage(handle, own_tree)
  if staged == nil then
    work.close(handle)
    return 1, stage_trouble
  end
  local state, state_trouble = reboot.state(handle)
  if state == nil then
    work.close(handle)
    return 1, state_trouble
  end
  if state == "fresh" then
    work.close(handle)
    return nil, ""
  end
  if state == "core" then
    work.close(handle)
    return 3, "the tool is stale; run bin/zig build boot"
  end
  -- state == "teal"
  Fs.put(Fs.stderr, "cosmic: the tool is stale; rebuilding it from the tree\n")
  local built = teal.lazy()
  local reboot_trouble = reboot.into(handle, built, argv)
  return 3, reboot_trouble
end

return reboot

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

return reboot

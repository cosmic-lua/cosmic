--- A stale tool, rebuilt from the tree it is stale against and
--- re-entered.
---
--- cosmic builds itself, so the tool is an artifact of the tree, and
--- a stale one is the bug to design against: in cosmic's own tree
--- `cosmic.*` resolves from the binary, so a test run by a binary
--- older than the tree would exercise old code silently. A binary
--- carries two fingerprints of what it was built from. When the
--- tree's differ only in what the C core is not built from, the tool
--- rebuilds itself: it compiles the tree, projects the database, and
--- attaches it to the host image it already carries, then replaces
--- this process with the result running the same command line, once.
--- When the C core's own inputs differ, only zig can build it, and
--- the tool refuses by name.

local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Proc = require("cosmic.proc")
local Store = require("cosmic.store")
local sys = require("cosmic.sys")
local artifact = require("build.artifact")
local attach = require("build.attach")
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
function reboot.into(handle: work.Handle, built: compiler, env: compiler.Env,
                     argv: {integer:string}): string
  if sys.getenv(marker) ~= nil then
    return "the tool is still stale after a reboot"
  end
  local host = Store.meta("host")
  if host == nil then
    return "the binary names no host target; run bin/zig build boot"
  end
  local root = handle.root
  local portable = Store.meta("runtime_context") == "portable-v1"
  local prefix: string | nil = nil
  local out: string | nil = nil

  local image: string | nil = nil
  if portable then
    local prefix_trouble: string
    prefix, prefix_trouble = artifact.trusted_prefix()
    if prefix == nil then
      return prefix_trouble
    end
    local executable_trouble: string
    out, executable_trouble = Proc.executable()
    if out == nil then
      return executable_trouble
    end
    -- A fresh checkout has no boot-populated compiler row in its working
    -- database yet. Preserve the exact compiler carried by the trusted
    -- running artifact so the rebuilt Cosmic remains able to rebuild again.
    local compiler_source, compiler_trouble = Store.source("vendor.tl")
    if compiler_source == nil then
      return "the compiler source is not in this binary: " .. compiler_trouble
    end
    local kept, keep_trouble = work.put_compiler(handle, compiler_source)
    if not kept then
      return keep_trouble
    end
  else
    -- A legacy tool re-enters the image the working database holds for its
    -- target. A checked binary running another image is not rebuilt from it.
    local image_trouble: string
    image, image_trouble = work.image(handle, host)
    if image == nil then
      return image_trouble .. "; run bin/zig build boot"
    end
    local host_image = Store.meta("host_image")
    if host_image == nil or host_image == "" then
      return "the running binary names no host image; run bin/zig build boot"
    end
    if Hash.hex_sha256(image) ~= host_image then
      return "the running image is not the one the working database " ..
        "holds; run bin/zig build boot"
    end
    local named, name_trouble = work.put_host(handle, host, image)
    if not named then
      return name_trouble
    end
    out = root .. "/o/bin/cosmic"
  end

  -- Compiled and keyed as the tree's own work: the tool that replaces
  -- this one carries the tree's compiler identity, so its keys are
  -- made under that identity -- what a boot of the same tree would
  -- make, and what the new tool finds again -- never under this stale
  -- tool's.
  local derived, derive_trouble = importer.derive(handle, true, built)
  if not derived then
    return derive_trouble
  end
  local identities, identity_trouble = work.identities(handle)
  if identities == nil then
    return identity_trouble
  end
  local result, compile_trouble =
    importer.compile(handle, built, env, identities.compiler)
  if result == nil then
    return compile_trouble
  end
  local database_path = root .. "/o/cosmic.db"
  local written, write_trouble =
    writer.write_result(handle, database_path, result, portable)
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
  if portable then
    local program, program_trouble =
      artifact.program(prefix as string, database)
    if program == nil then
      return program_trouble
    end
    local published, publish_trouble = Fs.write(out as string, program, 0x1ed)
    if not published then
      return publish_trouble
    end
  else
    local attached, attach_trouble =
      attach.write((out as string) .. ".new", host, image as string, database)
    if not attached then
      return attach_trouble
    end
    local renamed, rename_trouble =
      Fs.rename((out as string) .. ".new", out as string)
    if not renamed then
      return rename_trouble
    end
  end

  local arguments: {string} = {}
  local at = 0
  while argv[at] ~= nil do
    arguments[#arguments + 1] = argv[at]
    at = at + 1
  end
  local environment = sys.environ()
  environment[marker] = "1"
  local _, exec_trouble = Proc.exec(out as string, arguments, environment)
  return exec_trouble
end

return reboot

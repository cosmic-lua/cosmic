--- The bridge's Teal half: build the database and portable artifact.
---
--- This runs once on a machine with no cosmic binary yet. The C entry
--- has already loaded the vendored compiler from the tree and installed
--- a searcher that compiles a `.tl` straight from it; everything from
--- here is ordinary cosmic code.

local Fs = require("cosmic.fs")
local Log = require("cosmic.log")
local Time = require("cosmic.time")
local clock = require("build.clock")
local artifact = require("build.artifact")
local compiler = require("build.compiler")
local importer = require("build.importer")
local work = require("build.work")
local writer = require("build.writer")

local log = Log.new("cosmic")

--- @param root the tree to build
--- @param argv the command line: slot 4 is the host target, slot 5 is the
--- generated release target record file, and slots 6 through 8 optionally set
--- the checked output directory, checked raw core, and four-entry record file
local function boot(root: string, argv: {integer:string}): integer
  local started = Time.monotonic_ns()
  local host = argv[4]
  if host == nil or host == "" then
    log:verdict("boot", false, "the command line names no host target")
    return 1
  end

  local records_path = argv[5]
  if records_path == nil or records_path == "" then
    log:verdict("boot", false, "the command line names no target records")
    return 1
  end
  local records, records_trouble = Fs.read(records_path)
  if records == nil then
    log:verdict("boot", false, records_trouble)
    return 1
  end

  local targets: {string} = {}
  local images: {string:string} = {}
  local host_id: string | nil = nil
  local host_os: string | nil = nil
  local host_arch: string | nil = nil
  for line in records:gmatch("[^\n]+") do
    local id, configuration_id, configuration, target, uname_os, uname_arch =
      line:match("^(%d+)\t(%d+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)$")
    if id == nil or configuration_id ~= "1" or configuration ~= "release" or
       target == nil or uname_os == nil or uname_arch == nil then
      log:verdict("boot", false, "invalid generated release target record")
      return 1
    end
    local path = root .. "/o/core/" .. target .. "/cosmic-core"
    local image, failure = Fs.read(path)
    if image == nil then
      log:verdict("boot", false, failure)
      return 1
    end
    targets[#targets + 1] = target
    images[target] = image
    if target == host then
      host_id, host_os, host_arch = id, uname_os, uname_arch
    end
  end
  if #targets == 0 then
    log:verdict("boot", false, "the generated target list is empty")
    return 1
  end
  if host_id == nil then
    log:verdict("boot", false, "the host is absent from generated target records")
    return 1
  end

  local output = argv[6] or root .. "/o"
  local selected_configuration = 1
  local manifest_records = records
  if argv[7] ~= nil then
    if argv[8] == nil then
      log:verdict("boot", false, "checked boot names no checked target records")
      return 1
    end
    local checked, checked_trouble = Fs.read(argv[7])
    if checked == nil then
      log:verdict("boot", false, checked_trouble)
      return 1
    end
    local checked_records, checked_records_trouble = Fs.read(argv[8])
    if checked_records == nil then
      log:verdict("boot", false, checked_records_trouble)
      return 1
    end
    if checked_records:sub(1, #records) ~= records then
      log:verdict("boot", false, "checked records do not begin with release records")
      return 1
    end
    local extra = checked_records:sub(#records + 1)
    local checked_id, checked_configuration_id, checked_configuration,
      checked_name, checked_os, checked_arch =
      extra:match("^(%d+)\t(%d+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\n$")
    if checked_id ~= host_id or checked_configuration_id ~= "2" or
       checked_configuration ~= "sanitized" or checked_name == nil or
       checked_os ~= host_os or checked_arch ~= host_arch then
      log:verdict("boot", false, "invalid generated checked target record")
      return 1
    end
    images[checked_name] = checked
    manifest_records = checked_records
    selected_configuration = 2
  elseif argv[8] ~= nil then
    log:verdict("boot", false, "checked target records name no checked raw core")
    return 1
  end

  local made, mkdir_trouble = Fs.mkdirs(output .. "/bin")
  if not made then
    log:verdict("boot", false, mkdir_trouble)
    return 1
  end
  local teal_source, teal_trouble = Fs.read(root .. "/o/vendor/tl/tl.lua")
  if teal_source == nil then
    log:verdict("boot", false, teal_trouble)
    return 1
  end

  local handle, open_trouble = work.open(root)
  if handle == nil then
    log:verdict("boot", false, open_trouble)
    return 1
  end
  local staged, stage_trouble = work.stage(handle, true)
  if staged == nil then
    local _, _ = work.close(handle)
    log:verdict("boot", false, stage_trouble)
    return 1
  end
  local fingerprint, print_trouble = work.record_fingerprint(handle)
  if fingerprint == nil then
    local _, _ = work.close(handle)
    log:verdict("boot", false, print_trouble)
    return 1
  end
  local kept, keep_trouble = work.put_compiler(handle, teal_source)
  if not kept then
    local _, _ = work.close(handle)
    log:verdict("boot", false, keep_trouble)
    return 1
  end

  -- The tree's own identities, which are this boot's: the bridge runs the
  -- tree's build code. Parsed first, so the compiler closure is whole on a
  -- fresh working database and keys exactly as a warm build does.
  local derived, derive_trouble = importer.derive(handle, true, compiler)
  if not derived then
    local _, _ = work.close(handle)
    log:verdict("boot", false, derive_trouble)
    return 1
  end
  local identities, identity_trouble = work.record_identities(handle)
  if identities == nil then
    local _, _ = work.close(handle)
    log:verdict("boot", false, identity_trouble)
    return 1
  end

  local result, compile_trouble =
    importer.compile(handle, compiler, identities.compiler)
  if result == nil then
    local _, _ = work.record(handle, clock.elapsed_ms(started), staged, 0, 0, "FAIL")
    local _, _ = work.close(handle)
    log:say("boot: FAIL\n" .. compile_trouble)
    return 1
  end
  local database_path = output .. "/cosmic.db"
  local written, write_trouble =
    writer.write_result(handle, database_path, result)
  local _, _ = work.record(handle, clock.elapsed_ms(started), staged, result.compiled,
    result.cached, written and "PASS" or "FAIL")
  if not written then
    local _, _ = work.close(handle)
    log:say("boot: FAIL\n" .. write_trouble)
    return 1
  end

  -- The tool carries the projection without the tree's own tests,
  -- which `cosmic test` reads from `o/cosmic.db` itself.
  local carried_path = output .. "/carried.db"
  local carried, carry_trouble = writer.carried(database_path, carried_path)
  if not carried then
    local _, _ = work.close(handle)
    log:verdict("boot", false, carry_trouble)
    return 1
  end
  local database, read_trouble = Fs.read(carried_path)
  if database == nil then
    local _, _ = work.close(handle)
    log:verdict("boot", false, read_trouble)
    return 1
  end
  local prefix, prefix_trouble = artifact.prefix(manifest_records, images,
    selected_configuration)
  if prefix == nil then
    local _, _ = work.close(handle)
    log:verdict("boot", false, prefix_trouble)
    return 1
  end
  local program, program_trouble = artifact.program(prefix, database)
  if program == nil then
    local _, _ = work.close(handle)
    log:verdict("boot", false, program_trouble)
    return 1
  end
  local closed, close_trouble = work.close(handle)
  if not closed then
    log:verdict("boot", false, close_trouble)
    return 1
  end
  local published, publish_trouble =
    Fs.write(output .. "/bin/cosmic", program, 0x1ed)
  if not published then
    log:verdict("boot", false, publish_trouble)
    return 1
  end

  log:verdict("boot", true, #targets .. " targets, " .. staged.files ..
    " files staged, " .. result.compiled .. " modules compiled, " ..
    #database .. " database bytes, " .. clock.elapsed_ms(started) .. " ms")
  return 0
end

return boot

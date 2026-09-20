--- The bridge's Teal half: build the database and portable artifact.
---
--- This runs once on a machine with no cosmic binary yet. The C entry
--- has already loaded the vendored compiler from the tree and installed
--- a searcher that compiles a `.tl` straight from it; everything from
--- here is ordinary cosmic code.

local Fs = require("cosmic.fs")
local Time = require("cosmic.time")
local artifact = require("build.artifact")
local compiler = require("build.compiler")
local importer = require("build.importer")
local teal = require("build.teal")
local work = require("build.work")
local writer = require("build.writer")

local function elapsed_ms(from: integer): integer
  local now = Time.monotonic_ns()
  if now == nil then
    return 0
  end
  return (now - from) // 1000000
end

local function report(line: string)
  Fs.put(Fs.stdout, line .. "\n")
end

--- @param root the tree to build
--- @param argv the command line: slot 4 is the host target, slot 5 is the
--- generated release target record file, and slots 6 through 8 optionally set
--- the checked output directory, checked raw core, and four-entry record file
local function boot(root: string, argv: {integer:string}): integer
  local started = Time.monotonic_ns() or 0
  local host = argv[4]
  if host == nil or host == "" then
    report("boot: FAIL (the command line names no host target)")
    return 1
  end

  local records_path = argv[5]
  if records_path == nil or records_path == "" then
    report("boot: FAIL (the command line names no target records)")
    return 1
  end
  local records, records_trouble = Fs.read(records_path)
  if records == nil then
    report("boot: FAIL (" .. records_trouble .. ")")
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
      report("boot: FAIL (invalid generated release target record)")
      return 1
    end
    local path = root .. "/o/core/" .. target .. "/cosmic-core"
    local image, failure = Fs.read(path)
    if image == nil then
      report("boot: FAIL (" .. failure .. ")")
      return 1
    end
    targets[#targets + 1] = target
    images[target] = image
    if target == host then
      host_id, host_os, host_arch = id, uname_os, uname_arch
    end
  end
  if #targets == 0 then
    report("boot: FAIL (the generated target list is empty)")
    return 1
  end
  if host_id == nil then
    report("boot: FAIL (the host is absent from generated target records)")
    return 1
  end

  local output = argv[6] or root .. "/o"
  local selected_configuration = 1
  local manifest_records = records
  if argv[7] ~= nil then
    if argv[8] == nil then
      report("boot: FAIL (checked boot names no checked target records)")
      return 1
    end
    local checked, checked_trouble = Fs.read(argv[7])
    if checked == nil then
      report("boot: FAIL (" .. checked_trouble .. ")")
      return 1
    end
    local checked_records, checked_records_trouble = Fs.read(argv[8])
    if checked_records == nil then
      report("boot: FAIL (" .. checked_records_trouble .. ")")
      return 1
    end
    if checked_records:sub(1, #records) ~= records then
      report("boot: FAIL (checked records do not begin with release records)")
      return 1
    end
    local extra = checked_records:sub(#records + 1)
    local checked_id, checked_configuration_id, checked_configuration,
      checked_name, checked_os, checked_arch =
      extra:match("^(%d+)\t(%d+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\n$")
    if checked_id ~= host_id or checked_configuration_id ~= "2" or
       checked_configuration ~= "sanitized" or checked_name == nil or
       checked_os ~= host_os or checked_arch ~= host_arch then
      report("boot: FAIL (invalid generated checked target record)")
      return 1
    end
    images[checked_name] = checked
    manifest_records = checked_records
    selected_configuration = 2
  elseif argv[8] ~= nil then
    report("boot: FAIL (checked target records name no checked raw core)")
    return 1
  end

  local made, mkdir_trouble = Fs.mkdirs(output .. "/bin")
  if not made then
    report("boot: FAIL (" .. mkdir_trouble .. ")")
    return 1
  end
  local teal_source, teal_trouble = Fs.read(root .. "/o/vendor/tl/tl.lua")
  if teal_source == nil then
    report("boot: FAIL (" .. teal_trouble .. ")")
    return 1
  end

  local handle, open_trouble = work.open(root)
  if handle == nil then
    report("boot: FAIL (" .. open_trouble .. ")")
    return 1
  end
  local staged, stage_trouble = work.stage(handle, true)
  if staged == nil then
    work.close(handle)
    report("boot: FAIL (" .. stage_trouble .. ")")
    return 1
  end
  local fingerprint, print_trouble = work.fingerprint(handle)
  if fingerprint == nil then
    work.close(handle)
    report("boot: FAIL (" .. print_trouble .. ")")
    return 1
  end
  local env, trouble = teal.environment_for(compiler, handle)
  if env == nil then
    work.close(handle)
    report("boot: FAIL (" .. trouble .. ")")
    return 1
  end
  local kept, keep_trouble = work.put_compiler(handle, teal_source)
  if not kept then
    work.close(handle)
    report("boot: FAIL (" .. keep_trouble .. ")")
    return 1
  end

  -- The tree's own identities, which are this boot's: the bridge runs the
  -- tree's build code. Parsed first, so the compiler closure is whole on a
  -- fresh working database and keys exactly as a warm build does.
  local derived, derive_trouble = importer.derive(handle, true, compiler)
  if not derived then
    work.close(handle)
    report("boot: FAIL (" .. derive_trouble .. ")")
    return 1
  end
  local identities, identity_trouble = work.identities(handle)
  if identities == nil then
    work.close(handle)
    report("boot: FAIL (" .. identity_trouble .. ")")
    return 1
  end

  local result, compile_trouble =
    importer.compile(handle, compiler, env, identities.compiler)
  if result == nil then
    work.record(handle, elapsed_ms(started), staged, 0, 0, "FAIL")
    work.close(handle)
    report("boot: FAIL\n" .. compile_trouble)
    return 1
  end
  local database_path = output .. "/cosmic.db"
  local written, write_trouble =
    writer.write_result(handle, database_path, result)
  work.record(handle, elapsed_ms(started), staged, result.compiled,
    result.cached, written and "PASS" or "FAIL")
  if not written then
    work.close(handle)
    report("boot: FAIL\n" .. write_trouble)
    return 1
  end

  local database, read_trouble = Fs.read(database_path)
  if database == nil then
    work.close(handle)
    report("boot: FAIL (" .. read_trouble .. ")")
    return 1
  end
  local prefix, prefix_trouble = artifact.prefix(manifest_records, images,
    selected_configuration)
  if prefix == nil then
    work.close(handle)
    report("boot: FAIL (" .. prefix_trouble .. ")")
    return 1
  end
  local program, program_trouble = artifact.program(prefix, database)
  if program == nil then
    work.close(handle)
    report("boot: FAIL (" .. program_trouble .. ")")
    return 1
  end
  local closed, close_trouble = work.close(handle)
  if not closed then
    report("boot: FAIL (" .. close_trouble .. ")")
    return 1
  end
  local published, publish_trouble =
    Fs.write(output .. "/bin/cosmic", program, 0x1ed)
  if not published then
    report("boot: FAIL (" .. publish_trouble .. ")")
    return 1
  end

  report("boot: PASS (" .. #targets .. " targets, " .. staged.files ..
    " files staged, " .. result.compiled .. " modules compiled, " ..
    #database .. " database bytes, " .. elapsed_ms(started) .. " ms)")
  return 0
end

return boot

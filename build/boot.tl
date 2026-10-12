--- The bridge's Teal half: build the database and portable artifact.
---
--- Every boot runs this on the freshly built host core. The pinned
--- bootstrap cosmic starts zig; no tree-built tool is needed. The C entry
--- has already loaded the vendored compiler from the tree and installed
--- a searcher that compiles a `.tl` straight from it; everything from
--- here is ordinary cosmic code.

local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Log = require("cosmic.log")
local clock = require("build.clock")
local artifact = require("build.artifact")
local build_paths = require("build.paths")
local plural = require("build.plural")
local String = require("cosmic.string")

local log = Log.new("cosmic")

-- Only what the assembly needs is required above: the rest of the build
-- code loads where `stage` and the worker use it, since each module a boot
-- requires is compiled from source by the bridge's searcher
-- (core/bridge.lua) before it runs, and the assembly, started again once
-- every core is linked, would wait for that compile of code it never calls.
-- TODO: once core/bridge.lua takes its compile of the vendored `tl.tl` from
-- the compiles every checkout shares (its own TODO in `bootstrap`), the
-- assembly's start, about 6 s of the compiler's bootstrap on every run of
-- the core, falls to a read of the cache.

--- What `stage` leaves for the assembly and the verdict line.
local record Staged
  files: integer
  parsed: integer
  parses_shared: integer
  compiled: integer
  modules_shared: integer
end

--- Stages the tree into the build directory's working database, parses
--- and compiles it, and writes the projection and the carried database
--- beside the tool. Everything the Teal half of a boot does before the
--- raw cores matter. Says why on failure, returning nil.
local function stage(root: string, tl_dir: string, compiler_source: string,
                     working: build_paths.Layout, output: build_paths.Layout,
                     started: integer): Staged | nil
  local made, mkdir_trouble = Fs.mkdirs(output.bin)
  if not made then
    log:verdict("boot", false, mkdir_trouble)
    return nil
  end
  local derivation = require("build.derivation")
  local identity = require("build.identity")
  local importer = require("build.importer")
  local shared_compiles = require("build.shared_compiles")
  local work = require("build.work")
  local workers = require("build.workers")
  local writer = require("build.writer")
  local compiler = require("build.compiler")
  local handle, open_trouble = work.open(root, working.directory)
  if handle == nil then
    log:verdict("boot", false, open_trouble)
    return nil
  end
  local staged, stage_trouble = work.stage(handle, true)
  if staged == nil then
    local _, _ = work.close(handle)
    log:verdict("boot", false, stage_trouble)
    return nil
  end
  local fingerprint, print_trouble = identity.record_fingerprint(handle.db)
  if fingerprint == nil then
    local _, _ = work.close(handle)
    log:verdict("boot", false, print_trouble)
    return nil
  end
  local kept, keep_trouble = derivation.put_compiler(handle.db, compiler_source)
  if not kept then
    local _, _ = work.close(handle)
    log:verdict("boot", false, keep_trouble)
    return nil
  end
  -- Read from the tree itself, as zig reads vendor/cacert: the zones
  -- are data, which no patch record edits.
  local zones, zones_trouble = work.read_zoneinfo(root .. "/vendor/tzdata/zoneinfo")
  if zones == nil then
    local _, _ = work.close(handle)
    log:verdict("boot", false, zones_trouble)
    return nil
  end
  local zoned, zoned_trouble = work.put_zoneinfo(handle, zones)
  if not zoned then
    local _, _ = work.close(handle)
    log:verdict("boot", false, zoned_trouble)
    return nil
  end
  -- Likewise the files cosmic.web serves under /_web/, hashed here.
  local web, web_trouble = work.read_web_assets(root .. "/vendor")
  if web == nil then
    local _, _ = work.close(handle)
    log:verdict("boot", false, web_trouble)
    return nil
  end
  local web_put, web_put_trouble = work.put_web_assets(handle, web)
  if not web_put then
    local _, _ = work.close(handle)
    log:verdict("boot", false, web_put_trouble)
    return nil
  end

  -- The tree's own identities, which are this boot's: the bridge runs the
  -- tree's build code. Parsed first, so the compiler closure is whole on a
  -- fresh working database and keys exactly as a warm build does.
  local result, compile_trouble = importer.compile_tree(handle, compiler,
    function(recorded: identity.Identities): string, string
      return recorded.compiler, ""
    end, false, shared_compiles.for_build(),
    workers.pool(workers.boot_spec(root, tl_dir)))
  if result == nil then
    local _, _ = work.record(handle, clock.elapsed_ms(started), staged, 0, 0, "FAIL")
    local _, _ = work.close(handle)
    log:say("boot: FAIL\n" .. compile_trouble)
    return nil
  end
  local database_path = output.projection
  local written, write_trouble =
    writer.write_result(handle, database_path, result)
  local _, _ = work.record(handle, clock.elapsed_ms(started), staged, result.compiled,
    result.cached, written and "PASS" or "FAIL")
  if not written then
    local _, _ = work.close(handle)
    log:say("boot: FAIL\n" .. write_trouble)
    return nil
  end

  -- The tool carries the projection without the tree's own tests and
  -- examples, which `cosmic test` reads from the projection itself.
  local carried, carry_trouble = writer.carried(database_path, output.carried)
  if not carried then
    local _, _ = work.close(handle)
    log:verdict("boot", false, carry_trouble)
    return nil
  end
  local closed, close_trouble = work.close(handle)
  if not closed then
    log:verdict("boot", false, close_trouble)
    return nil
  end
  return {
    files = staged.files,
    parsed = result.parses.parsed,
    parses_shared = result.parses.shared,
    compiled = result.compiled,
    modules_shared = result.shared,
  }
end

local function describe(staged: Staged): string
  return plural.count(staged.files, "file") .. " staged, " ..
    plural.count(staged.parsed, "source") .. " parsed, " ..
    staged.parses_shared .. " taken from another checkout, " ..
    plural.count(staged.compiled, "module") .. " compiled, " ..
    staged.modules_shared .. " taken from another checkout"
end

--- Writes the tool: the artifact prefix over every raw core in `images`,
--- then the carried database `stage` wrote. The tool is written last and
--- whole, so a failure anywhere before leaves the previous one in place.
--- Returns the database's length, or nil having said why.
local function assemble(manifest_records: string, images: {string:string},
                        selected_configuration: integer,
                        output: build_paths.Layout): integer | nil
  local database, read_trouble = Fs.read(output.carried)
  if database == nil then
    log:verdict("boot", false, read_trouble)
    return nil
  end
  local prefix, prefix_trouble = artifact.prefix(manifest_records, images,
    selected_configuration)
  if prefix == nil then
    log:verdict("boot", false, prefix_trouble)
    return nil
  end
  local program, program_trouble = artifact.program(prefix, database)
  if program == nil then
    log:verdict("boot", false, program_trouble)
    return nil
  end
  local published, publish_trouble =
    Fs.write(output.tool, program, 0x1ed)
  if not published then
    log:verdict("boot", false, publish_trouble)
    return nil
  end
  return #database
end

--- @param root the tree to build
--- @param argv the command line: slot 4 is the host target, slot 5 is the
--- generated release target record file, and slot 6 the working directory.
--- A slot 4 of `--worker` instead makes this process serve a boot's phases
--- for another ([`build.workers`]) and build nothing.
--- A slot 4 of `--stage` or `--assemble` runs half of a boot and shifts
--- the slots above by one: `--stage` does the Teal work (staging, parsing,
--- compiling, the database and the carried database) without reading any
--- raw core, and `--assemble` reads every raw core and the carried
--- database `--stage` left and writes the tool. `bin/zig build boot` runs
--- the first as soon as the host core is linked and the second once every
--- core is, so the cores that only the assembly reads do not hold the
--- Teal work back. Neither takes a checked core.
--- Slots 7 through 9 optionally set the checked raw core, four-entry record
--- file and checked output directory
--- @param compiler_source the Lua the compiler running this was compiled
--- to from the vendored `tl.tl` (core/bridge.lua's `bootstrap`): the
--- compiler the tool carries
local function boot(root: string, argv: {integer:string},
                    compiler_source: string): integer
  if argv[4] == "--worker" then
    return require("build.worker").serve(require("build.compiler"))
  end
  local started = Clock.monotonic_ns()
  local first = 4
  local mode = "boot"
  if argv[4] == "--stage" or argv[4] == "--assemble" then
    mode = argv[4]:sub(3)
    first = 5
  end
  --- The command line's slot `n`, counted as a whole boot's.
  local function slot(n: integer): string | nil
    return argv[n + first - 4]
  end
  local host = slot(4)
  if host == nil or host == "" then
    log:verdict("boot", false, "the command line names no host target")
    return 1
  end
  -- The build directory bin/zig resolved and handed zig as its prefix.
  local working_directory = slot(6)
  if working_directory == nil or working_directory == "" then
    log:verdict("boot", false, "the command line names no working directory")
    return 1
  end
  local working = build_paths.under(working_directory)

  local records_path = slot(5)
  if records_path == nil or records_path == "" then
    log:verdict("boot", false, "the command line names no target records")
    return 1
  end
  local records, records_trouble = Fs.read(records_path)
  if records == nil then
    log:verdict("boot", false, records_trouble)
    return 1
  end
  if mode ~= "boot" and (slot(7) ~= nil or slot(8) ~= nil or slot(9) ~= nil) then
    log:verdict("boot", false, "a half boot takes no checked core")
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
    -- The staging half never reads a raw core: it is the point of
    -- running it before the cores other than this process's own exist.
    if mode ~= "stage" then
      local path = build_paths.core(working, target)
      local image, failure = Fs.read(path)
      if image == nil then
        log:verdict("boot", false, failure)
        return 1
      end
      images[target] = image
    end
    targets[#targets + 1] = target
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

  local output_directory = slot(9)
  local output = output_directory ~= nil and build_paths.under(output_directory) or working
  local selected_configuration = 1
  local manifest_records = records
  local checked_path = slot(7)
  if checked_path ~= nil then
    local checked_records_path = slot(8)
    if checked_records_path == nil then
      log:verdict("boot", false, "checked boot names no checked target records")
      return 1
    end
    local checked, checked_trouble = Fs.read(checked_path)
    if checked == nil then
      log:verdict("boot", false, checked_trouble)
      return 1
    end
    local checked_records, checked_records_trouble = Fs.read(checked_records_path)
    if checked_records == nil then
      log:verdict("boot", false, checked_records_trouble)
      return 1
    end
    if not String.starts_with(checked_records, records) then
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
  elseif slot(8) ~= nil then
    log:verdict("boot", false, "checked target records name no checked raw core")
    return 1
  end

  if mode == "stage" then
    local made = stage(root, argv[3], compiler_source, working, output, started)
    if made == nil then return 1 end
    log:verdict("stage", true, describe(made) .. ", " .. clock.took(started))
    return 0
  end
  local staged: Staged | nil = nil
  if mode == "boot" then
    staged = stage(root, argv[3], compiler_source, working, output, started)
    if staged == nil then return 1 end
  end
  local database_length = assemble(manifest_records, images,
    selected_configuration, output)
  if database_length == nil then return 1 end

  local summary = plural.count(#targets, "target")
  if staged ~= nil then
    summary = summary .. ", " .. describe(staged)
  end
  log:verdict("boot", true, summary .. ", " ..
      plural.count(database_length, "database byte") .. ", " .. clock.took(started))
  return 0
end

return boot

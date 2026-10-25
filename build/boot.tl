--- The bridge's Teal half: build the database and portable artifact.
---
--- Every boot runs this on the freshly built host core. The pinned
--- bootstrap cosmic starts zig; no tree-built tool is needed. The C entry
--- has already built the compiler from the seed (the Lua the pinned release
--- wrote for the files of [`build/seed.txt`], compiled again by itself,
--- core/bridge.lua) and installed a searcher that compiles a `.tl` straight
--- from the tree with it; everything from here is ordinary cosmic code.

local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Log = require("cosmic.log")
local GrammarMode = require("build.grammar_mode")
local identity = require("build.identity")
local importer = require("build.importer")
local shared_compiles = require("build.shared_compiles")
local work = require("build.work")
local writer = require("build.writer")
local clock = require("build.clock")
local artifact = require("build.artifact")
local build_paths = require("build.paths")
local plural = require("build.plural")
local Hash = require("cosmic.hash")
local String = require("cosmic.string")

local log = Log.new("cosmic")

--- What `stage` leaves for the assembly and the summary.
local record Staged
  files: integer
  parsed: integer
  parses_shared: integer
  compiled: integer
  modules_shared: integer
  --- Milliseconds the stage took, from its own start.
  elapsed_ms: integer
end

--- Where a stage vouches for the carried database it wrote, beside it.
local function stamp_path(output: build_paths.Layout): string
  return output.carried .. ".stamp"
end

--- The stamp's fields, in the order it keeps them.
local stamp_fields <const>: {string} = { "carried", "records", "files", "parsed",
  "parses_shared", "compiled", "modules_shared", "elapsed_ms" }

--- Vouches for the carried database a stage wrote: its digest, the digest
--- of the target records the stage ran for, and the figures the boot's
--- summary reports. `--assemble` accepts only the database a stamp
--- names, so a stale or foreign `carried.db` is refused instead of
--- shipped, and reports the whole boot's figures.
local function stamp_text(staged: Staged, carried: string, records: string): string
  local values: {string:string} = {
    carried = Hash.hex_sha256(carried),
    records = Hash.hex_sha256(records),
    files = tostring(staged.files),
    parsed = tostring(staged.parsed),
    parses_shared = tostring(staged.parses_shared),
    compiled = tostring(staged.compiled),
    modules_shared = tostring(staged.modules_shared),
    elapsed_ms = tostring(staged.elapsed_ms),
  }
  local lines: mut {string} = {}
  for _, field in ipairs(stamp_fields) do
    lines[#lines + 1] = field .. "=" .. values[field]
  end
  return table.concat(lines, "\n") .. "\n"
end

--- What a stamp vouches for: the stage's figures and the digest of the
--- carried database it wrote.
local record Stamp
  staged: Staged
  carried: string
end

--- The stamp `text` is, if it is one for `records`; else nil and why.
local function read_stamp(text: string, records: string): Stamp?, string
  local values: mut {string:string} = {}
  for field, value in text:gmatch("([%a_]+)=(%x+)\n") do
    values[field] = value
  end
  for _, field in ipairs(stamp_fields) do
    if values[field] == nil then
      return nil, "the stage's stamp lacks " .. field
    end
  end
  if values.records ~= Hash.hex_sha256(records) then
    return nil, "the stage's stamp is for other target records"
  end
  return { carried = values.carried, staged = {
    files = math.tointeger(values.files) or 0,
    parsed = math.tointeger(values.parsed) or 0,
    parses_shared = math.tointeger(values.parses_shared) or 0,
    compiled = math.tointeger(values.compiled) or 0,
    modules_shared = math.tointeger(values.modules_shared) or 0,
    elapsed_ms = math.tointeger(values.elapsed_ms) or 0,
  } }, ""
end

--- Stages the tree into the build directory's working database, parses
--- and compiles it, and writes the projection and the carried database
--- beside the tool. Everything the Teal half of a boot does before the
--- raw cores matter. Says why on failure, returning nil.
local function stage(root: string, working: build_paths.Layout, output: build_paths.Layout,
                     started: integer): Staged?
  local made, mkdir_trouble = Fs.mkdirs(output.bin)
  if not made then
    log:complain("boot: " .. mkdir_trouble)
    return nil
  end
  local grammar, grammar_trouble = GrammarMode.mode()
  if grammar == nil then
    log:complain("boot: " .. grammar_trouble)
    return nil
  end
  local handle, open_trouble = work.open(root, working.directory)
  if handle == nil then
    log:complain("boot: " .. open_trouble)
    return nil
  end
  local staged, stage_trouble = work.stage(handle, true)
  if staged == nil then
    local _, _ = work.close(handle)
    log:complain("boot: " .. stage_trouble)
    return nil
  end
  local fingerprint, print_trouble = identity.record_fingerprint(handle.db, handle.root)
  if fingerprint == nil then
    local _, _ = work.close(handle)
    log:complain("boot: " .. print_trouble)
    return nil
  end
  -- Read from the tree itself, as zig reads vendor/cacert: the zones
  -- are data, which no patch record edits.
  local zones, zones_trouble = work.read_zoneinfo(root .. "/vendor/tzdata/zoneinfo")
  if zones == nil then
    local _, _ = work.close(handle)
    log:complain("boot: " .. zones_trouble)
    return nil
  end
  local zoned, zoned_trouble = work.put_zoneinfo(handle, zones)
  if not zoned then
    local _, _ = work.close(handle)
    log:complain("boot: " .. zoned_trouble)
    return nil
  end
  -- Likewise the files cosmic.web serves under /_web/, hashed here.
  local web, web_trouble = work.read_web_assets(root .. "/vendor")
  if web == nil then
    local _, _ = work.close(handle)
    log:complain("boot: " .. web_trouble)
    return nil
  end
  local web_put, web_put_trouble = work.put_web_assets(handle, web)
  if not web_put then
    local _, _ = work.close(handle)
    log:complain("boot: " .. web_put_trouble)
    return nil
  end

  -- The tree's own identities, which are this boot's: the bridge runs the
  -- tree's build code. Parsed first, so the compiler closure is whole on a
  -- fresh working database and keys exactly as a warm build does. The new
  -- checker compiles the tree, in this process ([`importer.compile_tree`]).
  local result, compile_trouble = importer.compile_tree(handle,
    function(recorded: identity.Identities): string, string
      return GrammarMode.tool(recorded.compiler, grammar), ""
    end, false, shared_compiles.for_build())
  if result == nil then
    local _, _ = work.record(handle, clock.elapsed_ms(started), staged, 0, 0, "FAIL")
    local _, _ = work.close(handle)
    log:complain("boot: " .. compile_trouble)
    return nil
  end
  -- The new checker goes on past a module it refuses, to tell every refusal; a tool is not written from a tree it refused.
  local refused = result.refused
  if #refused > 0 then
    local _, _ = work.record(handle, clock.elapsed_ms(started), staged, 0, 0, "FAIL")
    local _, _ = work.close(handle)
    log:complain(table.concat(refused, "\n"))
    log:complain("boot: the new checker refused " .. plural.count(#refused, "module") ..
        " of the tree, so no tool is written from it")
    return nil
  end
  local database_path = output.projection
  local written, write_trouble =
    writer.write_result(handle, database_path, result)
  local _, _ = work.record(handle, clock.elapsed_ms(started), staged, result.compiled,
    result.cached, if written then "PASS" else "FAIL" end)
  if not written then
    local _, _ = work.close(handle)
    log:complain("boot: " .. write_trouble)
    return nil
  end

  -- The tool carries the projection without the tree's own tests and
  -- examples, which `cosmic test` reads from the projection itself.
  local carried, carry_trouble = writer.carried(database_path, output.carried)
  if not carried then
    local _, _ = work.close(handle)
    log:complain("boot: " .. carry_trouble)
    return nil
  end
  local closed, close_trouble = work.close(handle)
  if not closed then
    log:complain("boot: " .. close_trouble)
    return nil
  end
  return {
    files = staged.files,
    parsed = result.parses.parsed,
    parses_shared = result.parses.shared,
    compiled = result.compiled,
    modules_shared = result.shared,
    elapsed_ms = clock.elapsed_ms(started),
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
--- `expected`, when given, is the digest the database must have. Returns
--- the database's length, or nil having said why.
local function assemble(manifest_records: string, images: {string:string},
                        selected_configuration: integer,
                        output: build_paths.Layout,
                        expected?: string): integer?
  local database, read_trouble = Fs.read(output.carried)
  if database == nil then
    log:complain("boot: " .. read_trouble)
    return nil
  end
  if expected ~= nil and Hash.hex_sha256(database) ~= expected then
    log:complain("boot: " .. output.carried ..
        " is not the database the last stage stamped")
    return nil
  end
  local prefix, prefix_trouble = artifact.prefix(manifest_records, images,
    selected_configuration)
  if prefix == nil then
    log:complain("boot: " .. prefix_trouble)
    return nil
  end
  local program, program_trouble = artifact.program(prefix, database)
  if program == nil then
    log:complain("boot: " .. program_trouble)
    return nil
  end
  local published, publish_trouble =
    Fs.write(output.tool, program, 0x1ed)
  if not published then
    log:complain("boot: " .. publish_trouble)
    return nil
  end
  return #database
end

--- @param root the tree to build
--- @param argv the command line: slot 4 is the host target, slot 5 is the
--- generated release target record file, and slot 6 the working directory.
--- A slot 4 of `--stage` or `--assemble` runs half of a boot and shifts
--- the slots above by one: `--stage` does the Teal work (staging, parsing,
--- compiling, the database and the carried database) without reading any
--- raw core, and `--assemble` reads every raw core and the carried
--- database `--stage` left and writes the tool. `bin/zig build boot` runs
--- the first as soon as the host core is linked and the second once every
--- core is, so the cores that only the assembly reads do not hold the
--- Teal work back. `--stage` ends by writing a stamp beside `carried.db`
--- (the database's digest, the records it ran for, its figures and time),
--- and removes the last one first; `--assemble` refuses a `carried.db` or
--- records the stamp does not name, so the step graph is not all that
--- pairs the two, and its `boot: ` summary reports the whole boot.
--- Neither takes a checked core.
--- A leading `--host-only` (before `--stage` or `--assemble`, or alone
--- before the host target of a whole boot) says the tool carries the
--- host's raw core alone: the assembly reads no other, and puts
--- [`artifact.placeholder`] where each other target's core goes, in the
--- same portable layout the core accepts, so the tool runs as one of every
--- core does. `cosmic build` of a portable program refuses such a tool
--- ([`build.embed`]). Without it every raw core is read and the tool is the
--- one CI verifies, byte for byte as it has been.
--- Slots 7 through 9 optionally set the checked raw core, four-entry record
--- file and checked output directory
local function boot(root: string, argv: {string}): integer
  local started = Clock.monotonic_ns()
  local first = 4
  local mode = "boot"
  local host_only = false
  if argv[first] == "--host-only" then
    host_only = true
    first = first + 1
  end
  if argv[first] == "--stage" or argv[first] == "--assemble" then
    mode = argv[first]:sub(3)
    first = first + 1
  end
  --- The command line's slot `n`, counted as a whole boot's.
  local function slot(n: integer): string?
    return argv[n + first - 4]
  end
  local host = slot(4)
  if host == nil or host == "" then
    log:complain("boot: " .. "the command line names no host target")
    return 1
  end
  -- The build directory bin/zig resolved and handed zig as its prefix.
  local working_directory = slot(6)
  if working_directory == nil or working_directory == "" then
    log:complain("boot: " .. "the command line names no working directory")
    return 1
  end
  local working = build_paths.under(working_directory)

  local records_path = slot(5)
  if records_path == nil or records_path == "" then
    log:complain("boot: " .. "the command line names no target records")
    return 1
  end
  local records, records_trouble = Fs.read(records_path)
  if records == nil then
    log:complain("boot: " .. records_trouble)
    return 1
  end
  if mode ~= "boot" and (slot(7) ~= nil or slot(8) ~= nil or slot(9) ~= nil) then
    log:complain("boot: " .. "a half boot takes no checked core")
    return 1
  end

  local targets: mut {string} = {}
  local images: mut {string:string} = {}
  local host_id: string? = nil
  local host_os: string? = nil
  local host_arch: string? = nil
  for line in records:gmatch("[^\n]+") do
    local id, configuration_id, configuration, target, uname_os, uname_arch =
      line:match("^(%d+)\t(%d+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)$")
    if id == nil or configuration_id ~= "1" or configuration ~= "release" or
        target == nil or uname_os == nil or uname_arch == nil then
      log:complain("boot: " .. "invalid generated release target record")
      return 1
    end
    -- The staging half never reads a raw core: it is the point of
    -- running it before the cores other than this process's own exist.
    if mode ~= "stage" then
      local image: string?
      local failure = ""
      if host_only and target ~= host then
        image = artifact.placeholder(target)
      else
        image, failure = Fs.read(build_paths.core(working, target))
      end
      if image == nil then
        log:complain("boot: " .. failure)
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
    log:complain("boot: " .. "the generated target list is empty")
    return 1
  end
  if host_id == nil then
    log:complain("boot: " .. "the host is absent from generated target records")
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
      log:complain("boot: " .. "checked boot names no checked target records")
      return 1
    end
    local checked, checked_trouble = Fs.read(checked_path)
    if checked == nil then
      log:complain("boot: " .. checked_trouble)
      return 1
    end
    local checked_records, checked_records_trouble = Fs.read(checked_records_path)
    if checked_records == nil then
      log:complain("boot: " .. checked_records_trouble)
      return 1
    end
    if not String.starts_with(checked_records, records) then
      log:complain("boot: " .. "checked records do not begin with release records")
      return 1
    end
    local extra = checked_records:sub(#records + 1)
    local checked_id, checked_configuration_id, checked_configuration,
      checked_name, checked_os, checked_arch =
      extra:match("^(%d+)\t(%d+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\n$")
    if checked_id ~= host_id or checked_configuration_id ~= "2" or
        checked_configuration ~= "sanitized" or checked_name == nil or
        checked_os ~= host_os or checked_arch ~= host_arch then
      log:complain("boot: " .. "invalid generated checked target record")
      return 1
    end
    images[checked_name] = checked
    manifest_records = checked_records
    selected_configuration = 2
  elseif slot(8) ~= nil then
    log:complain("boot: " .. "checked target records name no checked raw core")
    return 1
  end

  if mode == "stage" then
    -- No stamp survives into a stage that has not finished: an
    -- interrupted one leaves the assembly nothing to trust.
    local _, _ = Fs.remove(stamp_path(output))
    local made = stage(root, working, output, started)
    if made == nil then return 1 end
    local database, read_trouble = Fs.read(output.carried)
    if database == nil then
      log:complain("boot: " .. read_trouble)
      return 1
    end
    local stamped, stamp_trouble =
      Fs.write(stamp_path(output), stamp_text(made, database, records))
    if not stamped then
      log:complain("boot: " .. stamp_trouble)
      return 1
    end
    local _, _ = Fs.put(Fs.stderr, "stage: " .. describe(made) .. ", " .. clock.took(started) .. "\n")
    return 0
  end
  local staged: Staged
  local expected: string? = nil
  if mode == "boot" then
    local made = stage(root, working, output, started)
    if made == nil then return 1 end
    staged = made
  else
    local text, text_trouble = Fs.read(stamp_path(output))
    if text == nil then
      log:complain("boot: " .. text_trouble)
      return 1
    end
    local read, read_trouble = read_stamp(text, records)
    if read == nil then
      log:complain("boot: " .. read_trouble)
      return 1
    end
    staged, expected = read.staged, read.carried
  end
  local database_length = assemble(manifest_records, images,
    selected_configuration, output, expected)
  if database_length == nil then return 1 end

  -- A whole boot's time: the stage's (which `--assemble` reads from its
  -- stamp, and which may have run while other cores linked) and this run's.
  local total_ms = clock.elapsed_ms(started)
  if mode == "assemble" then total_ms = total_ms + staged.elapsed_ms end
  local _, _ = Fs.put(Fs.stderr, "boot: " .. plural.count(#targets, "target") ..
      (if host_only then " (the host's core only)" else "" end) .. ", " ..
      describe(staged) .. ", " ..
      plural.count(database_length, "database byte") .. ", " .. total_ms .. " ms\n")
  return 0
end

return boot

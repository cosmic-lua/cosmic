--- The bridge's Teal half: build the database and attach it.
---
--- This runs once on a machine with no cosmic binary yet. The C entry
--- has already loaded the vendored compiler from the tree and installed
--- a searcher that compiles a `.tl` straight from it; everything from
--- here is ordinary cosmic code.

local Fs = require("cosmic.fs")
local Time = require("cosmic.time")
local attach = require("build.attach")
local compiler = require("build.compiler")
local importer = require("build.importer")
local teal = require("build.teal")
local work = require("build.work")
local writer = require("build.writer")

--- The targets every binary carries an image for.
local targets = {
  "x86_64-linux-musl",
  "aarch64-linux-musl",
  "aarch64-macos",
}

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
--- @param argv the command line: slot 4 is the host target, slots 5 and 6
--- optionally set the output directory and host core image for checked builds
local function boot(root: string, argv: {integer:string}): integer
  local started = Time.monotonic_ns() or 0
  local host = argv[4]
  if host == nil or host == "" then
    report("boot: FAIL (the command line names no host target)")
    return 1
  end

  local output = argv[5] or root .. "/o"
  local made, mkdir_trouble = Fs.mkdirs(output .. "/bin")
  if not made then
    report("boot: FAIL (" .. mkdir_trouble .. ")")
    return 1
  end
  local images: {string:string} = {}
  for _, target in ipairs(targets) do
    local path = root .. "/o/core/" .. target .. "/cosmic-core"
    local image, failure = Fs.read(path)
    if image == nil then
      report("boot: FAIL (" .. failure .. ")")
      return 1
    end
    images[target] = image
  end

  -- Checked boot changes the running host prefix, not the reusable images
  -- in the shared working database. Later ordinary builds read those images.
  local host_image = images[host]
  if argv[6] ~= nil then
    local checked, checked_trouble = Fs.read(argv[6])
    if checked == nil then
      report("boot: FAIL (" .. checked_trouble .. ")")
      return 1
    end
    host_image = checked
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
    report("boot: FAIL (" .. stage_trouble .. ")")
    return 1
  end
  local boot_hash, hash_trouble = work.boot_hash(handle)
  if boot_hash == nil then
    report("boot: FAIL (" .. hash_trouble .. ")")
    return 1
  end
  local env, trouble = teal.environment_for(compiler, handle)
  if env == nil then
    report("boot: FAIL (" .. trouble .. ")")
    return 1
  end

  -- What a boot alone puts in the working database, for every later
  -- build to carry: the three images and the compiler.
  for _, target in ipairs(targets) do
    local put, put_trouble = work.put_image(handle, target, images[target])
    if not put then
      report("boot: FAIL (" .. put_trouble .. ")")
      return 1
    end
  end
  local kept, keep_trouble = work.put_compiler(handle, teal_source)
  if not kept then
    report("boot: FAIL (" .. keep_trouble .. ")")
    return 1
  end

  local database_path = output .. "/cosmic.db"
  local result, compile_trouble =
    importer.compile(handle, compiler, env, boot_hash)
  if result == nil then
    work.record(handle, elapsed_ms(started), staged, 0, 0, "FAIL")
    work.close(handle)
    report("boot: FAIL\n" .. compile_trouble)
    return 1
  end
  local written, write_trouble =
    writer.write_result(handle, database_path, result)
  work.record(handle, elapsed_ms(started), staged, result.compiled,
    result.cached, written and "PASS" or "FAIL")
  work.close(handle)
  if not written then
    report("boot: FAIL\n" .. write_trouble)
    return 1
  end

  local database, read_trouble = Fs.read(database_path)
  if database == nil then
    report("boot: FAIL (" .. read_trouble .. ")")
    return 1
  end

  for _, target in ipairs(targets) do
    local out = output .. "/bin/cosmic-" .. target
    local image = target == host and host_image or images[target]
    local ok, failure = attach.write(out, target, image, database)
    if not ok then
      report("boot: FAIL (" .. failure .. ")")
      return 1
    end
    if target == host then
      local same, host_trouble =
        attach.write(output .. "/bin/cosmic", target, image, database)
      if not same then
        report("boot: FAIL (" .. host_trouble .. ")")
        return 1
      end
    end
  end

  report("boot: PASS (" .. #targets .. " targets, " .. staged.files ..
    " files staged, " .. result.compiled .. " modules compiled, " ..
    #database .. " database bytes, " .. elapsed_ms(started) .. " ms)")
  return 0
end

return boot

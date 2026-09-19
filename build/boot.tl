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
--- @param argv the command line, where slot 4 names the host target
local function boot(root: string, argv: {integer:string}): integer
  local started = Time.monotonic_ns() or 0
  local host = argv[4]
  if host == nil or host == "" then
    report("boot: FAIL (the command line names no host target)")
    return 1
  end

  local env, trouble = teal.environment_for(compiler, root)
  if env == nil then
    report("boot: FAIL (" .. trouble .. ")")
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

  local database_path = root .. "/o/cosmic.db"
  local written, write_trouble =
    writer.write(handle, database_path, compiler, env, boot_hash, images,
                 teal_source)
  work.record(handle, elapsed_ms(started), staged, staged.files,
    written and "PASS" or "FAIL")
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

  local made, mkdir_trouble = Fs.mkdirs(root .. "/o/bin")
  if not made then
    report("boot: FAIL (" .. mkdir_trouble .. ")")
    return 1
  end

  for _, target in ipairs(targets) do
    local out = root .. "/o/bin/cosmic-" .. target
    local ok, failure = attach.write(out, target, images[target], database)
    if not ok then
      report("boot: FAIL (" .. failure .. ")")
      return 1
    end
    if target == host then
      local same, host_trouble =
        attach.write(root .. "/o/bin/cosmic", target, images[target], database)
      if not same then
        report("boot: FAIL (" .. host_trouble .. ")")
        return 1
      end
    end
  end

  report("boot: PASS (" .. #targets .. " targets, " .. staged.files ..
    " files staged, " .. #database .. " database bytes, " ..
    elapsed_ms(started) .. " ms)")
  return 0
end

return boot

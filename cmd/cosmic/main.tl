--- The binary's main.
---
--- A bare path runs a file: cosmic builds the tree that file sits in,
--- into that tree's own database, and then requires the module. The
--- database is the only module source at run time, so running a file
--- and building a project are one path.

local Compress = require("cosmic.compress")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local importer = require("build.importer")
local teal = require("build.teal")

local help = [[
cosmic -- a runtime for self-contained command-line software

  cosmic <file.tl>   build the tree the file sits in, then run it
  cosmic help        this

Every verb ends in a verdict line and an exit code.
]]

local function say(line: string)
  Fs.put(Fs.stdout, line .. "\n")
end

local function complain(line: string)
  Fs.put(Fs.stderr, line .. "\n")
end

--- The directory a path sits in, absolute.
local function directory_of(path: string): string | nil, string
  local resolved, trouble = Fs.absolute(path)
  if resolved == nil then
    return nil, trouble
  end
  local parent = resolved:match("^(.*)/[^/]+$")
  if parent == nil or parent == "" then
    return "/"
  end
  return parent
end

--- The module a file is, as its path relative to the root says.
local function module_of(root: string, file: string): string | nil, string
  local resolved, trouble = Fs.absolute(file)
  if resolved == nil then
    return nil, trouble
  end
  if resolved:sub(1, #root + 1) ~= root .. "/" then
    return nil, file .. " is not inside " .. root
  end
  local relative = resolved:sub(#root + 2)
  if relative:sub(-3) ~= ".tl" then
    return nil, file .. " is not a Teal source"
  end
  return (relative:gsub("%.tl$", ""):gsub("/", "."))
end

--- The images and vendored compiler an existing database already
--- carries, read back so a re-import over it can carry them forward
--- unchanged instead of dropping them. Empty/nil when `path` does not
--- exist yet or holds neither -- an ordinary project's first run.
local function carried_payload(path: string): {string:string}, string | nil, string
  local images: {string:string} = {}
  if not Fs.exists(path) then
    return images, nil, ""
  end
  local handle, open_trouble = Sqlite.open(path, false)
  if handle == nil then
    return images, nil, "cosmic: " .. open_trouble
  end
  local rows, rows_trouble = Sqlite.rows(handle,
    "SELECT target, size, data FROM images")
  if rows == nil then
    handle:close()
    return images, nil, "cosmic: " .. rows_trouble
  end
  for _, row in ipairs(rows) do
    local target, size_text, packed = row[1], row[2], row[3]
    local size = math.tointeger(tonumber(size_text) or 0) or 0
    local raw, inflate_trouble = Compress.inflate(packed, size)
    if raw == nil then
      handle:close()
      return images, nil, "cosmic: " .. target .. ": " .. inflate_trouble
    end
    images[target] = raw
  end
  local vendor_rows, vendor_trouble = Sqlite.rows(handle,
    "SELECT source FROM modules WHERE kind = 'vendor' AND path = 'vendor.tl'")
  if vendor_rows == nil then
    handle:close()
    return images, nil, "cosmic: " .. vendor_trouble
  end
  local teal_source: string | nil = nil
  if #vendor_rows > 0 then
    teal_source = vendor_rows[1][1]
  end
  handle:close()
  return images, teal_source, ""
end

local function run(file: string, argv: {integer:string}): integer
  local root, trouble = directory_of(file)
  if root == nil then
    complain("cosmic: " .. trouble)
    return 1
  end
  local name, why = module_of(root, file)
  if name == nil then
    complain("cosmic: " .. why)
    return 1
  end

  -- A stale tool: this binary's own build/** and core/** no longer
  -- match what it was booted from. Rebuilding is the fix; running on
  -- would compile the tree with a checker or patch set the tree no
  -- longer agrees with.
  -- intended: re-run boot and re-exec once, per design.md's staleness
  -- section; M1 has no process spawning, so this only detects and
  -- refuses.
  if importer.is_own_tree(root) then
    local current, hash_trouble = importer.boot_hash(root)
    if current == nil then
      complain("cosmic: " .. hash_trouble)
      return 1
    end
    local running = Store.meta("boot_hash") or ""
    if current ~= running then
      complain("cosmic: the tool is stale; run bin/zig build boot")
      return 3
    end
  end

  local built, load_trouble = teal.load()
  if built == nil then
    complain("cosmic: " .. load_trouble)
    return 1
  end
  local env, env_trouble = teal.environment_for(built, root)
  if env == nil then
    complain("cosmic: " .. env_trouble)
    return 1
  end

  local made, mkdir_trouble = Fs.mkdirs(root .. "/o")
  if not made then
    complain("cosmic: " .. mkdir_trouble)
    return 1
  end

  -- The tool's own hash, which the build that made this binary recorded.
  -- A project's rows are keyed by it, so a new cosmic recompiles them.
  local boot_hash = Store.meta("boot_hash") or ""

  local database = root .. "/o/cosmic.db"

  -- Re-importing over cosmic's own database must not erase what `boot`
  -- put there: the three core images and the vendored compiler row.
  -- Read them back first and hand them straight through, so this run
  -- carries them forward unchanged rather than writing an empty set.
  local images, teal_source, carry_trouble = carried_payload(database)
  if carry_trouble ~= "" then
    complain(carry_trouble)
    return 1
  end

  local written, write_trouble =
    importer.write(root, database, built, env, boot_hash, images, teal_source)
  if not written then
    complain("cosmic: " .. write_trouble)
    return 1
  end

  local attached, attach_trouble = Store.attach(database)
  if not attached then
    complain("cosmic: " .. attach_trouble)
    return 1
  end

  local produced: any = require(name)
  if produced is function(...: any): any then
    local status: any = produced(argv)
    if status is integer then
      return status
    end
  end
  return 0
end

--- @param argv the command line, with the program's own name at slot 0
local function main(argv: {integer:string}): integer
  local verb = argv[1]
  if verb == nil or verb == "help" or verb == "-h" or verb == "--help" then
    say(help)
    return 0
  end
  if verb:sub(1, 1) == "-" then
    complain("cosmic: no such option: " .. verb)
    complain("cosmic: `cosmic help` is the whole discovery surface")
    return 2
  end
  return run(verb, argv)
end

return main

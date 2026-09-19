--- The binary's main.
---
--- A bare path runs a file: cosmic builds the tree that file sits in,
--- into that tree's own database, and then requires the module. The
--- database is the only module source at run time, so running a file
--- and building a project are one path.

local Fs = require("cosmic.fs")
local Store = require("cosmic.store")
local fix = require("build.fix")
local importer = require("build.importer")
local payload = require("build.payload")
local teal = require("build.teal")
local test = require("build.test")
local writer = require("build.writer")

local help = [[
cosmic -- a runtime for self-contained command-line software

  cosmic <file.tl>   build the tree the file sits in, then run it
  cosmic test        build the tree in the working directory, then
                     run every test it defines
  cosmic fix         rewrite every Teal source in the working
                     directory structurally, then write it back out
                     as canonical text, in place
  cosmic fix --check the same, writing nothing: name the files a fix
                     would change, and fail if there are any
  cosmic help        this

A verb takes paths to narrow it. `fix` rebuilds each file from its own
parsed tree. It decides everything a line holds -- every keyword,
operator and bracket, the spacing around each, and two columns of
indentation per level of block -- from the tree rather than from
whichever two tokens ended up adjacent, so `local x <const> = 5` is
one unit attached to the name and can never come back as `local x <
const > = 5`. It carries over where the lines break and where they do
not, and never rewraps one. Type syntax is written as the original
bytes. Nothing is written until the result has been parsed again and
found to mean the same thing, comments included.

That indentation is the indentation of LINES THAT OPEN SOMETHING: a
statement, a block's closing keyword. A line that continues one keeps
the column it was written at, moved with the statement it belongs to,
and so does an entry of a table spread over several lines, a comment
on a line of its own, and the body of a record or enum -- which is
copied out as the bytes it was read from. Lining those up is a
judgement about a whole line, which is the author's here, not the
tool's.

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

  -- A stale tool: this binary's source inputs no longer match what
  -- it was booted from. Rebuilding is the fix; running on
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
  local images, teal_source, carry_trouble = payload.carried(database)
  if carry_trouble ~= "" then
    complain("cosmic: " .. carry_trouble)
    return 1
  end

  local result, compile_trouble = importer.compile(root, built, env, boot_hash)
  if result == nil then
    complain("cosmic: " .. compile_trouble)
    return 1
  end
  local written, write_trouble =
    writer.write_result(database, result, images, teal_source)
  if not written then
    complain("cosmic: " .. write_trouble)
    return 1
  end

  -- A test file elsewhere in the tree that `importer.compile` refused
  -- (the return-collision case `positions.analyze` and
  -- `with_test_tail` guard against) is silently dropped from the
  -- database otherwise; the file the caller actually asked to run
  -- still compiled fine and still runs below, so this is a warning,
  -- never a reason to fail this invocation.
  for _, line in ipairs(result.refused) do
    complain("cosmic: warning: " .. line)
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
  if verb == "test" then
    return test.run()
  end
  if verb == "fix" then
    return fix.run(argv)
  end
  if verb:sub(1, 1) == "-" then
    complain("cosmic: no such option: " .. verb)
    complain("cosmic: `cosmic help` is the whole discovery surface")
    return 2
  end
  return run(verb, argv)
end

return main

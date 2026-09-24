--- The binary's main.
---
--- A bare path runs a file: cosmic builds the tree that file sits in,
--- into that tree's own database, and then requires the module. The
--- database is the only module source at run time, so running a file
--- and building a project are one path.

local Cli = require("cosmic.cli")
local Fs = require("cosmic.fs")
local Store = require("cosmic.store")
local Time = require("cosmic.time")
local clock = require("build.clock")

-- Require build modules lazily inside the verb that needs them, so `help`
-- remains fast and loads only `build.docs` and `build.reboot`.

local help_prefix = "cosmic -- a runtime for self-contained command-line software\n"

--- The one-line-per-verb usage block `cosmic help` prints, generated
--- from `cosmic.cli`'s own fields (`Cli.run`, `Cli.test`, ...) so this
--- wording is never a second, hand-kept copy of what `cosmic docs
--- build` (or fix, db, docs, uses, help, run, test) already answers.
--- Falls back to naming the lookup that failed, rather than silently
--- dropping a verb from its own help, if `cosmic.cli`'s own database
--- row is ever missing.
local function verb_help(): string
  local docs = require("build.docs")
  local handles, public = docs.databases()
  local view, view_trouble = docs.view(handles, public)
  if view == nil then
    return "(cosmic.cli: " .. view_trouble .. ")"
  end
  local names: {string} = {}
  for _, verb in ipairs(Cli.order) do
    names[#names + 1] = "Cli." .. verb
  end
  local found, trouble = docs.named_all(view, names)
  local lines: {string} = {}
  for _, verb in ipairs(Cli.order) do
    local symbol = "Cli." .. verb
    local text: string | nil = nil
    if found ~= nil then
      for _, entry in ipairs(found) do
        if entry.symbol == symbol then
          text = entry.text
          break
        end
      end
    end
    if found == nil then
      lines[#lines + 1] = "(cosmic.cli." .. symbol .. ": " .. trouble .. ")"
    elseif text == nil then
      lines[#lines + 1] = "(cosmic.cli." .. symbol .. ": not found)"
    else
      lines[#lines + 1] = text
    end
    lines[#lines + 1] = ""
  end
  return table.concat(lines, "\n")
end

local help_suffix = [[
Lua's `io`, `os`, and `debug` are not present; code that reaches for
one is told the replacement for the very field it used -- by the
compiler, or at run time by a chunk `load` was handed. `io` is
`cosmic.fs`: `Fs.stdout`, `.stderr`, `.stdin` are descriptors, written
and read with `Fs.put`/`Fs.take`. `os` is `cosmic.time`, `cosmic.env`,
and `cosmic.proc`. `debug` is `cosmic.errors.trace`. `print` still
works, an ordinary global written over the same syscall table
`cosmic.fs` uses.

A verb takes paths to narrow it. `test` accepts exact module names, source
paths, and directories. `fix` rebuilds each file from its own parsed tree. It decides everything a line holds -- every keyword,
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
  local _, _ = Fs.put(Fs.stdout, line .. "\n")
end

local function complain(line: string)
  local _, _ = Fs.put(Fs.stderr, line .. "\n")
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

--- The tree a file run builds: the working directory when the file
--- sits under it, so `cosmic cmd/notes/main.tl` from a project's root
--- builds the project as `test` and `build` do and the file reaches
--- the rest of it; the file's own directory otherwise, so a file
--- anywhere else runs on its own.
local function root_of(file: string): string | nil, string
  local resolved, trouble = Fs.absolute(file)
  if resolved == nil then
    return nil, file .. ": " .. trouble
  end
  local here, _ = Fs.absolute(".")
  if here ~= nil and (here == "/" or resolved:sub(1, #here + 1) == here .. "/") then
    return here
  end
  return directory_of(file)
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

--- Runs a file. The file is a module: it is required once its tree is
--- built, and if what it returns is a function, that function is
--- called with one argument: an array of the arguments after the
--- file's own path on the command line, indexed from 1 like any
--- ordinary Lua array, so `#argv` and `ipairs(argv)` see exactly
--- those and nothing before them. The file's own path is there too,
--- at `argv[0]`, the way C, Lua and every shell give a program its
--- own name -- but nothing ordinary reaches it, since no length or
--- loop starts before 1; a caller that wants its own name reads
--- `argv[0]` directly. A record whose `main` field is a function is
--- called the same way, through that field. An integer the function
--- returns is the exit code; anything else, or no function at all,
--- is 0.
--- @param file the path named on the command line
--- @param argv the whole command line, `cosmic` at slot 0 and `file` at
---   slot 1; the file sees only what follows it, as its own `argv`
local function run(file: string, argv: {integer:string}): integer
  local importer = require("build.importer")
  local reboot = require("build.reboot")
  local teal = require("build.teal")
  local work = require("build.work")
  local writer = require("build.writer")
  local root, trouble = root_of(file)
  if root == nil then
    complain("cosmic: " .. trouble)
    return 1
  end
  local name, why = module_of(root, file)
  if name == nil then
    complain("cosmic: " .. why)
    return 1
  end

  local started = Time.monotonic_ns()
  local own_tree, own_trouble = importer.is_own_tree(root)
  if own_tree == nil then
    complain("cosmic: " .. own_trouble)
    return 1
  end
  local handle, open_trouble = work.open(root)
  if handle == nil then
    complain("cosmic: " .. open_trouble)
    return 1
  end
  local staged, stage_trouble = work.stage(handle, own_tree)
  if staged == nil then
    local _, _ = work.close(handle)
    complain("cosmic: " .. stage_trouble)
    return 1
  end

  local built = teal.lazy()

  -- A stale tool: this binary's source inputs no longer match what
  -- it was booted from. Running on would compile the tree with a
  -- checker the tree no longer agrees with and run tests against
  -- old code. When only Teal moved, the tool rebuilds itself and
  -- re-enters this same command line; when the C core moved, it has
  -- zig boot it (`build.reboot`).
  if own_tree then
    local state, state_trouble = reboot.state(handle)
    if state == nil then
      local _, _ = work.close(handle)
      complain("cosmic: " .. state_trouble)
      return 1
    end
    if state == "core" then
      local _, _ = work.close(handle)
      if not reboot.auto_boot() then
        complain("cosmic: " .. reboot.core_refusal)
        return 3
      end
      complain("cosmic: " .. reboot.boot_into(root, argv))
      return 3
    end
    if state == "teal" then
      complain("cosmic: the tool is stale; rebuilding it from the tree")
      local reboot_trouble = reboot.into(handle, built, argv)
      complain("cosmic: " .. reboot_trouble)
      return 3
    end
  end

  -- The compiler this binary is, as the build that made it recorded.
  -- A project's rows are keyed by it, so a different compiler
  -- recompiles them.
  local tool = Store.meta("compiler") or ""

  local database = root .. "/o/cosmic.db"

  local result, compile_trouble = importer.compile(handle, built, tool)
  if result == nil then
    local _, _ = work.record(handle, clock.elapsed_ms(started), staged, 0, 0, "FAIL")
    local _, _ = work.close(handle)
    complain("cosmic: " .. compile_trouble)
    return 1
  end
  local written, write_trouble =
    writer.write_result(handle, database, result)
  local _, _ = work.record(handle, clock.elapsed_ms(started), staged, result.compiled,
    result.cached, written and "PASS" or "FAIL")
  local _, _ = work.close(handle)
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

  local standalone = require("build.standalone")
  local entry = standalone.entry(require(name))
  if entry ~= nil then
    local arguments: {string} = {}
    arguments[0] = file
    local slot = 2
    while argv[slot] ~= nil do
      arguments[slot - 1] = argv[slot]
      slot = slot + 1
    end
    local status: any = entry(arguments)
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
    -- Same staleness guard `test` applies: cheap (a fingerprint
    -- compare) when the tool is already fresh, so this keeps help
    -- fast in the ordinary case, and only rebuilds when an edit to
    -- build.docs itself would otherwise go unseen.
    local reboot = require("build.reboot")
    local root, root_trouble = Fs.absolute(".")
    if root == nil then
      complain("cosmic: " .. root_trouble)
      return 1
    end
    local code, trouble = reboot.ensure(root, argv)
    if code ~= nil then
      if trouble ~= "" then
        complain("cosmic: " .. trouble)
      end
      return code
    end
    say(help_prefix .. "\n" .. verb_help() .. "\n" .. help_suffix)
    return 0
  end
  if verb == "test" and argv[2] == "--worker" then
    -- One test in a process of its own, started by `cosmic test`: see
    -- build.test_worker. Never stale-checked or rebuilt, since the run
    -- that started it already was.
    local worker = require("build.test_worker")
    return worker.run(argv)
  end
  if verb == "test" then
    local test = require("build.test")
    return test.run(argv)
  end
  if verb == "fix" then
    local fix = require("build.fix")
    return fix.run(argv)
  end
  if verb == "db" then
    local databases = require("build.databases")
    return databases.run(argv)
  end
  if verb == "build" then
    local embed = require("build.embed")
    return embed.run(argv)
  end
  if verb == "docs" then
    local docs = require("build.docs")
    return docs.run(argv)
  end
  if verb == "uses" then
    local docs = require("build.docs")
    return docs.run_uses(argv)
  end
  if verb == "todos" then
    local todos = require("build.todos")
    return todos.run(argv)
  end
  if verb == "--standalone" then
    -- One file against this binary's own standard library: no tree is
    -- staged or built and no staleness is checked -- see
    -- build.standalone. What bin/zig and bin/vendor run, so a stale
    -- core never stops the tool that rebuilds it.
    local standalone = require("build.standalone")
    return standalone.run(argv)
  end
  if verb:sub(1, 1) == "-" then
    complain("cosmic: no such option: " .. verb)
    complain("cosmic: `cosmic help` is the whole discovery surface")
    return 2
  end
  return run(verb, argv)
end

return main

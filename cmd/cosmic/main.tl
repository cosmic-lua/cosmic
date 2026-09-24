--- The binary's main.
---
--- A bare path runs a file: cosmic builds the tree that file sits in,
--- into that tree's own database, and then requires the module. The
--- database is the only module source at run time, so running a file
--- and building a project are one path.

local Cli = require("cosmic.cli")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Store = require("cosmic.store")
local String = require("cosmic.string")
local Time = require("cosmic.time")
local clock = require("build.clock")
local verdict = require("build.verdict")

local log = verdict.log

-- Require build modules lazily inside the verb that needs them, so `help`
-- remains fast and loads only `build.docs`, `build.reboot` and
-- `build.verdict`.

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

Every verb ends in a verdict line -- `fix: PASS (...)` or `fix: FAIL
(...)` -- and an exit code: 0 when it passed; 1 when it failed; 2 when
its command line was refused -- an option, an argument or a verb it
does not know; 3 when the tool is older than the tree and did not
rebuild itself (`COSMIC_AUTO_BOOT=0`, or a boot that failed). A file
run exits with what its program returns.
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
  return Fs.dirname(resolved), ""
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
  if here ~= nil and Fs.within(resolved, here) then
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
  if not String.ends_with(relative, ".tl") then
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
  -- zig boot it (`build.reboot`). Only the tree's own tool does either;
  -- another refuses.
  if own_tree then
    local state, state_trouble = reboot.state(handle)
    if state == nil then
      local _, _ = work.close(handle)
      complain("cosmic: " .. state_trouble)
      return 1
    end
    if state ~= "fresh" then
      local own, own_tool_trouble = reboot.own_tool(root)
      if own == nil then
        local _, _ = work.close(handle)
        complain("cosmic: " .. own_tool_trouble)
        return 1
      end
      if not own then
        local _, _ = work.close(handle)
        complain("cosmic: " .. reboot.foreign_refusal)
        return 3
      end
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

--- The exit code to return at once when the tool is older than the tree
--- it runs in -- after a rebuild that failed, or a refused boot, having
--- said why -- or nil to go on. When the tool can rebuild itself it does,
--- and runs this command line again rather than returning.
local function stale_code(argv: {integer:string}): integer | nil
  local reboot = require("build.reboot")
  local root, root_trouble = Fs.absolute(".")
  if root == nil then
    complain("cosmic: " .. root_trouble)
    return 1
  end
  local code, trouble = reboot.ensure(root, argv)
  if code ~= nil and trouble ~= "" then
    complain("cosmic: " .. trouble)
  end
  return code
end

--- `cosmic help [verb]`: the whole discovery surface, and a verdict line.
--- @param asked the verb `cosmic <verb> --help` asked about, or nil to
---   read the words after `help` itself
local function help(argv: {integer:string}, asked: string | nil): integer
  local started = Time.monotonic_ns()
  -- Same staleness guard `test` applies: cheap (a fingerprint
  -- compare) when the tool is already fresh, so this keeps help
  -- fast in the ordinary case, and only rebuilds when an edit to
  -- build.docs itself would otherwise go unseen.
  local code = stale_code(argv)
  if code ~= nil then
    return code
  end
  local words: {string} = { asked }
  if asked == nil then
    local parsed, parse_trouble = Flags.parse(argv, 2, {})
    if parsed == nil then
      complain("cosmic: help: " .. parse_trouble)
      log:verdict("help", false, parse_trouble)
      return 2
    end
    words = parsed.words
  end
  if #words > 1 then
    complain("cosmic: help: one verb at a time, not " .. #words)
    log:verdict("help", false, "one verb at a time")
    return 2
  end
  if #words == 1 then
    local known = false
    for _, verb in ipairs(Cli.order) do
      if verb == words[1] then known = true end
    end
    if not known then
      complain("cosmic: help: no such verb: " .. words[1])
      log:verdict("help", false, "no such verb: " .. words[1])
      return 2
    end
  end
  -- TODO: print only the asked verb's line for `cosmic help <verb>`, as
  -- doc/design.md promises; until then a verb gets the whole surface.
  say(help_prefix .. "\n" .. verb_help() .. "\n" .. help_suffix)
  log:verdict("help", true, #Cli.order .. " verbs, " .. clock.elapsed_ms(started) .. " ms")
  return 0
end

--- Each verb that ends in a verdict line, by the word that names it.
local verbs: {string: function({integer:string}): integer} = {
  help = function(argv: {integer:string}): integer
    return help(argv, nil)
  end,
  test = function(argv: {integer:string}): integer
    return require("build.test").run(argv)
  end,
  fix = function(argv: {integer:string}): integer
    return require("build.fix").run(argv)
  end,
  db = function(argv: {integer:string}): integer
    return require("build.databases").run(argv)
  end,
  build = function(argv: {integer:string}): integer
    return require("build.embed").run(argv)
  end,
  docs = function(argv: {integer:string}): integer
    return require("build.docs").run(argv)
  end,
  uses = function(argv: {integer:string}): integer
    return require("build.docs").run_uses(argv)
  end,
  todos = function(argv: {integer:string}): integer
    return require("build.todos").run(argv)
  end,
}

--- What a verdict line a verb did not give itself says of its exit code.
local function detail_of(code: integer): string
  if code == 2 then
    return "usage: see `cosmic help`"
  elseif code == 3 then
    return "the tool is stale"
  end
  return ""
end

--- @param argv the command line, with the program's own name at slot 0
local function main(argv: {integer:string}): integer
  local word = argv[1]
  if word == "test" and argv[2] == "--worker" then
    -- One test in a process of its own, started by `cosmic test`: see
    -- build.test_worker. Never stale-checked or rebuilt, since the run
    -- that started it already was.
    local worker = require("build.test_worker")
    return worker.run(argv)
  end
  if word == "--standalone" then
    -- One file against this binary's own standard library: no tree is
    -- staged or built and no staleness is checked -- see
    -- build.standalone. What bin/zig and bin/vendor run, so a stale
    -- core never stops the tool that rebuilds it.
    local standalone = require("build.standalone")
    return standalone.run(argv)
  end
  local verb = word
  if word == nil or word == "-h" or word == "--help" then
    verb = "help"
  end
  local chosen = verbs[verb]
  if chosen ~= nil and verb ~= "help" and (argv[2] == "-h" or argv[2] == "--help") then
    -- `cosmic <verb> --help` is `cosmic help <verb>`.
    local asked = verb
    verb = "help"
    chosen = function(line: {integer:string}): integer
      return help(line, asked)
    end
  end
  if chosen ~= nil then
    -- A verb gives its own verdict wherever it has one to give; an exit
    -- it left without one -- its command line refused, a setup failure,
    -- a stale tool -- still ends in one here.
    local code = chosen(argv)
    if code == 2 and not verdict.given then
      -- A verb may read its command line before it checks the tool is
      -- as new as the tree, and an option the tree added is one a stale
      -- tool refuses: it rebuilds and runs the line again here instead.
      local stale = stale_code(argv)
      if stale ~= nil then
        code = stale
      end
    end
    if not verdict.given then
      log:verdict(verb, code == 0, detail_of(code))
    end
    return code
  end
  if verb:sub(1, 1) == "-" then
    -- TODO: take `-e <chunk>` here and run it, as doc/design.md's
    -- command-line section promises; the PR on those promises adds it.
    complain("cosmic: no such option: " .. verb)
    complain("cosmic: `cosmic help` is the whole discovery surface")
    return 2
  end
  -- A word that could not be a file to run is a mistyped verb, told as
  -- one rather than as a file that is not there.
  if not verb:find("/", 1, true) and not String.ends_with(verb, ".tl") then
    local exists, _ = Fs.exists(verb)
    if not exists then
      complain("cosmic: no such verb or file: " .. verb .. "; see `cosmic help`")
      return 2
    end
  end
  return run(verb, argv)
end

return main

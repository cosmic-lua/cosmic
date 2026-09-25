--- What the binary's main does with its command line, as a module
--- rather than the main itself, so a test can run a verb in-process
--- (`build.invoke`): `cmd/cosmic/main.tl` only hands `dispatch.main` on.
---
--- A bare path runs a file: cosmic builds the tree that file sits in,
--- into that tree's own database, and then requires the module. The
--- database is the only module source at run time, so running a file
--- and building a project are one path.

local Cli = require("cosmic.cli")
local Codec = require("cosmic.codec")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Proc = require("cosmic.proc")
local Store = require("cosmic.store")
local String = require("cosmic.string")
local Time = require("cosmic.time")
local clock = require("build.clock")
local exit_status = require("build.exit_status")
local verdict = require("build.verdict")

local log = verdict.log

-- Require build modules lazily inside the verb that needs them, so `help`
-- remains fast and loads only `build.docs`, `build.reboot` and
-- `build.verdict`.

local help_prefix = "cosmic -- a runtime for self-contained command-line software\n"

--- The one-line-per-verb usage block `cosmic help` prints, generated
--- from `cosmic.cli`'s own fields (`Cli.run`, `Cli.test`, ...) so this
--- wording is never a second, hand-kept copy of what `cosmic docs
--- build` (or any verb `Cli.order` names) already answers.
--- Falls back to naming the lookup that failed, rather than silently
--- dropping a verb from its own help, if `cosmic.cli`'s own database
--- row is ever missing.
--- @param verbs the verbs to print, in order
local function verb_help(verbs: {string}): string
  local docs = require("build.docs")
  local sources = docs.databases()
  local view, view_trouble = docs.view(sources.handles, sources.public)
  if view == nil then
    return "(cosmic.cli: " .. view_trouble .. ")"
  end
  local names: {string} = {}
  for _, verb in ipairs(verbs) do
    names[#names + 1] = "Cli." .. verb
  end
  local found, trouble = docs.named_all(view, names)
  local lines: {string} = {}
  for _, verb in ipairs(verbs) do
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
      local options = Flags.options(Cli.options[verb] or {})
      if options ~= "" then
        lines[#lines + 1] = options
      end
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

A verb takes paths to narrow it: `test` exact module names, source
paths and directories; `fix`, `build` and `todos` the files or
directories to act on; `uses` paths after its symbol; `db` the
sources whose rows to count. `docs` takes words to search for instead,
`sql` one statement, and `help` a verb.

`fix` rebuilds each file from its own parsed tree. It decides everything a line holds -- every keyword,
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
run, `--standalone` and `-e` are not verbs of that kind: each prints
only what its program prints and exits with what it returns.
`--version` is not one either: it prints its one line.
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
--- called the same way, through that field. What the function returns
--- is the exit code as a built program's is -- see build/exit_status.tl: nil
--- is 0, and anything but a whole number from 0 to 255 exits 2. No
--- function at all is 0.
--- @param file the path named on the command line
--- @param argv the whole command line, `cosmic` at slot 0 and `file` at
---   slot 1; the file sees only what follows it, as its own `argv`
local function run(file: string, argv: {integer:string}): integer
  local importer = require("build.importer")
  local reboot = require("build.reboot")
  local teal = require("build.teal")
  local tree = require("build.tree")
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
  local own_tree, own_trouble = tree.is_own(root)
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

  -- A stale tool refuses, or rebuilds itself or has zig boot the core
  -- and re-enters this command line (`reboot.guard`).
  if own_tree then
    local code = reboot.guard(handle, root, argv)
    if code ~= nil then
      return code
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
  -- (the return-collision case `analyzer.analyze` and
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
    return exit_status(file, entry(arguments))
  end
  return 0
end

--- The verbs spelled as options, by that spelling.
local as_option: {string:string} = {
  ["--standalone"] = "standalone",
  ["-e"] = "eval",
  ["--version"] = "version",
}

--- `cosmic --version`: the SHA-256 of the file this binary runs from,
--- read in pieces, as a release's SHA256SUMS names it: `cosmic <hex>`.
local function version(argv: {integer:string}): integer
  if argv[2] ~= nil then
    complain("cosmic: --version takes nothing after it, not " .. argv[2])
    return 2
  end
  local path, path_trouble = Proc.executable()
  if path == nil then
    complain("cosmic: --version: " .. path_trouble)
    return 1
  end
  -- TODO: hash the artifact descriptor startup retained rather than
  -- opening the path again, once the store offers the whole file as it
  -- offers its core (trusted_core): a file renamed over this one after
  -- launch is hashed in its place, and an unlinked one fails.
  local fd, open_trouble = Fs.open_read(path)
  if fd == nil then
    complain("cosmic: --version: " .. path .. ": " .. open_trouble)
    return 1
  end
  local hasher, hasher_trouble = Hash.hasher("sha256")
  if hasher == nil then
    local _, _ = Fs.close(fd)
    complain("cosmic: --version: " .. hasher_trouble)
    return 1
  end
  while true do
    local piece, read_trouble = Fs.take(fd, 1 << 20)
    if piece == nil then
      local _, _ = Fs.close(fd)
      complain("cosmic: --version: " .. path .. ": " .. read_trouble)
      return 1
    end
    if piece == "" then
      break
    end
    hasher:update(piece)
  end
  local _, _ = Fs.close(fd)
  local digest, digest_trouble = hasher:digest()
  if digest == nil then
    complain("cosmic: --version: " .. digest_trouble)
    return 1
  end
  say("cosmic " .. Codec.hex(digest))
  return 0
end

--- `cosmic -e <chunk> [args...]`: runs `chunk` as Lua, the way `lua -e`
--- does, against this binary's own standard library, with no tree around
--- it. The words after it are its `...`; what it returns is the exit
--- code as a file run's is -- see build/exit_status.tl.
--- @param argv the whole command line, `cosmic` at slot 0 and `-e` at
---   slot 1
local function evaluate(argv: {integer:string}): integer
  local chunk = argv[2]
  if chunk == nil then
    complain("cosmic: usage: cosmic -e '<chunk>' [args...]")
    return 2
  end
  local loaded, trouble = load(chunk, "=-e", "t")
  if loaded == nil then
    complain("cosmic: " .. tostring(trouble))
    return 1
  end
  local arguments: {string} = {}
  local slot = 3
  while argv[slot] ~= nil do
    arguments[#arguments + 1] = argv[slot]
    slot = slot + 1
  end
  return exit_status("-e", (loaded(table.unpack(arguments))))
end

--- `cosmic help [verb]`: the whole discovery surface, or one verb's line
--- of it, and a verdict line.
--- @param asked the verb `cosmic <verb> --help` asked about, or nil to
---   read the words after `help` itself
local function help(argv: {integer:string}, asked: string | nil): integer
  local started = Time.monotonic_ns()
  -- Same staleness guard `test` applies: cheap (a fingerprint
  -- compare) when the tool is already fresh, so this keeps help
  -- fast in the ordinary case, and only rebuilds when an edit to
  -- build.docs itself would otherwise go unseen.
  local code = require("build.reboot").stale_exit(argv)
  if code ~= nil then
    return code
  end
  local words: {string} = { asked }
  if asked == nil then
    local line = argv
    local spelled = argv[2] ~= nil and as_option[argv[2]] or nil
    if spelled ~= nil then
      -- A verb spelled as an option (`cosmic --standalone <file>`,
      -- `cosmic -e <chunk>`) is asked about by either spelling.
      line = {}
      for slot, word in pairs(argv) do line[slot] = word end
      line[2] = spelled
    end
    local parsed, parse_trouble = Flags.parse(line, 2, {})
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
  if #words == 1 then
    say(verb_help(words))
    log:verdict("help", true, "1 verb, " .. clock.elapsed_ms(started) .. " ms")
    return 0
  end
  say(help_prefix .. "\n" .. verb_help(Cli.order) .. "\n" .. help_suffix)
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
  -- Never stale-checked, unlike `db`: a staleness check stages the tree,
  -- and this verb reads o/ and nothing else under it. It gives its own
  -- verdict on every exit, a usage error included, so the check main
  -- runs after a verdictless exit 2 never runs for it.
  -- TODO: test that this dispatch neither stale-checks nor scans the
  -- working directory -- run `cosmic sql` in a directory whose tree
  -- would fail to stage -- beside build/verbs_test.tl, which runs this
  -- dispatch through build.invoke; build/sql_test.tl calls sql.run.
  sql = function(argv: {integer:string}): integer
    return require("build.sql").run(argv)
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

--- Whether a verb's command line asks for its help: "--help" or "-h"
--- anywhere after the verb, before a "--", that its options do not
--- name -- as `Flags.dispatch` reads a command's.
local function asks_help(argv: {integer:string},
    options: {string:boolean | Flags.Option}): boolean
  local slot = 2
  while argv[slot] ~= nil and argv[slot] ~= "--" do
    local word = argv[slot]
    if (word == "--help" or word == "-h") and options[word] == nil then
      return true
    end
    slot = slot + 1
  end
  return false
end

local dispatch = {}

--- Runs the command line and answers its exit code.
--- @param argv the command line, with the program's own name at slot 0
function dispatch.main(argv: {integer:string}): integer
  local word = argv[1]
  if word == "test" and argv[2] == "--worker" then
    -- One test in a process of its own, started by `cosmic test`: see
    -- build.test_worker. Never stale-checked or rebuilt, since the run
    -- that started it already was.
    local worker = require("build.test_worker")
    return worker.run(argv)
  end
  if word == "-e" then
    -- Lua's one-liner idiom: like --standalone, no tree and no staleness.
    return evaluate(argv)
  end
  if word == "--version" then
    -- Which build this is, with no tree and no staleness: the digest
    -- the release that published it records.
    return version(argv)
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
  if chosen ~= nil and verb ~= "help" and asks_help(argv, Cli.options[verb] or {}) then
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
      -- TODO: hold the stale tool's usage complaint until this check has
      -- run: a line the rebuilt tool refuses too is complained about
      -- twice, once by each tool, and one it takes still shows the stale
      -- tool's refusal above the rebuild. Each verb would check
      -- staleness before reading its command line, or complain through
      -- a logger that holds usage lines back until main flushes them.
      local stale = require("build.reboot").stale_exit(argv)
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

return dispatch

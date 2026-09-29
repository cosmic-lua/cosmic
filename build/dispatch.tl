--- What the binary's main does with its command line, as a module
--- rather than the main itself, so a test can run a verb in-process
--- (`build.invoke`): `cmd/cosmic/main.tl` hands `dispatch.main` every
--- command line but a test's worker's (`cosmic test --worker`), which it
--- runs itself, so a worker loads nothing of this module's. So
--- `cosmic test --worker` here is `test` refusing an option it does
--- not know.
---
--- A bare path runs a file: cosmic builds the tree that file sits in,
--- into that tree's own database, and then requires the module. The
--- database is the only module source at run time, so running a file
--- and building a project are one path.

local Cli = require("cosmic.cli")
local Codec = require("cosmic.codec")
local Env = require("cosmic.env")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Proc = require("cosmic.proc")
local Store = require("cosmic.store")
local String = require("cosmic.string")
local Time = require("cosmic.time")
local clock = require("build.clock")
local exit_status = require("build.exit_status")
local sys = require("cosmic.sys")
local verb_list = require("build.verb_list")
local verb_spec = require("build.verb_spec")
local verdict = require("build.verdict")

local log = verdict.log

-- Require build modules lazily inside what needs them, so a verb's command
-- line loads that verb's module alone (`verb_list.find`). Only the whole
-- `cosmic help`, which prints every verb's `Spec.takes` and `Spec.exits`,
-- loads them all.

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
      lines[#lines + 1] = "(cosmic.cli " .. symbol .. ": " .. trouble .. ")"
    elseif text == nil then
      lines[#lines + 1] = "(cosmic.cli " .. symbol .. ": not found)"
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

local help_head = [[
Lua's `io`, `os`, and `debug` are not present; code that reaches for
one is told the replacement for the very field it used -- by the
compiler, or at run time by a chunk `load` was handed. `io` is
`cosmic.fs`: `Fs.stdout`, `.stderr`, `.stdin` are descriptors, written
and read with `Fs.put`/`Fs.take`. `os` is `cosmic.time`, `cosmic.env`,
and `cosmic.proc`. `debug` is `cosmic.errors.trace`. `print` still
works, an ordinary global written over the same syscall table
`cosmic.fs` uses.

]]

--- The paragraph's opening: the rest of it is each verb's `Spec.takes`.
local help_takes_intro = "A verb takes paths to narrow it:"

local help_middle = [[

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

]]

--- What follows the list of bare verbs in the paragraph that names them,
--- before the sentence each bare verb's spec gives for its exit codes.
local help_verdict = "ends in a verdict line -- `fix: PASS (...)` or `fix: FAIL (...)` -- and an exit code: 0 when it passed; 1 when it failed; 2 when its command line was refused -- an option, an argument or a verb it does not know; 3 when the tool is older than the tree and did not rebuild itself (`COSMIC_AUTO_BOOT=0`, or a boot that failed). A file run, `--standalone` and `-e` are not verbs of that kind: each prints only what its program prints and exits with what it returns. `--version` is not one either: it prints its one line."

--- `a`, `b` and `c`: the words in backticks, the last after "and".
local function listed(names: {string}): string
  local quoted: {string} = {}
  for _, name in ipairs(names) do
    quoted[#quoted + 1] = "`" .. name .. "`"
  end
  if #quoted < 2 then
    return table.concat(quoted)
  end
  local last = table.remove(quoted)
  return table.concat(quoted, ", ") .. " and " .. last
end

--- `text` broken into lines of at most `width` characters at its spaces
--- (a word longer than that keeps its own line), with no line ending.
local function wrapped(text: string, width: integer): string
  local lines: {string} = {}
  local line = ""
  for word in text:gmatch("%S+") do
    if line == "" then
      line = word
    elseif #line + 1 + #word <= width then
      line = line .. " " .. word
    else
      lines[#lines + 1] = line
      line = word
    end
  end
  if line ~= "" then
    lines[#lines + 1] = line
  end
  return table.concat(lines, "\n")
end

--- The width `cosmic help` wraps the prose it generates to, as the prose
--- written by hand is.
local help_width <const> = 70

--- The clause of `cosmic help`'s paragraph on what verbs take: verbs that take
--- the same share one clause, at the place of the first.
local function takes_clauses(specs: {verb_spec.Spec}): {string}
  local order: {string} = {}
  local names: {string:{string}} = {}
  for _, spec in ipairs(specs) do
    if names[spec.takes] == nil then
      order[#order + 1] = spec.takes
      names[spec.takes] = {}
    end
    local group = names[spec.takes]
    group[#group + 1] = spec.name
  end
  local clauses: {string} = {}
  for _, takes in ipairs(order) do
    clauses[#clauses + 1] = listed(names[takes]) .. " " .. takes
  end
  return clauses
end

--- The closing prose of `cosmic help`: the paragraphs that say what each
--- verb takes and how the bare ones exit are written from the specs
--- (build/verb_spec.tl) and wrapped here; the rest is prose about no one
--- verb in particular, written by hand.
--- @param specs every verb's spec, in help's order
local function help_suffix(specs: {verb_spec.Spec}): string
  local clauses = takes_clauses(specs)
  clauses[#clauses] = "and " .. clauses[#clauses]
  local bare: {string} = {}
  local sentences: {string} = {}
  for _, spec in ipairs(specs) do
    if spec.bare then
      bare[#bare + 1] = spec.name
      sentences[#sentences + 1] = spec.exits or ""
    end
  end
  return help_head .. wrapped(help_takes_intro .. " " .. table.concat(clauses, "; ") .. ".",
      help_width) .. "\n" .. help_middle
    .. wrapped("Every verb but " .. listed(bare) .. " " .. help_verdict .. " " ..
      table.concat(sentences, " "), help_width) .. "\n"
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

--- The module a file is, as its path relative to the root says: a
--- directory's `init.tl` is the directory's, as the build's `inputs`
--- view (build/work.tl) names it.
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
  local name = relative:gsub("/init%.tl$", ""):gsub("%.tl$", "")
  return (name:gsub("/", "."))
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
--- is 0, and anything but a whole number from 0 to 255, or text naming
--- one, exits 2. No function at all is 0.
--- @param file the path named on the command line
--- @param argv the whole command line, `cosmic` at slot 0 and `file` at
---   slot 1; the file sees only what follows it, as its own `argv`
local function run(file: string, argv: {integer:string}): integer
  local importer = require("build.importer")
  local shared_compiles = require("build.shared_compiles")
  local reboot = require("build.reboot")
  local teal = require("build.teal")
  local tree = require("build.tree")
  local work = require("build.work")
  local writer = require("build.writer")
  local root, trouble = root_of(file)
  if root == nil then
    log:complain(trouble)
    return 1
  end
  local name, why = module_of(root, file)
  if name == nil then
    log:complain(why)
    return 1
  end

  local started = Time.monotonic_ns()
  local own_tree, own_trouble = tree.is_own(root)
  if own_tree == nil then
    log:complain(own_trouble)
    return 1
  end
  local handle, open_trouble = work.open(root)
  if handle == nil then
    log:complain(open_trouble)
    return 1
  end
  local staged, stage_trouble = work.stage(handle, own_tree)
  if staged == nil then
    local _, _ = work.close(handle)
    log:complain(stage_trouble)
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

  local result, compile_trouble = importer.compile(handle, built, tool, false,
    shared_compiles.for_build())
  if result == nil then
    local _, _ = work.record(handle, clock.elapsed_ms(started), staged, 0, 0, "FAIL")
    local _, _ = work.close(handle)
    log:complain(compile_trouble)
    return 1
  end
  local written, write_trouble =
    writer.write_result(handle, database, result)
  local _, _ = work.record(handle, clock.elapsed_ms(started), staged, result.compiled,
    result.cached, written and "PASS" or "FAIL")
  local _, _ = work.close(handle)
  if not written then
    log:complain(write_trouble)
    return 1
  end

  -- A test file elsewhere in the tree that `importer.compile` refused
  -- (the return-collision case `analyzer.analyze` and
  -- `with_test_tail` guard against) is silently dropped from the
  -- database otherwise; the file the caller actually asked to run
  -- still compiled fine and still runs below, so this is a warning,
  -- never a reason to fail this invocation.
  for _, line in ipairs(result.refused) do
    log:complain("warning: " .. line)
  end

  local attached, attach_trouble = Store.attach(database)
  if not attached then
    log:complain(attach_trouble)
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
    return exit_status.of(file, entry(arguments))
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
    log:complain("--version takes nothing after it, not " .. argv[2])
    return 2
  end
  local path, path_trouble = Proc.executable()
  if path == nil then
    log:complain("--version: " .. path_trouble)
    return 1
  end
  -- TODO: hash the artifact descriptor startup retained rather than
  -- opening the path again, once the store offers the whole file as it
  -- offers its core (trusted_core): a file renamed over this one after
  -- launch is hashed in its place, and an unlinked one fails.
  local fd, open_trouble = Fs.open_read(path)
  if fd == nil then
    log:complain("--version: " .. path .. ": " .. open_trouble)
    return 1
  end
  local hasher, hasher_trouble = Hash.hasher("sha256")
  if hasher == nil then
    local _, _ = Fs.close(fd)
    log:complain("--version: " .. hasher_trouble)
    return 1
  end
  while true do
    local piece, read_trouble = Fs.take(fd, 1 << 20)
    if piece == nil then
      local _, _ = Fs.close(fd)
      log:complain("--version: " .. path .. ": " .. read_trouble)
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
    log:complain("--version: " .. digest_trouble)
    return 1
  end
  log:say("cosmic " .. Codec.hex(digest))
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
    log:complain("usage: cosmic -e '<chunk>' [args...]")
    return 2
  end
  local loaded, trouble = load(chunk, "=-e", "t")
  if loaded == nil then
    log:complain(tostring(trouble))
    return 1
  end
  local arguments: {string} = {}
  local slot = 3
  while argv[slot] ~= nil do
    arguments[#arguments + 1] = argv[slot]
    slot = slot + 1
  end
  return exit_status.of("-e", (loaded(table.unpack(arguments))))
end

--- `help` is dispatch's own spec (below): it prints the specs of every other
--- verb, so it is declared here and set once `help` exists.
local help_spec: verb_spec.Spec

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
      log:complain("help: " .. parse_trouble)
      log:verdict("help", false, parse_trouble)
      return 2
    end
    words = parsed.words
  end
  if #words > 1 then
    log:complain("help: one verb at a time, not " .. #words)
    log:verdict("help", false, "one verb at a time")
    return 2
  end
  if #words == 1 then
    local known = false
    for _, verb in ipairs(Cli.order) do
      if verb == words[1] then
        known = true
        break
      end
    end
    if not known then
      log:complain("help: no such verb: " .. words[1])
      log:verdict("help", false, "no such verb: " .. words[1])
      return 2
    end
    log:say(verb_help(words))
    log:verdict("help", true, "1 verb, " .. clock.took(started))
    return 0
  end
  local specs = verb_list.specs()
  specs[#specs + 1] = help_spec
  log:say(help_prefix .. "\n" .. verb_help(Cli.order) .. "\n" .. help_suffix(specs))
  log:verdict("help", true, #Cli.order .. " verbs, " .. clock.took(started))
  return 0
end

help_spec = {
  name = "help",
  guide = "none: the verb that describes the others, itself described by `cosmic help help`",
  tests = { "build.verbs_store_test" },
  run = function(argv: {integer:string}): integer
    return help(argv, nil)
  end,
  bare = false,
  takes = "a verb",
}

--- The spec of the verb a command line's first word names, loading the
--- module of that verb alone, or nil for a word that names none. Every
--- verb but the bare ones (`Spec.bare`) ends in a verdict line: their
--- exit status is the verdict, and a usage error is complained about and
--- nothing more. build/json.tl says why.
local function spec_of(word: string): verb_spec.Spec | nil
  if word == "help" then
    return help_spec
  end
  local found = verb_list.find(word)
  if found ~= nil and found.fresh then
    local inner = found.run
    -- A tool older than the tree rebuilds first (`build.reboot`).
    found = {
      name = found.name,
      run = function(argv: {integer:string}): integer
        local stale = require("build.reboot").stale_exit(argv)
        if stale ~= nil then
          return stale
        end
        return inner(argv)
      end,
      bare = found.bare,
    }
  end
  return found
end

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
  local chosen = spec_of(verb)
  if chosen ~= nil and verb ~= "help" and asks_help(argv, Cli.options[verb] or {}) then
    -- `cosmic <verb> --help` is `cosmic help <verb>`.
    local asked = verb
    verb = "help"
    chosen = {
      name = "help",
      run = function(line: {integer:string}): integer
        return help(line, asked)
      end,
      bare = false,
    }
  end
  if chosen ~= nil and verb ~= "help" then
    -- A tree verb started below an established tree's root runs at the
    -- root (`build.tree_root`), its paths still read from here.
    local tree_root = require("build.tree_root")
    local answer = tree_root.move(argv, Cli.options[verb] or {},
      Env.get("HOME"), Env.get("COSMIC_TREE"))
    local moved, refused, note = answer.move, answer.refused, answer.note
    if refused ~= "" then
      log:complain(verb .. ": " .. refused)
      return 2
    end
    if note ~= "" then
      local _, _ = Fs.put(Fs.stderr, "cosmic: " .. verb .. ": " .. note .. "\n")
    end
    if moved ~= nil then
      local entered, enter_trouble = sys.chdir(moved.root)
      if not entered then
        log:complain(verb .. ": " .. moved.root .. ": " .. enter_trouble)
        return 1
      end
      local _, _ = Fs.put(Fs.stderr, "cosmic: " .. verb .. " runs in " .. moved.root ..
        ", the tree this directory is in;\n  paths below are relative to " .. moved.root .. "\n")
      argv = moved.argv
    end
  end
  if chosen ~= nil then
    -- A verb gives its own verdict wherever it has one to give; an exit
    -- it left without one -- its command line refused, a setup failure,
    -- a stale tool -- still ends in one here.
    local code = chosen.run(argv)
    if code == 2 and not verdict.given and not chosen.bare then
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
    if not verdict.given and not chosen.bare then
      log:verdict(verb, code == 0, detail_of(code))
    end
    return code
  end
  if verb:sub(1, 1) == "-" then
    log:complain("no such option: " .. verb)
    log:complain("`cosmic help` is the whole discovery surface")
    return 2
  end
  -- A word that could not be a file to run is a mistyped verb, told as
  -- one rather than as a file that is not there.
  if not verb:find("/", 1, true) and not String.ends_with(verb, ".tl") then
    local exists, _ = Fs.exists(verb)
    if not exists then
      log:complain("no such verb or file: " .. verb .. "; see `cosmic help`")
      return 2
    end
  end
  return run(verb, argv)
end

return dispatch

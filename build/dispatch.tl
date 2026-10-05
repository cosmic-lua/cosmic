--- What the binary's main does with its command line, as a module
--- rather than the main itself, so a test can run a verb in-process
--- ([`build.invoke`]): [`cmd/cosmic/main.tl`] hands [`dispatch.main`] every
--- command line but a test's worker's (`cosmic test --worker`), which it
--- runs itself, so a worker loads nothing of this module's. So
--- `cosmic test --worker` here is `test` refusing an option it does
--- not know.
---
--- A bare path runs a file: cosmic builds the tree that file sits in,
--- into that tree's own database, and then requires the module. The
--- database is the only module source at run time, so running a file
--- and building a project are one path.

local exit_status = require("build.exit_status")
local help_source = require("build.help_source")
local verdict = require("build.verdict")
local type verb_spec = require("build.verb_spec")

local log = verdict.log

-- Require modules lazily inside what needs them, so a verb's command line
-- loads that verb's module alone ([`verb_list.find`]), and `-e`,
-- `--version` and `--standalone`, which a test's child runs most, load
-- none of what the verbs and their help read (build/dispatch_tool_test.tl
-- holds `-e` to that). Only `cosmic help` of a verb loads its spec, and
-- `cosmic help exit` loads them all.

--- The full text of each verb's `cosmic help <verb>`, generated from
--- [`cosmic.cli`]'s own fields ([`cosmic.cli.Cli.run`],
--- [`cosmic.cli.Cli.test`], ...) so this wording is never a second,
--- hand-kept copy of what `cosmic docs build` (or any verb
--- [`cosmic.cli.order`] names) already answers.
--- Falls back to naming the lookup that failed, rather than silently
--- dropping a verb from its own help, if [`cosmic.cli`]'s own database
--- row is ever missing.
--- @param verbs the verbs to print
--- @return each verb's text, by verb
local function verb_help(verbs: {string}, binary_only?: boolean): {string: string}
  local Cli = require("cosmic.cli")
  local docs = require("build.docs")
  local link_text = require("build.link_text")
  local sources: docs.Sources
  if binary_only then
    local handles = require("cosmic.store").databases()
    local public: {boolean} = {}
    for i = 1, #handles do public[i] = true end
    sources = { handles = handles, public = public, opened = {} }
  else
    sources = docs.databases()
  end
  local view, view_trouble = docs.view(sources.handles, sources.public)
  local out: {string: string} = {}
  if view == nil then
    for _, verb in ipairs(verbs) do
      out[verb] = "(cosmic.cli: " .. view_trouble .. ")\n"
    end
    return out
  end
  local names: {string} = {}
  for _, verb in ipairs(verbs) do
    names[#names + 1] = "Cli." .. verb
  end
  local found, trouble = docs.named_all(view, names)
  for _, verb in ipairs(verbs) do
    local symbol = "Cli." .. verb
    local text: string | nil = nil
    if found ~= nil then
      for _, entry in ipairs(found) do
        if entry.symbol == symbol then
          text = link_text.unlinked(entry.text)
          break
        end
      end
    end
    local lines: {string} = {}
    if found == nil then
      lines[#lines + 1] = "(cosmic.cli " .. symbol .. ": " .. trouble .. ")"
    elseif text == nil then
      lines[#lines + 1] = "(cosmic.cli " .. symbol .. ": not found)"
    else
      lines[#lines + 1] = text
      local options = require("cosmic.flags").options(Cli.verbs[verb].spec or {})
      if options ~= "" then
        lines[#lines + 1] = options
      end
    end
    lines[#lines + 1] = ""
    out[verb] = table.concat(lines, "\n")
  end
  return out
end

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

--- What `cosmic help fix` says of how it lays a file out, after the
--- options: the design of the formatter, which no other verb's help
--- needs.
local fix_layout = [[
Each line is decided from the parsed tree, not from adjacent tokens:
every keyword, operator, bracket and the spacing around it, so `local
x <const> = 5` cannot come back as `local x < const > = 5`. Lines keep
the breaks they had and are never rewrapped; type syntax keeps its
original bytes. Nothing is written until the result parses again to
the same tree, comments included.

Two columns of indentation per block apply to lines that open
something: a statement or a block's closing keyword. A line that
continues one keeps its column, moved with its statement, as do table
entries spread over several lines, a comment on a line of its own,
and the body of a record or enum, which is copied as read. Lining
those up is the author's judgement, not the tool's.]]

--- What each verb's own text says of its command line, after its
--- options: what it takes and how it ends, from the verb's spec
--- (build/verb_spec.tl) and wrapped here.
--- @param verb the verb's name
--- @param spec the verb's spec, or nil for a verb that has none (a file
---   run, `--standalone`, `-e`, `--version`)
local function spec_notes(verb: string, spec: verb_spec.Spec | nil): string
  if spec == nil then
    return wrapped("Prints only what its program prints, and exits with what it returns, " ..
        "as `cosmic help exit` says.", help_width)
  end
  local paragraphs: {string} = {}
  if verb == "fix" then
    paragraphs[1] = fix_layout
  end
  paragraphs[#paragraphs + 1] = wrapped("Takes " .. spec.takes .. ".", help_width)
  if spec.exits ~= nil then
    paragraphs[#paragraphs + 1] = wrapped(spec.exits, help_width)
  else
    paragraphs[#paragraphs + 1] = wrapped("Ends in a verdict line, `" .. verb .. ": PASS (...)` or `" ..
        verb .. ": FAIL (...)`, and an exit code: see `cosmic help exit`.", help_width)
  end
  return table.concat(paragraphs, "\n\n")
end

--- The text of `cosmic help exit`: the verdict line and exit codes the
--- verbs share, then how each verb that prints no verdict exits.
--- @param specs every verb's spec, in help's order
local function exit_help(specs: {verb_spec.Spec}): string
  local bare: {string} = {}
  local sentences: {string} = {}
  for _, spec in ipairs(specs) do
    if spec.bare then
      bare[#bare + 1] = spec.name
      sentences[#sentences + 1] = spec.exits or ""
    end
  end
  return wrapped("Every verb but " .. listed(bare) .. " " .. help_verdict .. " " ..
      table.concat(sentences, " "), help_width) .. "\n"
end

--- The text of `cosmic help <verb>`: the verb's docs, its options, then
--- what its spec says of its command line.
--- @param specs every verb's spec, the `help` verb's included
--- @param docs the verb's own text if already read ([`verb_help`])
local function verb_text(verb: string, specs: {verb_spec.Spec}, docs?: string): string
  local spec: verb_spec.Spec | nil = nil
  for _, candidate in ipairs(specs) do
    if candidate.name == verb then spec = candidate end
  end
  return (docs or verb_help({ verb })[verb]) .. "\n" .. spec_notes(verb, spec)
end

--- The verbs spelled as options, by that spelling.
local as_option: {string:string} = {
  ["--standalone"] = "standalone",
  ["-e"] = "eval",
  ["--version"] = "version",
}

--- What the index shows of `verb`'s command line: `cosmic`, what names
--- the verb there, and the verb's own `usage`. A file run is named by
--- the file, and `--standalone`, `-e` and `--version` by their spelling.
local function usage_line(verb: string): string
  local typed = verb
  if verb == "run" then
    typed = ""
  end
  for spelled, name in pairs(as_option) do
    if name == verb then typed = spelled end
  end
  local words: {string} = { "cosmic" }
  if typed ~= "" then words[#words + 1] = typed end
  local command = require("cosmic.cli").verbs[verb]
  local usage = command.usage
  if usage == nil then
    usage = command.spec ~= nil and next(command.spec) ~= nil and "[options]" or ""
  end
  if usage ~= "" then words[#words + 1] = usage end
  return table.concat(words, " ")
end

--- The index `cosmic help` prints: what `cosmic` is, the guides to
--- start from, each verb's usage and purpose in the sections
--- [`cosmic.cli.groups`] names, and where to read more.
local function index_help(): string
  -- TODO: write the index through Flags.dispatch's program help, which
  -- lists every command alphabetically with its `about`. It waits on
  -- that help taking sections and a preamble: the index's groups, and
  -- the prose around them, are what `cosmic help` shows today.
  local Cli = require("cosmic.cli")
  local width = 0
  for _, verb in ipairs(Cli.order) do
    width = math.max(width, #usage_line(verb))
  end
  local lines = {
    "cosmic -- a runtime for self-contained command-line software",
    "",
    "cosmic runs Teal and Lua programs with a standard library that needs",
    "nothing installed, and builds them into single executables. Its",
    "verbs run code, work on a project, do quick jobs at the shell, and",
    "look things up.",
    "",
    "Start here: `cosmic docs doc.guides.quickstart` tours the standard",
    "library, and `cosmic docs doc.guides.project` builds a project with",
    "a module, tests, an example, a record with methods and a program",
    "with commands.",
  }
  for _, group in ipairs(Cli.groups) do
    lines[#lines + 1] = ""
    lines[#lines + 1] = group[1] .. ":"
    for slot = 2, #group do
      local verb = group[slot]
      local usage = usage_line(verb)
      lines[#lines + 1] = "  " .. usage .. string.rep(" ", width - #usage + 2) ..
        Cli.verbs[verb].about
    end
  end
  for _, line in ipairs({
      "",
      "More:",
      "  cosmic help <verb>       a verb's full text, with its options",
      "  cosmic help exit         verdict lines and exit codes",
      "  cosmic docs              every module of the standard library",
      "  cosmic docs <module>     a module, or a symbol such as Fs.read",
      "",
      "Lua's io, os and debug are absent (print stays): `cosmic docs",
      "cosmic.removed` names what replaces each.",
  }) do
    lines[#lines + 1] = line
  end
  return table.concat(lines, "\n") .. "\n"
end

--- The directory a path sits in, absolute.
local function directory_of(path: string): string | nil, string
  local Fs = require("cosmic.fs")
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
  local Fs = require("cosmic.fs")
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
  local Fs = require("cosmic.fs")
  local String = require("cosmic.string")
  local resolved, trouble = Fs.absolute(file)
  if resolved == nil then
    return nil, trouble
  end
  if not String.starts_with(resolved, root .. "/") then
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
--- built, with its arguments (below) set in the global `arg` before its
--- top level runs, and if what it returns is a function, that function is
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
  local Store = require("cosmic.store")
  local Clock = require("cosmic.clock")
  local clock = require("build.clock")
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

  local started = Clock.monotonic_ns()
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
  -- and re-enters this command line ([`reboot.guard`]).
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

  -- A file [`importer.compile`] refused (one whose top-level `return`
  -- collides with the tail generated for its tests) is left out of the
  -- database. The file asked for compiled, so this only warns.
  for _, line in ipairs(result.refused) do
    log:complain("warning: " .. line)
  end

  local attached, attach_trouble = Store.attach(database)
  if not attached then
    log:complain(attach_trouble)
    return 1
  end

  local standalone = require("build.standalone")
  local arguments: {string} = {}
  arguments[0] = file
  local slot = 2
  while argv[slot] ~= nil do
    arguments[slot - 1] = argv[slot]
    slot = slot + 1
  end
  -- The file's top level, which `require` hands its own name and loader
  -- data as `...`, finds its words in `arg`, as `lua file a b` gives them.
  rawset(_G, "arg", arguments)
  local entry = standalone.entry(require(name))
  if entry ~= nil then
    return exit_status.of(file, entry(arguments))
  end
  return 0
end

--- `cosmic --version`: the SHA-256 of the file this binary runs from,
--- read in pieces, as a release's SHA256SUMS names it: `cosmic <hex>`.
local function version(argv: {integer:string}): integer
  local Codec = require("cosmic.codec")
  local Fs = require("cosmic.fs")
  local Hash = require("cosmic.hash")
  local Proc = require("cosmic.proc")
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

--- `cosmic help [verb | exit]`: the index, or one verb's full text, or the
--- exit codes, and a verdict line.
--- @param asked the verb `cosmic <verb> --help` asked about, or nil to
---   read the words after `help` itself
local function help(argv: {integer:string}, asked: string | nil): integer
  local Cli = require("cosmic.cli")
  local Clock = require("cosmic.clock")
  local clock = require("build.clock")
  local plural = require("build.plural")
  local verb_list = require("build.verb_list")
  local started = Clock.monotonic_ns()
  -- Cache maintenance must remain usable when this directory's candidate
  -- cannot build. Its help comes from this binary too, without opening a
  -- candidate database or passing through the stale-tool guard.
  if asked == "cache" or (asked == nil and argv[2] == "cache" and argv[3] == nil) then
    local spec = assert(verb_list.find("cache"))
    log:say(verb_text("cache", { spec }, verb_help({ "cache" }, true).cache) .. "\n")
    log:verdict("help", true, "1 verb, " .. clock.took(started))
    return 0
  end
  -- The staleness guard `test` applies: a fingerprint compare when the
  -- tool is fresh. Help reads build.docs, so an edit to it must rebuild.
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
    local parsed, parse_trouble = require("cosmic.flags").parse(line, 2, { ["--help"] = { about = "the index" }, ["-h"] = { about = "the index" } })
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
    local known = words[1] == "exit"
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
    local specs = verb_list.specs()
    specs[#specs + 1] = help_spec
    if words[1] == "exit" then
      log:say(exit_help(specs))
    else
      log:say(verb_text(words[1], specs) .. "\n")
    end
    log:verdict("help", true, "1 verb, " .. clock.took(started))
    return 0
  end
  log:say(index_help())
  log:verdict("help", true, plural.count(#Cli.order, "verb") .. ", " .. clock.took(started))
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
  takes = "a verb, or `exit`",
}

--- The spec of the verb a command line's first word names, loading the
--- module of that verb alone, or nil for a word that names none. Every
--- verb but the bare ones ([`Spec.bare`]) ends in a verdict line: their
--- exit status is the verdict, and a usage error is complained about and
--- nothing more. build/json.tl says why.
local function spec_of(word: string): verb_spec.Spec | nil
  local verb_list = require("build.verb_list")
  if word == "help" then
    return help_spec
  end
  local found = verb_list.find(word)
  if found ~= nil and found.fresh then
    local inner = found.run
    -- A tool older than the tree rebuilds first ([`build.reboot`]).
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

local dispatch = {}

--- Every text `cosmic help` prints, by what asks for it: `""` is the
--- index, `exit` its page, and each verb of [`cosmic.cli.order`] its own,
--- so a check reads what a user reads.
local function help_texts(): {string: string}
  local Cli = require("cosmic.cli")
  local verb_list = require("build.verb_list")
  local specs = verb_list.specs()
  specs[#specs + 1] = help_spec
  local out: {string: string} = { [""] = index_help(), exit = exit_help(specs) }
  local texts = verb_help(Cli.order)
  for _, verb in ipairs(Cli.order) do
    out[verb] = verb_text(verb, specs, texts[verb])
  end
  return out
end

help_source.provide(help_texts)

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
  -- COSMIC_STANDALONE=1 runs a file (a first word ending .tl, which no
  -- verb does) as `--standalone` does, writing no o/: what a policy's run
  -- of this program is given (cosmic.child), whose user may own no o/ to
  -- build into.
  if word ~= nil and word:sub(-3) == ".tl" and require("cosmic.env").get("COSMIC_STANDALONE") == "1" then
    local shifted: {integer:string} = { [0] = argv[0], [1] = "--standalone" }
    local slot = 1
    while argv[slot] ~= nil do
      shifted[slot + 1] = argv[slot]
      slot = slot + 1
    end
    return require("build.standalone").run(shifted, "this file ran as --standalone, which " ..
        "finds only cosmic.* modules, because COSMIC_STANDALONE=1 (as under `cosmic sandbox " ..
        "--cosmic`); COSMIC_STANDALONE=0 builds the tree around it, which finds its own")
  end
  local Cli = require("cosmic.cli")
  local Env = require("cosmic.env")
  local Flags = require("cosmic.flags")
  local Fs = require("cosmic.fs")
  local String = require("cosmic.string")
  local sys = require("cosmic.sys")
  local verb = word
  if word == nil or word == "-h" or word == "--help" then
    verb = "help"
  end
  local chosen = spec_of(verb)
  -- TODO: dispatch through Flags.dispatch, with each verb a Flags.Command
  -- whose `run` takes the Flags.Parsed. It waits on two things in Flags.
  -- Flags.parse must read a negative number as a word where the spec
  -- declares no digit option: `time` and `rand` set one aside before
  -- parsing (build/time.tl's `protect`, build/rand.tl's `marked`), which
  -- Flags.dispatch's parse would refuse. Flags.dispatch must take a
  -- default command for a first word that names none: a file run
  -- (`cosmic <file.tl> args`, whose program arguments Flags.parse would
  -- refuse as options) and `-e`, `--standalone` and `--version` are
  -- verbs by no command name.
  local options = chosen ~= nil and Cli.verbs[verb].spec or {}
  -- The words of a program a verb runs are not the verb's to read.
  local own = argv
  if chosen ~= nil and chosen.program_slot ~= nil then
    local at = chosen.program_slot(argv)
    if at ~= nil then
      own = {}
      for slot = 1, at - 1 do own[slot] = argv[slot] end
    end
  end
  if chosen ~= nil and verb ~= "help" and Flags.asks_help(own, 2, options) then
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
    -- root ([`build.tree_root`]), its paths still read from here.
    local tree_root = require("build.tree_root")
    local answer = tree_root.move(argv, options, Env.get("HOME"), Env.get("COSMIC_TREE"))
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

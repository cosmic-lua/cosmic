--- What the binary's main does with its command line, as a module
--- rather than the main itself, so a test can run a verb in-process
--- ([`build.invoke`]): [`cmd/cosmic/main.tl`] hands [`Dispatch.main`] every
--- command line but a test's worker's (`cosmic test --worker`) and the
--- sandbox probe's (`cosmic test --sandbox-probe`), which it runs itself,
--- so neither loads anything of this module's. So `cosmic test --worker`
--- here is `test` refusing an option it does not know.
---
--- A bare path runs a file: cosmic builds the tree that file sits in,
--- into that tree's own database, and then requires the module. The
--- database is the only module source at run time, so running a file
--- and building a project are one path.

local exit_status = require("build.exit_status")
local help_source = require("build.help_source")
local logger = require("build.logger")
local type Failure = require("cosmic.failure")
local type verb_spec = require("build.verb_spec")
local type flags = require("cosmic.flags")
local type standalone_type = require("build.standalone")
local type tree_type = require("build.tree")

local log = logger.log

-- Require modules lazily inside what needs them, so a verb's command line
-- loads that verb's module alone ([`verb_list.find`]), and `-e`,
-- `--version` and `--standalone`, which a test's child runs most, load
-- none of what the verbs and their help read (build/dispatch_tool_test.tl
-- holds `-e` to that). Only `cosmic help` of a verb loads its spec, and
-- `cosmic help exit` loads them all.

--- The verbs spelled as options, by that spelling.
local as_option: {string:string} = {
  ["--standalone"] = "standalone",
  ["-e"] = "eval",
  ["--version"] = "version",
}

--- How `cosmic help` names `verb` on its page's usage line: `cosmic`
--- and the word the verb is typed as, or `cosmic` alone for a file run.
local function typed_name(verb: string): string
  if verb == "run" then
    return "cosmic"
  end
  for spelled, name in pairs(as_option) do
    if name == verb then return "cosmic " .. spelled end
  end
  return "cosmic " .. verb
end

--- The width Flags.help wraps a verb's options and examples to.
local page_width <const> = 80

--- The full text of each verb's `cosmic help <verb>`, generated from
--- the overview of the verb's own module ([`cosmic.cli.run`],
--- [`cosmic.cli.test`], ...) so this wording is never a second,
--- hand-kept copy of what `cosmic docs build` (or any verb
--- [`cosmic.cli.order`] names) already says.
--- Falls back to naming the lookup that failed, rather than silently
--- dropping a verb from its own help, if a verb module's database row
--- is ever missing.
--- @param verbs the verbs to print
--- @return each verb's text, by verb
local function verb_help(verbs: {string}, binary_only?: boolean): {string: string}
  local Cli = require("cosmic.cli")
  local docs = require("build.docs")
  local link_text = require("cosmic.internal.link_text")
  local sources: docs.Sources
  if binary_only == true then
    local handles = require("cosmic.store").databases()
    local public: mut {boolean} = {}
    for i = 1, #handles do public[i] = true end
    sources = { handles = handles, public = public, opened = {} }
  else
    sources = docs.databases()
  end
  local view, view_trouble = docs.view(sources.handles, sources.public)
  local out: mut {string: string} = {}
  if view == nil then
    for _, verb in ipairs(verbs) do
      out[verb] = "(cosmic.cli." .. verb .. ": " .. view_trouble .. ")\n"
    end
    return out
  end
  local names: mut {string} = {}
  for _, verb in ipairs(verbs) do
    names[#names + 1] = "cosmic.cli." .. verb
  end
  local found, trouble = require("cosmic.doc").named_all(view, names)
  for _, verb in ipairs(verbs) do
    local module = "cosmic.cli." .. verb
    local text: string? = nil
    if found ~= nil then
      for _, entry in ipairs(found) do
        if entry.module == module and entry.symbol == "" then
          text = link_text.unlinked(entry.text)
          break
        end
      end
    end
    local lines: mut {string} = {}
    if found == nil then
      lines[#lines + 1] = "(" .. module .. ": " .. tostring(trouble) .. ")"
    elseif text == nil then
      lines[#lines + 1] = "(" .. module .. ": not found)"
    else
      local command = Cli.verbs[verb]
      if command ~= nil then
        lines[#lines + 1] = require("cosmic.flags").help(command, typed_name(verb), page_width)
        lines[#lines + 1] = ""
      end
      lines[#lines + 1] = text
    end
    lines[#lines + 1] = ""
    out[verb] = table.concat(lines, "\n")
  end
  return out
end

--- What follows the list of bare verbs in the paragraph that names them,
--- before the sentence each bare verb's spec gives for its exit codes.
local help_exit = "exits 0 when it passed; 1 when it failed; 2 when its command line was refused -- an option, an argument or a verb it does not know; 3 when the tool is older than the tree and did not rebuild itself (`COSMIC_AUTO_BOOT=0`, or a boot that failed); 4 when `test` or `build` found that the tree, or a module a named run needs, did not compile -- the checker refused it, or it does not parse -- even when tests failed too, since they ran on a tree that is not whole; a failing test alone is 1, as is a line-coverage floor `test --min` or `--min-file` was given and the run did not meet, as is a failure to read, stage or write (a database, a file). Exit 5 is a run that could not do what was asked: a file it could not read or write, input data it refused, or a request that failed; the verbs whose sentences below name it give it. Its stdout is its result alone. Its stderr says what went wrong, and a run that passed ends there in a summary of how it went, `fix: 3 Teal files, 0 fixed, 12 ms`. `test`'s summary is its result instead, last on stdout once its tests ran, whether they passed or not: `test: 9 tests passed in 2 modules; ...` or `test: 2 of 9 tests failed, ...` (a floor not met adds `; coverage floor not met: ...` to either)."

--- What `cosmic help exit` says of what is not a verb.
local help_programs = "A file run, `--standalone` and `-e` are not verbs of that kind: each prints only what its program prints and exits with what it returns, or 4 when the file, or a module it requires, did not compile (a program that returns 4 itself reads the same). `--version` is not one either: it prints its one line."

--- `a`, `b` and `c`: the words in backticks, the last after "and".
local function listed(names: {string}): string
  local quoted: mut {string} = {}
  for _, name in ipairs(names) do
    quoted[#quoted + 1] = "`" .. name .. "`"
  end
  if #quoted < 2 then
    return table.concat(quoted)
  end
  local last = assert(table.remove(quoted))
  return table.concat(quoted, ", ") .. " and " .. last
end

--- `text` broken into lines of at most `width` characters at its spaces
--- (a word longer than that keeps its own line), with no line ending.
local function wrapped(text: string, width: integer): string
  local lines: mut {string} = {}
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

--- The columns a line of the index may reach. A usage too wide to
--- leave room for its summary takes a line of its own, with the summary
--- under it.
local index_width <const> = 80

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
local function spec_notes(verb: string, spec: verb_spec.Spec?): string
  if spec == nil then
    return wrapped("Prints only what its program prints, and exits with what it returns, " ..
        "as `cosmic help exit` says.", help_width)
  end
  local paragraphs: mut {string} = {}
  if verb == "fix" then
    paragraphs[1] = fix_layout
  end
  paragraphs[#paragraphs + 1] = wrapped("Takes " .. spec.takes .. ".", help_width)
  local exits = spec.exits
  if exits ~= nil then
    paragraphs[#paragraphs + 1] = wrapped(exits, help_width)
  elseif verb == "test" then
    paragraphs[#paragraphs + 1] = wrapped("Once its tests ran, ends its stdout in their summary, " ..
        "`test: 9 tests passed in 2 modules; ...` or `test: 2 of 9 tests failed, ...`, and exits " ..
        "as `cosmic help exit` says.", help_width)
  elseif spec.summarizes_failure == true then
    paragraphs[#paragraphs + 1] = wrapped("Ends a run with a summary on stderr, `" .. verb ..
        ": ...`, whether it passed or failed, and exits as `cosmic help exit` says.", help_width)
  else
    paragraphs[#paragraphs + 1] = wrapped("Ends a run that passed with a summary on stderr, `" ..
        verb .. ": ...`, and exits as `cosmic help exit` says.", help_width)
  end
  return table.concat(paragraphs, "\n\n")
end

--- The text of `cosmic help exit`: the exit codes and summary the verbs
--- share, then how each bare verb exits.
--- @param specs every verb's spec, in help's order
local function exit_help(specs: {verb_spec.Spec}): string
  local bare: mut {string} = {}
  local failing: mut {string} = {}
  local sentences: mut {string} = {}
  for _, spec in ipairs(specs) do
    if spec.bare then
      bare[#bare + 1] = spec.name
      sentences[#sentences + 1] = spec.exits or ""
    end
    if spec.summarizes_failure == true then
      failing[#failing + 1] = spec.name
    end
  end
  return wrapped("Every verb but " .. listed(bare) .. " " .. help_exit .. " " ..
      listed(failing) .. " end a failed run in one too: what it found nothing of, or what is left " ..
      "to fix. " ..
      help_programs .. " " .. table.concat(sentences, " "), help_width) .. "\n"
end

--- `help` is dispatch's own spec (below): [`spec_for`] and `help` read it, so
--- it is declared here and set once `help` exists.
local help_spec: verb_spec.Spec?

--- The spec `help` reads for `verb`: its own for `help`, else the verb's
--- from its module alone ([`verb_list.find`]), or nil for a verb with
--- none (`run`, `standalone`, `eval`, `version`). Loading no other verb's
--- module keeps `cosmic help <verb>` and `cosmic <verb> --help` from
--- paying for every verb's requires.
local function spec_for(verb: string): verb_spec.Spec?
  if verb == "help" then return help_spec end
  return require("build.verb_list").find(verb)
end

--- The text of `cosmic help <verb>`: the verb's docs, its options, then
--- what its spec says of its command line.
--- @param spec the verb's spec ([`spec_for`])
--- @param docs the verb's own text if already read ([`verb_help`])
local function verb_text(verb: string, spec: verb_spec.Spec?, docs?: string): string
  local text = docs or verb_help({ verb })[verb]
  assert(text, "verb_help answers each verb it is asked")
  return text .. "\n" .. spec_notes(verb, spec)
end

--- What a refusal of the mistyped verb `word` ends with when any of
--- `verbs` is near it by [`Flags.nearest`]'s rule, as [`cosmic.flags`]
--- ends its own: "; did you mean test?". "" when none is.
local function meant(word: string, verbs: {string}): string
  local found = require("cosmic.flags").nearest(word, verbs)
  if #found == 0 then
    return ""
  elseif #found == 1 then
    return "; did you mean " .. found[1] .. "?"
  end
  return "; did you mean one of " .. table.concat(found, ", ") .. "?"
end

--- The index `cosmic help` prints: what `cosmic` is, the guides to
--- start from, each verb's usage and purpose in the sections
--- [`cosmic.cli.groups`] names, and where to read more. It is the help
--- [`Flags.dispatch`] writes of a program whose commands are the verbs,
--- each listed as it is typed: a file run by the file, and
--- `--standalone`, `-e` and `--version` by their spelling.
local function index_help(): string
  local Cli = require("cosmic.cli")
  local Flags = require("cosmic.flags")
  local titles: mut {string} = {}
  local order: mut {string} = {}
  local group_of: mut {string: string} = {}
  for _, group in ipairs(Cli.groups) do
    local title = assert(group[1], "a group of Cli.groups opens with its title")
    titles[#titles + 1] = title
    for slot, verb in ipairs(group) do
      if slot > 1 then
        order[#order + 1] = verb
        group_of[verb] = title
      end
    end
  end
  local typed: mut {string: string} = { run = "" }
  for spelled, name in pairs(as_option) do typed[name] = spelled end
  local commands: mut {string: Flags.Command} = {}
  for _, verb in ipairs(order) do
    local command = assert(Cli.verbs[verb], "a grouped verb is one of Cli.verbs")
    commands[verb] = { spec = command.spec, about = assert(command.about), usage = command.usage,
      group = group_of[verb], typed = typed[verb] }
  end
  local index = assert(Flags.dispatch({ "--help" }, 1, commands, "cosmic", {
    groups = titles, order = order, usages = true, width = index_width,
    before = table.concat({
      "cosmic -- a runtime for self-contained command-line software",
      "",
      "cosmic runs Teal and Lua programs with a standard library that needs",
      "nothing installed, and builds them into single executables. Its",
      "verbs run code, work on a project, do quick jobs at the shell, and",
      "look things up.",
      "",
      "Start here: `cosmic docs quickstart` tours the standard library, and",
      "`cosmic docs project` builds a project with a module, tests, an",
      "example, a record with methods and a program with commands.",
    }, "\n"),
    after = table.concat({
      "More:",
      "  cosmic help <verb>       a verb's full text, with its options",
      "  cosmic help exit         exit codes and summaries",
      "  cosmic docs              every module of the standard library",
      "  cosmic docs <module>     a module, or a symbol such as Fs.read",
      "  cosmic - [args]          run the Teal that standard input holds",
      "  - for a file             standard input or output, where help says so",
      "",
      "Lua's io, os and debug are absent (print stays): `cosmic docs",
      "cosmic.removed` names what replaces each.",
    }, "\n"),
  }))
  return index.help .. "\n"
end

--- `command` as [`line_refusal`] hands it over: its options, usage and subcommands, each with a `run` that does
--- nothing.
local function described_only(command: flags.Command): flags.Command
  local given = command.subcommands
  local subcommands: mut {string:flags.Command} = {}
  if given ~= nil then
    for word, sub in pairs(given) do subcommands[word] = described_only(sub) end
  end
  -- `typed` stays: a subcommand typed by no word (`fetch`'s `get`) is what a line naming none runs.
  return { spec = command.spec, usage = command.usage, typed = command.typed,
    subcommands = if given ~= nil then subcommands else nil end, run = function(_: flags.Parsed): integer
      return 0
    end }
end

--- Why Flags.dispatch refuses the line `own` of the verb `verb`, whose options `command` names, or "" where it
--- takes it: "test: no such option: --jbs; did you mean --jobs?; usage: cosmic test [options] [path...]".
--- Nothing is run: the verb reads its own line after.
local function line_refusal(verb: string, command: flags.Command, own: {string}): string
  local ran, why = require("cosmic.flags").dispatch(own, 1, { [verb] = described_only(command) }, "cosmic")
  return if ran == nil then why else "" end
end

--- The tree a file run builds, and why it is that one.
local record Root
  --- The tree's directory, absolute.
  dir: string
  --- Which rule chose it, as a hint names it: the working directory, or the file's own directory.
  chosen: string
  --- The file run, absolute.
  file: string
end

--- The tree a file run builds: the working directory when the file
--- sits under it, so `cosmic cmd/notes/main.tl` from a project's root
--- builds the project as `test` and `build` do and the file reaches
--- the rest of it; the file's own directory otherwise, so a file
--- anywhere else runs on its own.
local function root_of(file: string): Root?, string
  local Fs = require("cosmic.fs")
  local resolved, trouble = Fs.absolute(file)
  if resolved == nil then
    return nil, tostring(trouble)
  end
  local here, _ = Fs.absolute(".")
  if here ~= nil and Fs.within(resolved, here) then
    return { dir = here, chosen = "the working directory, which holds the file", file = resolved }, ""
  end
  return {
    dir = Fs.dirname(resolved),
    chosen = "the file's own directory, since the working directory does not hold the file",
    file = resolved,
  }, ""
end

--- The module a file is, as its path relative to the root says: a
--- directory's `init.tl` is the directory's, as the build's `inputs`
--- view (build/work.tl) names it.
local function module_of(root: string, file: string): string?, string
  local Fs = require("cosmic.fs")
  local String = require("cosmic.string")
  local resolved, trouble = Fs.absolute(file)
  if resolved == nil then
    return nil, tostring(trouble)
  end
  -- TODO: refuse a tree of `/` (a file run from `/`, or of a file there) with a message that says to run the file
  -- from its project's root, before staging it: `root .. "/"` is `//` there, so a file under it is said not to be.
  if not String.starts_with(resolved, root .. "/") then
    return nil, file .. " is not inside " .. root
  end
  local relative = resolved:sub(#root + 2)
  if String.ends_with(relative, ".lua") then
    return nil, file .. " is Lua, and cosmic runs Teal, checked: rename it to " ..
      (relative:gsub("%.lua$", ".tl")) .. " and run `cosmic fix` on it to see what the checker asks of it"
  end
  if not String.ends_with(relative, ".tl") then
    return nil, file .. " is not a Teal source: cosmic runs files that end in .tl"
  end
  local name = relative:gsub("/init%.tl$", ""):gsub("%.tl$", "")
  return (name:gsub("/", ".")), ""
end

--- `trouble`, the reason a file run's build failed, with a line saying `--standalone` where the file it names is not the
--- file run and the file run requires no module of the project: `--standalone` finds only `cosmic.*` modules, so
--- it is the way to run such a file past a refused file beside it, and no way for one that requires a project module,
--- directly or through another. A file that does not parse gets no hint.
--- @param file the path named on the command line
--- @param name the module of that file
local function with_standalone_hint(trouble: string, file: string, name: string): string
  local culprit = trouble:match("^([^:\n]+):")
  if culprit == nil or not (culprit:match("%.tl$") ~= nil or culprit:match("%.tmpl$") ~= nil) then
    return trouble
  end
  local module = culprit:gsub("%.tmpl$", ""):gsub("%.tl$", ""):gsub("/init$", ""):gsub("/", ".")
  if module == name then
    return trouble
  end
  local Fs = require("cosmic.fs")
  local source, _ = Fs.read(file)
  if source == nil then
    return trouble
  end
  -- The requires as the checker's syntax tree reads them, the way `--standalone` itself reads them.
  local required, _ = require("build.standalone").requires(file, source)
  if required == nil then
    return trouble
  end
  for _, needed in ipairs(required) do
    if needed:sub(1, 7) ~= "cosmic." then
      return trouble
    end
  end
  return trouble .. "\n" .. "cosmic: " .. culprit .. " is not the file run, but a run builds the tree around its file; " ..
    "`cosmic --standalone " .. file .. "` (or COSMIC_STANDALONE=1) runs the file alone"
end

--- `trouble`, the reason a file run's build failed, with a line naming the tree the run built and the rule that chose
--- it where the checker found a `require` of a module the tree does not hold (`require_unknown`): a file run from
--- below its project's root, or from outside it, builds a smaller tree, which holds no module the file names from the
--- project's root. The line says only what the run knows; which project the file belongs to, it cannot tell.
local function with_tree_hint(trouble: string, root: Root): string
  if trouble:find("(require_unknown)", 1, true) == nil then
    return trouble
  end
  -- TODO: leave out the checker's "did you mean" of `trouble` where this hint is given, once lang/check/init.tl's
  -- `require_unknown` suggestion can be told the project's root: from a directory above the project it names the
  -- module from the run's tree (`proj.m`), a require that works only from there.
  return trouble .. "\n" .. "cosmic: this run built the tree " .. root.dir .. ", " .. root.chosen ..
    "; a module is named from the tree's root, so if the file belongs to a project elsewhere, run it from that " ..
    "project's root"
end

--- Runs the module `name`, the file `file` of the tree `tree_root`, from the projection `database` a build of the tree
--- wrote, with `argv` as the run's command line, the file at slot 1.
local function run_projected(file: string, argv: {string}, tree_root: Root, name: string, database: string): integer
  local Store = require("cosmic.store")
  -- TODO: attach this run's published projection before its writer releases
  -- the publication lock, once writer exposes a stable-consumption callback:
  -- another successful build can replace the path before this attach.
  -- The projection is the tool's own output of this run, not a file it was handed.
  local attached, attach_trouble = Store.attach(database, { unchecked_bytecode = true })
  if not attached then
    log:complain(tostring(attach_trouble))
    return 1
  end

  local standalone = require("build.standalone")
  -- `arg[0]` is the script, so the table is keyed by position and not a sequence.
  local arguments: mut {integer: string} = {}
  arguments[0] = file
  local slot = 2
  local given = argv[slot]
  while given ~= nil do
    arguments[slot - 1] = given
    slot = slot + 1
    given = argv[slot]
  end
  -- The file's top level, which `require` hands its own name and loader
  -- data as `...`, finds its words in `arg`, as `lua file a b` gives them.
  rawset(_G as {string:any}, "arg", arguments) -- checked: cast_refused, unchecked_binding
  -- What [`Proc.relaunch`] takes as `script`, so the program can start itself again.
  local source_run = require("cosmic.internal.source_run")
  source_run.script = tree_root.file
  -- What [`Assets.default`] reads to serve a program's own `cmd/<name>/static/` from disk, as a built one carries it.
  source_run.main = name
  source_run.projection = database
  local load_module = require("build.load_module")
  local entry = standalone.entry(load_module.load(name))
  if entry ~= nil then
    return exit_status.of(file, entry(arguments))
  end
  return 0
end

--- Runs `file`, the module `name` of the tree `tree_root`, as `run` does where its last good run stands
--- ([`build.run_stamp`]), but without the working database's write lock, which another run holds: the database read
--- without writing ([`work.settled_read`]) stands as the tree does, the tool is as new as cosmic's own tree
--- ([`reboot.settled`]), and the projection that run left is the one a build would write again. Nil where any of
--- that does not hold, or cannot be read: the run then waits for the lock, as ever. The projection is attached as
--- [`run_projected`] attaches it, so a build that publishes another meanwhile is one the locked run meets too.
--- @param standing what the tree is to the running tool ([`tree.standing`])
local function run_unlocked(file: string, argv: {string}, tree_root: Root, name: string,
                            standing: tree_type.Standing): integer?
  local build_paths = require("build.paths")
  local root = tree_root.dir
  local dir, _ = build_paths.optional(root)
  if dir == nil then return nil end
  local db, _ = require("build.work").settled_read(root, standing)
  if db == nil then return nil end
  if standing.own and not require("build.reboot").settled(db) then
    local _, _ = db:close()
    return nil
  end
  local run_stamp = require("build.run_stamp")
  local key = run_stamp.key(db, root, standing.own, run_stamp.own_tool(), name)
  local _, _ = db:close()
  local database = build_paths.under(dir).projection
  if key == nil or not run_stamp.holds(dir, key, name, database) then return nil end
  return run_projected(file, argv, tree_root, name, database)
end

-- TODO: hold a module of the tree that a run calls as an entry point ([`Declarations.Input.entry`]); the checker holds
-- only a program's cmd/<name>/main.tl and a file run alone so, since any module of a tree may be run.

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
--- @param argv the whole command line, `file` at slot 1; the file sees only
---   what follows it, as its own `argv`
local function run(file: string, argv: {string}): integer
  local Clock = require("cosmic.clock")
  local clock = require("build.clock")
  local type importer = require("build.importer")
  local Store = require("cosmic.store")
  local tree = require("build.tree")
  local build_paths = require("build.paths")
  local work = require("build.work")
  local tree_root, trouble = root_of(file)
  if tree_root == nil then
    log:complain(trouble)
    return 1
  end
  local root = tree_root.dir
  local name, why = module_of(root, file)
  if name == nil then
    log:complain(why)
    return 1
  end

  local started = Clock.monotonic_ns()
  local standing, standing_trouble = tree.standing(root)
  if standing == nil then
    log:complain(standing_trouble)
    return 1
  end
  -- In a project, a tool older than the checkout it was built from
  -- rebuilds from that checkout and re-enters this command line first
  -- ([`reboot.checkout_exit`]); cosmic's own tree is checked below. A release is built from none.
  if not standing.own and Store.meta("built_from") ~= nil then
    local code = require("build.reboot").checkout_exit(argv, root)
    if code ~= nil then
      return code
    end
  end
  -- Where another run holds the write lock, a module whose last good run stands as the tree does runs without waiting
  -- for it ([`run_unlocked`]).
  local doing = "running " .. file
  local opening, try_trouble = work.try_open(root, doing)
  if opening == nil then
    log:complain(try_trouble)
    return 1
  end
  local held = opening.handle
  if held == nil and opening.other_schema == nil then
    local code = run_unlocked(file, argv, tree_root, name, standing)
    if code ~= nil then
      return code
    end
  end
  if held == nil then
    local waited, open_trouble = work.open(root, nil, doing)
    if waited == nil then
      log:complain(open_trouble)
      return 1
    end
    held = waited
  end
  local handle = held
  local staged, stage_trouble = work.stage(handle, standing)
  if staged == nil then
    local _, _ = work.close(handle)
    log:complain(stage_trouble)
    return 1
  end

  -- A stale tool refuses, or rebuilds itself or has zig boot the core
  -- and re-enters this command line ([`reboot.guard`]).
  if standing.own then
    local code = require("build.reboot").guard(handle, root, argv)
    if code ~= nil then
      return code
    end
  end

  -- The compiler this binary is, as the build that made it recorded ([`run_stamp.own_tool`]).
  local run_stamp = require("build.run_stamp")
  local tool = run_stamp.own_tool()

  local database = build_paths.under(handle.dir).projection

  -- Nothing the build reads has moved since the last good run of this module: the projection that run left is the
  -- one a build would write again ([`build.run_stamp`]).
  local stamp_key = run_stamp.key(handle.db, root, standing.own, tool, name)
  if stamp_key ~= nil and run_stamp.holds(handle.dir, stamp_key, name, database) then
    local _, _ = work.close(handle)
    return run_projected(file, argv, tree_root, name, database)
  end

  local outcome: importer.Outcome = { refused = false }
  local result, compile_trouble = require("build.importer").compile_for(handle, tool, name,
    require("build.shared_compiles").for_build(), outcome)
  if result == nil then
    local _, _ = work.record(handle, clock.elapsed_ms(started), staged, 0, 0, "FAIL")
    local hinted = with_tree_hint(with_standalone_hint(compile_trouble, file, name), tree_root)
    local _, _ = work.close(handle)
    log:complain(require("build.error_render").annotated(hinted, function(named: string): string?
      local text, _ = require("cosmic.fs").read(root .. "/" .. named)
      return text
    end))
    return if outcome.refused then exit_status.uncompiled else 1 end
  end
  local writer = require("build.writer")
  local written, write_trouble = writer.write_recorded(handle, database, result, started, staged)
  -- Keyed again over the plan this build made, the one the next run's stage finds, and the links the write signed
  -- ([`build.run_stamp`]).
  local signed = writer.signed()
  local made_key = if written and signed.signature ~= "" and #result.refused == 0 and #result.left_out == 0 then
    run_stamp.key(handle.db, root, standing.own, tool, name, signed.links) else nil end
  local _, _ = work.close(handle)
  if not written then
    log:complain(write_trouble)
    return 1
  end
  if made_key ~= nil then
    run_stamp.mark(handle.dir, made_key, name, signed.signature)
  end

  -- A file [`importer.compile`] refused (one whose top-level `return`
  -- collides with the tail generated for its tests) is left out of the
  -- database. The file asked for compiled, so this only warns.
  for _, line in ipairs(result.refused) do
    log:complain("warning: " .. line)
  end
  -- A broken file the file run does not reach is left out of the database
  -- too, the run going on without it ([`importer.compile_for`]).
  -- TODO: keep a left-out module's last good rows in the projection, once
  -- the writer can carry a module's rows from the projection it replaces:
  -- until a whole build, `cosmic docs` and `uses` miss it and what requires it.
  for _, line in ipairs(result.left_out) do
    log:complain("warning: " .. line)
  end
  return run_projected(file, argv, tree_root, name, database)
end

--- Runs `file` as `--standalone` does where a tree run of it would build nothing the file needs
--- ([`standalone.runs_alone`]) and the tree is not cosmic's own, whose `cosmic.*` modules are its sources: so it
--- stages nothing and writes no build directory. nil where the file runs in its tree, which then reads, checks and
--- reports it as ever. The run is still a source run of the module the file is: [`Proc.relaunch`] names the file as
--- its `script`, and its top level finds its module's name as its `...`. A tool built from a checkout holds itself
--- to it first, as the tree run does ([`reboot.checkout_exit`]); a release is built from none.
--- @param argv the whole command line, the file at slot 1
local function run_alone(file: string, argv: {string}): integer?
  local Fs = require("cosmic.fs")
  local standalone = require("build.standalone")
  local source, _ = Fs.read(file)
  if source == nil then
    return nil
  end
  local tree_root, _ = root_of(file)
  if tree_root == nil then
    return nil
  end
  local name, _ = module_of(tree_root.dir, file)
  -- Judged by its path from the tree's root, as the tree names its modules, not as it was typed.
  if name == nil or not standalone.runs_alone(tree_root.file:sub(#tree_root.dir + 2), source) then
    return nil
  end
  local standing, _ = require("build.tree").standing(tree_root.dir)
  if standing == nil or standing.own then
    return nil
  end
  if require("cosmic.store").meta("built_from") ~= nil then
    local code = require("build.reboot").checkout_exit(argv, tree_root.dir)
    if code ~= nil then
      return code
    end
  end
  local source_run = require("cosmic.internal.source_run")
  source_run.script = tree_root.file
  source_run.main = name
  local shifted: mut {string} = { "--standalone" }
  for _, given in ipairs(argv) do
    shifted[#shifted + 1] = given
  end
  return standalone.run(shifted, nil, name)
end

--- [`reboot.stale_exit`] for a verb run in the working directory. It loads
--- build.reboot, and the modules it requires, only where the tool may be
--- held to a tree: where the working directory cannot be resolved, is
--- cosmic's own tree, or is refused by [`tree.standing`], and where the
--- tool is the own tool of a checkout that is still cosmic's own tree
--- ([`tree.checkout`]). A release, or a copy of a tool run from outside its
--- checkout's build directory, is held to none in a project. So `help`'s
--- index, and the `fresh` verbs whose own modules do not require
--- build.reboot, start without it there.
local function stale_exit(argv: {string}, reads: boolean): integer?
  local Fs = require("cosmic.fs")
  local here, _ = Fs.absolute(".")
  if here ~= nil then
    local tree = require("build.tree")
    local standing, _ = tree.standing(here)
    if standing ~= nil and not standing.own and
        tree.checkout(require("cosmic.store").meta("built_from")) == nil then
      return nil
    end
  end
  return require("build.reboot").stale_exit(argv, reads)
end

--- [`reboot.checkout_exit`] for a verb run in the project at `root`. It
--- loads build.reboot only where the tool is the own tool of a checkout
--- that is still cosmic's own tree ([`tree.checkout`]): any other tool,
--- a release among them, holds itself to no checkout, and that check
--- returns nil for it.
local function checkout_exit(argv: {string}, root: string): integer?
  if require("build.tree").checkout(require("cosmic.store").meta("built_from")) == nil then
    return nil
  end
  return require("build.reboot").checkout_exit(argv, root)
end

--- Says on standard error where a run that holds the tool to no tree (`--version`, `-e`, `-`) uses a tool older than the
--- checkout it was built from ([`reboot.stale_note`]). It reads and rebuilds nothing; a release, which records no
--- checkout, loads nothing here.
local function say_if_stale()
  local built = require("cosmic.store").meta("built_from")
  if built == nil or require("build.tree").checkout(built) == nil then return end
  local note = require("build.reboot").stale_note()
  if note ~= nil then log:complain(note) end
end

--- The SHA-256 of the file at `path`, hashed once per file: the digest is
--- kept in `Fs.cache_dir("version")`, named by the file's device, inode,
--- size, mtime and ctime, so a later run of the same file reads it there
--- in place of hashing 27 MB again. A file written over, renamed onto or
--- touched moves its ctime and is hashed again. The cache only saves
--- time: a cache that cannot be read or written is passed over, with no
--- word, and the file is hashed.
local function file_digest(path: string): (string) | (nil, Failure)
  local Fs = require("cosmic.fs")
  local Hash = require("cosmic.hash")
  local st, _ = Fs.stat(path)
  local key, entry = "", ""
  if st ~= nil then
    key = ("%d %d %d %d.%09d %d.%09d"):format(st.dev, st.ino, st.size,
      st.mtime, st.mtime_ns, st.ctime, st.ctime_ns)
    local dir, _ = Fs.cache_dir("version")
    if dir ~= nil then
      entry = dir .. "/digest"
      local kept, _ = Fs.read(entry)
      if kept ~= nil then
        local named, hex = kept:match("^(.-)\t(%x+)\n$")
        if named == key and hex ~= nil and #hex == 64 then return hex end
      end
    end
  end
  local digest, trouble = Hash.hex_file("sha256", path)
  if digest == nil then return nil, trouble end
  -- A file changed within the last two seconds may change again with
  -- the same size inside one coarse timestamp tick, and keep this key:
  -- such a file is hashed each time until it settles.
  if entry ~= "" and st ~= nil and require("cosmic.clock").now_ns() // 1000000000 - math.max(st.mtime, st.ctime) >= 2 then
    local _, _ = Fs.write(entry, key .. "\t" .. digest .. "\n", 0x180)
  end
  return digest
end

--- `cosmic --version`: the SHA-256 of the file this binary runs from,
--- read in pieces, as a release's SHA256SUMS names it: `cosmic <hex>`.
--- The digest is hashed once per file and kept ([`file_digest`]).
local function version(argv: {string}): integer
  local Proc = require("cosmic.proc")
  local extra = argv[2]
  if extra ~= nil then
    log:complain("--version takes nothing after it, not " .. extra)
    return 2
  end
  local path, path_trouble = Proc.executable()
  if path == nil then
    log:complain("--version: " .. tostring(path_trouble))
    return 1
  end
  -- TODO: hash the artifact descriptor startup retained rather than
  -- opening the path again, once the store offers the whole file as it
  -- offers its core (trusted_core): a file renamed over this one after
  -- launch is hashed in its place, and an unlinked one fails.
  local digest, digest_trouble = file_digest(path)
  if digest == nil then
    log:complain("--version: " .. tostring(digest_trouble))
    return 1
  end
  say_if_stale()
  log:say("cosmic " .. digest)
  return 0
end

--- `cosmic -e <chunk> [args...]`: runs `chunk` as the body of a Teal file, against this binary's own standard
--- library, with no tree around it. The chunk is parsed, checked as strictly as a tree build checks (a warning
--- is refused with an error, but an unused name is let pass) and compiled by [`build.standalone`], which keeps a clean compile as it keeps a file's;
--- a chunk the checker refuses does not run, and exits 4 ([`exit_status.uncompiled`]) with the checker's own messages. It reaches the standard library as a file does, by
--- `require("cosmic.json")` with a literal name, and may require the tool's own modules too, which are the
--- tool's one-liner's to use, and the modules of the working directory's tree, as a file at its root does
--- ([`standalone.compile_nearby`]); nothing is bound for it. The words after it are its `...` (each a `string?`); what it
--- returns is the exit code as a file run's is -- see build/exit_status.tl -- except a table or [`Json.null`], which is printed as
--- JSON and exits 0.
--- @param argv the whole command line, `-e` at slot 1
--- `name` is how messages name the chunk: "-e", or "stdin" for `cosmic -`.
local function evaluate(argv: {string}, name?: string): integer
  local chunk = argv[2]
  if chunk == nil then
    log:complain("usage: cosmic -e '<chunk>' [args...]")
    return 2
  end
  say_if_stale()
  local type importer = require("build.importer")
  local outcome: importer.Outcome = { refused = false }
  -- A chunk that requires a module of the working directory's tree is checked as a file at its root is.
  local loaded: standalone_type.Main?
  local trouble = ""
  if require("build.nearby").required({ "." }, chunk) then
    loaded, trouble = require("build.standalone").compile_nearby(name or "-e", chunk, outcome)
  else
    loaded, trouble = require("build.standalone").compile(name or "-e", chunk, nil, true, outcome)
  end
  if loaded == nil then
    local Fs = require("cosmic.fs")
    local _, _ = Fs.put(Fs.stderr, trouble .. "\n")
    log:complain((name or "-e") .. " runs its chunk as Teal, checked as a file is: see `cosmic help -e`")
    return if outcome.refused then exit_status.uncompiled else 1 end
  end
  local arguments: mut {string} = {}
  local slot = 3
  local given = argv[slot]
  while given ~= nil do
    arguments[#arguments + 1] = given
    slot = slot + 1
    given = argv[slot]
  end
  local returned = loaded(table.unpack(arguments))
  -- A table is an answer, not a status: it is printed as JSON, as an agent's snippet hands back what it returns. A
  -- status (nothing, a number, text) loads no JSON.
  if not (returned == nil or returned is number or returned is string) then
    local Json = require("cosmic.json")
    if returned is table or returned == Json.null then
      local Fs = require("cosmic.fs")
      local text, why = Json.encode_any(returned)
      if text == nil then
        log:complain((name or "-e") .. " returned a table that is not JSON: " .. tostring(why))
        return 2
      end
      local _, _ = Fs.put(Fs.stdout, text .. "\n")
      return 0
    end
  end
  return exit_status.of(name or "-e", returned)
end

--- The ending of each refusal of `help`'s own line, as Flags.dispatch ends every other verb's.
local help_usage <const> = "; usage: cosmic help [verb | exit | <verb> <subcommand>...]"

--- `cosmic help [verb | exit]`: the index, or one verb's full text, or the
--- exit codes, with no summary after it.
--- @param asked the verb `cosmic <verb> --help` asked about, or nil to
---   read the words after `help` itself
--- @param asked_subs the words of the verb's subcommand `cosmic <verb> <sub>... --help` asked about, if any
local function help(argv: {string}, asked: string?, asked_subs?: {string}): integer
  local Cli = require("cosmic.cli")
  local verb_list = require("build.verb_list")
  -- Cache maintenance must remain usable when this directory's candidate
  -- cannot build. Its help comes from this binary too, without opening a
  -- candidate database or passing through the stale-tool guard.
  if (asked == "cache" and #(asked_subs or {}) == 0) or (asked == nil and argv[2] == "cache" and argv[3] == nil) then
    local spec = assert(verb_list.find("cache"))
    log:say(verb_text("cache", spec, verb_help({ "cache" }, true).cache) .. "\n") -- checked: map_field
    return 0
  end
  -- The staleness guard `test` applies: a fingerprint compare when the
  -- tool is fresh. A verb's help reads build.docs, so an edit to it must
  -- rebuild. A cache subcommand's help is this binary's alone, as above.
  local cache_asked = asked == "cache" or (asked == nil and argv[2] == "cache")
  local code = if cache_asked then nil else stale_exit(argv, true) end
  if code ~= nil then
    return code
  end
  local words: mut {string} = {}
  if asked ~= nil then words[#words + 1] = asked end
  if asked ~= nil then
    for _, word in ipairs(asked_subs or {}) do words[#words + 1] = word end
  end
  if asked == nil then
    local line = argv
    local second = argv[2]
    local spelled = if second ~= nil then as_option[second] else nil end
    if spelled ~= nil then
      -- A verb spelled as an option (`cosmic --standalone <file>`,
      -- `cosmic -e <chunk>`) is asked about by either spelling.
      local spelled_line: mut {string} = {}
      for slot, word in ipairs(argv) do
        spelled_line[#spelled_line + 1] = if slot == 2 then spelled else word end
      end
      line = spelled_line
    end
    local parsed, parse_trouble = require("cosmic.flags").parse(line, 2, { ["--help"] = { about = "the index" }, ["-h"] = { about = "the index" } })
    if parsed == nil then
      log:complain("help: " .. parse_trouble .. help_usage)
      return 2
    end
    words = parsed.words
  end
  local requested = words[1]
  local asked_verb = if requested ~= nil then Cli.verbs[requested] else nil end
  local subcommands = if asked_verb ~= nil then asked_verb.subcommands else nil end
  if #words >= 2 and requested ~= nil and subcommands ~= nil then
    -- `cosmic help time add`, `cosmic help tailscale file get`: the subcommand's own help, as cosmic.flags
    -- writes it.
    local level: {string:flags.Command} = subcommands
    local named = typed_name(requested)
    local sub: flags.Command = assert(asked_verb)
    for slot = 2, #words do
      local word = assert(words[slot])
      local found = level[word]
      if found == nil then
        local names: mut {string} = {}
        for name in pairs(level) do names[#names + 1] = name end
        log:complain("help: " .. named .. " has no command " .. word .. meant(word, names) .. help_usage)
        return 2
      end
      -- A subcommand typed by no word is called as its parent alone.
      sub, named = found, if found.typed == "" then named else named .. " " .. word end
      local deeper = found.subcommands
      if deeper == nil and slot < #words then
        log:complain("help: " .. named .. " has no commands of its own, so not " .. assert(words[slot + 1]) .. help_usage)
        return 2
      end
      level = deeper or {}
    end
    log:say(require("cosmic.flags").help(sub, named, page_width) .. "\n")
    return 0
  end
  if #words > 1 then
    log:complain("help: one verb at a time, not " .. tostring(#words) .. help_usage)
    return 2
  end
  if #words == 1 and requested ~= nil then
    local known = requested == "exit"
    for _, verb in ipairs(Cli.order) do
      if verb == requested then
        known = true
        break
      end
    end
    if not known then
      local topics: mut {string} = { "exit" }
      for _, verb in ipairs(Cli.order) do topics[#topics + 1] = verb end
      log:complain("help: no such verb: " .. requested .. meant(requested, topics) .. help_usage)
      return 2
    end
    local own_help = assert(help_spec, "help's spec is set before a verb is dispatched")
    if requested == "exit" then
      local specs = verb_list.specs()
      specs[#specs + 1] = own_help
      log:say(exit_help(specs))
    else
      log:say(verb_text(requested, spec_for(requested)) .. "\n")
    end
    return 0
  end
  log:say(index_help())
  return 0
end

help_spec = {
  name = "help",
  guide = "none: the verb that describes the others, itself described by `cosmic help help`",
  tests = { "build.verbs_store_test" },
  run = function(argv: {string}): integer
    return help(argv, nil)
  end,
  -- Its output is the text asked for, and nothing after it: a summary would be one more line to read past.
  bare = true,
  exits = "`help` prints the text asked for and nothing after; it exits 0 when it did, 2 when it refuses its " ..
    "command line or does not know the verb or topic, and 3 when the tool is older than the tree and did not " ..
    "rebuild itself.",
  reads = true,
  recheck_on_refusal = false,
  takes = "a verb, or `exit`",
}

--- The spec of the verb a command line's first word names, loading the
--- module of that verb alone, or nil for a word that names none. A bare
--- verb ([`Spec.bare`]) prints no summary, its output being data:
--- build/json.tl says why.
local function spec_of(word: string): verb_spec.Spec?
  local verb_list = require("build.verb_list")
  if word == "help" then
    return help_spec
  end
  local found = verb_list.find(word)
  if found ~= nil and found.fresh == true then
    local inner = found.run
    local reads = found.reads == true
    -- A tool older than the tree rebuilds first ([`build.reboot`]).
    found = {
      name = found.name,
      run = function(argv: {string}): integer
        local stale = stale_exit(argv, reads)
        if stale ~= nil then
          return stale
        end
        return inner(argv)
      end,
      bare = found.bare,
      fresh = found.fresh,
      reads = found.reads,
      recheck_on_refusal = found.recheck_on_refusal,
      summarizes_failure = found.summarizes_failure,
      takes = found.takes,
      guide = found.guide,
      tests = found.tests,
    }
  end
  return found
end

local record Dispatch
end

--- Every text `cosmic help` prints, by what asks for it: `""` is the
--- index, `exit` its page, and each verb of [`cosmic.cli.order`] its own,
--- so a check reads what a user reads.
local function help_texts(): {string: string}
  local Cli = require("cosmic.cli")
  local verb_list = require("build.verb_list")
  local specs = verb_list.specs()
  local own_help = assert(help_spec, "help's spec is set before a verb is dispatched")
  specs[#specs + 1] = own_help
  local out: mut {string: string} = { [""] = index_help(), exit = exit_help(specs) }
  local texts = verb_help(Cli.order)
  for _, verb in ipairs(Cli.order) do
    out[verb] = verb_text(verb, spec_for(verb), texts[verb])
  end
  return out
end

help_source.provide(help_texts)

--- Loads [`cosmic.removed`], which [`build.removed_fix`] reads from `package.loaded` and requires by no name: the catalog
--- decides only what an error says, so it is no part of the compiler's identity, and this module is outside it. Where the
--- module is not in the store the tool is given, the load fails and no fix is offered.
local function load_removed_catalog()
  local _, _ = pcall(require, "cosmic.removed")
end

--- The flags of earlier releases that were the command line's first word, each with what replaced it. Only the first
--- word is asked: `cosmic test --check-types` is a current flag of a verb.
local RETIRED_FLAGS <const>: {string: string} = {
  ["--make"] = "use `cosmic build` to build a program, or `cosmic test` to run a tree's tests",
  ["--docs"] = "use `cosmic docs`",
  ["--check-types"] = "use `cosmic test`, which checks the tree's types as it builds (`cosmic test --check-types` also " ..
    "checks the values at run time)",
  ["--check-format"] = "use `cosmic fix --check`",
}

--- `cosmic --profile <dir> <command...>`: runs the command with `COSMIC_PROFILE=<dir>`, so each cosmic process
--- of it writes `<dir>/<pid>.prof` (`cosmic help profile`). The core reads the variable as it starts, before any
--- Lua runs, so this process starts the tool again with it set, and exits as that child does (128 plus the signal
--- that ended it); one that has it set already runs the command. 2 for a line it refuses, 1 where it cannot start
--- the child.
--- @param argv the command line, `--profile` at slot 1
--- @param main what runs the command where the variable is set already
local function profiled(argv: {string}, main: function({string}): integer): integer
  local dir = argv[2]
  if dir == nil or dir == "" or dir:sub(1, 1) == "-" or argv[3] == nil then
    log:complain("--profile takes a directory and the command to profile, `cosmic --profile <dir> <file.tl> " ..
        "[args]` or `cosmic --profile <dir> <verb> ...`, not " .. (if dir == nil then "nothing" else dir end) ..
        "; see `cosmic help profile`")
    return 2
  end
  local rest: mut {string} = {}
  for slot = 3, #argv do rest[#rest + 1] = argv[slot] end
  local Env = require("cosmic.env")
  if Env.get("COSMIC_PROFILE") == dir then
    return main(rest)
  end
  -- Made with its parents, as `cosmic test --profile` makes it: the core makes the last name alone.
  local made, made_trouble = require("cosmic.fs").mkdirs(dir)
  if not made then
    log:complain("--profile: " .. tostring(made_trouble))
    return 1
  end
  local Proc = require("cosmic.proc")
  local relaunch, trouble = Proc.relaunch()
  if relaunch == nil then
    log:complain("--profile: cannot start the tool again: " .. tostring(trouble))
    return 1
  end
  local environment = Env.all()
  for name, value in pairs(relaunch.env) do environment[name] = value end
  environment["COSMIC_PROFILE"] = dir
  local again: mut {string} = {}
  for _, given in ipairs(relaunch.argv) do again[#again + 1] = given end
  for _, given in ipairs(rest) do again[#again + 1] = given end
  -- A child, not an exec: the tool's descriptors (its artifact's) are closed across an exec.
  local Child = require("cosmic.child")
  local result, run_trouble = Child.run(again, { env = environment, fds = relaunch.fds, cwd = relaunch.cwd,
    timeout_ns = Child.FOREVER, process_group = false })
  if result == nil then
    log:complain("--profile: cannot start the tool again: " .. tostring(run_trouble))
    return 1
  end
  local code = result.code
  if code ~= nil then return code end
  return 128 + (result.signal or 0)
end

--- Runs the command line and returns its exit code.
--- @param argv the command line, the verb at slot 1
function Dispatch.main(argv: {string}): integer
  local word = argv[1]
  if word == "--profile" then
    return profiled(argv, Dispatch.main)
  end
  -- `run`, `eval` and `version` name the pages `cosmic help run`, `help eval` and `help version`, so each word is
  -- taken as its page's short form: `eval` as `-e`, `version` as `--version` and `run <file>` as `<file>`.
  local second_word = argv[2]
  if (word == "run" or word == "eval" or word == "-e") and (second_word == "--help" or second_word == "-h") then
    return Dispatch.main({ "help", if word == "run" then "run" else "eval" end })
  end
  if word == "eval" or word == "version" then
    local spelled: mut {string} = { if word == "eval" then "-e" else "--version" end }
    for slot = 2, #argv do spelled[#spelled + 1] = argv[slot] end
    argv, word = spelled, spelled[1]
  elseif word == "run" then
    -- Any other word goes on as a file run, whose own messages name a missing file, a Lua file or a directory.
    local file = argv[2]
    if file == nil or file == "help" or (file:sub(1, 1) == "-" and file ~= "--standalone" and file ~= "-") or
        (file ~= "--standalone" and file:sub(-3) ~= ".tl" and spec_of(file) ~= nil) then
      log:complain("run takes a file to run, `cosmic run <file.tl> [args]`, `cosmic run -` for standard input, or `cosmic run --standalone " ..
          "<file.tl>`, not " .. (if file ~= nil then file else "nothing" end) .. "; see `cosmic help run`")
      return 2
    end
    local shifted: mut {string} = {}
    for slot = 2, #argv do shifted[#shifted + 1] = argv[slot] end
    argv, word = shifted, file
  end
  if word == "-e" then
    -- The one-liner: a checked chunk of Teal, like --standalone with no tree and no staleness.
    return evaluate(argv)
  end
  if word == "-" then
    -- A chunk read from standard input, run as `-e` runs one: `echo 'print(1)' | cosmic -`. Read here, not
    -- through cosmic.flags, which `-e` never loads.
    local Fs = require("cosmic.fs")
    if require("cosmic.proc").is_tty(Fs.stdin) then
      log:complain("- runs standard input as a chunk, and standard input is a terminal: pipe the code in, " ..
          "or give a file; see `cosmic help -e`")
      return 5
    end
    local Stream = require("cosmic.stream")
    local chunk, why = Stream.read_all(Stream.from_fd(Fs.stdin))
    if chunk == nil then
      log:complain("standard input: " .. tostring(why))
      return 5
    end
    local spelled: mut {string} = { "-e", chunk }
    for slot = 2, #argv do spelled[#spelled + 1] = argv[slot] end
    return evaluate(spelled, "stdin")
  end
  if word == "--version" then
    -- Which build this is, with no tree and no staleness: the digest
    -- the release that published it records.
    return version(argv)
  end
  load_removed_catalog()
  if word == "--standalone" then
    -- One file against this binary's own standard library: no tree is
    -- staged or built and no staleness is checked -- see
    -- build.standalone. What bin/zig and bin/vendor run, so a stale
    -- core never stops the tool that rebuilds it.
    local standalone = require("build.standalone")
    return standalone.run(argv)
  end
  -- COSMIC_STANDALONE=1 runs a file (a first word ending .tl, which no
  -- verb does) as `--standalone` does, writing no build directory: what a
  -- policy's run of this program is given (cosmic.child), whose user may
  -- have no build directory to write.
  if word ~= nil and word:sub(-3) == ".tl" and require("cosmic.env").get("COSMIC_STANDALONE") == "1" then
    local shifted: mut {string} = { "--standalone" }
    for _, given in ipairs(argv) do
      shifted[#shifted + 1] = given
    end
    return require("build.standalone").run(shifted, "this file ran as --standalone, which " ..
        "finds only cosmic.* modules, because COSMIC_STANDALONE=1 (as under `cosmic " ..
        "sandbox`); COSMIC_STANDALONE=0 builds the tree around it, which finds its own")
  end
  if word ~= nil and word:sub(-3) == ".tl" and require("cosmic.env").get("COSMIC_STANDALONE") ~= "0" then
    local code = run_alone(word, argv)
    if code ~= nil then
      return code
    end
  end
  local Env = require("cosmic.env")
  local Flags = require("cosmic.flags")
  local Fs = require("cosmic.fs")
  local String = require("cosmic.string")
  local sys = require("cosmic.sys")
  local verb = if word == nil or word == "-h" or word == "--help" then "help" else word end
  local chosen = spec_of(verb)
  -- TODO: give each verb the line Flags.dispatch read, a Flags.Command whose `run` takes the Flags.Parsed, and
  -- delete each verb's own parse of it. Flags.dispatch reads the line of a verb typed by its name already
  -- ([`line_refusal`]), so their refusals are one rule's; until the verbs take what it read, a line is parsed
  -- twice, to the same result. It waits on two things. Most verbs offer `run(argv, io?)` to their tests, which
  -- would each hand over a parsed line instead; and `sql`, which says more of its usage than one line (a line a
  -- subcommand), needs its subcommands in cosmic/cli/sql.tl first, as `time` has them. A
  -- `fresh` verb and `todos` keep reading their own lines whatever is done: they rebuild a stale tool first.
  -- `-e`, `--standalone` and `--version` stay outside Flags.dispatch on purpose: they load neither cosmic.flags
  -- nor cosmic.cli (build/dispatch_tool_test.tl holds `-e` to it), being what runs when the tree cannot build.

  -- The verb's own module of cosmic.cli alone: [`cosmic.cli`] loads every verb's.
  local load_command = require("build.verb_list").commands[verb]
  local command = if chosen ~= nil and load_command ~= nil then load_command() else nil end
  local options = if chosen ~= nil and command ~= nil then command.spec or {} else {} end -- checked: literal_needs_type
  -- A subcommand typed by no word (`fetch`'s `get`) runs for a line that names none, so its options are the verb's.
  local default_sub: string? = nil
  local listed_subs = if command ~= nil then command.subcommands else nil end
  if listed_subs ~= nil then
    for name, sub in pairs(listed_subs) do
      if sub.typed == "" then
        default_sub = name
        if sub.spec ~= nil then options = sub.spec end
      end
    end
  end
  -- The words of a program a verb runs are not the verb's to read.
  local own = argv
  if chosen ~= nil and chosen.program_slot ~= nil then
    local at = chosen.program_slot(argv)
    if at ~= nil then
      own = {}
      for slot, given in ipairs(argv) do
        if slot < at then own[#own + 1] = given end -- checked: view_written
      end
    end
  end
  -- Whether the verb is typed by its name, and so is a command Flags.dispatch reads the line of: `help`, a file
  -- run and the verbs spelled as options read their own.
  local typed_by_name = chosen ~= nil and verb ~= "help" and verb:sub(1, 1) ~= "-"
  local verb_subcommands = if command ~= nil then command.subcommands else nil end
  local asks_sub_help = verb_subcommands ~= nil and own[2] == "help"
  if chosen ~= nil and verb ~= "help" and (asks_sub_help or Flags.asks_help(own, 2, options)) then
    -- `cosmic <verb> --help` is `cosmic help <verb>`, and `cosmic <verb> <sub> --help` and
    -- `cosmic <verb> help <sub>` are `cosmic help <verb> <sub>`.
    local asked = verb
    -- The words that name subcommands, down from the verb, and the first one that names none. A word no
    -- subcommand is named by is a default subcommand's, where a level has one (`cosmic fetch <url> --help`).
    local asked_subs: mut {string} = {}
    local level = verb_subcommands
    local first = if asks_sub_help then 3 else 2 end
    local slot = first
    while level ~= nil do
      local typed = own[slot]
      if typed == nil or typed:sub(1, 1) == "-" then break end
      local found = level[typed]
      if found == nil and slot == first and default_sub ~= nil then break end
      asked_subs[#asked_subs + 1] = typed
      level = if found ~= nil then found.subcommands else nil end
      slot = slot + 1
    end
    typed_by_name = false
    local own_spec = assert(help_spec, "help's spec is set before a verb is dispatched")
    verb = "help"
    chosen = {
      name = "help",
      run = function(line: {string}): integer
        return help(line, asked, asked_subs)
      end,
      bare = own_spec.bare,
      reads = own_spec.reads,
      recheck_on_refusal = false,
      takes = own_spec.takes,
      guide = own_spec.guide,
      tests = own_spec.tests,
    }
  end
  if chosen ~= nil and verb ~= "help" and require("build.verb_list").tree_paths[verb] ~= nil then
    -- A tree verb started below an established tree's root runs at the
    -- root ([`build.tree_root`]), its paths still read from here.
    local tree_root = require("build.tree_root")
    local answer = tree_root.move(argv, options, Env.read("HOME"), Env.read("COSMIC_TREE"))
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
    -- A verb that writes and checks the tool as it goes holds it to
    -- cosmic's own tree alone; in a project it is held to its checkout
    -- here ([`reboot.checkout_exit`]). A fresh verb and one that only
    -- reads make that check in [`reboot.stale_exit`].
    if not chosen.bare and chosen.fresh ~= true and chosen.reads ~= true then
      local here, here_trouble = Fs.absolute(".")
      if here == nil then
        log:complain(verb .. ": " .. tostring(here_trouble))
        return 1
      end
      local stale = checkout_exit(argv, here)
      if stale ~= nil then
        return stale
      end
    end
    -- The verb's line is read by Flags.dispatch first, as a program's command is, so every verb refuses a
    -- mistyped option alike, naming the one meant and its usage; the verb then reads the line it was given.
    local code = 2
    local vetted = command ~= nil and typed_by_name and chosen.fresh ~= true and chosen.own_line ~= true
    local refusal = if command ~= nil and vetted then line_refusal(verb, command, own) else "" end
    if refusal ~= "" then
      log:complain(refusal)
    else
      code = chosen.run(argv)
    end
    if code == 2 and not chosen.bare and chosen.fresh ~= true and chosen.recheck_on_refusal ~= false then
      -- A verb may read its command line before it checks the tool is
      -- as new as the tree, and an option the tree added is one a stale
      -- tool refuses: it rebuilds and runs the line again here instead.
      -- TODO: hold the stale tool's usage complaint until this check has
      -- run: a line the rebuilt tool refuses too is complained about
      -- twice, once by each tool, and one it takes still shows the stale
      -- tool's refusal above the rebuild. Each verb would check
      -- staleness before reading its command line, or complain through
      -- a logger that holds usage lines back until main flushes them.
      local stale = require("build.reboot").stale_exit(argv, chosen.reads == true)
      if stale ~= nil then
        code = stale
      end
    end
    return code
  end
  if verb:sub(1, 1) == "-" then
    local retired = RETIRED_FLAGS[verb]
    if retired ~= nil then
      log:complain("cosmic " .. verb .. " was removed: " .. retired)
      return 2
    end
    local spelled: mut {string} = { "--help" }
    for option in pairs(as_option) do spelled[#spelled + 1] = option end
    log:complain("no such option: " .. verb .. meant(verb, spelled))
    log:complain("`cosmic help` is the whole discovery surface")
    return 2
  end
  -- A word that could not be a file to run is a mistyped verb, told as
  -- one rather than as a file that is not there.
  if not verb:find("/", 1, true) and not String.ends_with(verb, ".tl") then
    local exists_status, _ = Fs.status(verb)
    local exists = exists_status ~= nil and exists_status.exists
    if exists ~= true then
      -- The verbs typed by their names: all but `standalone`, which is typed `--standalone` (or
      -- `run --standalone`).
      local untyped: {string:boolean} = { standalone = true }
      local typed: mut {string} = {}
      for _, known in ipairs(require("cosmic.cli").order) do
        if untyped[known] == nil then typed[#typed + 1] = known end
      end
      log:complain("no such verb or file: " .. verb .. meant(verb, typed) .. "; see `cosmic help`")
      return 2
    end
  end
  return run(verb, argv)
end

return Dispatch

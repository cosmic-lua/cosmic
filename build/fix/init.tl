--- `cosmic fix`: check a tree's Teal, C, YAML, Markdown and Zig, and write back what it can set right.
---
--- It reads each Teal file with the new checker's parser ([`build.syntax_node`]), as written, and holds it to what the
--- verb checks of a file: that it parses, that its links resolve ([`build.syntax_links`]) and that no function of it
--- repeats one the standard library has ([`build.fix.near`], read off its doc comments by [`build.syntax_analyzer`]). It
--- lays Teal out with [`build.fix.format`]: a file it refuses (a syntax error, a layout that is not the same file or not a
--- fixed point) is never written, and is told with its reason.
---
--- The verb takes paths to narrow it, defaults to the whole tree in the working directory, and writes what it fixes,
--- which is the layout of Teal, the links it makes of plain code spans, the layout of C and of YAML in flow style.
--- `--check` writes nothing and reports what it would have changed, which is what a gate runs; it fails on a Teal file
--- that is not laid out and on one the formatter refuses.
---
--- A second run changes nothing the first did not. CI's format-check step runs `cosmic fix --check .` over the whole
--- tree.
---
--- It also lays out YAML in flow style ([`build.flow`]): a file it is named, and, in cosmic's own tree, the files under
--- `.github/` (the workflows and actions) when a directory covering them is named. A file in block style is refused when
--- named and passed over otherwise. A file that cannot be read ends the run.
---
--- In cosmic's own tree it also covers the tree's C. Every C file is written back in the layout `build.c` holds. Every
--- `.c` file is then compiled to its syntax tree and held to the rules `build.c` holds; a finding refuses the file and is
--- fixed by hand. A header is held to the rules through the files that include it.
---
--- When it covers every Teal source of cosmic's own tree (`cosmic fix --check .`, as CI runs it), it also builds the
--- tree's projection with the new checker and holds it to the checks only the whole tree can answer
--- ([`build.tree_checks`]), and that every public example and user-guide example compiles as shown, alone
--- ([`build.example_checks`]). A tree that does not build fails, since the checks need its projection, and a note on the
--- standard library fails the run instead of being a note. A run over some paths does none of this.
---
--- `--changed` names the paths that changed since the whole tree passed
--- (`cosmic fix --check --changed $(git diff --name-only main)`): it checks only those, yet answers as a run over the whole
--- tree would, making every check that spans files over all of it ([`fix.narrowed`]). Where a path named is part of what
--- checks each file alone (the C rules, the readers of Teal), it covers the whole tree, and says why. A branch's CI runs it
--- in place of the whole tree's check; the merge queue still runs that.
---
--- In any project it also holds the links in comments and Markdown to resolving ([`build.links`]): each Teal and C file it
--- covers, and each Markdown and Zig file, whose layout it never changes. A plain code span that would link to one thing
--- is made a link ([`build.links`]'s `rewrite`), and a Markdown file's definitions are rewritten to match; `--check` is
--- the dry run, and fails on one it would link. A path git ignores ([`link_files.ignoring`]) and anything under a
--- `node_modules/` is not covered, and no link names it.

local build_paths = require("build.paths")
local Cli = require("cosmic.cli")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local identity = require("build.identity")
local c_check = require("build.c")
local c_functions = require("build.c_functions")
local Store = require("cosmic.store")
local String = require("cosmic.string")
local Clock = require("cosmic.clock")
local clock = require("build.clock")
local docs = require("build.docs")
local docs_checks = require("build.docs_checks")
local help_source = require("build.help_source")
local flow = require("build.flow")
local laid = require("build.fix.laid")
local Format = require("build.fix.format")
local link_files = require("build.link_files")
local link_resolve = require("build.link_resolve")
local links = require("build.links")
local near = require("build.fix.near")
local Ast = require("lang.ast")
local SyntaxAnalyzer = require("build.syntax_analyzer")
local SyntaxLinks = require("build.syntax_links")
local SyntaxNode = require("build.syntax_node")
local reboot = require("build.reboot")
local rebuild = require("build.rebuild")
local Pipeline = require("build.pipeline")
local template = require("cosmic.template")
local tree = require("build.tree")
local example_checks = require("build.example_checks")
local Memprobe = require("build.memprobe")
local tree_checks = require("build.tree_checks")
local CeilingsBase = require("build.ceilings_base")
local Env = require("cosmic.env")
local Sqlite = require("cosmic.sqlite")

local logger = require("build.logger")
local progress = require("build.progress")
local log = logger.log
local verb_spec = require("build.verb_spec")
local plural = require("build.plural")

local record fix
  --- [`build.fix.format`]'s `format`, as [`format_text`], the way in for what is not inside `build/fix/`, such as the language server's
  --- formatting ([`build.lsp.session`]).
  format_text: function(source: string, name: string): Format.Result
  --- The verb's registration: see build/verb_spec.tl.
  spec: verb_spec.Spec
  --- The files one invocation covers, and the named paths it will not
  --- take: one that is not there, and one that is not a source the verb
  --- handles. A refused path is carried here rather than ending the verb,
  --- so it is reported and counted like any other refused file and the
  --- run still ends in the verb's summary.
  --- What `links` found: each link that does not resolve, notes on
  --- what it could not check, each plain span that would be linked
  --- ([`build.links`]'s `rewrite`), and each file it linked spans in.
  record Linked
    broken: {string}
    notes: {string}
    would: {string}
    --- Each Markdown file whose block of definitions would change.
    redefined: {string}
    rewritten: {string}
  end

  --- How laying out a Teal file ended ([`fix.lay_out_source`]): `laid` it was laid out already, `unlaid` it is not and a
  --- check wrote nothing, `written` it is now, `refused` the formatter or the parse of its layout refused it and nothing
  --- was written, `linked` the file is a symlink, which is not written, `changed` it was edited while it was laid out and
  --- is not written, `unwritable` the write failed.
  enum LaidState
    "laid"
    "unlaid"
    "written"
    "refused"
    "linked"
    "changed"
    "unwritable"
  end

  --- What laying out a Teal file left of it.
  record Laid
    state: LaidState
    --- What the file holds now, and its parse.
    text: string
    chunk: Ast.Chunk
    --- For the states that wrote nothing and are no layout (all but `laid`, `unlaid` and `written`), why.
    why: string
  end

  --- Where links' names are read, and how to close what that opened.
  record LinkSource
    context: link_resolve.Context
    close: function()
    --- Why the build made to resolve a link failed, once one has: the
    --- links then resolved against the last build, and the run fails.
    mut unbuilt?: string
  end

  record Chosen
    files: {string}
    --- The C files, which only cosmic's own tree has checked.
    c_files: {string}
    --- The YAML files in flow style, laid out by [`build.flow`].
    flow_files: {string}
    --- The Markdown and Zig files, whose links are checked and which
    --- are never rewritten.
    checked: {string}
    refused: {string}
    --- The templates (`.tmpl`), which are parsed and never rewritten:
    --- a template has no layout.
    templates: {string}
    --- Whether `files` are every Teal source of cosmic's own tree, as
    --- `cosmic fix --check .` covers it: only then does the run hold
    --- the tree to [`build.tree_checks`]. A run of `--changed` is whole
    --- too ([`fix.narrowed`]).
    whole: boolean
    --- The named Teal files, in `files` too, that are no input of the project at the root ([`build.identity`]'s
    --- `is_input`: under `bin/`, `vendor/`, a hidden directory, outside the root): the build never reads them, so
    --- [`fix.chosen`] sets them apart for a check of their own, as `cosmic --standalone` makes one. Only a project
    --- other than cosmic's own has them; nil is none.
    alone?: {string}
    --- For a run of `--changed`, everything a run over the whole tree
    --- covers, which the checks spanning files still cover: the asserts
    --- the build refuses and the links; nil for any other run.
    every?: Chosen
    --- For a run of `--changed`, the Teal files whose notes it reads
    --- ([`fix.notes`]), where these are not `files`.
    noted?: {string}
    --- For a run of `--changed` that lays out the whole tree after all,
    --- why: a path named that is part of what checks each file alone.
    widened?: string
  end
end

--- What is never a file to fix: the build's own output, the upstream
--- sources and the records that patch them, the C core, the one shell
--- script that fetches zig, a project's static assets, and anything hidden.
local not_source: {string:boolean} = {
  ["o"] = true,
  ["static"] = true,
  ["vendor"] = true,
  ["patch"] = true,
  ["bin"] = true,
  ["core"] = true,
}

--- The Teal file `path` as one name however it is spelled: its directory made absolute, its own name kept, so that a link
--- stays itself and is not what it points at.
local function named_as(path: string): string
  local parent, _ = Fs.absolute(Fs.dirname(path))
  if parent == nil then return path end
  return parent .. "/" .. Fs.basename(path)
end

--- Whether the Teal file `path`, named in a project at `root`, is to be checked alone, as it is no input of that project's
--- build: outside it, under a directory identity never takes ([`identity.is_input`]), or under a hidden one. The path is
--- judged as named ([`named_as`]): a link inside the build to a file under `bin/` is the build's, which reads it.
local function checked_alone(root: string, own: boolean, path: string): boolean
  -- TODO: once `fix` can check a file of cosmic's own tree that is no input of it (`ci/`, which is a project of its own, and
  -- `lang/*.d.tl`) in the project that reads it, ask this of cosmic's own tree too.
  if own then return false end
  local top, _ = Fs.absolute(root)
  if top == nil then return false end
  local relative, _ = Fs.relative(named_as(path), top)
  -- Outside the root, which [`Fs.relative`] says by answering nothing.
  if relative == nil then return true end
  if relative == ".." or relative:sub(1, 3) == "../" then return true end
  for part in relative:gmatch("[^/]+") do
    if part:sub(1, 1) == "." then return true end
  end
  return not identity.is_input(relative, false)
end

--- The fixture of forms the new grammar refuses on purpose (a project written in them is refused in the new checker's words,
--- [`build.project_grammar_tool_test`]): never a file to read.
local refused_on_purpose <const>: string = "testdata/projects/fork_only"

local function skip(entry: string): boolean
  local first = entry:match("^([^/]+)") or entry
  if not_source[first] then
    return true
  end
  if entry == refused_on_purpose or String.starts_with(entry, refused_on_purpose .. "/") then
    return true
  end
  return Fs.basename(entry):sub(1, 1) == "."
end

--- Every Teal source under `root`, as paths relative to it. Declaration files count: their links and notes are read like
--- any other source's.
--- @param root string
--- @return {string}|nil
--- @return string Error message on failure
local function sources(root: string): {string}?, string
  local files, trouble = Fs.walk(root, skip)
  if files == nil then
    return nil, trouble
  end
  local out: mut {string} = {}
  for _, file in ipairs(files) do
    if String.ends_with(file, ".tl") then
      out[#out + 1] = file
    end
  end
  return out, ""
end

--- Every template under `root`, as paths relative to it, but those under
--- a `testdata/` directory, which the build never makes a module of
--- ([`build.derivation`]) and a test may keep broken on purpose.
local function template_sources(root: string): {string}?, string
  local files, trouble = Fs.walk(root, skip)
  if files == nil then
    return nil, trouble
  end
  local out: mut {string} = {}
  for _, file in ipairs(files) do
    if String.ends_with(file, ".tmpl") and file:sub(1, 9) ~= "testdata/" and
        file:find("/testdata/", 1, true) == nil then
      out[#out + 1] = file
    end
  end
  return out, ""
end

--- Whether `path` is a file whose links are checked and nothing more.
local function check_only(path: string): boolean
  return String.ends_with(path, ".md") or String.ends_with(path, ".zig")
end

--- Every file under `root` whose links are checked and that is not
--- laid out, as paths relative to it: each Markdown and Zig file the
--- walk for links finds ([`link_files.walk`]), and the core's Teal,
--- which a narrower run names as it names any other. The core's C is
--- checked apart.
local function checked_sources(root: string): {string}?, string
  local files, trouble = link_files.walk(root)
  if files == nil then
    return nil, trouble
  end
  local out: mut {string} = {}
  for _, file in ipairs(files) do
    local core_teal = file:sub(1, 5) == "core/" and
      (String.ends_with(file, ".tl") or String.ends_with(file, ".lua"))
    if check_only(file) or core_teal then out[#out + 1] = file end
  end
  return out, ""
end

--- Whether `files`, however each was named, hold every Teal source
--- under `root`.
local function covers(root: string, files: {string}): boolean
  local all, _ = sources(root)
  if all == nil then return false end
  local named: mut {string: boolean} = {}
  for _, file in ipairs(files) do
    local absolute, _ = Fs.absolute(file)
    if absolute ~= nil then named[absolute] = true end
  end
  for _, file in ipairs(all) do
    local absolute, _ = Fs.absolute(root .. "/" .. file)
    if absolute == nil or not named[absolute] then return false end
  end
  return true
end

--- Whether `file` is named as YAML.
local function is_yaml(file: string): boolean
  return String.ends_with(file, ".yml") or String.ends_with(file, ".yaml")
end

--- The flow-style YAML files `dir` covers, as paths relative to it. For
--- the tree's root these are the files under its `.github/`. For that
--- `.github/` or a directory under it, they are the files under `dir`.
--- For any other directory there are none, since the walk of the tree
--- passes over a `.github/` anywhere else. A file that cannot be read
--- is a failure, not passed over.
local function workflow_sources(dir: string, root: string): {string}?, string
  dir = dir:gsub("/+$", "")
  if dir == "" then dir = "/" end
  local absolute, _ = Fs.absolute(dir)
  local top, _ = Fs.absolute(root)
  local inside: string? = nil
  if absolute ~= nil and top ~= nil then
    local relative, _ = Fs.relative(absolute, top)
    if relative ~= nil and relative ~= ".." and relative:sub(1, 3) ~= "../" then
      inside = relative
    end
  end
  if inside == nil then
    return {}, ""
  end
  local within = inside == ".github" or inside:sub(1, 8) == ".github/"
  if not within and inside ~= "." then
    return {}, ""
  end
  local base = within and dir or dir .. "/.github"
  local prefix = if within then "" else ".github/" end
  local st, _ = Fs.stat(base)
  if st == nil or st.kind ~= "dir" then
    return {}, ""
  end
  local files, trouble = Fs.walk(base, function(entry: string): boolean
    return Fs.basename(entry):sub(1, 1) == "."
  end)
  if files == nil then
    return nil, trouble
  end
  local out: mut {string} = {}
  for _, file in ipairs(files) do
    if is_yaml(file) then
      local text, read_trouble = Fs.read(base .. "/" .. file)
      if text == nil then
        return nil, read_trouble
      end
      if flow.is_flow(text) then
        out[#out + 1] = prefix .. file
      end
    end
  end
  table.sort(out)
  return out, ""
end

--- The files one invocation covers: whatever paths were named, or the
--- whole tree when none were.
---
--- One stat says what a named path is first: a path with nothing at it
--- is reported missing rather than judged on its suffix, which would
--- answer `nosuchdir/` with a remark about Teal. A directory is walked
--- for its Teal sources (and, in cosmic's own tree, C and flow-style
--- YAML). A named file is taken at its word by its suffix, so one that
--- is none of those is refused here, not sent to the parser to come
--- back as a syntax error.
---
--- Only a failure to walk a directory fails outright. Any other path
--- the verb will not take is one refusal among those named.
--- @param root string The tree to cover when no path was named
--- @param paths {string} The paths named on the command line
--- @return fix.Chosen|nil The files to fix and the paths refused
--- @return string Error message on failure
--- @param standing what `root` is to the running tool ([`tree.standing`])
function fix.chosen(root: string, paths: {string}, standing: tree.Standing): fix.Chosen?, string
  local own = standing.own
  if #paths == 0 then
    local all, trouble = sources(root)
    if all == nil then
      return nil, trouble
    end
    local checked, checked_trouble = checked_sources(root)
    if checked == nil then
      return nil, checked_trouble
    end
    local templates, templates_trouble = template_sources(root)
    if templates == nil then
      return nil, templates_trouble
    end
    local c_files: {string} = {}
    local flow_files: {string} = {}
    if own then
      local found, c_trouble = c_check.sources(root)
      if found == nil then
        return nil, c_trouble
      end
      c_files = found
      local workflows, flow_trouble = workflow_sources(root, root)
      if workflows == nil then
        return nil, flow_trouble
      end
      flow_files = workflows
    end
    return { files = all, c_files = c_files, flow_files = flow_files, checked = checked,
      templates = templates, refused = {}, whole = own }, ""
  end
  local out: mut {string} = {}
  local c_out: mut {string} = {}
  local flow_out: mut {string} = {}
  local checked_out: mut {string} = {}
  local templates_out: mut {string} = {}
  local refused: mut {string} = {}
  local alone_out: mut {string} = {}
  local seen: mut {string: boolean} = {}
  local static_root, _ = Fs.absolute(root .. "/static")
  for _, path in ipairs(paths) do
    local what, missing = Fs.stat(path)
    local real: string? = nil
    if what ~= nil then
      local resolved, _ = Fs.absolute(path)
      real = resolved
    end
    if what == nil then
      refused[#refused + 1] = missing
    elseif static_root ~= nil and real ~= nil and
        (real == static_root or real:sub(1, #static_root + 1) == static_root .. "/") then
      refused[#refused + 1] = path .. ": under static/, which is carried verbatim, not laid out"
    elseif what.kind == "dir" then
      local under, trouble = sources(path)
      if under == nil then
        return nil, trouble
      end
      for _, file in ipairs(under) do
        local named = path .. "/" .. file
        if seen[named_as(named)] == nil then
          seen[named_as(named)] = true
          out[#out + 1] = named
          if checked_alone(root, own, named) then alone_out[#alone_out + 1] = named end
        end
      end
      local checked, checked_trouble = checked_sources(path)
      if checked == nil then
        return nil, checked_trouble
      end
      for _, file in ipairs(checked) do
        checked_out[#checked_out + 1] = path .. "/" .. file
      end
      local templates, templates_trouble = template_sources(path)
      if templates == nil then
        return nil, templates_trouble
      end
      for _, file in ipairs(templates) do
        templates_out[#templates_out + 1] = path .. "/" .. file
      end
      if own then
        local c_under, c_trouble = c_check.sources(path)
        if c_under == nil then
          return nil, c_trouble
        end
        for _, file in ipairs(c_under) do
          c_out[#c_out + 1] = path .. "/" .. file
        end
        local workflows, flow_trouble = workflow_sources(path, root)
        if workflows == nil then
          return nil, flow_trouble
        end
        local base = path:gsub("/+$", "")
        for _, file in ipairs(workflows) do
          flow_out[#flow_out + 1] = base .. "/" .. file
        end
      end
    elseif String.ends_with(path, ".c") or String.ends_with(path, ".h") then
      if own then
        c_out[#c_out + 1] = path
      else
        refused[#refused + 1] = path .. ": C is checked only in cosmic's own tree"
      end
    elseif is_yaml(path) then
      flow_out[#flow_out + 1] = path
    elseif check_only(path) then
      checked_out[#checked_out + 1] = path
    elseif String.ends_with(path, ".tmpl") then
      templates_out[#templates_out + 1] = path
    elseif not String.ends_with(path, ".tl") then
      refused[#refused + 1] = path .. ": not a Teal, C or template source, YAML, Markdown or Zig"
    else
      if seen[named_as(path)] == nil then
        seen[named_as(path)] = true
        out[#out + 1] = path
        if checked_alone(root, own, path) then alone_out[#alone_out + 1] = path end
      end
    end
  end
  return { files = out, c_files = c_out, flow_files = flow_out, checked = checked_out,
    templates = templates_out, refused = refused, whole = own and covers(root, out), alone = alone_out }, ""
end

--- The modules whose code checks each file alone, with every module each requires: the reading of Teal
--- ([`build.syntax_node`], [`build.syntax_links`], [`build.syntax_analyzer`]), the notes on the standard library
--- ([`build.fix.near`]), the layout of YAML ([`build.flow`]), of C and its rules ([`build.c`]), and what reads the command
--- line, says the summary and tells cosmic's own tree ([`build.tree`]), whose files a run over the whole of it covers. A
--- change to one can change what a run says of a file that did not change, so a run of `--changed` naming one covers the
--- whole tree ([`fix.narrowed`]). What checks the tree as a whole -- the build, the tree checks, the links -- is not among
--- them: such a run makes those checks over the whole tree anyway.
local file_checks: {string} = { "build.syntax_node", "build.syntax_links", "build.syntax_analyzer", "build.flow", "build.c",
  "build.fix.near", "build.fix.laid", "build.logger", "build.tree", "cosmic.flags", "cosmic.cli", "cosmic.template" }

--- What else a run of `--changed` covers the whole tree for, by a path's first directory, and why: what the program and
--- the clang that reads each C file are built from or run on. A test there (`core/*_test.tl`) is none of these.
local file_check_dirs: {string: string} = {
  ["vendor"] = "the program is built from vendor/",
  ["patch"] = "the program is built from patch/'s records",
  ["bin"] = "bin/ pins zig, whose clang reads each C file",
  ["core"] = "the program runs on core/, whose headers each C file reads",
  ["cmd"] = "the program starts in cmd/",
}

--- As `file_check_dirs`, by a file's whole path: this verb, what
--- builds and writes the program (the image [`identity.record_fingerprint`]
--- names, less the directories above), and the pin of the cosmic the C
--- rules run clang through ([`build.c`] gives the compiler it to read).
local file_check_files: {string: string} = {
  ["build/fix/init.tl"] = "this verb checks each file",
  ["build.zig"] = "the program is built by build.zig",
  ["build.zig.zon"] = "the program is built by build.zig",
  ["build/launcher.tl"] = "the program is written by build/launcher.tl",
  ["build/artifact.tl"] = "the program is written by build/artifact.tl",
  ["build/patch.tl"] = "the program's vendored libraries are patched by build/patch.tl",
  ["ci/cosmic-driver.pin"] = "the C rules run clang through the cosmic it pins",
}

--- `path` as a path under `root` without a leading `./` or trailing
--- `/`, "" for the root itself; nil for one outside it.
local function under(root: string, path: string): string?
  local out = path
  if String.starts_with(out, root .. "/") then
    out = out:sub(#root + 2)
  elseif out == root then
    out = ""
  elseif out:sub(1, 1) == "/" then
    return nil
  end
  while out:sub(1, 2) == "./" do out = out:sub(3) end
  out = out:gsub("/+$", "")
  if out == "." then out = "" end
  if out == ".." or out:sub(1, 3) == "../" then return nil end
  return out
end

--- Whether `file`, a path under the root, is `named` or under it.
local function inside(file: string, named: string): boolean
  return named == "" or file == named or String.starts_with(file, named .. "/")
end

--- The files, under the root, of the modules `file_checks` names and
--- every module they require, as the running program's `databases`
--- ([`Store.databases()`]) hold them: nil, and why, where they hold
--- none of one.
local function file_check_sources(databases: {Sqlite.Handle}): {string: boolean}?, string
  local roots: mut {string} = {}
  for _, module in ipairs(file_checks) do roots[#roots + 1] = "('" .. module .. "')" end
  local query = "WITH RECURSIVE closure(module) AS (VALUES " .. table.concat(roots, ", ") ..
    " UNION SELECT imports.requires FROM imports JOIN closure ON imports.path = closure.module) " ..
    "SELECT modules.path, modules.file FROM closure JOIN modules ON modules.path = closure.module"
  local out: mut {string: boolean} = {}
  local found: mut {string: boolean} = {}
  for _, db in ipairs(databases) do
    local rows, _ = Sqlite.text_rows(db, query)
    for _, row in ipairs(rows or {}) do
      found[row:text(1)] = true
      out[row:text(2)] = true
    end
  end
  for _, module in ipairs(file_checks) do
    if not found[module] then
      return nil, module .. " is not among the program's modules"
    end
  end
  return out, ""
end

--- The files a run of `--changed` lays out: of `every`, the whole
--- tree's ([`fix.chosen`] with no path named), those `changed` names
--- (a path of `root`, or a directory holding them), which name what
--- changed since a tree a run over the whole of it passed. Every C
--- file is held to its rules when one of them changed, since a rule
--- reads other files. The run is whole, and makes every check that
--- spans files over `every`: the tree checks, the asserts the build
--- refuses, the links, and a note on the standard library, which reads
--- the docs of all of it. A path named that was removed lays out
--- nothing.
---
--- Where a path named is part of what checks each file alone
--- (`file_checks`, read from `databases`, and the like), a file that
--- did not change can answer otherwise, so it answers `every` itself,
--- `widened` saying why; as it does for a path outside `root`.
--- @param root string The tree's root, the working directory
--- @param every fix.Chosen The whole tree's files
--- @param changed {string} The paths named
--- @param databases {Sqlite.Handle} The program's own
--- ([`Store.databases()`]), which name its modules' requires
--- @return fix.Chosen
function fix.narrowed(root: string, every: fix.Chosen, changed: {string},
                      databases: {Sqlite.Handle}): fix.Chosen
  local function widened(why: string): fix.Chosen
    return { files = every.files, c_files = every.c_files, flow_files = every.flow_files,
      checked = every.checked, templates = every.templates, refused = every.refused,
      whole = every.whole,
      every = every, widened = why }
  end
  local named: mut {string} = {}
  for _, path in ipairs(changed) do
    local relative = under(root, path)
    if relative == nil then return widened(path .. ": outside the tree") end
    if relative == "" then return widened(path .. ": the whole tree") end
    named[#named + 1] = relative
  end
  local checking, checking_trouble = file_check_sources(databases)
  if checking == nil then return widened(checking_trouble) end
  for _, path in ipairs(named) do
    local first = path:match("^([^/]+)") or path
    local why: string? = nil
    if not String.ends_with(path, "_test.tl") then why = file_check_dirs[first] end
    for file, reason in pairs(file_check_files) do
      if why == nil and inside(file, path) then why = reason end
    end
    for file in pairs(checking) do
      if why == nil and inside(file, path) then why = "it checks each file alone" end
    end
    if why ~= nil then return widened(path .. ": " .. why) end
  end
  local function picked(files: {string}): {string}
    local out: mut {string} = {}
    for _, file in ipairs(files) do
      local relative = under(root, file) or file
      for _, path in ipairs(named) do
        if inside(relative, path) then
          out[#out + 1] = file
          break
        end
      end
    end
    return out
  end
  local files = picked(every.files)
  local c_files: {string} = {}
  if #picked(every.c_files) > 0 then c_files = every.c_files end
  -- A note on the standard library fails the run, and reads the docs
  -- the program carries of every file of it, which a change to what
  -- writes them can move as well as a change to one of them.
  local noted: mut {string} = {}
  for _, file in ipairs(every.files) do
    if tree_checks.standard(under(root, file) or file) then noted[#noted + 1] = file end
  end
  for _, file in ipairs(files) do
    if not tree_checks.standard(under(root, file) or file) then noted[#noted + 1] = file end
  end
  return { files = files, c_files = c_files, flow_files = picked(every.flow_files),
    checked = {}, templates = picked(every.templates), refused = {},
    whole = every.whole, every = every, noted = noted }
end

--- Lays out each YAML file of `files` ([`build.flow`]), writing it back
--- unless `checking`: each one that changes, or would, is appended to
--- `changed`, and each one refused -- not in flow style, or not one
--- [`flow.format`] takes -- to `failures`, with why.
function fix.lay_out(files: {string}, checking: boolean, changed: mut {string}, failures: mut {string})
  for _, file in ipairs(files) do
    local source, read_trouble = Fs.read(file)
    local out, flow_trouble: string?, string
    if source == nil then
      flow_trouble = read_trouble
    elseif not flow.is_flow(source) then
      flow_trouble = "not in flow style: only a YAML file whose value opens with { or [ is laid out"
    else
      out, flow_trouble = flow.format(source)
    end
    if out == nil then
      failures[#failures + 1] = file .. ": " .. flow_trouble
    elseif out ~= source then
      local written, write_trouble = true, ""
      if not checking then
        written, write_trouble = Fs.write(file, out)
      end
      if written then
        changed[#changed + 1] = file
      else
        failures[#failures + 1] = file .. ": " .. write_trouble
      end
    end
  end
end

--- The new text of `file`, a file of `kind` whose spans were linked, as it is written: what the verb makes of it with its
--- links in, or nil and why when linking moved the layout of C. Linking changes the text of comments only, which the layout of
--- Teal never reads, so a Teal file laid out stays so ([`build/fix/grammar_tool_test.tl`] holds it).
local function relaid(kind: string, linked: string): string?, string
  if kind == "c" then
    local out, trouble = c_check.laid_out(linked)
    if out == nil then return nil, trouble end
    if out ~= linked then return nil, "linking its spans changes its layout" end
  end
  return linked, ""
end

--- What is wrong with the links of `files` ([`build.links`]), each line
--- `file:line: link: ...`, the file as named; a file that cannot be
--- read is one line of its own. What each link names is looked up in
--- `context`, once for every file. A note says how many links were not
--- checked against symbols the context did not have.
---
--- A Teal file's links are read off the new syntax tree ([`build.syntax_links`]) and it is written with its spans linked at
--- their own positions, never laid out.
---
--- `mode` "write" links each plain span [`build.links`]'s `rewrite`
--- would, writes the file, and checks its links as written; "check"
--- lists each such span in `would` and writes nothing. With no mode,
--- no span is looked at.
function fix.links(context: link_resolve.Context, files: {string}, mode?: string,
                   facts?: {string: links.Facts}): fix.Linked
  local known: {string: links.Facts} = facts or {}
  local resolver = link_resolve.resolver(context)
  local out: mut {string} = {}
  local would: mut {string} = {}
  local redefined: mut {string} = {}
  local rewritten: mut {string} = {}
  for _, file in ipairs(files) do
    local kind = link_files.kind_of(file)
    local source, read_trouble = Fs.read(file)
    local absolute, absolute_trouble = Fs.absolute(file)
    if source == nil then
      out[#out + 1] = file .. ": " .. read_trouble
    elseif absolute == nil then
      out[#out + 1] = file .. ": " .. absolute_trouble
    elseif kind ~= nil then
      if mode ~= nil then
        local linked = SyntaxLinks.rewrite(resolver, file, absolute, kind, source, known[file])
        if linked.source ~= source and mode == "check" then
          for _, line in ipairs(linked.linked) do would[#would + 1] = line end
          if linked.redefined then
            redefined[#redefined + 1] = file .. ": link: its definitions would be rewritten"
          end
        elseif linked.source ~= source then
          local text, trouble = relaid(kind, linked.source)
          if text == nil then
            out[#out + 1] = file .. ": link: " .. trouble
          else
            local written, write_trouble = Fs.write(file, text)
            if written then
              source = text
              rewritten[#rewritten + 1] = file
            else
              out[#out + 1] = file .. ": " .. write_trouble
            end
          end
        end
      end
      for _, line in ipairs(SyntaxLinks.check(resolver, file, absolute, kind, source, known[file])) do
        out[#out + 1] = line
      end
    end
  end
  local resolver_trouble = resolver.trouble
  if resolver_trouble ~= nil then
    out[#out + 1] = "links: reading the symbols: " .. resolver_trouble
  end
  local notes: mut {string} = {}
  if resolver.unchecked > 0 then
    notes[1] = "links: " .. plural.count(resolver.unchecked, "link") ..
      " to a symbol not checked: " .. tostring(context.unbuilt())
  end
  return { broken = out, notes = notes, would = would, redefined = redefined, rewritten = rewritten }
end

local type LinkSource = fix.LinkSource

--- Leaves why the build made to resolve a link failed in `unbuilt` of `target`.
local function leave_why(target: LinkSource, why: string)
  target.unbuilt = why
end

--- Where `fix` reads what links name, over the project at `root`: its
--- databases (`databases`, as [`docs.databases`] answers), opened when
--- a link first names a symbol. A run over part of the tree builds the
--- project first (`rebuild_here`), so an edit is seen; a `whole` run
--- reads the projection its tree checks just wrote. Outside cosmic's
--- own tree (`own`), a project with no projection once that build
--- has run (one that failed, or a `rebuild_here` that made none) has no
--- symbols of its own yet, which the context says rather than failing
--- links to them. `close` closes what was opened. A build that fails
--- leaves why in `unbuilt`.
function fix.link_context(root: string, whole: boolean, own: boolean,
                          rebuild_here: function(string): boolean, string,
                          databases: function(): docs.Sources): fix.LinkSource
  local opened: mut {docs.Sources} = {}
  local source: fix.LinkSource?
  local function open(): docs.View?, string
    if not whole then
      local rebuilt, rebuild_trouble = rebuild_here("fix")
      if not rebuilt then
        -- Opened only once the context below is made and holds this source.
        leave_why(assert(source, "the link context opened before it was made"), rebuild_trouble)
      end
    end
    local found = databases()
    opened[1] = found
    return docs.view(found.handles, found.public)
  end
  local function unbuilt(): string?
    if own then return nil end
    local built_before, _ = Fs.exists(build_paths.resolve(root).projection)
    if built_before then return nil end
    return "the project has no projection yet (`cosmic build` or `cosmic test` makes one)"
  end
  local function close()
    for _, each in ipairs(opened) do
      for _, handle in ipairs(each.opened or {}) do
        local _, _ = handle:close()
      end
    end
  end
  source = { context = links.context(root, open, unbuilt), close = close }
  return source
end

--- Whether `file` is one whose functions `near` compares: not a test,
--- an example or a declaration file, which offer nothing to compare.
local function compared(file: string): boolean
  return not String.ends_with(file, "_test.tl") and
    not String.ends_with(file, "_example.tl") and not String.ends_with(file, ".d.tl")
end

--- The candidate `near` compares for a doc entry, nil for one it passes over: an exported function or method with a
--- doc comment. `signature` tells a method written as a function with a `self` first.
local function candidate_of(exported: boolean, kind: string, text: string, signature: string, source_symbol: string,
                            line: integer): near.Candidate?
  if exported and (kind == "function" or kind == "method") and text ~= "" then
    return { source_symbol = source_symbol, text = text, line = line,
      method = kind == "method" or signature:find("^[^(]*%(%s*self%s*:") ~= nil }
  end
  return nil
end

--- What `near` compares of a file: each exported function or method with a doc comment, read off `chunk`
--- ([`SyntaxAnalyzer.docs`]), the tree of `text`.
local function candidates_from(chunk: Ast.Chunk, text: string): {near.Candidate}
  local candidates: mut {near.Candidate} = {}
  for _, entry in ipairs(SyntaxAnalyzer.docs(chunk, text)) do
    local found = candidate_of(entry.exported, entry.kind, entry.text, entry.signature, entry.source_symbol, entry.line)
    if found ~= nil then candidates[#candidates + 1] = found end
  end
  return candidates
end

--- [`candidates_from`] `source`, as written; nil where it does not parse.
local function written_candidates_of(source: string, file: string): {near.Candidate}?
  local chunk, _ = SyntaxNode.parse(source, file)
  if chunk == nil then return nil end
  return candidates_from(chunk, source)
end

--- `near`'s notes on the exported functions of `files`, each line
--- prefixed with its file: a test, an example or a declaration file
--- offers nothing to compare, nor does a file outside `root`. The module
--- a file declares is read off its path under `root`, as the build names
--- it (`a/b.tl` and `a/b/init.tl` are both `a.b`).
--- @param root string The tree the files are in
--- @param files {string} The files a fix covered
--- @param databases {Sqlite.Handle} Where the standard library's docs are
--- read, in search order: fix's `run` hands it [`Store.databases()`]
--- @param ready? {string: {near.Candidate}} Each file's candidates
--- ([`candidates_from`]), where a parse made already found them; a file
--- missing here is read and parsed again
--- @return {string} One line per note, `file:line: message`
function fix.notes(root: string, files: {string}, databases: {Sqlite.Handle},
                   ready?: {string: {near.Candidate}}): {string}
  -- Each file's path is resolved, so the root must be too: on macOS a
  -- temporary directory is under /var, a link to /private/var.
  local resolved_root, _ = Fs.absolute(root)
  local base = resolved_root or root
  local known, known_trouble = near.known(databases)
  if known == nil then
    return { "comparing with the standard library: " .. known_trouble }
  end
  local prepared = near.index(known)
  local out: mut {string} = {}
  for _, file in ipairs(files) do
    local plain = compared(file)
    local absolute, _ = Fs.absolute(file)
    local relative: string? = nil
    if plain and absolute ~= nil then
      local within, _ = Fs.relative(absolute, base)
      relative = within
    end
    local candidates: {near.Candidate}? = nil
    if relative ~= nil and relative:sub(1, 3) ~= "../" then
      candidates = ready ~= nil and ready[file] or nil
      if candidates == nil then
        local source, _ = Fs.read(file)
        if source ~= nil then
          candidates = written_candidates_of(source, file)
        end
      end
    end
    if candidates ~= nil and relative ~= nil then
      local module = relative:gsub("%.tl$", ""):gsub("/init$", ""):gsub("/", ".")
      for _, note in ipairs(near.notes(module, candidates, known, prepared)) do
        out[#out + 1] = file .. ":" .. note
      end
    end
  end
  return out
end

--- What a run keeps of `file`'s parse, so nothing after it parses the file again: what its links read (`facts`), what the
--- notes compare (`ready`), and, where the tree checks will run, the plurals they look for (`plurals`, by the file's path
--- from the root). `chunk` is the new checker's tree of `source`, as written.
function fix.read_off(file: string, chunk: Ast.Chunk, source: string, facts: mut {string: links.Facts},
                      ready: mut {string: {near.Candidate}}, plurals: mut {string: tree_checks.Plurals}?)
  facts[file] = SyntaxLinks.facts(chunk, SyntaxNode.scope(chunk, file), source)
  if compared(file) then ready[file] = candidates_from(chunk, source) end
  if plurals ~= nil then
    while file:sub(1, 2) == "./" do file = file:sub(3) end
    local found = tree_checks.plurals_in(file, source)
    if found ~= nil then plurals[file] = found end
  end
end

--- Whether `file` is in a tree of its own inside cosmic's own tree at
--- `root` ([`identity.is_foreign_tree`]).
local function in_foreign_tree(root: string, file: string): boolean
  local absolute, _ = Fs.absolute(file)
  if absolute == nil then return false end
  local relative, _ = Fs.relative(absolute, root)
  local first = relative ~= nil and relative:match("^([^/]+)/") or nil
  return first ~= nil and identity.is_foreign_tree(first)
end

--- What the phases of [`fix_verb`] pass on to each other.
local record Fix
  argv: {string}
  started: integer

  -- The command line ([`read_command`]).
  mut checking?: boolean
  mut paths?: {string}
  mut changes_only?: boolean
  mut root?: string
  mut standing?: tree.Standing

  -- The files chosen ([`choose_files`]).
  mut picked?: fix.Chosen
  mut every?: fix.Chosen

  -- What the run has found so far ([`start_tally`] onward).
  mut files?: {string}
  mut counted?: integer
  mut changed?: {string}
  --- The changed files whose only change was a link written.
  mut link_only?: {string:boolean}
  mut failures?: {string}
  --- The Teal files that are not laid out, which a check fails on ([`lay_out_teal`]).
  mut unlaid?: {string}

  -- The C ([`lay_out_c`]).
  mut c_files?: {string}

  -- The Teal ([`lay_out_teal`]).
  mut facts?: {string: links.Facts}
  mut ready?: {string: {near.Candidate}}
  mut plurals?: {string: tree_checks.Plurals}

  -- The build's refusal ([`find_unbuilt`]).
  mut unbuilt?: string

  -- The tree checks ([`run_tree_checks`]).
  mut findings?: {string}

  -- The links ([`check_links`]).
  mut linked_out?: fix.Linked
  mut links_unbuilt?: string
end

--- Reads the command line and the working directory into `ctx`.
--- @return integer | nil The exit code when either is refused, else nil
local function read_command(ctx: Fix): integer?
  local parsed, parse_trouble = Flags.parse(ctx.argv, 2, assert(Cli.verbs.fix.spec))
  if parsed == nil then
    log:complain("fix: " .. parse_trouble)
    return 2
  end
  ctx.checking = parsed.set["--check"] == true
  ctx.paths = parsed.words
  ctx.changes_only = parsed.set["--changed"] == true

  local root, root_trouble = Fs.absolute(".")
  if root == nil then
    log:complain(root_trouble)
    return 1
  end
  ctx.root = root
  return nil
end

--- Chooses the files the run covers, narrowing them for `--changed`.
--- @return integer | nil The exit code when the choice fails, else nil
local function choose_files(ctx: Fix): integer?
  local root = assert(ctx.root)
  local paths = assert(ctx.paths)
  -- A run of `--changed` starts from the whole tree, which it narrows.
  local covered: {string} = paths
  if ctx.changes_only then covered = {} end
  local standing, standing_trouble = tree.standing(root)
  if standing == nil then
    log:complain(standing_trouble)
    return 1
  end
  ctx.standing = standing
  local picked, list_trouble = fix.chosen(root, covered, standing)
  if picked == nil then
    log:complain(list_trouble)
    return 1
  end
  if ctx.changes_only then
    if not picked.whole then
      log:complain("fix: --changed covers only cosmic's own tree, whose checks span files")
      return 2
    end
    picked = fix.narrowed(root, picked, paths, Store.databases())
    local widened = picked.widened
    if widened ~= nil then
      log:say("fix: --changed: laying out the whole tree, since " .. widened)
    else
      log:say("fix: --changed: laying out " .. plural.count(#picked.files + #picked.c_files +
          #picked.flow_files, "file") .. " of the paths named; the checks spanning files " ..
          "cover the whole tree")
    end
  end
  ctx.picked = picked
  -- What the checks spanning files cover: a run of `--changed` lays out
  -- only some of it.
  local every = picked.every
  if every == nil then every = picked end
  ctx.every = every
  return nil
end

--- Starts what the run reports: the files it covers and the failures
--- the choice already holds.
local function start_tally(ctx: Fix)
  local picked = assert(ctx.picked)
  local files = picked.files
  ctx.files = files
  -- A named path the verb would not take counts among the files the run
  -- covers, so the summary says how many of everything asked for was
  -- refused rather than only how many of what survived the naming.
  ctx.counted = #files + #picked.c_files + #picked.flow_files + #picked.checked +
    #picked.templates + #picked.refused
  local failures: mut {string} = {}
  ctx.changed = {}
  ctx.failures = failures
  for _, why in ipairs(picked.refused) do
    failures[#failures + 1] = why
  end
end

--- Parses each template, which has no layout to write back: one the
--- template compiler refuses fails the run with its own reason
--- (`file:line:col: ...`).
local function check_templates(ctx: Fix)
  local picked = assert(ctx.picked)
  local failures = assert(ctx.failures)
  for _, file in ipairs(picked.templates) do
    local source, read_trouble = Fs.read(file)
    if source == nil then
      failures[#failures + 1] = read_trouble
    else
      local made, why = template.compile(source, file)
      if made == nil then failures[#failures + 1] = why end
    end
  end
end

--- Lays out and checks the C files, then lays out the YAML.
local function lay_out_c(ctx: Fix)
  local picked = assert(ctx.picked)
  local root = assert(ctx.root)
  local changed: mut {string} = assert(ctx.changed)
  local failures: mut {string} = assert(ctx.failures)
  -- The C is compiled from the root, so a path named from elsewhere is
  -- taken relative to it.
  local c_files: mut {string} = {}
  for _, file in ipairs(picked.c_files) do
    -- A path that cannot be resolved, or lies outside the root, is
    -- refused below either way; the failure line says why.
    local absolute, _ = Fs.absolute(file)
    local rest: string? = nil
    if absolute ~= nil then
      local relative, _ = Fs.relative(absolute, root)
      rest = relative
    end
    if rest ~= nil and rest ~= "." then
      c_files[#c_files + 1] = rest
    else
      failures[#failures + 1] = file .. ": C is checked only inside the tree"
    end
  end
  ctx.c_files = c_files
  local compiled: mut {string} = {}
  for _, file in ipairs(c_files) do
    local source, read_trouble = Fs.read(root .. "/" .. file)
    local out, layout_trouble: string?, string
    if source ~= nil then
      out, layout_trouble = c_check.laid_out(source)
    else
      layout_trouble = read_trouble
    end
    if out == nil then
      failures[#failures + 1] = file .. ": " .. layout_trouble
    elseif out ~= source then
      changed[#changed + 1] = file
      if not ctx.checking then
        local written, write_trouble = Fs.write(root .. "/" .. file, out)
        if not written then failures[#failures + 1] = write_trouble end
      end
    end
    if String.ends_with(file, ".c") then compiled[#compiled + 1] = file end
  end
  -- What the checks made of the compile of each file is kept in the build directory, so that a file whose inputs have not
  -- changed is not compiled again; without the memo every file is.
  local memo: Sqlite.Handle? = nil
  if #compiled > 0 then
    local opened, _ = Sqlite.open(build_paths.resolve(root).translate_check, { writable = true })
    memo = opened
  end
  local outcomes = c_check.check(root, compiled, nil, nil, memo)
  if memo ~= nil then
    local _, _ = memo:close()
  end
  for _, outcome in ipairs(outcomes) do
    local findings = outcome.findings
    if findings == nil then
      table.insert(failures, outcome.file .. ": " .. assert(outcome.trouble))
    else
      for _, f in ipairs(findings) do
        local variants = f.variants
        -- Named only when the variants it was found in are not all that
        -- its file was checked under.
        local seen = if variants ~= nil and #variants < #assert(outcome.variants) then
          " [" .. table.concat(variants, ", ") .. "]" else "" end
        table.insert(failures, f.file .. ":" .. tostring(f.line) .. ": " .. f.rule ..
            " in " .. f.within .. seen .. ": " .. f.message)
      end
    end
  end
  fix.lay_out(picked.flow_files, ctx.checking == true, changed, failures)
end

--- Lays out the Teal file `file`, whose text is `source` and whose parse is `chunk`, with [`build.fix.format`] (`layout`
--- makes the layout it checks, as `format`'s does): a layout that passes is written unless `checking`, and a file
--- the formatter refuses, or whose layout the parser refuses, is never written. `kept` is the memo of what was found
--- laid out ([`build.fix.laid`]).
function fix.lay_out_source(file: string, source: string, chunk: Ast.Chunk, checking: boolean, kept: laid.Kept?,
                            layout?: Format.Layouter): fix.Laid
  local result = laid.format(kept, source, file, layout)
  local text = result.text
  if text == nil then
    return { state = "refused", text = source, chunk = chunk, why = result.why }
  elseif text == source then
    return { state = "laid", text = source, chunk = chunk, why = "" }
  end
  if checking then
    return { state = "unlaid", text = source, chunk = chunk, why = "" }
  end
  -- What the later phases read is the file as it will stand, so a layout they cannot read is refused unwritten.
  local again, again_refusal = SyntaxNode.parse(text, file)
  if again == nil then
    return { state = "refused", text = source, chunk = chunk, why = file .. ": its layout does not parse: " .. again_refusal }
  end
  -- A write replaces the path with a file of its own, which would turn a link into a copy and leave its target as it is.
  local target, _ = Fs.readlink(file)
  if target ~= nil then
    return { state = "linked", text = source, chunk = chunk, why = "not written: " .. file .. " is a link; fix its target" }
  end
  -- Another editor's save since the file was read is not overwritten.
  local now, _ = Fs.read(file)
  if now ~= source then
    return { state = "changed", text = source, chunk = chunk, why = "not written: " .. file .. " changed while being laid out" }
  end
  -- The file keeps its mode: a script that is executable stays so. [`Fs.write`] gives the mode less the umask, so it is
  -- set again to what the file had.
  local stat, _ = Fs.stat(file)
  local written, write_trouble = Fs.write(file, text, if stat ~= nil then stat.mode & 0xfff else nil end)
  if written and stat ~= nil then
    written, write_trouble = Fs.chmod(file, stat.mode & 0xfff)
  end
  if not written then
    return { state = "unwritable", text = source, chunk = chunk, why = write_trouble }
  end
  return { state = "written", text = text, chunk = again, why = "" }
end

--- `list` as a list of its own, which a phase may add to and hand back: the lists of `ctx` are views.
local function copied(list: {string}): mut {string}
  local out: mut {string} = {}
  for _, item in ipairs(list) do out[#out + 1] = item end
  return out
end

--- Lays out each Teal file ([`build.fix.format`]), keeping what the parse of its text gives the later phases. A plain run
--- writes the layout of a file that is not laid out and lists it as changed. `--check` writes nothing and fails on the
--- files that are not laid out, naming them ([`build.fix.laid`] holds what a file laid out costs a later run). A file the
--- formatter refuses is never written, and is told with the reason: a failure of a plain run and of a check.
--- A file the new parser does not read fails in the new parser's words, with its fix.
local function lay_out_teal(ctx: Fix)
  local files = assert(ctx.files)
  local failures = copied(assert(ctx.failures))
  local picked = assert(ctx.picked)
  local changed = copied(assert(ctx.changed))
  local checking = ctx.checking == true
  -- What the links read of each Teal file, from the parse it was read by.
  local facts: mut {string: links.Facts} = {}
  -- What the notes compare of each file.
  local ready: mut {string: {near.Candidate}} = {}
  -- What the tree checks' plurals read of each file, when they will run.
  local plurals: mut {string: tree_checks.Plurals}? = nil
  if picked.whole then plurals = {} end
  -- What the formatter found laid out is kept in the build directory, so that a file whose text and formatter have not
  -- changed is not formatted again; without the memo every file is.
  local memo: Sqlite.Handle? = nil
  local kept: laid.Kept? = nil
  if #files > 0 then
    local opened, _ = Sqlite.open(build_paths.resolve(assert(ctx.root)).translate_check, { writable = true })
    memo = opened
    if memo ~= nil then kept = laid.begin(memo) end
  end
  local unlaid: mut {string} = {}
  for _, file in ipairs(files) do
    local source, read_trouble = Fs.read(file)
    if source == nil then
      failures[#failures + 1] = read_trouble
    else
      local chunk, refusal = SyntaxNode.parse(source, file)
      if chunk == nil then
        failures[#failures + 1] = refusal
      else
        local done = fix.lay_out_source(file, source, chunk, checking, kept)
        if done.state == "unlaid" then
          unlaid[#unlaid + 1] = file
        elseif done.state == "written" then
          changed[#changed + 1] = file
        elseif done.state ~= "laid" then
          failures[#failures + 1] = done.why
        end
        chunk = done.chunk
        local text = done.text
        fix.read_off(file, chunk, text, facts, ready, plurals)
      end
    end
  end
  if kept ~= nil then
    laid.finish(kept, picked.whole == true and picked.every == nil and #failures == 0)
  end
  if memo ~= nil then
    local _, _ = memo:close()
  end
  ctx.unlaid = unlaid
  ctx.failures = failures
  ctx.changed = changed
  ctx.facts = facts
  ctx.ready = ready
  ctx.plurals = plurals
end

--- The named files that are no input of the project ([`fix.Chosen`]'s `alone`), which the build never reads and so
--- [`find_unbuilt`] cannot vouch for: each is checked on its own as `cosmic --standalone` checks a file ([`Pipeline.lone`]),
--- and the checker's refusal fails the run like a finding of the tree. The log says each was checked alone.
local function check_alone(ctx: Fix)
  local named = assert(ctx.picked).alone
  if named == nil or #named == 0 then return end
  local root = assert(ctx.root)
  local failures: mut {string} = {}
  for _, line in ipairs(assert(ctx.failures)) do failures[#failures + 1] = line end
  local options, options_trouble = Pipeline.alone()
  for _, file in ipairs(named) do
    -- A file that did not read or parse has failed already, in the same words.
    local failed = false
    for _, line in ipairs(failures) do
      if String.starts_with(line, file .. ":") then failed = true end
    end
    local source, _ = Fs.read(file)
    if failed or source == nil then
      -- The layout's own check said why already.
    elseif options == nil then
      failures[#failures + 1] = file .. ": not an input of the tree at " .. root .. " and not checked: " .. options_trouble
    else
      local made = Pipeline.checked_alone(file, source, options)
      local why = "not an input of the tree at " .. root .. ", checked alone"
      if made.code == nil then
        -- One failure for the file, its problems on lines of their own as the build's refusal lists them.
        local hint = ""
        for _, line in ipairs(made.lines) do
          if line:find("require_unknown", 1, true) then
            hint = "\nfix: FAIL  a file checked alone sees only the cosmic modules and a sibling declaration file (`.d.tl`)"
          end
        end
        failures[#failures + 1] = file .. ": " .. why .. ", and refused:\nfix: FAIL  " ..
          table.concat(made.lines, "\nfix: FAIL  ") .. hint
      else
        log:say("fix: " .. file .. ": " .. why)
      end
    end
  end
  ctx.failures = failures
end

--- A tree the build refuses fails the run, saying why: a PASS would read as a tree that builds, which `cosmic test` then
--- refuses. The new checker's build, in its own words: over the whole tree the tree checks' projection says so; a
--- narrower run builds the project here.
local function find_unbuilt(ctx: Fix)
  local picked = assert(ctx.picked)
  local unbuilt: string? = nil
  if not picked.whole then
    local built, why = rebuild.here("fix", true)
    if not built then unbuilt = why end
  end
  ctx.unbuilt = unbuilt
end

--- What the CI legs' promises say against the requirements the tree's
--- test modules declare ([`tree_checks.promises`]), the declarations read
--- from the working database the projection just wrote.
local function promise_findings(root: string): {string}
  local build, open_trouble = Sqlite.open(build_paths.resolve(root).working)
  if build == nil then return { "tree checks: " .. open_trouble } end
  local declared, declared_trouble = tree_checks.requirements(build)
  local _, _ = build:close()
  if declared == nil then return { "tree checks: " .. declared_trouble } end
  for key, name in pairs(c_functions.prerequisites()) do
    declared["C function " .. key] = { name }
  end
  local legs, legs_trouble = tree_checks.legs(root)
  if legs == nil then return { "tree checks: " .. legs_trouble } end
  local out: mut {string} = {}
  for _, line in ipairs(tree_checks.promises(declared, legs)) do
    out[#out + 1] = "promises: " .. line
  end
  return out
end

--- The sealed test modules that name the portable launcher's contract
--- ([`tree_checks.sealed_launch`]), over the projection `db` and the
--- declarations the working database holds.
local function sealed_launch_findings(root: string, db: Sqlite.Handle): {string}
  local build, open_trouble = Sqlite.open(build_paths.resolve(root).working)
  if build == nil then return { "tree checks: " .. open_trouble } end
  local unsealed, unsealed_trouble = tree_checks.unsealed(build)
  local _, _ = build:close()
  if unsealed == nil then return { "tree checks: " .. unsealed_trouble } end
  local out: mut {string} = {}
  for _, line in ipairs(tree_checks.sealed_launch(db, unsealed)) do
    out[#out + 1] = "sealed launch: " .. line
  end
  return out
end

--- Whether the build's own pipeline holds each module as the checks of the tree do, over the working database's inputs
--- ([`tree_checks.pipeline`]).
local function pipeline_findings(root: string, memo: Sqlite.Handle?): {string}
  local build, open_trouble = Sqlite.open(build_paths.resolve(root).working)
  if build == nil then return { open_trouble } end
  local lines = tree_checks.pipeline(root, build, memo)
  local _, _ = build:close()
  return lines
end

--- Says what the tree checks are doing, as a line of the run's log.
local function tree_say(line: string)
  log:say("fix: tree checks: " .. line)
end

--- When the check being run began, in nanoseconds of the monotonic clock,
--- and when the tree checks did.
local record TreeTiming
  mut began: integer
  run_began: integer
end

--- Says on stderr which part of the tree checks begins and how long they
--- have run, so that a part that takes minutes is not silent: [`tree_took`]
--- speaks only once it is over. `step` is "n of m" for the memoed checks.
local function tree_begin(timing: TreeTiming, name: string, step?: string)
  local _, _ = logger.summary("fix", "tree checks: " .. name .. (if step ~= nil then " (" .. step .. ")" else "" end) ..
      ", " .. progress.elapsed(Clock.monotonic_ns() - timing.run_began) .. " in")
end

--- Says how long the check `name` took, where that is long enough to wait on, so that a run that is slow says where, and
--- starts the next check's time.
local function tree_took(timing: TreeTiming, name: string)
  local now = Clock.monotonic_ns()
  local seconds = (now - timing.began) // 1000000000
  if seconds >= 3 then tree_say(name .. ": " .. tostring(seconds) .. " s") end
  timing.began = now
end

--- Over the whole of cosmic's own tree, what only the whole tree can
--- answer ([`build.tree_checks`]), asked of its projection built afresh:
--- a finding is the tree's, not a file's, so it is counted apart.
local function run_tree_checks(ctx: Fix)
  local picked = assert(ctx.picked)
  local root = assert(ctx.root)
  local findings: mut {string} = {}
  ctx.findings = findings
  if picked.whole then
    local timing: TreeTiming = { began = Clock.monotonic_ns(), run_began = Clock.monotonic_ns() }
    tree_begin(timing, "making the projection")
    local db, projection_trouble = tree_checks.projection(root, assert(ctx.standing))
    if db == nil then
      findings[#findings + 1] = "tree checks: " .. projection_trouble
    else
      local guide, guide_trouble = Fs.read(root .. "/doc/guides/quickstart.md")
      if guide == nil then
        findings[#findings + 1] = "tree checks: " .. guide_trouble
      end
      local carried, carried_trouble = docs_checks.carried(build_paths.resolve(root).projection,
        build_paths.resolve(root).docs_check)
      if carried == nil then
        findings[#findings + 1] = "tree checks: " .. carried_trouble
      end
      local help, help_trouble = help_source.texts()
      if help == nil then
        findings[#findings + 1] = "tree checks: " .. help_trouble
      end
      tree_begin(timing, "the checks of the projection, docs and examples")
      local found = tree_checks.run(db, guide, tree_checks.ci_sources(root), carried, help, ctx.plurals)
      for _, line in ipairs(found) do
        findings[#findings + 1] = line
      end
      if carried ~= nil then
        local _, _ = carried:close()
      end
      for _, line in ipairs(example_checks.run(db, root)) do
        findings[#findings + 1] = "examples as shown: " .. line
      end
      for _, line in ipairs(tree_checks.ci_testdata(root)) do
        findings[#findings + 1] = "ci testdata: " .. line
      end
      for _, line in ipairs(tree_checks.package_readers(root)) do
        findings[#findings + 1] = "package: " .. line
      end
      for _, line in ipairs(tree_checks.text_loaders(root)) do
        findings[#findings + 1] = "loaders: " .. line
      end
      -- The ceilings only fall: the file is held to its merge base with main.
      local held = CeilingsBase.check(root, Env.all(), CeilingsBase.live_git())
      for _, line in ipairs(held.lines) do
        findings[#findings + 1] = "ceilings: " .. line
      end
      if held.note ~= "" then
        tree_say("ceilings: " .. held.note)
      end
      -- What the scope builder, the lowering and the checker found in a file that has not changed is kept in the build
      -- directory; without the memo the checks run in full.
      local memo, _ = Sqlite.open(build_paths.resolve(root).translate_check, { writable = true })
      Memprobe.mark("tree checks: before the memoed checks")
      timing.began = Clock.monotonic_ns()
      tree_begin(timing, "scopes", "1 of 5")
      for _, line in ipairs(tree_checks.scoped(root, nil, memo)) do
        findings[#findings + 1] = "scopes: " .. line
      end
      tree_took(timing, "scopes")
      Memprobe.mark("tree checks: scopes")
      tree_begin(timing, "declarations", "2 of 5")
      for _, line in ipairs(tree_checks.declared(root, nil, memo)) do
        findings[#findings + 1] = "declarations: " .. line
      end
      tree_took(timing, "declarations")
      Memprobe.mark("tree checks: declarations")
      tree_begin(timing, "checker", "3 of 5")
      for _, line in ipairs(tree_checks.checked(root, nil, memo)) do
        findings[#findings + 1] = "checker: " .. line
      end
      tree_took(timing, "checker")
      Memprobe.mark("tree checks: checker")
      tree_begin(timing, "pipeline", "4 of 5")
      for _, line in ipairs(pipeline_findings(root, memo)) do
        findings[#findings + 1] = "pipeline: " .. line
      end
      tree_took(timing, "pipeline")
      Memprobe.mark("tree checks: pipeline")
      -- The new checker's own count of the calls no rule judged.
      tree_begin(timing, "untyped", "5 of 5")
      for _, line in ipairs(tree_checks.untyped(root, nil, memo)) do
        findings[#findings + 1] = "untyped: " .. line
      end
      tree_took(timing, "untyped")
      if memo ~= nil then
        local _, _ = memo:close()
      end
      for _, line in ipairs(promise_findings(root)) do
        findings[#findings + 1] = line
      end
      for _, line in ipairs(sealed_launch_findings(root, db)) do
        findings[#findings + 1] = line
      end
      local closed, close_trouble = db:close()
      if not closed then findings[#findings + 1] = "tree checks: " .. close_trouble end
    end
  end
end

--- Every link, once the files are as the run leaves them. What a link
--- names is read from the project's databases, rebuilt first so a
--- narrowed run sees the tree as it stands; over the whole tree, the
--- tree checks just wrote them.
--- A file of a tree inside cosmic's own (`ci/`) names what that
--- tree's own databases hold, so its links are that tree's run's.
--- `root`, [`rebuild.here`] and [`docs.databases`] are the working
--- directory, which a run started below the tree's root has already
--- moved to that root ([`build.tree_root`]).
local function check_links(ctx: Fix)
  local c_files = assert(ctx.c_files)
  local ready = assert(ctx.ready)
  local root = assert(ctx.root)
  local picked = assert(ctx.picked)
  local every = assert(ctx.every)
  local files = assert(ctx.files)
  local changed = assert(ctx.changed)
  -- The files already listed as changed: a link written is listed only for a file that was not.
  local listed: mut {string: boolean} = {}
  for _, file in ipairs(changed) do listed[file] = true end
  local own = assert(ctx.standing).own
  local linked: mut {string} = {}
  local groups: {{string}} = { files, c_files, picked.checked }
  -- TODO: in a run of `--changed`, check the links of only the files
  -- changed and those naming a symbol of a module that changed (what
  -- the projection's `links` rows would say, where they hold each file's
  -- links), not of every file, lexed again without the facts a parse gives: that is some 12 s of such a run's 20.
  if picked.every ~= nil then groups = { every.files, every.c_files, every.checked } end
  for _, group in ipairs(groups) do
    for _, file in ipairs(group) do
      if not (own and in_foreign_tree(root, file)) then linked[#linked + 1] = file end
    end
  end
  local linked_out: fix.Linked
  local links_unbuilt: string? = nil
  do
    -- Built even where no build has been made yet, so that a link resolves alike whether or not a `cosmic test` ran first.
    local source = fix.link_context(root, picked.whole, own,
      function(verb: string): boolean, string return rebuild.here(verb, true) end,
      function(): docs.Sources return docs.databases() end)
    linked_out = fix.links(source.context, linked, if ctx.checking then "check" else "write" end, ctx.facts)
    source.close()
    local unbuilt = source.unbuilt
    -- A refusal the build above met already fails the run.
    if unbuilt ~= nil and ctx.unbuilt == nil then
      links_unbuilt = "links: not rebuilt, resolved from the last build: " .. unbuilt
    end
  end
  -- Held no longer than the links need them.
  local link_only: mut {string:boolean} = {}
  ctx.facts = {}
  ctx.link_only = link_only
  for _, file in ipairs(linked_out.rewritten) do
    -- What the notes kept of its parse is of the text before.
    ready[file] = nil
    if not listed[file] then
      -- Linking was the file's only change.
      link_only[file] = true
      listed[file] = true
      changed[#changed + 1] = file
    end
  end
  ctx.linked_out = linked_out
  ctx.links_unbuilt = links_unbuilt
end

--- Says the notes the links and the heuristics found. A note is a
--- heuristic's, and names what to look at; only one on the standard
--- library, in a run over the whole tree, is a failure: the library as
--- it stands earns no note against itself. The notes compare with every
--- database the binary sees ([`Store.databases()`]).
local function say_notes(ctx: Fix)
  local files = assert(ctx.files)
  local ready = assert(ctx.ready)
  local linked_out = assert(ctx.linked_out)
  local root = assert(ctx.root)
  local picked = assert(ctx.picked)
  local findings = assert(ctx.findings)
  for _, line in ipairs(linked_out.notes) do
    log:say("fix: note  " .. line)
  end

  for _, line in ipairs(fix.notes(root, picked.noted or files, Store.databases(), ready)) do
    local named = line:match("^([^:]*):") or ""
    local absolute, _ = Fs.absolute(named)
    local relative: string? = nil
    if absolute ~= nil then
      local within, _ = Fs.relative(absolute, root)
      relative = within
    end
    if picked.whole and relative ~= nil and tree_checks.standard(relative) then
      findings[#findings + 1] = "near: " .. line
    else
      log:say("fix: note  " .. line)
    end
  end
  if picked.whole then
    log:say("fix: tree checks: ran over the whole tree, " .. tostring(#findings) .. " found")
  end
end

--- What kinds the files of a run are, as "3 Teal + 2 Markdown files": a Markdown
--- file and a Teal one are checked alike but differently fixed. Files
--- refused before their kind was known are in the count and not here.
local function kind_list(picked: fix.Chosen): string
  local markdown, zig = 0, 0
  for _, file in ipairs(picked.checked) do
    if String.ends_with(file, ".zig") then
      zig = zig + 1
    else
      markdown = markdown + 1
    end
  end
  local counts = { #picked.files, #picked.c_files, #picked.flow_files, markdown, zig, #picked.templates }
  local names = { "Teal", "C", "YAML", "Markdown", "Zig", "template" }
  local parts: mut {string} = {}
  for i, name in ipairs(names) do
    local count = assert(counts[i], "a count for each kind named")
    if count > 0 then
      parts[#parts + 1] = tostring(count) .. " " .. name
    end
  end
  return table.concat(parts, " + ")
end

--- The count of files a summary says: "1 Teal file", "3 Teal + 2 Markdown
--- files", or the bare count where refused paths leave no kind to name.
local function files_said(ctx: Fix): string
  local picked = assert(ctx.picked)
  local kinds = kind_list(picked)
  if kinds == "" or #picked.refused > 0 then
    return plural.count(assert(ctx.counted), "file")
  end
  return kinds .. (if ctx.counted == 1 then " file" else " files" end)
end

--- Says each failure, finding and change, then the summary.
--- @return integer The exit code: 0 when nothing is left to fix
local function report(ctx: Fix): integer
  local link_only = assert(ctx.link_only)
  local linked_out = assert(ctx.linked_out)
  local checking = ctx.checking
  local failures = assert(ctx.failures)
  local unlaid = assert(ctx.unlaid)
  local findings = assert(ctx.findings)
  local changed = assert(ctx.changed)
  local counted = assert(ctx.counted)
  local unbuilt = ctx.unbuilt
  local links_unbuilt = ctx.links_unbuilt
  local broken = linked_out.broken
  local would = linked_out.would
  local redefined = linked_out.redefined
  -- A file's own failure names it as it was given (`./a.tl` for `fix
  -- .`), the build's as the tree's: compared without the `./`.
  local function plain(line: string): string
    return (line:gsub("^%./([^:]*): %./", "%1: "))
  end
  local failed: mut {string:boolean} = {}
  for _, line in ipairs(failures) do
    failed[plain(line)] = true
    log:say("fix: FAIL  " .. line)
  end
  for _, file in ipairs(unlaid) do
    log:say("fix: FAIL  not laid out  " .. file)
  end
  for _, line in ipairs(findings) do
    log:say("fix: FAIL  " .. line)
  end
  for _, line in ipairs(broken) do
    log:say("fix: FAIL  " .. line)
  end
  for _, line in ipairs(would) do
    log:say("fix: FAIL  " .. line)
  end
  for _, line in ipairs(redefined) do
    log:say("fix: FAIL  " .. line)
  end
  -- A file that does not parse is refused by its own check and by the
  -- build in the same words: the line is said once.
  if unbuilt ~= nil and not failed[plain(unbuilt)] then
    -- The new checker's refusal lists every file it refused, one per line, among them a file the new parser could not
    -- read, whose line the file's own check said already.
    local rest = ""
    for line in (unbuilt .. "\n"):gmatch("(.-)\n") do
      if failed[plain(line)] ~= true then
        if rest ~= "" then rest = rest .. "\n" end
        rest = rest .. line
      end
    end
    if rest ~= "" then log:say("fix: FAIL  " .. rest) end
  end
  if links_unbuilt ~= nil then
    log:say("fix: FAIL  " .. links_unbuilt)
  end
  local linked = link_only
  for _, file in ipairs(changed) do
    log:say("fix: " .. (if checking then "would fix  " else "fixed  " end) .. file ..
        (if linked[file] then " (links)" else "" end))
  end
  if #failures > 0 or #unlaid > 0 or #findings > 0 or #broken > 0 or #would > 0 or #redefined > 0 or
      unbuilt ~= nil or links_unbuilt ~= nil then
    local said: mut {string} = {}
    if #failures > 0 then
      said[#said + 1] = tostring(#failures) .. " of " .. plural.count(counted, "file") .. " refused"
    end
    if #unlaid > 0 then
      said[#said + 1] = plural.count(#unlaid, "Teal file") .. (if #unlaid == 1 then " is" else " are" end) ..
        " not laid out (`cosmic fix <paths>` lays them out)"
    end
    if #findings > 0 then
      said[#said + 1] = tostring(#findings) .. " found by the tree checks"
    end
    if #broken > 0 then
      said[#said + 1] = plural.count(#broken, "link") .. " not resolving"
    end
    if #would > 0 then
      said[#said + 1] = plural.count(#would, "plain reference") ..
        " to link (`cosmic fix` links them)"
    end
    if #redefined > 0 then
      said[#said + 1] = plural.count(#redefined, "Markdown file") ..
        " whose definitions to rewrite (`cosmic fix` rewrites them)"
    end
    if unbuilt ~= nil then
      said[#said + 1] = "the tree not building"
    end
    if links_unbuilt ~= nil then
      said[#said + 1] = "the links' build failing"
    end
    local _, _ = logger.summary("fix", table.concat(said, ", ") .. ", " .. clock.took(ctx.started))
    return 1
  end
  if checking and #changed > 0 then
    local _, _ = logger.summary("fix", tostring(#changed) .. " of " .. plural.count(counted, "file") .. " to fix, " ..
        clock.took(ctx.started) .. "; `cosmic fix` rewrites them in place")
    return 1
  end
  local _, _ = logger.summary("fix", files_said(ctx) .. ", " .. tostring(#changed) ..
      (if checking then " to fix, " else " fixed, " end) .. clock.took(ctx.started))
  return 0
end

--- `cosmic fix [--check] [path...]`. Each phase above does one part, in
--- order, and the first to answer an exit code ends the run.
--- @param argv {string} The command line, the verb at slot 1
--- @return integer The exit code: 0 when nothing is left to fix
local function fix_verb(argv: {string}): integer
  local ctx: Fix = { argv = argv, started = Clock.monotonic_ns() }
  local code = read_command(ctx)
  if code ~= nil then return code end
  -- In cosmic's own tree the rules are the tree's: a tool
  -- older than the tree would check with the old ones and say nothing, so
  -- it rebuilds itself first and re-enters this command line.
  code = reboot.stale_exit(argv)
  if code ~= nil then return code end
  code = choose_files(ctx)
  if code ~= nil then return code end
  start_tally(ctx)
  lay_out_c(ctx)
  Memprobe.mark("fix: C checked")
  check_templates(ctx)
  lay_out_teal(ctx)
  Memprobe.mark("fix: Teal read")
  check_alone(ctx)
  find_unbuilt(ctx)
  run_tree_checks(ctx)
  Memprobe.mark("fix: tree checks done")
  check_links(ctx)
  Memprobe.mark("fix: links checked")
  say_notes(ctx)
  return report(ctx)
end

--- [`fix_verb`] under Lua's generational collector, and the incremental
--- one, Lua's default, after it. A run holds what the links read of every file
--- ([`links.Facts`]) from its parse to the end, and rebuilds its tree
--- meanwhile: the incremental collector traverses all of it again at
--- each cycle, which costs a whole run more than the rest of the links.
local function run(argv: {string}): integer
  collectgarbage("generational")
  local code = fix_verb(argv)
  collectgarbage("incremental")
  return code
end

--- [`build.fix.format`]'s `format` of `source`, the contents of the file `name`.
function fix.format_text(source: string, name: string): Format.Result
  return Format.format(source, name)
end

--- The `fix` verb as [`build/verb_list.tl`] lists it.
fix.spec = {
  name = "fix",
  summarizes_failure = true,
  guide = "none: a tree-maintenance verb, described by `cosmic help fix`; the quickstart does not cover checking a tree",
  tests = { "build.fix.fix_test" },
  run = function(argv: {string}): integer return run(argv) end,
  bare = false,
  takes = "the files or directories to act on",
}

return fix

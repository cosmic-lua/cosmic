--- `cosmic fix`: rewrite Teal source structurally, then write it back
--- out as canonical text.
---
--- The pipeline runs in one order: parse, apply the structural rules
--- ([`build.fix.rule`]), render ([`build.fix.render`]), break lines
--- ([`build.fix.breaks`]) and render again until no break is added,
--- compare. A fix
--- changes the parsed tree and never patches bytes, and whatever a
--- rule produces is rendered rather than spliced, so a fixed file
--- reads like one that was never fixed.
---
--- One fix only the type checker can place ([`build.fix.spill`]) follows:
--- the tree is built, and every `assert(...)` the checker names as
--- passing on values it should not is parenthesized, until it names
--- none.
---
--- The verb takes paths to narrow it, defaults to the whole tree in the
--- working directory, and writes what it fixes. `--check` writes
--- nothing and reports what it would have changed, which is what a
--- gate runs.
---
--- A second run changes nothing the first did not. The verb renders its
--- own output once more and refuses a file whose second pass would
--- change it, rather than write something that is not a fixed point.
--- CI's format-check step runs `cosmic fix --check .` over the whole
--- tree.
---
--- It also lays out YAML in flow style ([`build.flow`]): a file it is
--- named, and, in cosmic's own tree, the files under `.github/` (the
--- workflows and actions) when a directory covering them is named. A
--- file in block style is refused when named and passed over
--- otherwise. A file that cannot be read ends the run.
---
--- In cosmic's own tree it also covers the tree's C. Every C file is
--- written back in the layout `build.c` holds. Every `.c` file is then
--- compiled to its syntax tree and held to the rules `build.c` holds;
--- a finding refuses the file and is fixed by hand. A header is held
--- to the rules through the files that include it.
---
--- When it covers every Teal source of cosmic's own tree (`cosmic fix
--- --check .`, as CI runs it), it also builds the tree's projection and
--- holds it to the checks only the whole tree can answer
--- ([`build.tree_checks`]), and that every public example and user-guide
--- example compiles as shown, alone ([`build.example_checks`]). A tree that does not build fails, since the
--- checks need its projection, and a note on the standard library
--- fails the run instead of being a note. A run over some paths does
--- none of this.
---
--- `--changed` names the paths that changed since the whole tree passed
--- (`cosmic fix --check --changed $(git diff --name-only main)`): it
--- lays out only those, yet answers as a run over the whole tree would,
--- making every check that spans files over all of it
--- ([`fix.narrowed`]). Where a path named is part of what checks each
--- file alone (the layout, the C rules, the compiler), it lays out the
--- whole tree, and says why. A branch's CI runs it in place of the
--- whole tree's check; the merge queue still runs that.
---
--- In any project it also holds the links in comments and Markdown to
--- resolving ([`build.links`]): each Teal and C file it covers, and each
--- Markdown and Zig file, which it never lays out. A plain code span
--- that would link to one thing is made a link ([`build.links`]'s
--- `rewrite`), and `--check` fails on one it would link.

local Cli = require("cosmic.cli")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local identity = require("build.identity")
local c_check = require("build.c")
local Store = require("cosmic.store")
local String = require("cosmic.string")
local Clock = require("cosmic.clock")
local clock = require("build.clock")
local docs = require("build.docs")
local docs_checks = require("build.docs_checks")
local help_source = require("build.help_source")
local ast = require("build.ast")
local equiv = require("build.fix.equiv")
local flow = require("build.flow")
local link_files = require("build.link_files")
local link_resolve = require("build.link_resolve")
local links = require("build.links")
local near = require("build.fix.near")
local analyzer = require("build.analyzer")
local reboot = require("build.reboot")
local rebuild = require("build.rebuild")
local render_mod = require("build.fix.render")
local rule = require("build.fix.rule")
local spill = require("build.fix.spill")
local teal = require("build.teal")
local tree = require("build.tree")
local example_checks = require("build.example_checks")
local tree_checks = require("build.tree_checks")
local type compiler = require("build.compiler")
local Sqlite = require("cosmic.sqlite")

local log = require("build.verdict").log
local verb_spec = require("build.verb_spec")
local plural = require("build.plural")

local record fix
  --- The verb's registration: see build/verb_spec.tl.
  spec: verb_spec.Spec
  --- What one file's pipeline produced, and whether it differs from
  --- what is on disk. Bundled into one record rather than returned as
  --- separate slots: the first return admits nil, and a fallible return
  --- may declare at most two slots.
  record Fixed
    source: string
    changed: boolean
    --- The parse of `source`.
    parsed: ast.Parsed
  end

  --- The files one invocation covers, and the named paths it will not
  --- take: one that is not there, and one that is not a source the verb
  --- handles. A refused path is carried here rather than ending the verb,
  --- so it is reported and counted like any other refused file and the
  --- run still ends in the verb's verdict line.
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

  --- Where links' names are read, and how to close what that opened.
  record LinkSource
    context: link_resolve.Context
    close: function()
    --- Why the build made to resolve a link failed, once one has: the
    --- links then resolved against the last build, and the run fails.
    unbuilt: string | nil
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
    --- Whether `files` are every Teal source of cosmic's own tree, as
    --- `cosmic fix --check .` covers it: only then does the run hold
    --- the tree to [`build.tree_checks`]. A run of `--changed` is whole
    --- too ([`fix.narrowed`]).
    whole: boolean
    --- For a run of `--changed`, everything a run over the whole tree
    --- covers, which the checks spanning files still cover: the asserts
    --- the build refuses and the links; nil for any other run.
    every: Chosen | nil
    --- For a run of `--changed`, the Teal files whose notes it reads
    --- ([`fix.notes`]), where these are not `files`.
    noted: {string} | nil
    --- For a run of `--changed` that lays out the whole tree after all,
    --- why: a path named that is part of what checks each file alone.
    widened: string | nil
  end
end

--- What is never a file to fix: the build's own output, the upstream
--- sources and the records that patch them, the C core, the one shell
--- script that fetches zig, and anything hidden.
local not_source: {string:boolean} = {
  ["o"] = true,
  ["vendor"] = true,
  ["patch"] = true,
  ["bin"] = true,
  ["core"] = true,
}

local function skip(entry: string): boolean
  local first = entry:match("^([^/]+)") or entry
  if not_source[first] then
    return true
  end
  return Fs.basename(entry):sub(1, 1) == "."
end

--- Every Teal source under `root`, as paths relative to it. Declaration
--- files count, since the renderer must write them back unchanged like
--- any other source.
--- @param root string
--- @return {string}|nil
--- @return string Error message on failure
local function sources(root: string): {string} | nil, string
  local files, trouble = Fs.walk(root, skip)
  if files == nil then
    return nil, trouble
  end
  local out: {string} = {}
  for _, file in ipairs(files) do
    if String.ends_with(file, ".tl") then
      out[#out + 1] = file
    end
  end
  return out
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
local function checked_sources(root: string): {string} | nil, string
  local files, trouble = link_files.walk(root)
  if files == nil then
    return nil, trouble
  end
  local out: {string} = {}
  for _, file in ipairs(files) do
    local core_teal = file:sub(1, 5) == "core/" and
      (String.ends_with(file, ".tl") or String.ends_with(file, ".lua"))
    if check_only(file) or core_teal then out[#out + 1] = file end
  end
  return out
end

--- Whether `files`, however each was named, hold every Teal source
--- under `root`.
local function covers(root: string, files: {string}): boolean
  local all, _ = sources(root)
  if all == nil then return false end
  local named: {string: boolean} = {}
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
local function workflow_sources(dir: string, root: string): {string} | nil, string
  dir = dir:gsub("/+$", "")
  if dir == "" then dir = "/" end
  local absolute, _ = Fs.absolute(dir)
  local top, _ = Fs.absolute(root)
  local inside: string | nil = nil
  if absolute ~= nil and top ~= nil then
    local relative, _ = Fs.relative(absolute, top)
    if relative ~= nil and relative ~= ".." and relative:sub(1, 3) ~= "../" then
      inside = relative
    end
  end
  if inside == nil then
    return {}
  end
  local within = inside == ".github" or inside:sub(1, 8) == ".github/"
  if not within and inside ~= "." then
    return {}
  end
  local base = within and dir or dir .. "/.github"
  local prefix = within and "" or ".github/"
  local st, _ = Fs.stat(base)
  if st == nil or st.kind ~= "dir" then
    return {}
  end
  local files, trouble = Fs.walk(base, function(entry: string): boolean
    return Fs.basename(entry):sub(1, 1) == "."
  end)
  if files == nil then
    return nil, trouble
  end
  local out: {string} = {}
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
  return out
end

--- How many times [`fix.source`] breaks lines and renders again before
--- it gives up on a file: a pass opens the outermost blocks a line
--- holds, the next those they held, and blocks nest only so deep on one
--- line.
local breaking_passes <const> = 16

--- The whole pipeline over one file's source: parse, rewrite, render,
--- and check that rendering still says the same thing and has reached a
--- fixed point.
---
--- Both checks are part of the verb, not tests. A renderer that is
--- only self-consistent can be consistently wrong: `local x <const> = 5`
--- re-emitted as `local x < const > = 5` is stable and idempotent. So
--- rendered text that differs from its input is parsed again and
--- compared, tree and comments, with the tree it came from. Identical
--- bytes preserve both and need no second parse. A file that fails the
--- comparison is reported and left as it was.
---
--- Before either, lines are broken ([`build.fix.breaks`]) and the
--- result rendered again, as many times as a render finds a break due.
---
--- The output is then rendered once more from the tree in hand and must
--- come back byte for byte, since a fix that a second pass would still
--- change is not done. When the first render left the text untouched,
--- there is nothing to check: it rendered this very tree and text, so
--- the common case costs one render and one parse.
--- @param built compiler The loaded compiler capsule ([`build.teal.load()`])
--- @param source string
--- @param name string Filename used in diagnostics
--- @return fix.Fixed|nil What to write, and whether it differs
--- @return string Error message on failure
function fix.source(built: compiler, source: string,
                    name: string): fix.Fixed | nil, string
  local rewritten, rule_trouble = rule.apply(built, source, name)
  if rewritten == nil then
    return nil, rule_trouble
  end
  local before, parse_trouble = ast.parse(built, rewritten, name)
  if before == nil then
    return nil, parse_trouble
  end
  -- Each render says which line breaks the file still lacks; those are
  -- written into its source, which is parsed and rendered again. A
  -- break can leave a block that sat on one line too long for it, or
  -- holding a block it did not before, so this repeats until none is
  -- due, which for a file already laid out is the first render.
  local parsed, text = before, rewritten
  local out: string
  for pass = 1, breaking_passes do
    local layout, render_trouble = render_mod.laid_out(parsed, text)
    if layout == nil then
      return nil, render_trouble
    end
    local opened = layout.opened
    if opened == nil then
      out = layout.text
      break
    end
    if pass == breaking_passes then
      return nil, "breaking lines did not settle in " .. breaking_passes .. " passes"
    end
    local reparsed, trouble = ast.parse(built, opened, name)
    if reparsed == nil then
      return nil, "what was broken onto lines does not parse: " .. trouble
    end
    parsed, text = reparsed, opened
  end
  local parsed_out = before
  if out ~= rewritten then
    local after, reparse_trouble = ast.parse(built, out, name)
    if after == nil then
      return nil, "what was rendered does not parse: " .. reparse_trouble
    end
    local same, difference = equiv.same_tree(before.node, after.node)
    if not same then
      return nil, "rendering changed the program: " .. difference
    end
    local kept, lost = equiv.same_comments(before.tokens, after.tokens)
    if not kept then
      return nil, "rendering changed the comments: " .. lost
    end
    parsed_out = after
  end
  if out == text then
    -- The last render was of this text, parsed, and gave it back
    -- unchanged; another gives the same.
    return { source = out, changed = out ~= source, parsed = parsed_out }
  end
  local again, again_trouble = render_mod.laid_out(parsed_out, out)
  if again == nil then
    return nil, "a second pass over what was rendered refused it: " .. again_trouble
  end
  if again.text ~= out or again.opened ~= nil then
    return nil, "rendering is not a fixed point: a second pass changed it"
  end
  return { source = out, changed = out ~= source, parsed = parsed_out }
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
function fix.chosen(root: string, paths: {string}): fix.Chosen | nil, string
  local own, own_trouble = tree.is_own(root)
  if own == nil then
    return nil, own_trouble
  end
  if #paths == 0 then
    local all, trouble = sources(root)
    if all == nil then
      return nil, trouble
    end
    local checked, checked_trouble = checked_sources(root)
    if checked == nil then
      return nil, checked_trouble
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
      refused = {}, whole = own }
  end
  local out: {string} = {}
  local c_out: {string} = {}
  local flow_out: {string} = {}
  local checked_out: {string} = {}
  local refused: {string} = {}
  for _, path in ipairs(paths) do
    local what, missing = Fs.stat(path)
    if what == nil then
      refused[#refused + 1] = missing
    elseif what.kind == "dir" then
      local under, trouble = sources(path)
      if under == nil then
        return nil, trouble
      end
      for _, file in ipairs(under) do
        out[#out + 1] = path .. "/" .. file
      end
      local checked, checked_trouble = checked_sources(path)
      if checked == nil then
        return nil, checked_trouble
      end
      for _, file in ipairs(checked) do
        checked_out[#checked_out + 1] = path .. "/" .. file
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
    elseif not String.ends_with(path, ".tl") then
      refused[#refused + 1] = path .. ": not a Teal or C source, YAML, Markdown or Zig"
    else
      out[#out + 1] = path
    end
  end
  return { files = out, c_files = c_out, flow_files = flow_out, checked = checked_out,
    refused = refused, whole = own and covers(root, out) }
end

--- The modules whose code checks each file alone, with every module
--- each requires: the layout of Teal ([`build.fix.rule`],
--- [`build.fix.render`], [`build.fix.breaks`], [`build.fix.equiv`], [`build.ast`], and the
--- compiler [`build.teal`] loads), of YAML ([`build.flow`]), of C and
--- its rules ([`build.c`]), a note on the standard library
--- ([`build.fix.near`], [`build.analyzer`]), and what reads the command
--- line, says the verdict and tells cosmic's own tree ([`build.tree`]),
--- whose files a run over the whole of it covers. A change to one can
--- change the verdict on a file that did not change, so a run of
--- `--changed` naming one lays out the whole tree ([`fix.narrowed`]).
--- What checks the tree as a
--- whole -- the build, the tree checks, the links -- is not among them:
--- such a run makes those checks over the whole tree anyway.
local file_checks: {string} = { "build.fix.rule", "build.fix.render", "build.fix.breaks",
  "build.fix.equiv", "build.ast", "build.teal", "build.flow", "build.c",
  "build.fix.near", "build.analyzer", "build.verdict",
  "build.tree", "cosmic.flags", "cosmic.cli" }

--- What else a run of `--changed` lays out the whole tree for, by a
--- path's first directory, and why: what the program, its Teal compiler
--- and the clang that reads each C file are built from or run on. A
--- test there (`core/*_test.tl`) is none of these.
local file_check_dirs: {string: string} = {
  ["vendor"] = "the program and its Teal compiler are built from vendor/",
  ["patch"] = "the program and its Teal compiler are built from patch/'s records",
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
  ["build/patch.tl"] = "the program's Teal compiler is patched by build/patch.tl",
  ["ci/cosmic-driver.pin"] = "the C rules run clang through the cosmic it pins",
}

--- `path` as a path under `root` without a leading `./` or trailing
--- `/`, "" for the root itself; nil for one outside it.
local function under(root: string, path: string): string | nil
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
local function file_check_sources(databases: {Sqlite.Handle}): {string: boolean} | nil, string
  local roots: {string} = {}
  for _, module in ipairs(file_checks) do roots[#roots + 1] = "('" .. module .. "')" end
  local query = "WITH RECURSIVE closure(module) AS (VALUES " .. table.concat(roots, ", ") ..
    " UNION SELECT imports.requires FROM imports JOIN closure ON imports.path = closure.module) " ..
    "SELECT modules.path, modules.file FROM closure JOIN modules ON modules.path = closure.module"
  local out: {string: boolean} = {}
  local found: {string: boolean} = {}
  for _, db in ipairs(databases) do
    local rows, _ = Sqlite.text_rows(db, query)
    for _, row in ipairs(rows or {}) do
      found[row[1]] = true
      out[row[2]] = true
    end
  end
  for _, module in ipairs(file_checks) do
    if not found[module] then
      return nil, module .. " is not among the program's modules"
    end
  end
  return out
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
      checked = every.checked, refused = every.refused, whole = every.whole,
      every = every, widened = why }
  end
  local named: {string} = {}
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
    local why: string | nil = nil
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
    local out: {string} = {}
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
  local noted: {string} = {}
  for _, file in ipairs(every.files) do
    if tree_checks.standard(under(root, file) or file) then noted[#noted + 1] = file end
  end
  for _, file in ipairs(files) do
    if not tree_checks.standard(under(root, file) or file) then noted[#noted + 1] = file end
  end
  return { files = files, c_files = c_files, flow_files = picked(every.flow_files),
    checked = {}, refused = {}, whole = every.whole, every = every, noted = noted }
end

--- Lays out each YAML file of `files` ([`build.flow`]), writing it back
--- unless `checking`: each one that changes, or would, is appended to
--- `changed`, and each one refused -- not in flow style, or not one
--- [`flow.format`] takes -- to `failures`, with why.
function fix.lay_out(files: {string}, checking: boolean, changed: {string}, failures: {string})
  for _, file in ipairs(files) do
    local source, read_trouble = Fs.read(file)
    local out, flow_trouble: string, string
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

--- The new text of `file`, a file of `kind` whose spans were linked,
--- as it is written: what the verb makes of it with its links in, or
--- nil and why when linking moved what the rest of the verb writes.
local function relaid(built: compiler, kind: string, file: string, linked: string): string | nil, string
  if kind == "teal" then
    local result, trouble = fix.source(built, linked, file)
    if result == nil then return nil, trouble end
    if result.changed then return nil, "linking its spans changes its rendering" end
  elseif kind == "c" then
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
--- A Teal file not in `laid_out`, when it is given, is written with
--- its spans linked and not rendered: the verb lays out no other.
---
--- `mode` "write" links each plain span [`build.links`]'s `rewrite`
--- would, writes the file, and checks its links as written; "check"
--- lists each such span in `would` and writes nothing. With no mode,
--- no span is looked at.
--- @param built compiler The loaded compiler, which lexes Teal
function fix.links(context: link_resolve.Context, built: compiler, files: {string},
                   mode?: string, facts?: {string: links.Facts},
                   laid_out?: {string: boolean}): fix.Linked
  local known: {string: links.Facts} = facts or {}
  local resolver = link_resolve.resolver(context)
  local out: {string} = {}
  local would: {string} = {}
  local redefined: {string} = {}
  local rewritten: {string} = {}
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
        local linked = links.rewrite(resolver, file, absolute, kind, source, built, known[file])
        if linked.source ~= source and mode == "check" then
          for _, line in ipairs(linked.linked) do would[#would + 1] = line end
          if linked.redefined then
            redefined[#redefined + 1] = file .. ": link: its definitions would be rewritten"
          end
        elseif linked.source ~= source then
          local text, trouble: string, string = linked.source, ""
          if laid_out == nil or laid_out[file] or kind ~= "teal" then
            text, trouble = relaid(built, kind, file, linked.source)
          end
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
      for _, line in ipairs(links.check(resolver, file, absolute, kind, source, built, known[file])) do
        out[#out + 1] = line
      end
    end
  end
  if resolver.trouble ~= nil then
    out[#out + 1] = "links: reading the symbols: " .. resolver.trouble
  end
  local notes: {string} = {}
  if resolver.unchecked > 0 then
    notes[1] = "links: " .. plural.count(resolver.unchecked, "link") ..
      " to a symbol not checked: " .. tostring(context.unbuilt())
  end
  return { broken = out, notes = notes, would = would, redefined = redefined, rewritten = rewritten }
end

--- Where `fix` reads what links name, over the project at `root`: its
--- databases (`databases`, as [`docs.databases`] answers), opened when
--- a link first names a symbol. A run over part of the tree builds the
--- project first (`rebuild_here`), so an edit is seen; a `whole` run
--- reads the projection its tree checks just wrote. Outside cosmic's
--- own tree (`own`), a project with no `o/cosmic.db` once that build
--- has run (one that failed, or a `rebuild_here` that made none) has no
--- symbols of its own yet, which the context says rather than failing
--- links to them. `close` closes what was opened. A build that fails
--- leaves why in `unbuilt`.
function fix.link_context(root: string, whole: boolean, own: boolean,
                          rebuild_here: function(string): boolean, string,
                          databases: function(): docs.Sources): fix.LinkSource
  local opened: docs.Sources | nil = nil
  local source: fix.LinkSource
  local function open(): docs.View | nil, string
    if not whole then
      local rebuilt, rebuild_trouble = rebuild_here("fix")
      if not rebuilt then source.unbuilt = rebuild_trouble end
    end
    local found = databases()
    opened = found
    return docs.view(found.handles, found.public)
  end
  local function unbuilt(): string | nil
    if own then return nil end
    local built_before, _ = Fs.exists(root .. "/o/cosmic.db")
    if built_before then return nil end
    return "the project has no o/cosmic.db yet (`cosmic build` or `cosmic test` makes one)"
  end
  local function close()
    if opened ~= nil then
      for _, handle in ipairs(opened.opened or {}) do
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

--- What `near` compares of a file: each exported function or method
--- with a doc comment, read off a parse already made of `source`.
local function candidates_of(parsed: ast.Parsed, source: string): {near.Candidate}
  local candidates: {near.Candidate} = {}
  for _, entry in ipairs(analyzer.docs(parsed, source)) do
    if entry.exported and (entry.kind == "function" or entry.kind == "method") and
        entry.text ~= "" then
      candidates[#candidates + 1] = { source_symbol = entry.source_symbol,
        text = entry.text, line = entry.line }
    end
  end
  return candidates
end

--- `near`'s notes on the exported functions of `files`, each line
--- prefixed with its file: a test, an example or a declaration file
--- offers nothing to compare, nor does a file outside `root`. The module
--- a file declares is read off its path under `root`, as the build names
--- it (`a/b.tl` and `a/b/init.tl` are both `a.b`).
--- @param built compiler The loaded compiler
--- @param root string The tree the files are in
--- @param files {string} The files a fix covered
--- @param databases {Sqlite.Handle} Where the standard library's docs are
--- read, in search order: fix's `run` hands it [`Store.databases()`]
--- @param ready? {string: {near.Candidate}} Each file's candidates
--- ([`candidates_of`]), where a parse made already found them; a file
--- missing here is read and parsed again
--- @return {string} One line per note, `file:line: message`
function fix.notes(built: compiler, root: string, files: {string},
                   databases: {Sqlite.Handle}, ready?: {string: {near.Candidate}}): {string}
  -- Each file's path is resolved, so the root must be too: on macOS a
  -- temporary directory is under /var, a link to /private/var.
  local resolved_root, _ = Fs.absolute(root)
  local base = resolved_root or root
  local known, known_trouble = near.known(databases)
  if known == nil then
    return { "comparing with the standard library: " .. known_trouble }
  end
  local prepared = near.index(known)
  local out: {string} = {}
  for _, file in ipairs(files) do
    local plain = compared(file)
    local absolute, _ = Fs.absolute(file)
    local relative: string | nil = nil
    if plain and absolute ~= nil then
      local within, _ = Fs.relative(absolute, base)
      relative = within
    end
    local candidates: {near.Candidate} | nil = nil
    if relative ~= nil and relative:sub(1, 3) ~= "../" then
      candidates = ready ~= nil and ready[file] or nil
      if candidates == nil then
        local source, _ = Fs.read(file)
        if source ~= nil then
          local parsed, _ = ast.parse(built, source, file)
          if parsed ~= nil then
            candidates = candidates_of(parsed, source)
          end
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

--- What a run keeps of `file`'s parse, made in fixing it, so nothing
--- after parses it again: what its links read (`facts`), what the
--- notes compare (`ready`), and, where the tree checks will run, the
--- plurals they look for (`plurals`, by the file's path from the root).
local function read_off(file: string, result: fix.Fixed,
                        facts: {string: links.Facts}, ready: {string: {near.Candidate}},
                        plurals: {string: tree_checks.Plurals} | nil)
  facts[file] = links.facts(result.parsed, result.source)
  if compared(file) then
    ready[file] = candidates_of(result.parsed, result.source)
  end
  if plurals ~= nil then
    while file:sub(1, 2) == "./" do file = file:sub(3) end
    plurals[file] = tree_checks.plurals_in(file, result.source, result.parsed)
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
  argv: {integer:string}
  started: integer

  -- The command line ([`read_command`]).
  checking: boolean
  paths: {string}
  changes_only: boolean
  root: string

  -- The files chosen ([`choose_files`]).
  picked: fix.Chosen
  every: fix.Chosen

  -- The compiler ([`load_compiler`]).
  built: compiler

  -- What the run has found so far ([`start_tally`] onward).
  files: {string}
  counted: integer
  changed: {string}
  failures: {string}

  -- The C ([`lay_out_c`]).
  c_files: {string}

  -- The Teal ([`lay_out_teal`]).
  facts: {string: links.Facts}
  ready: {string: {near.Candidate}}
  plurals: {string: tree_checks.Plurals} | nil

  -- The asserts ([`wrap_asserts`]).
  listed: {string:boolean}
  refused: string
  spilled: boolean

  -- The build's refusal ([`find_unbuilt`]).
  unbuilt: string | nil

  -- The tree checks ([`run_tree_checks`]).
  findings: {string}

  -- The links ([`check_links`]).
  linked_out: fix.Linked
  links_unbuilt: string | nil
end

--- Reads the command line and the working directory into `ctx`.
--- @return integer | nil The exit code when either is refused, else nil
local function read_command(ctx: Fix): integer | nil
  local parsed, parse_trouble = Flags.parse(ctx.argv, 2, Cli.verbs.fix.spec)
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
local function choose_files(ctx: Fix): integer | nil
  local root = ctx.root
  local paths = ctx.paths
  -- A run of `--changed` starts from the whole tree, which it narrows.
  local covered: {string} = paths
  if ctx.changes_only then covered = {} end
  local picked, list_trouble = fix.chosen(root, covered)
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
    if picked.widened ~= nil then
      log:say("fix: --changed: laying out the whole tree, since " .. picked.widened)
    else
      log:say("fix: --changed: laying out " .. plural.count(#picked.files + #picked.c_files +
          #picked.flow_files, "file") .. " of the paths named; the checks spanning files " ..
          "cover the whole tree")
    end
  end
  ctx.picked = picked
  -- What the checks spanning files cover: a run of `--changed` lays out
  -- only some of it.
  ctx.every = picked.every or picked
  return nil
end

--- Loads the Teal compiler.
--- @return integer | nil The exit code when it does not load, else nil
local function load_compiler(ctx: Fix): integer | nil
  local built, load_trouble = teal.load()
  if built == nil then
    log:complain(load_trouble)
    return 1
  end
  ctx.built = built
  return nil
end

--- Starts what the run reports: the files it covers and the failures
--- the choice already holds.
local function start_tally(ctx: Fix)
  local picked = ctx.picked
  ctx.files = picked.files
  -- A named path the verb would not take counts among the files the run
  -- covers, so the verdict says how many of everything asked for was
  -- refused rather than only how many of what survived the naming.
  ctx.counted = #ctx.files + #picked.c_files + #picked.flow_files + #picked.checked +
    #picked.refused
  ctx.changed = {}
  ctx.failures = {}
  for _, why in ipairs(picked.refused) do
    ctx.failures[#ctx.failures + 1] = why
  end
end

--- Lays out and checks the C files, then lays out the YAML.
local function lay_out_c(ctx: Fix)
  local root = ctx.root
  local changed = ctx.changed
  local failures = ctx.failures
  -- The C is compiled from the root, so a path named from elsewhere is
  -- taken relative to it.
  local c_files: {string} = {}
  for _, file in ipairs(ctx.picked.c_files) do
    -- A path that cannot be resolved, or lies outside the root, is
    -- refused below either way; the failure line says why.
    local absolute, _ = Fs.absolute(file)
    local rest: string | nil = nil
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
  local compiled: {string} = {}
  for _, file in ipairs(c_files) do
    local source, read_trouble = Fs.read(root .. "/" .. file)
    local out, layout_trouble: string, string
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
  for _, outcome in ipairs(c_check.check(root, compiled)) do
    if outcome.findings == nil then
      failures[#failures + 1] = outcome.file .. ": " .. outcome.trouble
    else
      for _, f in ipairs(outcome.findings) do
        failures[#failures + 1] = f.file .. ":" .. f.line .. ": " .. f.rule ..
          " in " .. f.within .. ": " .. f.message
      end
    end
  end
  fix.lay_out(ctx.picked.flow_files, ctx.checking, changed, failures)
end

--- Lays out each Teal file, keeping what its parse gives the later
--- phases.
local function lay_out_teal(ctx: Fix)
  local checking = ctx.checking
  local changed = ctx.changed
  local failures = ctx.failures
  -- What the links read of each Teal file, from the parse its fix made,
  -- while the file on disk is what was parsed.
  local facts: {string: links.Facts} = {}
  -- What the notes compare of each file whose text on disk the parse
  -- read, kept from that parse rather than parsing it again.
  local ready: {string: {near.Candidate}} = {}
  -- What the tree checks' plurals read of each file, when they will run.
  local plurals: {string: tree_checks.Plurals} | nil = nil
  if ctx.picked.whole then plurals = {} end
  for _, file in ipairs(ctx.files) do
    local source, read_trouble = Fs.read(file)
    if source == nil then
      failures[#failures + 1] = read_trouble
    else
      local result, trouble = fix.source(ctx.built, source, file)
      if result == nil then
        failures[#failures + 1] = file .. ": " .. trouble
      elseif result.changed then
        changed[#changed + 1] = file
        if not checking then
          local written, write_trouble = Fs.write(file, result.source)
          if not written then
            failures[#failures + 1] = write_trouble
          else
            read_off(file, result, facts, ready, plurals)
          end
        end
      else
        read_off(file, result, facts, ready, plurals)
      end
    end
  end
  ctx.facts = facts
  ctx.ready = ready
  ctx.plurals = plurals
end

--- What only the checker can see: built from what is on disk, so a
--- check reports the files once and a fix repeats until it settles.
local function wrap_asserts(ctx: Fix)
  local root = ctx.root
  local checking = ctx.checking
  local built = ctx.built
  local changed = ctx.changed
  local failures = ctx.failures
  local facts = ctx.facts
  local ready = ctx.ready
  local chosen_files: {string:string} = {}
  for _, file in ipairs(ctx.every.files) do
    local absolute, _ = Fs.absolute(file)
    if absolute ~= nil then chosen_files[absolute] = file end
  end
  local listed: {string:boolean} = {}
  for _, file in ipairs(changed) do listed[file] = true end
  local rounds = 0
  local refused = ""
  local spilled = false
  while true do
    local checked, check_trouble = spill.check(root)
    if checked == nil then
      failures[#failures + 1] = "checking asserts: " .. check_trouble
      break
    end
    refused = checked.refused
    spilled = false
    local wrapped = false
    for name, at in pairs(checked.sites) do
      local file = chosen_files[root .. "/" .. name]
      if file ~= nil then spilled = true end
      if file ~= nil and not checking then
        local source, read_trouble = Fs.read(file)
        local out, wrap_trouble: string, string
        if source ~= nil then
          out, wrap_trouble = spill.wrap(built, source, file, at)
        else
          wrap_trouble = read_trouble
        end
        local result: fix.Fixed
        if out ~= nil then
          result, wrap_trouble = fix.source(built, out, file)
        end
        if result == nil then
          failures[#failures + 1] = file .. ": " .. wrap_trouble
        elseif result.source ~= source then
          facts[file] = nil
          ready[file] = nil
          local written, write_trouble = Fs.write(file, result.source)
          if not written then
            failures[#failures + 1] = write_trouble
          else
            wrapped = true
          end
        end
      end
      if file ~= nil and (checking or wrapped) and not listed[file] then
        listed[file] = true
        changed[#changed + 1] = file
      end
    end
    rounds = rounds + 1
    if checking or not wrapped then break end
    if rounds >= 50 then
      failures[#failures + 1] = "wrapping asserts did not settle after " .. plural.count(rounds, "build")
      break
    end
  end
  ctx.listed = listed
  ctx.refused = refused
  ctx.spilled = spilled
end

--- A tree the build refuses fails the run, saying why: a PASS would
--- read as a tree that builds, which `cosmic test` then refuses. A
--- check whose build names a spill in a file it covers counts that
--- file to fix instead, since the checker reports each spill with an
--- error of its own; over the whole tree, the tree checks' projection
--- refuses it.
local function find_unbuilt(ctx: Fix)
  local unbuilt: string | nil = nil
  if not ctx.picked.whole and ctx.refused ~= "" and not (ctx.checking and ctx.spilled) then
    unbuilt = ctx.refused
  end
  ctx.unbuilt = unbuilt
end

--- Over the whole of cosmic's own tree, what only the whole tree can
--- answer ([`build.tree_checks`]), asked of its projection built afresh:
--- a finding is the tree's, not a file's, so it is counted apart.
local function run_tree_checks(ctx: Fix)
  local root = ctx.root
  local built = ctx.built
  local findings: {string} = {}
  ctx.findings = findings
  if ctx.picked.whole then
    local db, projection_trouble = tree_checks.projection(root, built)
    if db == nil then
      findings[#findings + 1] = "tree checks: " .. projection_trouble
    else
      local guide, guide_trouble = Fs.read(root .. "/doc/guides/quickstart.md")
      if guide == nil then
        findings[#findings + 1] = "tree checks: " .. guide_trouble
      end
      local carried, carried_trouble = docs_checks.carried(root .. "/o/cosmic.db",
        root .. "/o/docs-check.db")
      if carried == nil then
        findings[#findings + 1] = "tree checks: " .. carried_trouble
      end
      local help, help_trouble = help_source.texts()
      if help == nil then
        findings[#findings + 1] = "tree checks: " .. help_trouble
      end
      local found = tree_checks.run(db, guide, built, tree_checks.ci_sources(root), carried, help,
        ctx.plurals)
      for _, line in ipairs(found) do
        findings[#findings + 1] = line
      end
      if carried ~= nil then
        local _, _ = carried:close()
      end
      -- A compiler of its own: the check points its search at this
      -- binary's sources, which the tree's build must not inherit.
      local shown, shown_trouble = teal.load()
      if shown == nil then
        findings[#findings + 1] = "examples as shown: " .. shown_trouble
      else
        for _, line in ipairs(example_checks.run(db, root, shown)) do
          findings[#findings + 1] = "examples as shown: " .. line
        end
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
  local root = ctx.root
  local picked = ctx.picked
  local every = ctx.every
  local files = ctx.files
  local changed = ctx.changed
  local listed = ctx.listed
  local own, _ = tree.is_own(root)
  local linked: {string} = {}
  local groups: {{string}} = { files, ctx.c_files, picked.checked }
  -- TODO: in a run of `--changed`, check the links of only the files
  -- changed and those naming a symbol of a module that changed (what
  -- the projection's `links` rows would say, where they hold each file's
  -- links), not of every file, lexed again without the facts a layout's
  -- parse gives: that is some 12 s of such a run's 20.
  if picked.every ~= nil then groups = { every.files, every.c_files, every.checked } end
  for _, group in ipairs(groups) do
    for _, file in ipairs(group) do
      if not (own and in_foreign_tree(root, file)) then linked[#linked + 1] = file end
    end
  end
  local laid_out: {string: boolean} = {}
  for _, file in ipairs(files) do laid_out[file] = true end
  local linked_out: fix.Linked
  local links_unbuilt: string | nil = nil
  do
    -- Built even where no build has been made yet: this run has staged
    -- and compiled the directory already ([`spill.check`]), and a link
    -- must resolve alike whether or not a `cosmic test` ran first.
    local source = fix.link_context(root, picked.whole, own == true,
      function(verb: string): boolean, string return rebuild.here(verb, true) end,
      function(): docs.Sources return docs.databases() end)
    linked_out = fix.links(source.context, ctx.built, linked, ctx.checking and "check" or "write",
      ctx.facts, laid_out)
    source.close()
    -- A refusal the build above met already fails the run.
    if source.unbuilt ~= nil and ctx.unbuilt == nil then
      links_unbuilt = "links: not rebuilt, resolved from the last build: " .. source.unbuilt
    end
  end
  -- Held no longer than the links need them.
  ctx.facts = {}
  for _, file in ipairs(linked_out.rewritten) do
    -- What the notes kept of its parse is of the text before.
    ctx.ready[file] = nil
    if not listed[file] then
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
  local root = ctx.root
  local picked = ctx.picked
  local findings = ctx.findings
  for _, line in ipairs(ctx.linked_out.notes) do
    log:say("fix: note  " .. line)
  end

  for _, line in ipairs(fix.notes(ctx.built, root, picked.noted or ctx.files, Store.databases(),
      ctx.ready)) do
    local named = line:match("^([^:]*):") or ""
    local absolute, _ = Fs.absolute(named)
    local relative: string | nil = nil
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
    log:say("fix: tree checks: ran over the whole tree, " .. #findings .. " found")
  end
end

--- Says each failure, finding and change, then the verdict.
--- @return integer The exit code: 0 when nothing is left to fix
local function report(ctx: Fix): integer
  local checking = ctx.checking
  local failures = ctx.failures
  local findings = ctx.findings
  local changed = ctx.changed
  local counted = ctx.counted
  local unbuilt = ctx.unbuilt
  local links_unbuilt = ctx.links_unbuilt
  local broken = ctx.linked_out.broken
  local would = ctx.linked_out.would
  local redefined = ctx.linked_out.redefined
  -- A file's own failure names it as it was given (`./a.tl` for `fix
  -- .`), the build's as the tree's: compared without the `./`.
  local function plain(line: string): string
    return (line:gsub("^%./([^:]*): %./", "%1: "))
  end
  local failed: {string:boolean} = {}
  for _, line in ipairs(failures) do
    failed[plain(line)] = true
    log:say("fix: FAIL  " .. line)
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
    log:say("fix: FAIL  " .. unbuilt)
  end
  if links_unbuilt ~= nil then
    log:say("fix: FAIL  " .. links_unbuilt)
  end
  for _, file in ipairs(changed) do
    log:say("fix: " .. (checking and "would fix  " or "fixed  ") .. file)
  end
  if #failures > 0 or #findings > 0 or #broken > 0 or #would > 0 or #redefined > 0 or
      unbuilt ~= nil or links_unbuilt ~= nil then
    local said: {string} = {}
    if #failures > 0 then
      said[#said + 1] = #failures .. " of " .. plural.count(counted, "file") .. " refused"
    end
    if #findings > 0 then
      said[#said + 1] = #findings .. " found by the tree checks"
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
    log:verdict("fix", false, table.concat(said, ", ") .. ", " .. clock.took(ctx.started))
    return 1
  end
  if checking and #changed > 0 then
    log:verdict("fix", false, #changed .. " of " .. plural.count(counted, "file") .. " to fix, " ..
        clock.took(ctx.started) .. "; `cosmic fix` rewrites them in place")
    return 1
  end
  log:verdict("fix", true, plural.count(counted, "file") .. ", " .. #changed ..
      (checking and " to fix, " or " fixed, ") .. clock.took(ctx.started))
  return 0
end

--- `cosmic fix [--check] [path...]`. Each phase above does one part, in
--- order, and the first to answer an exit code ends the run.
--- @param argv {integer:string} The command line, the verb at slot 1
--- @return integer The exit code: 0 when nothing is left to fix
local function fix_verb(argv: {integer:string}): integer
  local ctx: Fix = { argv = argv, started = Clock.monotonic_ns() }
  local code = read_command(ctx)
  if code ~= nil then return code end
  -- In cosmic's own tree the rules and the layout are the tree's: a tool
  -- older than the tree would fix with the old ones and say nothing, so
  -- it rebuilds itself first and re-enters this command line.
  code = reboot.stale_exit(argv)
  if code ~= nil then return code end
  code = choose_files(ctx)
  if code ~= nil then return code end
  code = load_compiler(ctx)
  if code ~= nil then return code end
  start_tally(ctx)
  lay_out_c(ctx)
  lay_out_teal(ctx)
  wrap_asserts(ctx)
  find_unbuilt(ctx)
  run_tree_checks(ctx)
  check_links(ctx)
  say_notes(ctx)
  return report(ctx)
end

--- [`fix_verb`] under Lua's generational collector, and the incremental
--- one, Lua's default, after it. A run holds what the links read of every file
--- ([`links.Facts`]) from its parse to the end, and rebuilds its tree
--- meanwhile: the incremental collector traverses all of it again at
--- each cycle, which costs a whole run more than the rest of the links.
local function run(argv: {integer:string}): integer
  collectgarbage("generational")
  local code = fix_verb(argv)
  collectgarbage("incremental")
  return code
end

--- The `fix` verb as [`build/verb_list.tl`] lists it.
fix.spec = {
  name = "fix",
  guide = "none: a tree-maintenance verb, described by `cosmic help fix`; the quickstart does not cover checking a tree",
  tests = { "build.fix.fix_test" },
  run = function(argv: {integer:string}): integer return run(argv) end,
  bare = false,
  takes = "the files or directories to act on",
}

return fix

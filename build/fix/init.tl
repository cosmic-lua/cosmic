--- `cosmic fix`: rewrite Teal source structurally, then write it back
--- out as canonical text.
---
--- One pipeline, always in one order: parse, apply the structural rules
--- (`build.fix.rule`), render (`build.fix.render`), compare. The order
--- is the point. Then one fix only the type checker can place
--- (`build.fix.spill`): the tree is built, and every `assert(...)` the
--- checker names as passing on values it should not is parenthesized,
--- until it names none. A fix is a change to the parsed tree and never a patch
--- over bytes, and whatever a rule produces is rendered rather than
--- spliced, so the result of a fix reads the same as source that was
--- never fixed at all.
---
--- The verb takes paths to narrow it, defaults to the whole tree in the
--- working directory, and writes what it fixes. `--check` writes
--- nothing and reports what it would have changed instead, which is
--- what a gate runs.
---
--- Running it twice changes nothing the first run did not: the verb
--- itself renders its own output once more and refuses a file whose
--- second pass would change it, rather than writing something that has
--- not reached a fixed point. `cosmic fix --check .` over the whole
--- tree is how that is checked here, in CI's own format-check step.
---
--- It also lays out a YAML file in flow style (`build.flow`) it is named,
--- and, in cosmic's own tree, those under `.github/` -- the workflows
--- and actions -- as a directory holding it is covered: one written in
--- block style is refused when named and passed over otherwise, and one
--- that cannot be read ends the run.
---
--- In cosmic's own tree it also covers the tree's C: every C file it
--- covers is written back in the layout `build.c` holds, and every
--- `.c` file is then compiled to its syntax tree and held to the rules
--- `build.c` holds, where a finding is a file refused and is fixed by
--- hand. A header is held to them through the files that include it.

local Cli = require("cosmic.cli")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local c_check = require("build.c")
local Store = require("cosmic.store")
local String = require("cosmic.string")
local Time = require("cosmic.time")
local clock = require("build.clock")
local ast = require("build.ast")
local equiv = require("build.fix.equiv")
local flow = require("build.flow")
local near = require("build.fix.near")
local analyzer = require("build.analyzer")
local reboot = require("build.reboot")
local render_mod = require("build.fix.render")
local rule = require("build.fix.rule")
local spill = require("build.fix.spill")
local teal = require("build.teal")
local tree = require("build.tree")
local type compiler = require("build.compiler")

local log = require("build.verdict").log

local record fix
  --- What one file's pipeline produced, and whether it differs from
  --- what is on disk. Bundled into one record rather than returned as
  --- separate slots: the first return admits nil, and a fallible return
  --- may declare at most two slots.
  record Fixed
    source: string
    changed: boolean
  end

  --- The files one invocation covers, and the named paths it will not
  --- take: one that is not there at all, and one that is there but is
  --- not Teal source. A refused path rides here rather than ending the
  --- verb on the spot, so it is reported and counted like any other
  --- refused file and the run still finishes in the verb's own verdict
  --- line.
  record Chosen
    files: {string}
    --- The C files, which only cosmic's own tree has checked.
    c_files: {string}
    --- The YAML files in flow style, laid out by `build.flow`.
    flow_files: {string}
    refused: {string}
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
--- files count: they are source in the tree the same as any other, and
--- a renderer that cannot write one back out unchanged has a hole in
--- it.
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

--- Whether `file` is named as YAML.
local function is_yaml(file: string): boolean
  return String.ends_with(file, ".yml") or String.ends_with(file, ".yaml")
end

--- The YAML files in flow style `dir` covers, as paths relative to it:
--- for the tree's root, those under its `.github/`, and for that
--- `.github/` or a directory under it, those under it; none for any
--- other directory, as the walk of the tree passes over a `.github/`
--- anywhere else.
--- A file there that cannot be read is a failure, not one passed over.
local function workflow_sources(dir: string, root: string): {string} | nil, string
  dir = dir:gsub("/+$", "")
  if dir == "" then dir = "/" end
  local absolute, _ = Fs.absolute(dir)
  local top, _ = Fs.absolute(root)
  local inside: string | nil = nil
  if absolute ~= nil and top ~= nil then
    local relative, _ = Fs.relative(absolute, top)
    if relative ~= nil and relative ~= ".." and relative:sub(1, 3) ~= "../" then inside = relative end
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

--- The whole pipeline over one file's source: parse, rewrite, render,
--- and check that rendering still says the same thing and has reached a
--- fixed point.
---
--- Neither check is a test, both are part of the verb. A renderer that
--- is merely self-consistent can be consistently wrong -- `local x
--- <const> = 5` re-emitted as `local x < const > = 5` is stable and
--- idempotent -- so changed rendered text is parsed again and compared,
--- tree and comments, against the tree it came from. Identical bytes
--- already preserve both and need no second parse. A file that fails
--- the comparison is reported and left exactly as it was.
---
--- What comes out is then rendered once more, from the tree already in
--- hand, and required to come back byte for byte: a fix that a second
--- pass would still change is not done fixing. When the render left the
--- text untouched this reuses the tree already parsed from it, so the
--- common case pays for one extra render and no extra parse.
--- @param built compiler The loaded compiler capsule (`build.teal.load()`)
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
  local out, render_trouble = render_mod.rendered(before, rewritten)
  if out == nil then
    return nil, render_trouble
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
  local again, again_trouble = render_mod.rendered(parsed_out, out)
  if again == nil then
    return nil, "a second pass over what was rendered refused it: " .. again_trouble
  end
  if again ~= out then
    return nil, "rendering is not a fixed point: a second pass changed it"
  end
  return { source = out, changed = out ~= source }
end

--- The files one invocation covers: whatever paths were named, or the
--- whole tree when none were.
---
--- What a named path IS comes first, in one stat: a path with nothing
--- at it is said to be missing rather than judged on its suffix, which
--- would answer `nosuchdir/` with a remark about Teal. A directory is
--- walked, which picks out the Teal sources in it and nothing else. A
--- named FILE is taken at its word, so one that is not Teal source at
--- all is said so here -- it would otherwise reach the parser and come
--- back as a syntax error in a file nobody ever claimed was Teal.
---
--- Only a failure to walk a directory fails outright. A path the verb
--- will not take is one refusal among however many were named, and is
--- reported as one.
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
    return { files = all, c_files = c_files, flow_files = flow_files, refused = {} }
  end
  local out: {string} = {}
  local c_out: {string} = {}
  local flow_out: {string} = {}
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
    elseif not String.ends_with(path, ".tl") then
      refused[#refused + 1] = path .. ": not a Teal or C source, or YAML"
    else
      out[#out + 1] = path
    end
  end
  return { files = out, c_files = c_out, flow_files = flow_out, refused = refused }
end

--- Lays out each YAML file of `files` (`build.flow`), writing it back
--- unless `checking`: each one that changes, or would, is appended to
--- `changed`, and each one refused -- not in flow style, or not one
--- `flow.format` takes -- to `failures`, with why.
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

--- `near`'s notes on the exported functions of `files`, each line
--- prefixed with its file: a test, an example or a declaration file
--- offers nothing to compare, nor does a file outside `root`. The module
--- a file declares is read off its path under `root`, as the build names
--- it (`a/b.tl` and `a/b/init.tl` are both `a.b`).
--- @param built compiler The loaded compiler
--- @param root string The tree the files are in
--- @param files {string} The files a fix covered
--- @return {string} One line per note, `file:line: message`
function fix.notes(built: compiler, root: string, files: {string}): {string}
  -- Each file's path is resolved, so the root must be too: on macOS a
  -- temporary directory is under /var, a link to /private/var.
  local resolved_root, _ = Fs.absolute(root)
  local base = resolved_root or root
  local known, known_trouble = near.known(Store.databases())
  if known == nil then
    return { "comparing with the standard library: " .. known_trouble }
  end
  local out: {string} = {}
  for _, file in ipairs(files) do
    local plain = not String.ends_with(file, "_test.tl") and
      not String.ends_with(file, "_example.tl") and not String.ends_with(file, ".d.tl")
    local absolute, _ = Fs.absolute(file)
    local relative: string | nil = nil
    if plain and absolute ~= nil then
      local within, _ = Fs.relative(absolute, base)
      relative = within
    end
    local source: string | nil = nil
    if relative ~= nil and relative:sub(1, 3) ~= "../" then
      local read, _ = Fs.read(file)
      source = read
    end
    local found: analyzer.Analysis | nil = nil
    if source ~= nil then
      local analyzed, _ = analyzer.analyze(built, source, file)
      found = analyzed
    end
    if found ~= nil and relative ~= nil then
      local module = relative:gsub("%.tl$", ""):gsub("/init$", ""):gsub("/", ".")
      local candidates: {near.Candidate} = {}
      for _, entry in ipairs(found.docs) do
        if entry.exported and (entry.kind == "function" or entry.kind == "method") and
            entry.text ~= "" then
          candidates[#candidates + 1] = { source_symbol = entry.source_symbol,
            text = entry.text, line = entry.line }
        end
      end
      for _, note in ipairs(near.notes(module, candidates, known)) do
        out[#out + 1] = file .. ":" .. note
      end
    end
  end
  return out
end

--- `cosmic fix [--check] [path...]`.
--- @param argv {integer:string} The command line, the verb at slot 1
--- @return integer The exit code: 0 when nothing is left to fix
function fix.run(argv: {integer:string}): integer
  local started = Time.monotonic_ns()
  local parsed, parse_trouble = Flags.parse(argv, 2, Cli.options.fix)
  if parsed == nil then
    log:complain("fix: " .. parse_trouble)
    return 2
  end
  local checking = parsed.set["--check"] == true
  local paths = parsed.words

  local root, root_trouble = Fs.absolute(".")
  if root == nil then
    log:complain(root_trouble)
    return 1
  end
  -- In cosmic's own tree the rules and the layout are the tree's: a tool
  -- older than the tree would fix with the old ones and say nothing, so
  -- it rebuilds itself first and re-enters this command line.
  local code = reboot.stale_exit(argv)
  if code ~= nil then
    return code
  end
  local picked, list_trouble = fix.chosen(root, paths)
  if picked == nil then
    log:complain(list_trouble)
    return 1
  end

  local built, load_trouble = teal.load()
  if built == nil then
    log:complain(load_trouble)
    return 1
  end

  -- A named path the verb would not take counts among the files the run
  -- covers, so the verdict says how many of everything asked for was
  -- refused rather than only how many of what survived the naming.
  local files = picked.files
  local counted = #files + #picked.c_files + #picked.flow_files + #picked.refused
  local changed: {string} = {}
  local failures: {string} = {}
  for _, why in ipairs(picked.refused) do
    failures[#failures + 1] = why
  end
  -- The C is compiled from the root, so a path named from elsewhere is
  -- taken relative to it.
  local c_files: {string} = {}
  for _, file in ipairs(picked.c_files) do
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
      if not checking then
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
  fix.lay_out(picked.flow_files, checking, changed, failures)
  for _, file in ipairs(files) do
    local source, read_trouble = Fs.read(file)
    if source == nil then
      failures[#failures + 1] = read_trouble
    else
      local result, trouble = fix.source(built, source, file)
      if result == nil then
        failures[#failures + 1] = file .. ": " .. trouble
      elseif result.changed then
        changed[#changed + 1] = file
        if not checking then
          local written, write_trouble = Fs.write(file, result.source)
          if not written then
            failures[#failures + 1] = write_trouble
          end
        end
      end
    end
  end

  -- What only the checker can see: built from what is on disk, so a
  -- check reports the files once and a fix repeats until it settles.
  local chosen_files: {string:string} = {}
  for _, file in ipairs(files) do
    local absolute, _ = Fs.absolute(file)
    if absolute ~= nil then chosen_files[absolute] = file end
  end
  local listed: {string:boolean} = {}
  for _, file in ipairs(changed) do listed[file] = true end
  local rounds = 0
  while true do
    local sites, check_trouble = spill.check(root)
    if sites == nil then
      failures[#failures + 1] = "checking asserts: " .. check_trouble
      break
    end
    local wrapped = false
    for name, at in pairs(sites) do
      local file = chosen_files[root .. "/" .. name]
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
      failures[#failures + 1] = "wrapping asserts did not settle after " .. rounds .. " builds"
      break
    end
  end

  -- A note is a heuristic's, never a failure: it names what to look at.
  for _, line in ipairs(fix.notes(built, root, files)) do
    log:say("fix: note  " .. line)
  end
  for _, line in ipairs(failures) do
    log:say("fix: FAIL  " .. line)
  end
  for _, file in ipairs(changed) do
    log:say("fix: " .. (checking and "would fix  " or "fixed  ") .. file)
  end
  if #failures > 0 then
    log:verdict("fix", false, #failures .. " of " .. counted .. " files refused, " ..
      clock.took(started))
    return 1
  end
  if checking and #changed > 0 then
    log:verdict("fix", false, #changed .. " of " .. counted .. " files to fix, " ..
      clock.took(started) .. "; `cosmic fix` rewrites them in place")
    return 1
  end
  log:verdict("fix", true, counted .. " files, " .. #changed ..
    (checking and " to fix, " or " fixed, ") .. clock.took(started))
  return 0
end

return fix

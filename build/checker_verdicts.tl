--- What the type checker says of a list of sources, one stable line per
--- error and warning, so that two checkers can be diffed. Changing how the
--- checker narrows must not change a verdict it did not mean to: this is
--- how a change shows every verdict it moved.
---
--- A line is
---
---     file TAB code TAB y TAB x TAB message
---
--- `file` is the source's name, `y` and `x` the position the checker
--- gives, and `message` its text with `\` `\t` `\n` `\r` written as
--- escapes, so a line is a line. `code` is the list the finding is in
--- (`syntax`, `type` or `warning`), a dot, and the finding's code
--- ([`compiler.ErrorCode`]) or, for a warning, its tag (`unused`,
--- `redeclaration`...); `other` where it has none. A source the checker
--- raises on is the line `raised` with the message (addresses elided). Lines
--- are sorted by file, then `y`, `x`, `code` and `message`, so the output
--- is a function of the sources and the checker alone.
---
--- The checker is the running tool's: [`build.teal`]'s `load`, the compiler
--- the tree carries. A tree file is checked as the build checks it
--- ([`build.compilation`]'s `generate`) in these ways, and no other:
---
--- * the environment has the settings and the stripped names
---   [`build.teal`]'s `environment_for` gives, less its staged database
---   (build/checker_verdicts_test.tl holds the two together). Modules are
---   read from a `--root` directory instead, so that two tools can read
---   one tree, or from the binary for `cosmic.*`;
--- * the source goes through [`build.shape_specs`]'s `resolve` first;
--- * the file is checked under its own name, and the type it answers is
---   what a later `require` of it finds.
---
--- It leaves out what the build does besides: the discounts for tests and
--- examples (a test function nothing calls is an `unused` warning here),
--- the type report and the contracts and run-time checks built on it
--- ([`receivers.install`], `runtime_checks`), declaration files (they are
--- served to a `require` and not checked alone), and the modules the build
--- generates (doc examples, templates).
---
--- To compare the checker of a tree with main's, build both tools and run
--- the same sources through each, reading one tree from both. The script is
--- run by the tool of the checkout it sits in (`cosmic <file>` builds the
--- tree around the file), so the base checkout must hold this file.
---
---     git worktree add --detach ../wt-main origin/main
---     (cd ../wt-main && bin/zig build boot)
---     tree=$PWD
---     for where in $tree ../wt-main; do
---       (cd $where && bin/cosmic build/checker_verdicts.tl tree --root $tree \
---         > /tmp/verdicts-$(basename $where).txt)
---     done
---     diff /tmp/verdicts-*.txt        # empty: no verdict moved
---
--- The commands, each writing its lines to standard output:
---
--- * `tree [--root DIR] [--skip DIR]... [--fresh] [--stride N]`: every `.tl`
---   file under `DIR` (the working directory by default) but a `.d.tl`,
---   skipping `.`-directories, `o`, `ci` (a tree of its own: run `tree
---   --root ci`) and each `--skip`. One environment is shared, as the build
---   shares one, and the files go in the order each follows the modules it
---   requires by a literal name ([`tree_order`]), so that a module is checked
---   before the files that use it. The checker's answer for a file can
---   depend on what the environment has loaded (a file reading
---   [`cosmic.shape`] after an unrelated module loaded it once gave
---   unresolved generics), so the order is part of what the lines are a
---   function of. `--fresh` checks each file in an environment of its own,
---   in name order; it is too slow for the tree (over twenty minutes of
---   checking), and `--stride N` keeps every Nth file to sample it. The
---   file is named relative to `DIR`.
--- * `programs PATH...`: each file, and each file under a directory, as a
---   program of its own, checked in an environment of its own as
---   build/checker_fuzz_test.tl checks one. The file is named as the path
---   is written. The corpora of `testdata/fuzz/checker-*` are checked this
---   way.
--- * `dump DIR SEED ITERS`: writes the programs the checker's fuzz
---   properties draw ([`build.checker_programs`]) for `FUZZ_SEED=SEED` and
---   iterations 1 through `ITERS`, to `DIR/total-<seed>-<n>.tl` and
---   `DIR/sound-<seed>-<n>.tl`, which `programs DIR` then reads. Both
---   tools read the files, not the generator.
---
--- The three source sets of a change that must move no verdict are the
--- tree (`tree`, and `tree --root ci`), the corpora (`programs
--- testdata/fuzz/checker-total testdata/fuzz/checker-sound`) and the
--- dumped programs (`dump`, then `programs`), each run by both tools.
---
--- The tree is weak evidence for a change to narrowing: the tree's own
--- code is written to pass, so a checker that narrowed less or more would
--- often leave its lines as they are (making a call drop nothing moves
--- none of them). The corpora and the dumped programs are
--- drawn to put narrowing at risk and carry that sensitivity, so a change
--- to narrowing runs all three sets, with several seeds for `dump`.

-- TODO: write `(file, y, x, type)` lines from the type report for the
-- narrowed reads too (a `--types` mode), once checker/facts.tl feeds the
-- type report: until then the lines cannot show a read whose type moved
-- while its verdict did not.
local Fs = require("cosmic.fs")
local shape_specs = require("build.shape_specs")
local programs = require("build.checker_programs")
local teal = require("build.teal")
local type compiler = require("build.compiler")

local record verdicts
  --- One finding of the checker.
  record Line
    file: string
    code: string
    y: integer
    x: integer
    message: string
  end

  --- The lines for each finding of the checker in `text` as a program: in
  --- an environment of its own, as the fuzz properties check one. `file` names
  --- the source in each line.
  program_lines: function(built: compiler, file: string, text: string): {Line}

  --- A checker environment as the build makes one, less its staged database.
  environment: function(built: compiler): compiler.Env

  --- The files of `names`, relative to `root`, with each after the ones it
  --- requires by a literal name that `names` holds (a cycle is cut where it
  --- is met), and otherwise in the order given.
  tree_order: function(root: string, names: {string}): {string}

  --- The lines for each of the files `names` lists, relative to `root`, in
  --- one environment in the order of [`tree_order`], or in one apiece, in the
  --- order given, with `fresh`.
  tree_lines: function(built: compiler, root: string, names: {string}, fresh?: boolean): {Line}

  --- The text of the lines, sorted, one to a line, each ending in a newline.
  render: function(lines: {Line}): string

  --- The files `tree` checks under `root`, sorted: see the module's docs.
  tree_names: function(root: string, skip: {string}): {string}

  --- Runs a command: see the module's docs. The exit status.
  main: function(argv: {string}): integer
end

--- A checker environment for the tree: the strictness the build holds
--- itself to and without the names the runtime removes, as
--- [`build.teal`]'s `environment_for` makes one.
function verdicts.environment(built: compiler): compiler.Env
  local env = assert(built.new_env({ defaults = teal.defaults(false) }))
  teal.strip(env)
  return env
end
local environment <const> = verdicts.environment

local function escaped(text: string): string
  return (text:gsub("[\\\t\n\r]", {
    ["\\"] = "\\\\", ["\t"] = "\\t", ["\n"] = "\\n", ["\r"] = "\\r",
  }))
end

--- The lines of one list of a checker answer.
local function add_list(out: mut {verdicts.Line}, file: string, list_name: string,
                        list: {compiler.Error}?, only: string?)
  -- A source that did not parse comes back without the lists the checker
  -- never reached.
  for _, e in ipairs(list or {}) do
    if only == nil or e.filename == only then
      out[#out + 1] = {
        file = file,
        code = list_name .. "." .. (e.code or e.tag or "other"),
        y = e.y or 0, x = e.x or 0, message = e.msg or "",
      }
    end
  end
end

--- The lines of one checker answer.
local function collect(out: {verdicts.Line}, file: string, result: compiler.Result,
                       only: string?)
  add_list(out, file, "syntax", result.syntax_errors, only)
  add_list(out, file, "type", result.type_errors, only)
  add_list(out, file, "warning", result.warnings, only)
end

--- A raise of the checker, as a line.
local function raised(out: mut {verdicts.Line}, file: string, why: any)
  local message = tostring(why):gsub("0x%x+", "0xADDR")
  out[#out + 1] = { file = file, code = "raised", y = 0, x = 0, message = message }
end

function verdicts.program_lines(built: compiler, file: string, text: string): {verdicts.Line}
  local out: {verdicts.Line} = {}
  local env = environment(built)
  local ok, code, result = pcall(built.gen, text, env, nil, "tl")
  if not ok then
    raised(out, file, code)
  else
    collect(out, file, result, nil)
  end
  return out
end

--- The candidates for a module's file under `root`, a declaration first as
--- the staged tree prefers it.
local function candidates(name: string): {string}
  local stem = name:gsub("%.", "/")
  return { stem .. ".d.tl", stem .. ".tl", stem .. "/init.d.tl", stem .. "/init.tl" }
end

--- Points `built` at the modules under `root` and the binary's own
--- `cosmic.*` modules ([`build.teal`]'s `standard_text`), and nothing else.
local function serving(built: compiler, root: string)
  built.search_module = function(name: string, _search_all: boolean): string?, compiler.Handle?
    for _, relative in ipairs(candidates(name)) do
      local text, _ = Fs.read(root .. "/" .. relative)
      if text ~= nil then
        return relative, teal.served(text)
      end
    end
    local standard = teal.standard_text(name)
    if standard ~= nil then
      return name:gsub("%.", "/") .. ".tl", teal.served(standard.text)
    end
    return nil, nil
  end
end

--- The name a file is required by, nil for one nothing requires.
local function module_name(relative: string): string?
  if relative:find("%.d%.tl$") ~= nil then
    return nil
  end
  local name = relative:gsub("/init%.tl$", ""):gsub("%.tl$", "")
  return (name:gsub("/", "."))
end

function verdicts.tree_order(root: string, names: {string}): {string}
  local by_module: mut {string:string} = {}
  for _, relative in ipairs(names) do
    local name = module_name(relative)
    if name ~= nil then
      by_module[name] = relative
    end
  end
  local visited: {string:boolean} = {}
  local out: {string} = {}
  local function visit(relative: string)
    if visited[relative] then
      return
    end
    visited[relative] = true
    local text, _ = Fs.read(root .. "/" .. relative)
    for required in (text or ""):gmatch('require%(%s*"([^"]+)"%s*%)') do
      local dependency = by_module[required]
      if dependency ~= nil then
        visit(dependency)
      end
    end
    out[#out + 1] = relative
  end
  for _, relative in ipairs(names) do
    visit(relative)
  end
  return out
end

function verdicts.tree_lines(built: compiler, root: string, names: {string}, fresh?: boolean): {verdicts.Line}
  local out: {verdicts.Line} = {}
  serving(built, root)
  local env = environment(built)
  for _, relative in ipairs(fresh and names or verdicts.tree_order(root, names)) do
    if fresh then
      env = environment(built)
    end
    local name = module_name(relative)
    local text, why = Fs.read(root .. "/" .. relative)
    if text == nil then
      raised(out, relative, why)
    else
      local ok, source, refusal = pcall(shape_specs.resolve, built, env, relative, name or relative, text)
      if not ok then
        raised(out, relative, source)
      elseif source == nil then
        raised(out, relative, refusal)
      else
        local checked, result = pcall(built.check_string, source, env, relative, "tl")
        if not checked then
          raised(out, relative, result)
        else
          collect(out, relative, result, relative)
          local module_type = result.type
          if name ~= nil and module_type ~= nil then
            env.modules[name] = module_type
          end
        end
      end
    end
  end
  return out
end

local function before(a: verdicts.Line, b: verdicts.Line): boolean
  if a.file ~= b.file then return a.file < b.file end
  if a.y ~= b.y then return a.y < b.y end
  if a.x ~= b.x then return a.x < b.x end
  if a.code ~= b.code then return a.code < b.code end
  return a.message < b.message
end

function verdicts.render(lines: {verdicts.Line}): string
  local sorted: mut {verdicts.Line} = {}
  for i, line in ipairs(lines) do
    sorted[i] = line
  end
  table.sort(sorted, before)
  local out: mut {string} = {}
  for i, line in ipairs(sorted) do
    out[i] = table.concat({ escaped(line.file), line.code, tostring(line.y), tostring(line.x),
      escaped(line.message) }, "\t") .. "\n"
  end
  return table.concat(out)
end

function verdicts.tree_names(root: string, skip: {string}): {string}
  local skipped: mut {string:boolean} = { o = true, ci = true }
  for _, name in ipairs(skip) do
    skipped[name] = true
  end
  local found = assert(Fs.walk(root, function(_path: string, name: string, kind: Fs.Kind): boolean
    return kind == "dir" and (name:sub(1, 1) == "." or skipped[name] == true)
  end))
  local names: mut {string} = {}
  for _, relative in ipairs(found) do
    if relative:find("%.tl$") ~= nil and relative:find("%.d%.tl$") == nil then
      names[#names + 1] = relative
    end
  end
  table.sort(names)
  return names
end

--- The files a `programs` argument names, as the path is written.
local function files_of(path: string): {string}
  local directory, _ = Fs.is_dir(path)
  if directory == true then
    local found = assert(Fs.walk(path))
    local out: mut {string} = {}
    for _, relative in ipairs(found) do
      out[#out + 1] = (path:gsub("/+$", "")) .. "/" .. relative
    end
    return out
  end
  return { path }
end

local function complain(text: string)
  local _, _ = Fs.put(Fs.stderr, "checker_verdicts: " .. text .. "\n")
end

local USAGE <const> = "usage: tree [--root DIR] [--skip DIR]... [--fresh] [--stride N] | programs PATH... | dump DIR SEED ITERS"

local function dump(argv: {string}): integer
  local dir = argv[2]
  local seed = math.tointeger(tonumber(argv[3] or ""))
  local iters = math.tointeger(tonumber(argv[4] or ""))
  if dir == nil or seed == nil or iters == nil or seed < 0 or iters < 0 then
    complain(USAGE)
    return 2
  end
  assert(Fs.mkdirs(dir))
  for _, kind in ipairs({ "total", "sound" }) do
    for n, text in ipairs(programs.drawn(kind, seed, iters)) do
      assert(Fs.write(("%s/%s-%d-%04d.tl"):format(dir, kind, seed, n), text))
    end
  end
  return 0
end

function verdicts.main(argv: {string}): integer
  local command = argv[1]
  if command == "dump" then
    return dump(argv)
  end
  local built = assert(teal.load(true))
  local lines: mut {verdicts.Line} = {}
  if command == "tree" then
    local root = "."
    local skip: mut {string} = {}
    local fresh = false
    local stride = 1
    local i = 2
    while argv[i] ~= nil do
      if argv[i] == "--stride" and argv[i + 1] ~= nil then
        stride = math.tointeger(tonumber(argv[i + 1])) or 0
        if stride < 1 then
          complain(USAGE)
          return 2
        end
      elseif argv[i] == "--fresh" then
        fresh = true
        i = i - 1
      elseif argv[i] == "--root" and argv[i + 1] ~= nil then
        root = argv[i + 1]
      elseif argv[i] == "--skip" and argv[i + 1] ~= nil then
        skip[#skip + 1] = argv[i + 1]
      else
        complain(USAGE)
        return 2
      end
      i = i + 2
    end
    local names: mut {string} = {}
    for n, name in ipairs(verdicts.tree_names(root, skip)) do
      if (n - 1) % stride == 0 then
        names[#names + 1] = name
      end
    end
    lines = verdicts.tree_lines(built, root, names, fresh)
  elseif command == "programs" then
    if argv[2] == nil then
      complain(USAGE)
      return 2
    end
    local i = 2
    while argv[i] ~= nil do
      for _, file in ipairs(files_of(argv[i])) do
        local text = assert(Fs.read(file))
        for _, line in ipairs(verdicts.program_lines(built, file, text)) do
          lines[#lines + 1] = line
        end
      end
      i = i + 1
    end
  else
    complain(USAGE)
    return 2
  end
  local _, _ = Fs.put(Fs.stdout, verdicts.render(lines))
  return 0
end

return verdicts

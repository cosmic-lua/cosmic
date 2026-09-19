--- `cosmic fix`: rewrite Teal source structurally, then write it back
--- out as canonical text.
---
--- One pipeline, always in one order: parse, apply the structural rules
--- (`build.fix.rule`), render (`build.fix.render`), compare. The order
--- is the point. A fix is a change to the parsed tree and never a patch
--- over bytes, and whatever a rule produces is rendered rather than
--- spliced, so the result of a fix reads the same as source that was
--- never fixed at all.
---
--- The verb takes paths to narrow it, defaults to the whole tree in the
--- working directory, and writes what it fixes. `--check` writes
--- nothing and reports what it would have changed instead, which is
--- what a gate runs.
---
--- Running it twice changes nothing the first run did not: the
--- pipeline's own output parses to the same tree and renders to the
--- same bytes, which `build.fix.fix_test` holds it to on this tree's
--- own files.

local Fs = require("cosmic.fs")
local ast = require("build.ast")
local equiv = require("build.fix.equiv")
local render_mod = require("build.fix.render")
local rule = require("build.fix.rule")
local teal = require("build.teal")
local type compiler = require("build.compiler")

local record fix
  --- What one file's pipeline produced, and whether it differs from
  --- what is on disk. Bundled into one record rather than returned as
  --- separate slots: the first return admits nil, and a fallible return
  --- may declare at most two slots.
  record Fixed
    source: string
    changed: boolean
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
  local name = entry:match("([^/]+)$") or entry
  return name:sub(1, 1) == "."
end

--- Every Teal source under `root`, as paths relative to it. Declaration
--- files count: they are source in the tree the same as any other, and
--- a renderer that cannot write one back out unchanged has a hole in
--- it.
--- @param root string
--- @return {string}|nil
--- @return string Error message on failure
function fix.sources(root: string): {string} | nil, string
  local files, trouble = Fs.walk(root, skip)
  if files == nil then
    return nil, trouble
  end
  local out: {string} = {}
  for _, file in ipairs(files) do
    if file:sub(-3) == ".tl" then
      out[#out + 1] = file
    end
  end
  return out
end

--- The whole pipeline over one file's source: parse, rewrite, render,
--- and then read the result back to check it still says the same thing.
---
--- That last step is not a test, it is part of the verb. A renderer
--- that is merely self-consistent can be consistently wrong -- `local x
--- <const> = 5` re-emitted as `local x < const > = 5` is stable and
--- idempotent -- so nothing is written until the rendered text has been
--- parsed again and compared, tree and comments, against the tree it
--- came from. A file that fails the comparison is reported and left
--- exactly as it was.
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
  return { source = out, changed = out ~= source }
end

local function report(line: string)
  Fs.put(Fs.stdout, line .. "\n")
end

local function complain(line: string)
  Fs.put(Fs.stderr, "cosmic: " .. line .. "\n")
end

--- The files one invocation covers: whatever paths were named, or the
--- whole tree when none were.
local function chosen(root: string, paths: {string}): {string} | nil, string
  if #paths == 0 then
    return fix.sources(root)
  end
  local out: {string} = {}
  for _, path in ipairs(paths) do
    if Fs.is_dir(path) then
      local under, trouble = fix.sources(path)
      if under == nil then
        return nil, trouble
      end
      for _, file in ipairs(under) do
        out[#out + 1] = path .. "/" .. file
      end
    else
      out[#out + 1] = path
    end
  end
  return out
end

--- `cosmic fix [--check] [path...]`.
--- @param argv {integer:string} The command line, the verb at slot 1
--- @return integer The exit code: 0 when nothing is left to fix
function fix.run(argv: {integer:string}): integer
  local checking = false
  local paths: {string} = {}
  local i = 2
  while argv[i] ~= nil do
    local word = argv[i]
    if word == "--check" then
      checking = true
    elseif word:sub(1, 1) == "-" then
      complain("fix: no such option: " .. word)
      return 2
    else
      paths[#paths + 1] = word
    end
    i = i + 1
  end

  local root, root_trouble = Fs.absolute(".")
  if root == nil then
    complain(root_trouble)
    return 1
  end
  local files, list_trouble = chosen(root, paths)
  if files == nil then
    complain(list_trouble)
    return 1
  end

  local built, load_trouble = teal.load()
  if built == nil then
    complain(load_trouble)
    return 1
  end

  local changed: {string} = {}
  local failures: {string} = {}
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

  for _, line in ipairs(failures) do
    report("fix: FAIL  " .. line)
  end
  for _, file in ipairs(changed) do
    report("fix: " .. (checking and "would fix  " or "fixed  ") .. file)
  end
  if #failures > 0 then
    report("fix: FAIL (" .. #failures .. " of " .. #files .. " files refused)")
    return 1
  end
  if checking and #changed > 0 then
    report("fix: FAIL (" .. #changed .. " of " .. #files .. " files to fix)")
    return 1
  end
  report("fix: PASS (" .. #files .. " files, " .. #changed ..
    (checking and " to fix)" or " fixed)"))
  return 0
end

return fix

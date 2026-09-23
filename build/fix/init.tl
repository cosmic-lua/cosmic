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

local Fs = require("cosmic.fs")
local Time = require("cosmic.time")
local clock = require("build.clock")
local ast = require("build.ast")
local equiv = require("build.fix.equiv")
local render_mod = require("build.fix.render")
local rule = require("build.fix.rule")
local spill = require("build.fix.spill")
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

  --- The files one invocation covers, and the named paths it will not
  --- take: one that is not there at all, and one that is there but is
  --- not Teal source. A refused path rides here rather than ending the
  --- verb on the spot, so it is reported and counted like any other
  --- refused file and the run still finishes in the verb's own verdict
  --- line.
  record Chosen
    files: {string}
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
local function sources(root: string): {string} | nil, string
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

local function report(line: string)
  Fs.put(Fs.stdout, line .. "\n")
end

local function complain(line: string)
  Fs.put(Fs.stderr, "cosmic: " .. line .. "\n")
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
  if #paths == 0 then
    local all, trouble = sources(root)
    if all == nil then
      return nil, trouble
    end
    return { files = all, refused = {} }
  end
  local out: {string} = {}
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
    elseif path:sub(-3) ~= ".tl" then
      refused[#refused + 1] = path .. ": not a Teal source"
    else
      out[#out + 1] = path
    end
  end
  return { files = out, refused = refused }
end

--- `cosmic fix [--check] [path...]`.
--- @param argv {integer:string} The command line, the verb at slot 1
--- @return integer The exit code: 0 when nothing is left to fix
function fix.run(argv: {integer:string}): integer
  local started = Time.monotonic_ns() or 0
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
  local picked, list_trouble = fix.chosen(root, paths)
  if picked == nil then
    complain(list_trouble)
    return 1
  end

  local built, load_trouble = teal.load()
  if built == nil then
    complain(load_trouble)
    return 1
  end

  -- A named path the verb would not take counts among the files the run
  -- covers, so the verdict says how many of everything asked for was
  -- refused rather than only how many of what survived the naming.
  local files = picked.files
  local counted = #files + #picked.refused
  local changed: {string} = {}
  local failures: {string} = {}
  for _, why in ipairs(picked.refused) do
    failures[#failures + 1] = why
  end
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
    local absolute = Fs.absolute(file)
    if absolute ~= nil then chosen_files[absolute] = file end
  end
  local listed: {string:boolean} = {}
  for _, file in ipairs(changed) do listed[file] = true end
  local rounds = 0
  while true do
    local sites, check_trouble = spill.check(root)
    if check_trouble ~= "" then
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

  for _, line in ipairs(failures) do
    report("fix: FAIL  " .. line)
  end
  for _, file in ipairs(changed) do
    report("fix: " .. (checking and "would fix  " or "fixed  ") .. file)
  end
  if #failures > 0 then
    report("fix: FAIL (" .. #failures .. " of " .. counted .. " files refused, " ..
      clock.elapsed_ms(started) .. " ms)")
    return 1
  end
  if checking and #changed > 0 then
    report("fix: FAIL (" .. #changed .. " of " .. counted .. " files to fix, " ..
      clock.elapsed_ms(started) .. " ms); `cosmic fix` rewrites them in place")
    return 1
  end
  report("fix: PASS (" .. counted .. " files, " .. #changed ..
    (checking and " to fix, " or " fixed, ") .. clock.elapsed_ms(started) .. " ms)")
  return 0
end

return fix

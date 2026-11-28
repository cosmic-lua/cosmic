--- The checks of the tree over its tests: no test returning early (a skip is [`Test.skip`]) and no test helper
--- copied from another file.

local SyntaxNode = require("build.syntax_node")
local TestClones = require("build.test_clones")
local TestReturns = require("build.test_returns")
local _ = require("build.reads.all")
local tree_common = require("build.tree_checks.common")

local sources_of = tree_common.sources_of

local record tree_tests
end

--- Each early return of a test in a `*_test.tl` file of the tree under `root` ([`TestReturns`]), as `<file>:<line>:
--- <test> returns early ...`. A test that cannot check its subject here declares `requires` or calls `Test.skip(reason)`
--- (doc/testing.md, "skipping"); a `return` passes having checked nothing.
function tree_tests.test_returns(root: string): {string}
  local sources, trouble = sources_of(root)
  if sources == nil then
    return { "reading the sources: " .. trouble }
  end
  local out: mut {string} = {}
  for _, entry in ipairs(sources) do
    local file, text = entry[1], entry[2]
    if file ~= nil and text ~= nil and file:match("_test%.tl$") ~= nil and text:find("return", 1, true) ~= nil then
      local sites = tree_common.known_returns(text, file)
      local parse_trouble = ""
      if sites == nil then
        local chunk, refusal = SyntaxNode.parse(text, file)
        if chunk ~= nil then sites = TestReturns.of_chunk(chunk) end
        parse_trouble = refusal
      end
      if sites == nil then
        out[#out + 1] = file .. ": cannot read it to check its early returns: " .. parse_trouble
      else
        for _, site in ipairs(sites) do
          out[#out + 1] = file .. ":" .. tostring(site[1]) .. ": " .. tostring(site[2]) .. " returns early (`" ..
            tostring(site[3]) .. "`), which passes having checked nothing: declare `requires`, or call " ..
            "`Test.skip(reason)` (doc/testing.md, \"skipping\"), after which nothing runs"
        end
      end
    end
  end
  return out
end

-- TODO: once the helpers copied between files below `CLONE_TOKENS` are moved into shared fixtures, lower it to 30.

--- The fewest tokens a helper has for [`test_clones`] to compare it. Copies ran from about 30 tokens to a screen: below
--- about 30 a wrapper that two files write alike is no copy of the other, and 70 is the lowest where the copies the tree
--- held were few enough for one change to move (a process runner, a project writer).
local CLONE_TOKENS = 70

--- A helper [`test_clones`] has read: where it is.
local record CloneSite
  file: string
  line: integer
  name: string
end

--- Each top-level `local function` that is no test, of a `*_test.tl` or `*_fixture.tl` file under `root`, written
--- token for token as one in another such file ([`TestClones`]), as `<file>:<line>: <name> is ...`, one for each
--- set of copies. A copy is fixed in one place: a helper goes into a shared fixture (build/test_support_fixture.tl,
--- build/test_sandbox_fixture.tl, build/child_policy_fixture.tl ...), and each file requires it.
function tree_tests.test_clones(root: string, threshold?: integer): {string}
  local sources, trouble = sources_of(root)
  if sources == nil then
    return { "reading the sources: " .. trouble }
  end
  local least = threshold or CLONE_TOKENS
  local out: mut {string} = {}
  -- Only the files that are tests or fixtures take part, on both sides of a pair. A helper is read only where its head
  -- ([`TestClones`]'s `scan`) is another file's too.
  local scans: mut {string: TestClones.Scan} = {}
  local texts: mut {string: string} = {}
  local candidates: mut {string} = {}
  local in_files: mut {string: mut {string: boolean}} = {}
  for _, entry in ipairs(sources) do
    local file, text = entry[1], entry[2]
    if file ~= nil and text ~= nil and text:find("local function", 1, true) ~= nil and
        (file:match("_test%.tl$") ~= nil or file:match("_fixture%.tl$") ~= nil) then
      local scan = TestClones.scan(text)
      scans[file] = scan
      texts[file] = text
      candidates[#candidates + 1] = file
      for _, head in ipairs(scan.heads) do
        local files: mut {string: boolean} = in_files[head.key] or {}
        in_files[head.key] = files
        files[file] = true
      end
    end
  end
  -- The lines where a file's real top-level helpers begin, parsed whole once and only for a file a finding is made of:
  -- a head in a long string that holds Teal source is no helper.
  local real: mut {string: {string: boolean}} = {}
  local function is_real(file: string, line: integer): boolean, string
    local lines = real[file]
    if lines == nil then
      local chunk, parse_trouble = SyntaxNode.parse(assert(texts[file]), file)
      if chunk == nil then
        return false, parse_trouble
      end
      local found: mut {string: boolean} = {}
      for _, top in ipairs(chunk.body.stats) do
        if top.kind == "LocalFunction" then
          found[tostring(SyntaxNode.span(chunk, top).y)] = true
        end
      end
      real[file] = found
      lines = found
    end
    return lines[tostring(line)] == true, ""
  end
  local groups: mut {string: mut {CloneSite}} = {}
  local order: mut {string} = {}
  local unreadable: mut {string} = {}
  for _, file in ipairs(candidates) do
    local scan = assert(scans[file])
    for _, head in ipairs(scan.heads) do
      local files = assert(in_files[head.key])
      local count = 0
      for _ in pairs(files) do count = count + 1 end
      if count >= 2 then
        local helper, cut_trouble = TestClones.read(scan, head, file)
        if helper == nil then
          local genuine, parse_trouble = is_real(file, head.line)
          if parse_trouble ~= "" then
            out[#out + 1] = file .. ": cannot read it to check its helpers: " .. parse_trouble
          elseif genuine then
            unreadable[#unreadable + 1] = file .. ":" .. tostring(head.line) .. ": cannot read " .. head.name ..
              " to check it is no copy: " .. cut_trouble
          end
        elseif helper.size >= least then
          local group: mut {CloneSite} = groups[helper.body] or {}
          if groups[helper.body] == nil then
            groups[helper.body] = group
            order[#order + 1] = helper.body
          end
          group[#group + 1] = { file = file, line = helper.line, name = helper.name }
        end
      end
    end
  end
  for _, line in ipairs(unreadable) do out[#out + 1] = line end
  for _, body in ipairs(order) do
    local group = assert(groups[body])
    local files: mut {string: boolean} = {}
    local distinct = 0
    local sites: mut {CloneSite} = {}
    local checked = #group >= 2
    for _, site in ipairs(group) do
      local genuine = false
      if checked then
        local real_here, parse_trouble = is_real(site.file, site.line)
        genuine = real_here
        if parse_trouble ~= "" then
          out[#out + 1] = site.file .. ": cannot read it to check its helpers: " .. parse_trouble
        end
      end
      if genuine then
        if files[site.file] ~= true then
          files[site.file] = true
          distinct = distinct + 1
        end
        sites[#sites + 1] = site
      end
    end
    if distinct >= 2 then
      local first = assert(sites[1])
      local others: mut {string} = {}
      for i = 2, #sites do
        local site = assert(sites[i])
        others[#others + 1] = site.file .. ":" .. tostring(site.line) .. " (" .. site.name .. ")"
      end
      out[#out + 1] = first.file .. ":" .. tostring(first.line) .. ": " .. first.name ..
        " is copied token for token in " .. table.concat(others, ", ") .. ": move it into a shared fixture " ..
        "(build/test_support_fixture.tl, build/test_sandbox_fixture.tl, build/child_policy_fixture.tl ...) that " ..
        "each requires"
    end
  end
  return out
end

--- The programs a test, bench or eval may look for with [`Proc.find`] without declaring them: the ones [`bin/cosmic`] and
--- the tests' own shells already need.
local BASELINE_PROGRAMS: {string: boolean} = { sh = true, cat = true, env = true }

--- Files that look for a program they do not declare, by `<file> <program>`, each with what holds it.
local PROGRAM_EXEMPT: {string: string} = {
  ["build/fix/ignored_tool_test.tl git"] = "todo build-ignored-tool-test-no-git: build its repository from committed testdata",
  ["ci/cosmic_ci/fuzz_test.tl setsid"] = "fails on Linux, skips on macOS, which has none (find_setsid)",
}

--- Each `Proc.find("<program>")` of a `*_test.tl`, `bench/` or `eval/` file under `root` that names a program neither in
--- the baseline (`sh`, `cat`, `env`), nor declared as `"program:<name>"` in the same file, nor exempt, as `<file>:<line>:
--- looks for <program> ...`. A test that needs a program declares `requires = { "program:<name>" }` so a leg that
--- promises it fails when it is absent; a bench or eval has no such declaration and runs no program at all.
function tree_tests.undeclared_programs(root: string): {string}
  local sources, trouble = sources_of(root)
  if sources == nil then
    return { "reading the sources: " .. trouble }
  end
  local out: mut {string} = {}
  for _, entry in ipairs(sources) do
    local file, text = entry[1], entry[2]
    local watched = file ~= nil and (file:match("_test%.tl$") ~= nil or file:match("^bench/") ~= nil or
      file:match("^eval/") ~= nil)
    if watched and text ~= nil and text:find("Proc.find(", 1, true) ~= nil then
      local line_number = 0
      for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        line_number = line_number + 1
        for program in line:gmatch('Proc%.find%("([^"]+)"%)') do
          if BASELINE_PROGRAMS[program] == nil and text:find('"program:' .. program .. '"', 1, true) == nil and
              PROGRAM_EXEMPT[tostring(file) .. " " .. program] == nil then
            out[#out + 1] = tostring(file) .. ":" .. tostring(line_number) .. ": looks for `" .. program ..
              "` without declaring it: add `requires = { \"program:" .. program .. "\" }` to the test's policy " ..
              "and promise it in ci/cosmic_ci/capabilities.json, or commit the testdata it would produce"
          end
        end
      end
    end
  end
  return out
end

return tree_tests

--- The project model, rendered for a reader, out of the model itself.
---
--- `skills/cosmic/model.md` is what `--docs guide.model` prints, and
--- every fact in it is derived: the kind vocabulary, what each marker
--- declares, what an artifact carries, and the verbs. Restating any of
--- them is a second copy with no gate over it, and the copy is what
--- goes stale -- D15 made shipping opt-in and deleted one row, and the
--- guide went on teaching that row in four places, one of them two
--- lines under a corrected one, through three review rounds and two
--- commits. A derived table cannot be WRONG; it can only be different.
---
--- **Every fact comes from the TREE, never from the running engine.**
--- That is the whole reason this module looks the way it does.
--- `package.path` puts `/zip` ahead of the tree, so a `require` here
--- resolves to the modules embedded in whichever binary drives the
--- build -- and on a cold clone that is the pinned release, whose model
--- is a release behind the tree's. Measured: the pin classifies
--- `pkg/db_benchmark.tl` as `module`, because `benchmark` is newer than
--- the pin, and compiling the tree's `project.tl` against the pin's
--- types fails outright with `string "benchmark" is not a member of
--- Kind`.
---
--- A guide rendered from the engine would therefore be wrong on a cold
--- clone and would CHANGE between build generations, which is the one
--- thing an artifact's payload may not do: the fixpoint check compares
--- generations.
---
--- So the rule is: **execute the tree's behaviour, read the tree's
--- data.** `classify` is behaviour, so it is compiled from the tree
--- with `TL_PATH` pointed there and run. The vocabulary, the `ships`
--- set and the verb registry are data, so they are read from the
--- sources that declare them. Nothing here asks the engine anything.
---
--- Gaps WARN and never fail. A generator that refuses wedges the build
--- that would fix it -- the refusal survives `--make clean`, and only
--- reaching for the pin by hand gets out of it. The gate lives in
--- `_build/skill_test.tl`, which reads what this renders and fails the
--- RUN instead.

local fs = require("cosmic.fs")
local teal = require("cosmic.teal")

--- What a row says when a fact could not be filled in. Rendered rather
--- than omitted, so a gap is visible to a reader and greppable by the
--- gate.
local MISSING < const > = "(undocumented)"

--- Where the guide lands inside an artifact, beside the committed ones.
local STORED < const > = "skills/cosmic/model.md"

--- Report a gap without failing. See the header.
--- @param what string The gap, named
local function warn_gap(what: string)
  io.stderr:write("model: " .. what .. "\n")
end

--- Markers, each with a path the model can be asked about.
---
--- The example is the input, not decoration: a row's kind is whatever
--- `classify` answers for it, so a marker that stops meaning what it
--- meant changes this table rather than contradicting it.
local MARKERS < const >: {{string, string}} = {
  {"`<dir>/*.tl`, `<dir>/*.lua`", "pkg/db.tl"},
  {"`main.tl` at the root", "main.tl"},
  {"`cmd/<name>/main.tl`", "cmd/tool/main.tl"},
  {"`*_test.tl`", "pkg/db_test.tl"},
  {"`*_example.tl`", "pkg/db_example.tl"},
  {"`*_benchmark.tl`", "pkg/db_benchmark.tl"},
  {"`*.d.tl`", "pkg/db.d.tl"},
  {"`*_pin.tl`", "3p/tl/tl_pin.tl"},
  {"`*_gen.tl`", "pkg/schema_gen.tl"},
  {"`cmd/<name>/embed_gen.tl`", "cmd/tool/embed_gen.tl"},
  {"`embed/**`", "embed/schema.sql"},
  {"`testdata/`", "pkg/testdata/fixture.json"},
  {"anything that is not a source", "notes.md"},
}

--- One of the tree's sources, read as text.
--- @param path string Path relative to the project root
--- @return string The bytes, or "" when unreadable
local function source(path: string): string
  return fs.read(path) or ""
end

--- Load a module from the TREE, whatever the engine carries.
---
--- The invariant this exists to keep: **a derived document is a pure
--- function of the tree.** A plain `require` is not -- `package.path`
--- puts `/zip` first, so it answers with the running binary's embedded
--- copy, and on a cold clone that binary is the pinned release.
---
--- Both halves are needed and both were learned by being wrong:
---
--- - **compile, not require**, because the module may be newer than any
---   release. `_make.model` itself is: the pin has no such module.
--- - **`TL_PATH` first**, because the module's own imports resolve at
---   COMPILE time against the engine otherwise. Compiling the tree's
---   `project.tl` against the pin's `_make.types` fails outright:
---   `string "benchmark" is not a member of Kind`. `;;` keeps the
---   engine's path after the tree's, for everything the tree does not
---   define.
---
--- Scoped to one compile rather than set process-wide, deliberately: a
--- tree-first `TL_PATH` left standing would change resolution for every
--- later `.tl` require in the process, including the engine's own.
--- @param path string A source path, relative to the project root
--- @return table | nil The loaded module, or nil when unavailable
--- @return string The reason
local function from_tree(path: string): table, string
  local env = require("cosmic.env")
  local before = os.getenv("TL_PATH")
  env.set("TL_PATH", "./?.tl;./?/init.tl;;", true)
  local code, cerr = teal.compile_cached(path)
  if before then
    env.set("TL_PATH", before, true)
  else
    env.unset("TL_PATH")
  end
  local chunk = code and load(code, "@" .. path)
  if not chunk then
    return nil, path .. ": " .. (cerr or "cannot compile or load")
  end
  return chunk() as table -- cast: from any
end

--- The tree's `classify`.
--- @return function(string): string The classifier, or nil when unavailable
local function tree_classify(): function(string): string
  local mod, err = from_tree("_make/project.tl")
  if not mod then
    warn_gap(err)
    return nil
  end
  -- cast: from any, through the tree-loaded module
  return (mod as {string: function(string): string}).classify
end

--- What each kind means, from the block that declares the enum.
---
--- `_make/types.tl` documents every kind directly above `enum Kind`,
--- one indented `---   name  text` entry each, continued on deeper
--- indents. Reading THAT is the point: a description written beside the
--- declaration cannot be added without the thing it describes being
--- visible, and cannot be forgotten when the thing is removed. A copy
--- of it here would be the restatement this module exists to delete --
--- and it was: `benchmark` was in the enum and absent from the block,
--- which no reader of either would have noticed.
--- @return {string: string} Kind to its one-line description
local function kind_docs(): {string: string}
  local block = string.match(source("_make/types.tl"),
    "(.-)\n%s*enum Kind\n") or ""
  local out: {string: string} = {}
  local current = ""
  for line in string.gmatch(block, "[^\n]+") do
    local name, rest = string.match(line, "^%s*%-%-%-   ([%w%-]+)%s+(.+)$")
    if name then
      current = name
      out[current] = rest
    elseif current ~= "" then
      local more = string.match(line, "^%s*%-%-%-%s+(.+)$")
      if more then
        out[current] = out[current] .. " " .. more
      else
        current = ""
      end
    end
  end
  return out
end

--- Every kind the model declares, from the enum's source.
---
--- A Teal enum is type-level: erased by the time this runs, so there is
--- no value to ask and the alternative is a list here, which is the
--- restatement this module exists to delete.
--- @return {string} Kind names, in declaration order
local function vocabulary(): {string}
  local block = string.match(source("_make/types.tl"),
    "enum Kind\n(.-)\n%s*end\n") or ""
  local kinds: {string} = {}
  for name in string.gmatch(block, '"([^"]+)"') do
    kinds[#kinds + 1] = name
  end
  if #kinds == 0 then
    warn_gap("no `enum Kind` found in _make/types.tl")
  end
  return kinds
end

--- The kinds an artifact carries, from the table the builder reads.
--- @return {string: boolean} Kind to whether an artifact carries it
local function ships(): {string: boolean}
  local block = string.match(source("_make/artifact.tl"),
    "local ships: {string: boolean} = {(.-)}") or ""
  local out: {string: boolean} = {}
  local n = 0
  for kind in string.gmatch(block, "([%w%-_]+)%s*=%s*true") do
    out[kind] = true
    n = n + 1
  end
  if n == 0 then
    warn_gap("no `ships` table found in _make/artifact.tl")
  end
  return out
end

--- The verbs, from the registry the dispatcher is built from.
---
--- Name, description and status all come off the same row, because the
--- `Verb` record carries `doc` -- so a verb cannot enter the registry
--- without saying what it is for, and the table below cannot describe a
--- verb the dispatcher does not have.
--- @return {{string, string, boolean}} Name, doc and whether planned
local function verb_rows(): {{string, string, boolean}}
  local block = string.match(source("_make/init.tl"),
    "local VERBS < const >: {Verb} = {(.-)\n}") or ""
  local rows: {{string, string, boolean}} = {}
  for line in string.gmatch(block, "[^\n]+") do
    local name = string.match(line, '{name = "([%w%-_]+)"')
    if name then
      local doc = string.match(line, 'doc = "(.-)"') or ""
      rows[#rows + 1] = {name, doc,
        string.find(line, "planned = true", 1, true) ~= nil}
    end
  end
  if #rows == 0 then
    warn_gap("no VERBS table found in _make/init.tl")
  end
  return rows
end

--- The marker table.
--- @param classify function The tree's classifier
--- @return string The rendered rows
local function marker_table(classify: function(string): string): string
  local carried = ships()
  local docs = kind_docs()
  local out: {string} = {
    "| marker | declares | ships |",
    "|---|---|---|",
  }
  for _, row in ipairs(MARKERS) do
    local kind = classify and classify(row[2]) or ""
    local gloss = docs[kind] or MISSING
    out[#out + 1] = "| " .. row[1] .. " | " .. gloss .. " | " ..
    (carried[kind] and "yes" or "no") .. " |"
  end
  return table.concat(out, "\n")
end

--- The verb table.
--- @return string The rendered rows
local function verb_table(): string
  local out: {string} = {"| verb | what it does | today |", "|---|---|---|"}
  local function emit(planned: boolean, today: string)
    for _, row in ipairs(verb_rows()) do
      if row[3] == planned then
        local what = row[2] ~= "" and row[2] or MISSING
        out[#out + 1] = "| `" .. row[1] .. "` | " .. what ..
        " | " .. today .. " |"
      end
    end
  end
  emit(false, "✅")
  emit(true, "planned")
  return table.concat(out, "\n")
end

--- Everything this module could not derive, named.
---
--- The gate reads this. Rendering only WARNS, because a generator that
--- refuses wedges the build that would fix it; a test that reads the
--- same list fails the run instead, which is loud and recoverable.
--- @return {string} One entry per gap, empty when the guide is whole
local function gaps(): {string}
  local out: {string} = {}
  local classify = tree_classify()
  if not classify then
    out[#out + 1] = "the tree's _make/project.tl could not be compiled, " ..
    "so no row knows what it declares"
    return out
  end
  local seen: {string: boolean} = {}
  local docs = kind_docs()
  for _, row in ipairs(MARKERS) do
    local kind = classify(row[2])
    seen[kind] = true
    if not docs[kind] then
      out[#out + 1] = "kind '" .. kind .. "' has no description: add a " ..
      "`---   " .. kind .. "  …` line to the block above `enum Kind` in " ..
      "_make/types.tl"
    end
  end
  for _, kind in ipairs(vocabulary()) do
    if not seen[kind] then
      out[#out + 1] = "no example produces kind '" .. kind ..
      "': add a marker and an example path to MARKERS in _make/model.tl"
    end
  end
  for _, row in ipairs(verb_rows()) do
    if row[2] == "" then
      out[#out + 1] = "verb '" .. row[1] .. "' has no description: add " ..
      "`doc = \"…\"` to its row in the VERBS table in _make/init.tl"
    end
  end
  return out
end

--- The whole guide.
--- @return string The rendered markdown
local function render(): string
  local classify = tree_classify()
  local rows = marker_table(classify)
  for _, gap in ipairs(gaps()) do
    warn_gap(gap)
  end

  local carried: {string} = {}
  local ships_set = ships()
  for _, kind in ipairs(vocabulary()) do
    if ships_set[kind] then
      carried[#carried + 1] = "`" .. kind .. "`"
    end
  end

  return table.concat({
      "# the project model",
      "",
      "generated from `_make` itself: what a file declares is" ..
      " `project.classify` answering about a path of that shape, what" ..
      " ships is the `ships` table the artifact builder reads, and the" ..
      " verbs are the registry the dispatcher is built from. nothing" ..
      " here can disagree with the build, because none of it is written" ..
      " twice.",
      "",
      "## what a file declares",
      "",
      "position is the manifest: a file's path and name say what it is.",
      "",
      rows,
      "",
      "## what an artifact carries",
      "",
      "shipping is opt-in. an artifact carries " ..
      table.concat(carried, ", ") .. " and nothing else, so `docs/`, a" ..
      " stray `notes.md` and `testdata/` stay behind without anyone" ..
      " excluding them — a file that is merely IN the repo is not IN the" ..
      " binary.",
      "",
      "## verbs",
      "",
      verb_table(),
      "",
    }, "\n")
end

--- Write the guide into a payload directory.
---
--- Here rather than at the call site because the artifact path is a
--- fact about this guide, not about the payload generator that stages
--- it -- and the generator loads this module by compiling it, so
--- everything it does not have to know, it does not.
--- @param dest string The payload directory
--- @return boolean Whether it was written
--- @return string The reason it was not
local function write(dest: string): boolean, string
  local out = fs.join(dest, STORED)
  fs.makedirs(fs.dirname(out))
  local ok, werr = fs.write(out, render())
  if not ok then
    return false, out .. ": " .. (werr or "cannot write")
  end
  return true
end

local record ModelModule
  MISSING: string
  STORED: string
  from_tree: function(path: string): table, string
  render: function(): string
  write: function(dest: string): boolean, string
  gaps: function(): {string}
  vocabulary: function(): {string}
  verb_rows: function(): {{string, string, boolean}}
end

local M: ModelModule = {
  MISSING = MISSING,
  STORED = STORED,
  from_tree = from_tree,
  render = render,
  write = write,
  gaps = gaps,
  vocabulary = vocabulary,
  verb_rows = verb_rows,
}

return M

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

--- What each kind IS, in a reader's words.
---
--- Hand-written, and keyed by KIND rather than by marker, so a kind the
--- vocabulary gains is named in the warning instead of quietly missing
--- a row.
local GLOSS < const >: {string: string} = {
  ["module"] = "a package — compiled, checked, formatted",
  ["entry"] = "the project's binary",
  ["test"] = "a test",
  ["example"] = "an example",
  ["benchmark"] = "a benchmark",
  ["types"] = "type-only; on the include path",
  ["pin"] = "a pinned external asset — data, never executed",
  ["gen"] = "a generation unit — runs BEFORE the graph, writes inputs",
  ["payload-gen"] = "a binary's payload generator — runs AFTER it",
  ["payload"] = "payload, staged at the artifact root",
  ["testdata"] = "test fixtures",
  ["asset"] = "an ordinary part of the project",
}

--- What each verb DOES. The registry knows every verb's name and
--- whether it is planned, and nothing about what it is for.
local VERB_GLOSS < const >: {string: string} = {
  ["build"] = "compile the tree, then stage + embed → `o/bin/<name>`",
  ["check"] = "strict type-check (warnings are errors), in process",
  ["fmt"] = "formatting over every `.tl`; `--fix` rewrites",
  ["lint"] = "style: file length, cast justifications, test order",
  ["test"] = "run `*_test.tl` and report",
  ["example"] = "run `Example_*` functions and check their output",
  ["benchmark"] = "run every `*_benchmark.tl`",
  ["coverage"] = "tests + line coverage, ratcheted against `.cosmic-coverage`",
  ["docs"] = "extract the doc index",
  ["ci"] = "fmt, check, test, example, lint, coverage — the gate",
  ["clean"] = "remove `o/`",
  ["fetch"] = "resolve `*_pin.tl` — the only verb with a network",
  ["run"] = "build, then exec the artifact",
  ["enforce"] = "rerun the sandbox tests unsandboxed, where a skip fails",
  ["reproducible"] = "a policy lane over the graph",
  ["offline"] = "a policy lane over the graph",
}

--- One of the tree's sources, read as text.
--- @param path string Path relative to the project root
--- @return string The bytes, or "" when unreadable
local function source(path: string): string
  return fs.read(path) or ""
end

--- The tree's `classify`, compiled from the tree and loaded.
---
--- `TL_PATH` first, so the compile resolves `_make.types` to the TREE's
--- enum: without it the pin's enum is consulted and the compile fails
--- on the kinds the pin does not have. `;;` keeps the engine's own path
--- after it, for everything the tree does not define.
--- @return function(string): string The classifier, or nil when unavailable
local function tree_classify(): function(string): string
  local before = os.getenv("TL_PATH")
  require("cosmic.env").set("TL_PATH", "./?.tl;./?/init.tl;;", true)
  local code, cerr = teal.compile_cached("_make/project.tl")
  if before then
    require("cosmic.env").set("TL_PATH", before, true)
  else
    require("cosmic.env").unset("TL_PATH")
  end
  if not code then
    warn_gap("cannot compile the tree's _make/project.tl: " ..
      (cerr or "unknown error"))
    return nil
  end
  local chunk = load(code, "@_make/project.tl")
  if not chunk then
    warn_gap("cannot load the compiled _make/project.tl")
    return nil
  end
  local mod = chunk() as {string: function(string): string} -- cast: from any
  return mod.classify
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
--- @return {{string, boolean}} Name and whether it is planned, in order
local function verb_rows(): {{string, boolean}}
  local block = string.match(source("_make/init.tl"),
    "local VERBS < const >: {Verb} = {(.-)\n}") or ""
  local rows: {{string, boolean}} = {}
  for line in string.gmatch(block, "[^\n]+") do
    local name = string.match(line, '{name = "([%w%-_]+)"')
    if name then
      rows[#rows + 1] = {name, string.find(line, "planned = true", 1, true) ~= nil}
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
  local out: {string} = {
    "| marker | declares | ships |",
    "|---|---|---|",
  }
  for _, row in ipairs(MARKERS) do
    local kind = classify and classify(row[2]) or ""
    local gloss = GLOSS[kind] or MISSING
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
      if row[2] == planned then
        local what = VERB_GLOSS[row[1]] or MISSING
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
  for _, row in ipairs(MARKERS) do
    local kind = classify(row[2])
    seen[kind] = true
    if not GLOSS[kind] then
      out[#out + 1] = "no gloss for kind '" .. kind .. "' (" .. row[2] ..
      "): add one to GLOSS in _make/model.tl"
    end
  end
  for _, kind in ipairs(vocabulary()) do
    if not seen[kind] then
      out[#out + 1] = "no example produces kind '" .. kind ..
      "': add a marker and an example path to MARKERS in _make/model.tl"
    end
  end
  for _, row in ipairs(verb_rows()) do
    if not VERB_GLOSS[row[1]] then
      out[#out + 1] = "no description for verb '" .. row[1] ..
      "': add one to VERB_GLOSS in _make/model.tl"
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
  render: function(): string
  write: function(dest: string): boolean, string
  gaps: function(): {string}
  vocabulary: function(): {string}
  verb_rows: function(): {{string, boolean}}
end

local M: ModelModule = {
  MISSING = MISSING,
  STORED = STORED,
  render = render,
  write = write,
  gaps = gaps,
  vocabulary = vocabulary,
  verb_rows = verb_rows,
}

return M

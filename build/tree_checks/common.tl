--- What the checks of the tree share: the `.tl` sources of a tree, and the lines a check of markers tells.

local Fs = require("cosmic.fs")
local identity = require("build.identity")
local Ast = require("lang.ast")
local Ceilings = require("build.ceilings")
local SyntaxNode = require("build.syntax_node")
local TestReturns = require("build.test_returns")
local String = require("cosmic.string")
local Hash = require("cosmic.hash")
local _ = require("build.reads.all")

local record tree_common
end

--- Element `position` of `list`, a position taken from its bounds or from the rows a producer in this file made.
function tree_common.nth<T>(list: {T}, position: integer): T
  return (assert(list[position], "a position is within the list"))
end

--- The value kept under `key` in `map`, a key taken from `map` or set before it is read.
function tree_common.lookup_in<K is Key, V>(map: {K: V}, key: K): V
  return (assert(map[key], "the key is one of the map's"))
end

--- The sink of `marking`, if it has one.
function tree_common.sink_of(marking: Ceilings.Marking?): Ceilings.Sink?
  if marking == nil then
    return nil
  end
  return marking.sink
end

--- The lines that tell what `judged`, the markers of `file` against its findings, found: the findings no marker holds, then
--- each marker that holds what the line lacks, which `cosmic fix` removes. They go to `sink` as well, where it is given.
function tree_common.told_marks(file: string, judged: Ceilings.Judged, sink: Ceilings.Sink?): {string}
  local told: mut {string} = {}
  for _, line in ipairs(judged.lines) do
    told[#told + 1] = line
  end
  -- A caller that mends the stale markers does not tell them.
  if sink == nil or sink.mend ~= true then
    for _, spot in ipairs(judged.stale) do
      local line = file .. ":" .. tostring(spot.line) .. ": its marker holds " .. String.counted(spot.count, "finding") ..
        " of " .. spot.code .. " that the line no longer has; `cosmic fix` removes the marker"
      told[#told + 1] = line
    end
  end
  if sink ~= nil then
    for _, spot in ipairs(judged.unmarked) do
      sink.unmarked[#sink.unmarked + 1] = spot
    end
    for _, spot in ipairs(judged.stale) do
      sink.stale[#sink.stale + 1] = spot
    end
  end
  return told
end

--- Every `.tl` file under `root` as `{file, source}` pairs, read from disk: the modules and tests, the declaration files
--- of a tree. The projection is not read, as it holds no declaration file. `vendor/`, the hidden directories,
--- `o/` (never read) and `ci/` hold none the tree owns: `ci/` is a project of its own, whose modules are named from its own
--- root and checked there (`cosmic fix --check` run in `ci/`, which build/ci_check_test.tl runs). The declarations of the globals ([`lang/prelude.d.tl`],
--- [`lang/stdlib.d.tl`]) are left out: they are the globals of every build ([`build.tree_program`]), no module of it.
function tree_common.sources_of(root: string): {{string}}?, string
  local listed, trouble = Fs.walk(root, { skip = function(relative: string, name: string, kind: Fs.Kind): boolean
    return kind == "dir" and (name:sub(1, 1) == "." or relative == "vendor" or relative == "o" or
      identity.is_foreign_tree(relative))
  end })
  if listed == nil then
    return nil, tostring(trouble)
  end
  local out: mut {{string}} = {}
  for _, file in ipairs(listed) do
    if file:match("%.tl$") ~= nil and file ~= "lang/prelude.d.tl" and file ~= "lang/stdlib.d.tl" then
      local text, read_trouble = Fs.read(root .. "/" .. file)
      if text == nil then
        return nil, tostring(read_trouble)
      end
      out[#out + 1] = { file, text }
    end
  end
  return out, ""
end

--- The modules a source requires by a literal name, as `require("m")` or `pcall(require, "m")`: the parser's own
--- reading of the file `file`. A file that does not parse is read by its text, a name in a comment or a string counting
--- too, which costs a key that moves for no reason and never a missed edge.
local function parsed_requires(source: string, file: string): {string}
  local chunk, _ = SyntaxNode.parse(source, file)
  if chunk ~= nil then
    return SyntaxNode.requires(chunk)
  end
  local out: mut {string} = {}
  local seen: mut {string: boolean} = {}
  for _, name in source:gmatch("require%s*[%(,]?%s*([\"'])([%w_%.%-]+)%1") do
    if seen[name] ~= true then
      seen[name] = true
      out[#out + 1] = name
    end
  end
  return out
end

--- What [`parsed_requires`] returned for each text, by its digest and its dialect, which a path ending in `.d.tl`
--- says: the checks of one run each index the tree ([`build.tree_checks.checked`]), and parsing every file is most of the work of
--- one. `fix` tells it what its own parse of each file found ([`tree_common.knows_parse`]).
local requires_known: mut {string: {string}} = {}

--- The early returns ([`TestReturns`]) of each test file's text, keyed as `requires_known` is, as `fix`'s own parse
--- found them ([`tree_common.knows_parse`]), for [`tree_tests.test_returns`] to read rather than parse it again.
local returns_known: mut {string: {{string}}} = {}

local function requires_key(digest: string, file: string): string
  return digest .. (if file:find("%.d%.tl$") ~= nil then " decl" else " tl" end)
end

--- Keeps what `chunk`, the parse of `source` as the text of `file`, requires, and a test file's early returns, for
--- the checks later in the run to read rather than parse the file again.
function tree_common.knows_parse(source: string, file: string, chunk: Ast.Chunk)
  local key = requires_key(Hash.hex_sha256(source), file)
  requires_known[key] = SyntaxNode.requires(chunk)
  if file:match("_test%.tl$") ~= nil then returns_known[key] = TestReturns.of_chunk(chunk) end
end

function tree_common.required_modules(source: string, file: string, digest: string): {string}
  local key = requires_key(digest, file)
  local known = requires_known[key]
  if known == nil then
    known = parsed_requires(source, file)
    requires_known[key] = known
  end
  return known
end

--- The early returns of the test file `file`, whose text is `text`, as [`tree_common.knows_parse`] kept them, or nil.
function tree_common.known_returns(text: string, file: string): {{string}}?
  return returns_known[requires_key(Hash.hex_sha256(text), file)]
end

return tree_common

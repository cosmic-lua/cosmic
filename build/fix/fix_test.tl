--- The properties `cosmic fix` has to hold whatever it is given, and
--- the one that ties it to this tree.
---
--- Four properties, and the reason each is here. Idempotency, because a
--- fix that keeps finding something to fix never converges, and one run
--- of the verb has to be enough. Determinism, because the renderer
--- walks tables whose key order Lua does not fix, so a traversal that
--- leaked into the output would show up as two different files from one
--- input. A semantic round-trip, because neither of the first two can
--- tell a consistently wrong renderer from a right one. And
--- self-hosting, because a renderer is only as good as the source it
--- has been made to survive, and this tree is the source there is.
---
--- The self-hosting check is a test rather than something run by hand
--- once: nothing else would notice the day a change to the renderer
--- starts failing on a file the tree already holds.

local Fs = require("cosmic.fs")
local ast = require("build.ast")
local equiv = require("build.fix.equiv")
local fix = require("build.fix")
local teal = require("build.teal")

local built, load_trouble = teal.load()
if built == nil then
  error("could not load the compiler: " .. tostring(load_trouble))
end

--- A fixture broad enough to reach most of the grammar at once, in one
--- string, so the properties below are checked over something with
--- real shape rather than over a one-liner.
local fixture = table.concat({
  "--- A doc comment on the module.",
  "local Mod = {}",
  "",
  "-- why this is here",
  "local counts <const>: {string:integer} = {",
  "  first = 1,",
  "  second = 2,",
  "}",
  "",
  "--- What this does.",
  "--- @param name string",
  "local function look_up(name: string, fallback?: integer): integer | nil, string",
  "  if counts[name] == nil then",
  "    return fallback, \"no such name: \" .. name -- give back what we can",
  "  end",
  "  for key, value in pairs(counts) do",
  "    if key == name then return value end",
  "  end",
  "  local total = 0",
  "  for i = 1, #name, 2 do",
  "    total = total + i",
  "  end",
  "  while total > 100 do",
  "    total = total // 2",
  "  end",
  "  return total, \"\"",
  "end",
  "",
  "function Mod.run(argv: {integer:string}): integer",
  "  local first = argv[1] as string",
  "  local found, trouble = look_up(first,",
  "    3)",
  "  return found ~= nil and found or #trouble",
  "end",
  "",
  "return Mod",
  "",
}, "\n")

--- Run the whole pipeline, asserting it succeeded.
local function fixed(source: string, name: string): string
  local result, trouble = fix.source(built, source, name)
  assert(result ~= nil, name .. ": fix refused it: " .. tostring(trouble))
  return result.source
end

--- Fixing what was already fixed changes nothing further.
local function test_fixing_twice_is_the_same_as_fixing_once()
  local once = fixed(fixture, "fixture.tl")
  local twice = fixed(once, "fixture.tl")
  assert(twice == once, "second pass differs:\n" .. twice .. "\nfirst:\n" .. once)
end

--- Rendering an already-canonical source leaves it byte for byte.
local function test_a_canonical_source_is_left_alone()
  local once = fixed(fixture, "fixture.tl")
  local result, trouble = fix.source(built, once, "fixture.tl")
  assert(result ~= nil, "fix refused it: " .. tostring(trouble))
  assert(not result.changed, "a second pass reported a change")
end

--- The same input gives the same bytes, run after run: nothing in the
--- renderer reads a table in whatever order Lua felt like.
local function test_the_same_input_renders_the_same_bytes_every_time()
  local first = fixed(fixture, "fixture.tl")
  for round = 2, 8 do
    local again = fixed(fixture, "fixture.tl")
    assert(again == first, "round " .. round .. " differs from the first")
  end
end

--- What was rendered parses to the same tree, and carries the same
--- comments, as what it was rendered from -- checked here directly as
--- well as inside the verb, because this is the property the golden
--- strings alone cannot establish.
local function test_rendering_keeps_the_tree_and_the_comments()
  local before, before_trouble = ast.parse(built, fixture, "fixture.tl")
  assert(before ~= nil, "parse failed: " .. tostring(before_trouble))
  local after, after_trouble = ast.parse(built, fixed(fixture, "fixture.tl"),
                                         "fixture.tl")
  assert(after ~= nil, "reparse failed: " .. tostring(after_trouble))
  local same, difference = equiv.same_tree(before.node, after.node)
  assert(same, "the tree changed: " .. difference)
  local kept, lost = equiv.same_comments(before.tokens, after.tokens)
  assert(kept, "the comments changed: " .. lost)
  assert(#equiv.comments(before.tokens) > 0, "the fixture carries no comments")
end

--- Mangled spacing and indentation come back canonical, and still mean
--- the same thing: the properties above would all hold for a renderer
--- that refused to change anything at all, and this is what says it
--- does.
local function test_mangled_spacing_and_indentation_are_repaired()
  local mangled = "local   x <const>   = 5\nlocal t = {1,2}\nif  x  then\n" ..
                  "        print( x )\nend\n"
  local want = "local x <const> = 5\nlocal t = { 1, 2 }\nif x then\n" ..
               "  print(x)\nend\n"
  local got = fixed(mangled, "mangled.tl")
  assert(got == want, "got:\n" .. got .. "\nwant:\n" .. want)
end

--- A named path the verb will not take is a refusal among the files the
--- run covers, not an end to the run: it comes back in `refused` with
--- the others still listed, which is what lets `fix.run` report it and
--- still finish in its own verdict line.
---
--- And what a path IS is decided before what it is NAMED. A path with
--- nothing at it is missing, whatever its suffix -- answering `nope`
--- with a remark about Teal says the wrong thing about it, and says it
--- about a file the caller may only have mistyped.
local function test_a_path_that_is_not_there_is_missing_before_it_is_judged(tmp: string)
  assert(Fs.write(tmp .. "/real.tl", "local x = 1\nprint(x)\n"))
  assert(Fs.write(tmp .. "/notes.txt", "not Teal at all\n"))
  local picked, trouble = fix.chosen(tmp, {
    tmp .. "/real.tl",
    tmp .. "/nope",
    tmp .. "/nosuchdir/",
    tmp .. "/notes.txt",
  })
  assert(picked ~= nil, "naming a missing path should not end the run: " ..
    tostring(trouble))
  assert(#picked.files == 1 and picked.files[1] == tmp .. "/real.tl",
    "the real source should still be listed")
  assert(#picked.refused == 3, "expected three refusals, got " .. #picked.refused)
  for i, what in ipairs({ "nope", "nosuchdir/" }) do
    assert(picked.refused[i]:find("No such file", 1, true) ~= nil,
      what .. " should be reported as missing, not judged on its suffix: " ..
      picked.refused[i])
  end
  assert(picked.refused[3]:find("not a Teal source", 1, true) ~= nil,
    "a file that is there but is not Teal should be said so: " ..
    picked.refused[3])
end

--- Every Teal source this tree holds renders, is already canonical,
--- and stays at the fixed point on a second pass. Check these together
--- so the canonical-source gate reuses the first rendering instead of
--- repeating a whole-tree pass. Neither pass may change the syntax tree
--- or comments, and any failure names the source responsible.
local function test_every_source_in_the_tree_is_canonical_and_stays_so()
  local root, root_trouble = Fs.absolute(".")
  assert(root ~= nil, "could not resolve the tree root: " .. tostring(root_trouble))
  local files, list_trouble = fix.sources(root)
  assert(files ~= nil, "could not walk the tree: " .. tostring(list_trouble))
  assert(#files > 20, "expected the whole tree, found " .. #files .. " files")
  local differing: {string} = {}
  local unsettled: {string} = {}
  for _, file in ipairs(files) do
    local source, read_trouble = Fs.read(root .. "/" .. file)
    assert(source ~= nil, file .. ": " .. tostring(read_trouble))
    -- Each call parses what it wrote and compares it, tree and
    -- comments, against what it came from, so a file that renders at
    -- all has already round-tripped by the time this returns.
    local result, trouble = fix.source(built, source, file)
    assert(result ~= nil, file .. ": fix refused it: " .. tostring(trouble))
    assert(result.changed == (result.source ~= source),
      file .. ": change flag disagrees with rendered bytes")
    if result.source ~= source then
      differing[#differing + 1] = file
    end
    local twice = fixed(result.source, file)
    if twice ~= result.source then
      unsettled[#unsettled + 1] = file
    end
  end
  assert(#unsettled == 0,
    "a second pass changed these again: " .. table.concat(unsettled, ", "))
  assert(#differing == 0,
    "run `cosmic fix` -- these are not what it writes: " ..
    table.concat(differing, ", "))
end

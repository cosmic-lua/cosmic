--- A memo of what `cosmic fix` reads off a Teal file ([`build.fix.read_memo`]) gives back what the read made: the
--- comment blocks, what each line of a block sees declared (its own names, the names every comment sees, its aliases),
--- the top-level names, the candidates and the plurals; and a text that is no memo of a read is a miss.
local Node = require("build.syntax_node")
local ReadMemo = require("build.fix.read_memo")
local store_lookups = require("build.store_lookups")
local SyntaxLinks = require("build.syntax_links")
local Test = require("cosmic.test")

Test.policy{}

local source = table.concat({
  "local Fs = require(\"cosmic.fs\")",
  "",
  "--- A box: see [`Box.n`] and `Fs.read`.",
  "local record Box",
  "  n: integer",
  "end",
  "",
  "local function f(b: Box): integer",
  "  local inner = Fs",
  "  -- `inner` and [`b`] are in scope here.",
  "  return b.n + (inner and 0 or 1)",
  "end",
  "",
  "return { Box = Box, f = f }",
  "",
}, "\n")

local function sorted_keys(set: {string: boolean}): string
  local keys: mut {string} = {}
  for k in pairs(set) do keys[#keys + 1] = k end
  table.sort(keys)
  return table.concat(keys, ",")
end

local function test_a_read_comes_back_as_it_was_kept()
  local chunk = assert(Node.parse(source, "box.tl"))
  local settled = SyntaxLinks.settled(chunk, Node.scope(chunk, "box.tl"))
  local read: ReadMemo.Read = {
    settled = settled,
    candidates = { { source_symbol = "box.f", text = "f", line = 8, method = true }, { source_symbol = "box.g", text = "g", line = 9 } },
    plurals = { source = source, sites = { { "a", "b" }, { "c" } } },
    requires = { "cosmic.fs" },
    returns = { { "x", "1" } },
  }
  local back = assert(ReadMemo.decode(ReadMemo.encode(read), source))
  assert(#back.settled.blocks == #settled.blocks and #settled.blocks > 0)
  for i, block in ipairs(settled.blocks) do
    local other = assert(back.settled.blocks[i])
    assert(other.line == block.line and other.text == block.text, "block " .. tostring(i))
  end
  assert(sorted_keys(back.settled.module_level) == sorted_keys(settled.module_level))
  local facts, kept = SyntaxLinks.facts_of(settled, source), SyntaxLinks.facts_of(back.settled, source)
  for line in pairs(settled.lines) do
    local want, got = facts.known.at(line), kept.known.at(line)
    for _, name in ipairs({ "Box", "Fs", "f", "inner", "b", "Box.n", "nothing" }) do
      assert((want.names[name] == true) == (got.names[name] == true), name .. " on line " .. tostring(line))
    end
    assert(want.aliases["Fs"] == got.aliases["Fs"], "the alias of Fs on line " .. tostring(line))
    assert(want.aliases["inner"] == got.aliases["inner"], "the alias of inner on line " .. tostring(line))
  end
  local candidates = assert(back.candidates)
  assert(#candidates == 2 and assert(candidates[1]).method == true and assert(candidates[2]).method == nil)
  assert(assert(candidates[2]).line == 9 and assert(candidates[1]).source_symbol == "box.f")
  local plurals = assert(back.plurals)
  assert(plurals.source == source and #plurals.sites == 2 and assert(plurals.sites[1])[2] == "b")
  assert(assert(back.requires)[1] == "cosmic.fs" and assert(assert(back.returns)[1])[2] == "1")
end

local function test_what_a_read_left_out_stays_out_and_another_text_is_a_miss()
  local chunk = assert(Node.parse(source, "box.tl"))
  local read: ReadMemo.Read = { settled = SyntaxLinks.settled(chunk, Node.scope(chunk, "box.tl")) }
  local back = assert(ReadMemo.decode(ReadMemo.encode(read), source))
  assert(back.candidates == nil and back.plurals == nil and back.requires == nil and back.returns == nil)
  assert(ReadMemo.decode("", source) == nil)
  assert(ReadMemo.decode("other 1\n", source) == nil)
end

--- A read's salt is the code a read runs: what [`build.fix.read`] loads, however far, holds none of the rest of fix or of
--- the tree checks, so an edit there leaves every read kept.
local function test_the_code_a_read_runs_holds_no_other_part_of_fix_or_the_tree_checks()
  local seen: mut {string: boolean} = {}
  local stack: mut {string} = { "build.fix.read" }
  while #stack > 0 do
    local name = assert(table.remove(stack))
    if not (seen[name] == true) then
      seen[name] = true
      local needs = assert(store_lookups.requires(name))
      for _, need in ipairs(needs) do stack[#stack + 1] = need end
    end
  end
  local allowed: {string: boolean} = { ["build.fix.read"] = true, ["build.fix.read_memo"] = true,
    ["build.fix.near"] = true, ["build.tree_checks.known"] = true, ["build.tree_checks.common"] = true }
  for name in pairs(seen) do
    local part = name == "build.fix" or name:sub(1, 10) == "build.fix." or name == "build.tree_checks" or
      name:sub(1, 18) == "build.tree_checks."
    assert(not part or allowed[name] == true, name .. " is in the code a read runs")
  end
end

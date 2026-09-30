--- The verb registry (build/verb_list.tl): each listed module carries a
--- `spec` that says what it is, and the list, [`cosmic.cli`]'s `order` (the
--- prose of every verb is held in build/verbs_store_test.tl, which reads
--- each one's help) and the verbs dispatch reaches agree. A module's `spec`
--- missing from the list, and a verb's guide and tests, are held over the
--- whole tree by build/tree_checks.tl's `verbs`.

local Cli = require("cosmic.cli")
local verb_list = require("build.verb_list")

--- The verbs that run code -- a file, a chunk, `--version` -- which no
--- module of the list holds, and `help`, which build/dispatch.tl holds
--- itself: what `Cli.order` has around the list.
local before <const> = { "run", "standalone", "eval", "version" }
local after <const> = { "help" }

local function test_every_listed_module_has_its_spec()
  for _, entry in ipairs(verb_list.entries) do
    local spec = entry.load()
    assert(spec.name == entry.name, entry.name .. ": its spec names " .. tostring(spec.name))
    local run: any = spec.run
    local bare: any = spec.bare
    assert(type(run) == "function", entry.name .. ": no run")
    local takes: any = spec.takes
    assert(type(takes) == "string", entry.name .. ": say what it takes")
    assert(type(bare) == "boolean", entry.name .. ": say whether it is bare")
  end
end

local function test_a_name_is_listed_once()
  local seen: {string:boolean} = {}
  for _, spec in ipairs(verb_list.specs()) do
    assert(not seen[spec.name], spec.name .. " is listed twice")
    seen[spec.name] = true
  end
  for _, name in ipairs(before) do
    assert(not seen[name], name .. " runs code, not a listed module")
  end
  for _, name in ipairs(after) do
    assert(not seen[name], name .. " is dispatch's own")
  end
end

local function test_a_bare_verb_says_how_it_exits_and_why_it_is_uncased()
  for _, spec in ipairs(verb_list.specs()) do
    if spec.bare then
      assert(spec.exits ~= nil and spec.exits:find("`" .. spec.name .. "`", 1, true),
        spec.name .. ": bare, so its exit codes are help's to state, starting with its name")
      assert(spec.passthrough ~= nil, spec.name .. ": bare, so verb_cases needs its reason")
    else
      assert(spec.exits == nil, spec.name .. ": ends in a verdict line, so has no exit sentence")
      assert(spec.passthrough == nil, spec.name .. ": ends in a verdict line, so is cased")
    end
  end
end

local function test_the_list_and_cli_order_agree()
  local want: {string} = {}
  for _, name in ipairs(before) do want[#want + 1] = name end
  for _, spec in ipairs(verb_list.specs()) do want[#want + 1] = spec.name end
  for _, name in ipairs(after) do want[#want + 1] = name end
  assert(table.concat(want, " ") == table.concat(Cli.order, " "),
    "verb_list and Cli.order differ:\n  " .. table.concat(want, " ") .. "\n  " ..
    table.concat(Cli.order, " "))
end

local function test_every_option_table_is_a_verbs()
  local known: {string:boolean} = {}
  for _, name in ipairs(Cli.order) do known[name] = true end
  for name in pairs(Cli.options) do
    assert(known[name], "Cli.options." .. name .. " is not a verb in Cli.order")
  end
end

--- `cosmic help exit` gathers each bare verb's clause with the others', in the
--- list's order, so a clause that leans on its neighbours ("instead", "likewise")
--- says something else there than in its own module.
local function test_a_spec_prose_stands_by_itself()
  for _, spec in ipairs(verb_list.specs()) do
    for _, prose in ipairs({ spec.takes, spec.exits or "" }) do
      for _, word in ipairs({ "instead", "likewise" }) do
        assert(not prose:find(word, 1, true),
          spec.name .. ": \"" .. word .. "\" leans on the verb before it in help")
      end
    end
  end
end

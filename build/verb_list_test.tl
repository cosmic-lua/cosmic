--- The verb registry (build/verb_list.tl): each listed module carries a
--- `spec` that says what it is, and the verbs listed are those
--- [`cosmic.cli`]'s groups name (the prose of every verb is held in
--- build/verbs_store_test.tl, which reads each one's help). A module's `spec`
--- missing from the list, and a verb's guide and tests, are held over the
--- whole tree by build/tree_checks.tl's `verbs`.

local Cli = require("cosmic.cli")
local verb_list = require("build.verb_list")

--- The verbs that run code -- a file, a chunk, `--version` -- which no
--- module of the list holds, and `help`, which build/dispatch.tl holds
--- itself: the verbs [`Cli.groups`] names that the list has not.
local before <const> = { "run", "standalone", "eval", "version" }
local after <const> = { "help" }

local function test_every_listed_module_has_its_spec()
  for name, loader in pairs(verb_list.loads) do
    local spec = loader()
    assert(spec.name == name, name .. ": its spec names " .. tostring(spec.name))
    local run: any = spec.run -- checked: any_use
    local bare: any = spec.bare -- checked: any_use
    assert(type(run) == "function", name .. ": no run")
    local takes: any = spec.takes -- checked: any_use
    assert(type(takes) == "string", name .. ": say what it takes")
    assert(type(bare) == "boolean", name .. ": say whether it is bare")
  end
end

local function test_a_name_is_listed_once()
  local seen: mut {string:boolean} = {}
  for _, spec in ipairs(verb_list.specs()) do
    assert(seen[spec.name] ~= true, spec.name .. " is listed twice")
    seen[spec.name] = true
  end
  for _, name in ipairs(before) do
    assert(seen[name] ~= true, name .. " runs code, not a listed module")
  end
  for _, name in ipairs(after) do
    assert(seen[name] ~= true, name .. " is dispatch's own")
  end
end

local function test_a_bare_verb_says_how_it_exits_and_why_it_is_uncased()
  for _, spec in ipairs(verb_list.specs()) do
    if spec.bare then
      local exits = spec.exits
      assert(exits ~= nil and exits:find("`" .. spec.name .. "`", 1, true) ~= nil,
        spec.name .. ": bare, so its exit codes are help's to state, starting with its name")
      assert(spec.passthrough ~= nil, spec.name .. ": bare, so verb_cases needs its reason")
    else
      assert(spec.exits == nil, spec.name .. ": not bare, so `cosmic help exit` covers it")
      assert(spec.passthrough == nil, spec.name .. ": not bare, so is cased")
    end
  end
end

local function test_the_list_holds_the_grouped_verbs_that_are_not_code_or_help()
  local own: mut {string:boolean} = {}
  for _, name in ipairs(before) do own[name] = true end
  for _, name in ipairs(after) do own[name] = true end
  local listed = 0
  for _, name in ipairs(Cli.order) do
    if own[name] ~= true then
      assert(verb_list.loads[name] ~= nil, name .. " is in Cli.groups but not in verb_list")
      listed = listed + 1
    end
  end
  local loads = 0
  for name in pairs(verb_list.loads) do
    loads = loads + 1
    assert(Cli.verbs[name] ~= nil, name .. " is in verb_list but not in Cli.verbs")
  end
  assert(loads == listed, "verb_list has " .. tostring(loads) .. " verbs, Cli.groups " .. tostring(listed))
  local want: mut {string} = {}
  for _, name in ipairs(Cli.order) do
    if own[name] ~= true then want[#want + 1] = name end
  end
  local got: mut {string} = {}
  for _, spec in ipairs(verb_list.specs()) do got[#got + 1] = spec.name end
  assert(table.concat(got, " ") == table.concat(want, " "),
    "specs answers the listed verbs in Cli.order's order:\n  " .. table.concat(got, " ") .. "\n  " ..
      table.concat(want, " "))
end

local function test_the_groups_name_every_verb_once_and_nothing_else()
  local seen: mut {string:integer} = {}
  for _, group in ipairs(Cli.groups) do
    for slot = 2, #group do
      seen[group[slot]] = (seen[group[slot]] or 0) + 1
    end
  end
  for name in pairs(Cli.verbs) do
    assert(seen[name] == 1, name .. " is in " .. tostring((seen[name] or 0)) .. " groups of Cli.groups")
  end
  for name in pairs(seen) do
    assert(Cli.verbs[name] ~= nil, "Cli.groups names " .. name .. ", which Cli.verbs lacks")
  end
end

--- `cosmic help exit` gathers each bare verb's clause with the others', in the
--- order of [`Cli.order`], so a clause that leans on its neighbours ("instead", "likewise")
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

--- The words of an example line as a shell splits them: spaces apart,
--- and a word in single quotes kept whole.
local function example_words(line: string): {string}
  local words: mut {string} = {}
  local rest = line
  while true do
    rest = rest:gsub("^%s+", "")
    if rest == "" then break end
    local quoted, remaining = rest:match("^'([^']*)'(.*)$")
    if quoted ~= nil and remaining ~= nil then
      words[#words + 1] = quoted
      rest = remaining
    else
      local word, tail = rest:match("^(%S+)(.*)$")
      words[#words + 1] = assert(word)
      rest = tail or ""
    end
  end
  return words
end

--- Every verb's help shows at least one example, and each example's
--- options are ones the verb takes, so an example cannot name an option
--- that is gone.
local function test_every_verb_has_examples_its_options_take()
  local Flags = require("cosmic.flags")
  for _, verb in ipairs(Cli.order) do
    local command = assert(Cli.verbs[verb])
    local examples = command.examples or {}
    assert(#examples > 0, verb .. ": its help shows no example")
    for _, example in ipairs(examples) do
      assert(example.about ~= "", verb .. " " .. example.line .. ": says nothing of what it does")
      local words = example_words(example.line)
      -- A file run, `--standalone`, `-e` and `--version` read their own lines, with no spec.
      local spec = command.spec
      if spec ~= nil then
        local parsed, why = Flags.parse(words, 1, spec)
        assert(parsed ~= nil, verb .. " " .. example.line .. ": " .. why)
      end
    end
  end
end

--- A verb that runs at its tree's root is a listed verb: a key that names none would leave the verb it meant where it
--- was started.
local function test_every_tree_verb_is_listed()
  for name, kind in pairs(verb_list.tree_paths) do
    assert(verb_list.loads[name] ~= nil, name .. " runs at its tree's root but is no listed verb")
    assert(kind == "all" or kind == "rest" or kind == "named" or kind == "none", name .. ": " .. kind)
  end
end

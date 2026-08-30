#!/usr/bin/env cosmic
-- The doctrine pages: every listed topic renders, the listing names
-- them all, `help <topic>` serves a page through the real dispatch,
-- and no topic name shadows a verb — the intercept runs before the
-- command dispatcher, so a collision would silently eat a verb's own
-- help page.

local doctrine = require("_work.doctrine")
local gitboard = require("_work.gitboard")

--- Run gitboard.main(...) and capture exactly what it prints via
--- print() — the swap-and-restore pattern gitboard_test.tl uses.
--- @param ... string Arguments to pass to gitboard.main, as on argv
--- @return integer gitboard.main's exit code
--- @return string Every print()'d line, newline-joined
local function gitboard_and_capture(...: string): integer, string
  local old_print = _G.print
  local lines: {string} = {}
  _G.print = function(...: any)
    local parts: {string} = {}
    for i = 1, select("#", ...) do
      parts[i] = tostring((select(i, ...)))
    end
    lines[#lines + 1] = table.concat(parts, "\t")
  end
  local ok, result = pcall(gitboard.main, ...)
  _G.print = old_print
  if not ok then
    error(result, 0)
  end
  return result, table.concat(lines, "\n")
end

local function test_every_topic_renders()
  local names = doctrine.names()
  assert(#names >= 5, "the system ships at least its five pages")
  for _, name in ipairs(names) do
    local page = doctrine.page(name)
    assert(page ~= nil and #page > 200,
      ("topic %s renders a real page"):format(name))
    assert(page:sub(1, #name) == name,
      ("a page opens with its own name: %s"):format(name))
  end
  assert(doctrine.page("no-such-topic") == nil,
    "a name that is not a topic is nil, not a guess")
end
test_every_topic_renders()

local function test_listing_names_every_topic()
  local listing = doctrine.listing()
  for _, name in ipairs(doctrine.names()) do
    assert(listing:find(name, 1, true) ~= nil,
      ("the listing names %s"):format(name))
  end
end
test_listing_names_every_topic()

local function test_help_serves_a_topic_through_the_dispatch()
  local code, out = gitboard_and_capture("help", "system")
  assert(code == 0, "help <topic> exits clean")
  assert(out:find("finishing beats starting", 1, true) ~= nil,
    "the system page came through the real dispatch: " .. out:sub(1, 80))
end
test_help_serves_a_topic_through_the_dispatch()

local function test_help_overview_lists_the_topics()
  local code, out = gitboard_and_capture("help")
  assert(code == 0)
  assert(out:find("topics ('gitboard help <topic>')", 1, true) ~= nil,
    "the overview carries the topic list")
end
test_help_overview_lists_the_topics()

local function test_no_topic_shadows_a_verb()
  -- The overview's command rows are the verb vocabulary; a topic
  -- sharing a name would be served by the intercept INSTEAD of that
  -- verb's help page, so the two sets must be disjoint.
  local _, out = gitboard_and_capture("help")
  local commands: {string: boolean} = {}
  local in_commands = false
  for line in (out .. "\n"):gmatch("(.-)\n") do
    if line == "commands:" then
      in_commands = true
    elseif in_commands then
      local name = line:match("^  (%S+)")
      if name == nil then
        in_commands = false
      else
        commands[name] = true
      end
    end
  end
  assert(commands["take"], "the parse found the real command rows")
  for _, name in ipairs(doctrine.names()) do
    assert(not commands[name],
      ("topic %s shadows a verb — rename the topic"):format(name))
  end
  -- And a verb's own page still wins: `help take` is the verb's help,
  -- never a doctrine page.
  local code, verb_out = gitboard_and_capture("help", "take")
  assert(code == 0)
  assert(verb_out:find("usage:", 1, true) ~= nil,
    "help <verb> still renders the verb page: " .. verb_out:sub(1, 80))
end
test_no_topic_shadows_a_verb()

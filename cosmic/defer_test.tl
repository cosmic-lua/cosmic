local Defer = require("cosmic.defer")
local Test = require("cosmic.test")

Test.policy{}

local function test_a_deferred_function_runs_as_its_block_ends()
  local ran: mut {string} = {}
  do
    local _ <close> = Defer.new(function() ran[#ran + 1] = "first" end)
    ran[#ran + 1] = "body"
  end
  assert(table.concat(ran, " ") == "body first", table.concat(ran, " "))
end

local function test_a_deferred_function_runs_when_its_block_raises_and_each_time_it_is_closed()
  local count = 0
  local ok, why = pcall(function()
    local held <close> = Defer.new(function() count = count + 1 end)
    local _ = held
    error("raised", 0)
  end)
  assert(not ok and why == "raised", tostring(why))
  assert(count == 1, tostring(count))
  local twice = Defer.new(function() count = count + 1 end)
  do
    local _ <close> = twice
  end
  do
    local _ <close> = twice
  end
  assert(count == 3, tostring(count))
end

local function test_deferred_functions_run_in_the_reverse_of_their_order()
  local ran: mut {integer} = {}
  do
    local _first <close> = Defer.new(function() ran[#ran + 1] = 1 end)
    local _second <close> = Defer.new(function() ran[#ran + 1] = 2 end)
  end
  assert(ran[1] == 2 and ran[2] == 1)
end

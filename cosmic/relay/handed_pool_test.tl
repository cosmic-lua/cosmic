--- How [`Relay.handed`] shares the connectors of a kind among the relay's
--- connections: a request waits for a free one in the order it came, at
--- most its own time; one that has ended is passed over; a request whose
--- connector ends under it is asked of another only while its time lasts;
--- and the first request that finds every one ended tells `lost`. The
--- connectors are stand-ins that say what they were asked, hold a request
--- as long as a test says, and connect nothing.
local Clock = require("cosmic.clock")
local Poll = require("cosmic.poll")
local Relay = require("cosmic.relay.server")
local type Net = require("cosmic.net")

--- A stand-in for a connector, named `name`: it records each request in
--- `log` as "<name> <target>", holds it for `hold_ns`, and then refuses
--- it, or ends where it `dies`. One made `gone` has ended already.
local function fake(name: string, log: {string}, hold_ns?: integer, dies?: boolean, gone?: boolean): Net.Connector
  local hold = hold_ns or 0
  local ended = gone or false
  local stand_in: any = {
    connect = function(_: any, target: integer | string, _port: integer, _timeout_ns: integer): any, string
      log[#log + 1] = name .. " " .. tostring(target)
      if hold > 0 then
        local waited, why = Poll.delay(hold)
        if not waited then return nil, why end
      end
      if dies then
        ended = true
        return nil, "net: the connector has ended"
      end
      return nil, "refused by " .. name
    end,
    ended = function(_: any): boolean
      return ended
    end,
    close = function(_: any): boolean, string
      ended = true
      return true, ""
    end,
  }
  return stand_in as Net.Connector -- cast: it has every method the relay calls
end

local WAIT <const> = Clock.seconds(1)

local function test_a_request_finding_every_connector_held_times_out_at_its_deadline()
  local log: {string} = {}
  Poll.run(function()
    local connect = Relay.handed({ public_connectors = { fake("held", log, Clock.ms(500)) }, wait_ns = WAIT })
    local holding = Poll.spawn(function()
      local _, _ = connect("192.0.2.1", 443, WAIT)
    end)
    assert(Poll.delay(Clock.ms(20)))
    local began = Clock.monotonic_ns()
    local conn, why = connect("192.0.2.2", 443, Clock.ms(100))
    local took = Clock.monotonic_ns() - began
    assert(conn == nil and why == Poll.TIMEOUT, tostring(why))
    assert(took >= Clock.ms(100) and took < Clock.ms(400), took .. " ns")
    assert(table.concat(log, ",") == "held 192.0.2.1", table.concat(log, ","))
    local _, _ = holding:join()
  end)
end

local function test_requests_waiting_for_a_connector_take_it_in_the_order_they_came()
  local log: {string} = {}
  Poll.run(function()
    local connect = Relay.handed({ public_connectors = { fake("one", log, Clock.ms(30)) }, wait_ns = WAIT })
    local tasks: {Poll.Task} = {}
    for i = 1, 4 do
      tasks[i] = Poll.spawn(function()
        local _, _ = connect("192.0.2." .. i, 443, Clock.seconds(5))
      end)
      assert(Poll.delay(Clock.ms(5)))
    end
    for _, task in ipairs(tasks) do local _, _ = task:join() end
    assert(table.concat(log, ",") == "one 192.0.2.1,one 192.0.2.2,one 192.0.2.3,one 192.0.2.4",
      table.concat(log, ","))
  end)
end

local function test_the_table_pool_passes_over_a_connector_that_has_ended()
  local log: {string} = {}
  Poll.run(function()
    local connect = Relay.handed({ table_connectors = { fake("gone", log, 0, false, true), fake("live", log) },
      table = { { host = "127.0.0.1", port = 443 } }, wait_ns = WAIT })
    for _ = 1, 3 do
      local conn, why = connect("127.0.0.1", 443, WAIT)
      assert(conn == nil and why == "refused by live", tostring(why))
    end
    assert(table.concat(log, ",") == "live 1,live 1,live 1", table.concat(log, ","))
  end)
end

--- A connector that ends under a request is replaced by another only while
--- the request's own time lasts: one past it ends with that connect,
--- however many connectors are left to try.
local function test_a_request_whose_connector_ends_under_it_retries_only_within_its_time()
  Poll.run(function()
    local function dying(log: {string}): {Net.Connector}
      local pool: {Net.Connector} = {}
      for i = 1, 4 do pool[i] = fake("dies" .. i, log, Clock.ms(100), true) end
      return pool
    end
    local brief: {string} = {}
    local connect = Relay.handed({ public_connectors = dying(brief), wait_ns = WAIT })
    local began = Clock.monotonic_ns()
    local conn, why = connect("192.0.2.1", 443, Clock.ms(50))
    local took = Clock.monotonic_ns() - began
    assert(conn == nil and why == Poll.TIMEOUT, tostring(why))
    assert(#brief == 1 and took < Clock.ms(250), #brief .. " connects in " .. took .. " ns")
    local longer: {string} = {}
    connect = Relay.handed({ public_connectors = dying(longer), wait_ns = WAIT })
    conn, why = connect("192.0.2.1", 443, Clock.ms(150))
    assert(conn == nil and why == Poll.TIMEOUT, tostring(why))
    assert(#longer == 2, table.concat(longer, ","))
  end)
end

local function test_every_connector_of_a_kind_ended_is_told_to_lost_once()
  local log: {string} = {}
  local told: {string} = {}
  Poll.run(function()
    local connect = Relay.handed({
      public_connectors = { fake("a", log, 0, false, true), fake("b", log, 0, false, true) },
      wait_ns = WAIT, lost = function(why: string) told[#told + 1] = why end,
    })
    for _ = 1, 2 do
      local conn, why = connect("192.0.2.1", 443, WAIT)
      assert(conn == nil and why == "relay: every public connector has ended", tostring(why))
    end
  end)
  assert(#log == 0, table.concat(log, ","))
  assert(#told == 1 and told[1] == "relay: every public connector has ended", table.concat(told, ","))
  local ok, why = pcall(Relay.handed, { public_connectors = { fake("c", log) }, wait_ns = WAIT,
    lost = 1 as any as function(string) })
  assert(not ok and tostring(why):find("handed.lost must be a function", 1, true) ~= nil, tostring(why))
end

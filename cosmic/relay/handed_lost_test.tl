--- How [`Relay.handed`] asks the connector of a kind for the relay's
--- connections: every request at once, each with its own time, and the
--- first request that finds the connector ended tells `lost`. The
--- connectors are stand-ins that say what they were asked, hold a request
--- as long as a test says, and connect nothing.
local Clock = require("cosmic.clock")
local Poll = require("cosmic.poll")
local Relay = require("cosmic.relay.server")
local type Net = require("cosmic.net")

--- A stand-in for a connector, named `name`: it records each request in
--- `log` as "<name> <host> <timeout_ns>", holds it for `hold_ns`, and
--- then refuses it, or ends where it `dies`. One made `gone` has ended
--- already.
local function fake(name: string, log: {string}, hold_ns?: integer, dies?: boolean, gone?: boolean): Net.Connector
  local hold = hold_ns or 0
  local ended = gone or false
  local stand_in: any = {
    connect = function(_: any, address: Net.Address, opts: Net.ConnectOptions): any, string
      log[#log + 1] = name .. " " .. address.host .. " " .. opts.timeout_ns
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

--- Requests are asked of the connector as they come, none waiting for
--- another: a connect that hangs holds up none of the rest, each asked
--- with its own time.
local function test_requests_are_asked_of_the_connector_at_once_each_with_its_own_time()
  local log: {string} = {}
  Poll.run(function()
    local connect = Relay.handed({ connector = fake("one", log, Clock.ms(200)) })
    local tasks: {Poll.Task} = {}
    local began = Clock.monotonic_ns()
    for i = 1, 4 do
      tasks[i] = Poll.spawn(function()
        local conn, why = connect("192.0.2." .. i, 443, Clock.seconds(i))
        assert(conn == nil and why == "refused by one", tostring(why))
      end)
    end
    for _, task in ipairs(tasks) do assert(task:join()) end
    local took = Clock.monotonic_ns() - began
    assert(took < Clock.ms(600), "the requests were asked one after another: " .. took .. " ns")
    table.sort(log)
    assert(table.concat(log, ",") == "one 192.0.2.1 1000000000,one 192.0.2.2 2000000000," ..
        "one 192.0.2.3 3000000000,one 192.0.2.4 4000000000", table.concat(log, ","))
  end)
end

--- The relay asks the connector by the address itself, whatever the
--- table or the public lists make of it.
local function test_the_connector_is_asked_by_address()
  local log: {string} = {}
  Poll.run(function()
    local connect = Relay.handed({ connector = fake("one", log) })
    local conn, why = connect("127.0.0.1", 443, WAIT)
    assert(conn == nil and why == "refused by one", tostring(why))
    conn, why = connect("192.0.2.1", 443, WAIT)
    assert(conn == nil and why == "refused by one", tostring(why))
    assert(table.concat(log, ",") == "one 127.0.0.1 1000000000,one 192.0.2.1 1000000000", table.concat(log, ","))
  end)
end

--- A connector that ends under a request fails that request with why it
--- did, and is told to `lost` once; later requests fail at once.
local function test_a_connector_that_ends_under_a_request_is_told_to_lost_once()
  local log: {string} = {}
  local told: {string} = {}
  Poll.run(function()
    local connect = Relay.handed({ connector = fake("dies", log, 0, true),
      lost = function(why: string) told[#told + 1] = why end })
    local conn, why = connect("192.0.2.1", 443, WAIT)
    assert(conn == nil and why == "net: the connector has ended", tostring(why))
    for _ = 1, 2 do
      conn, why = connect("192.0.2.1", 443, WAIT)
      assert(conn == nil and why == "relay: the connector has ended", tostring(why))
    end
  end)
  assert(#log == 1, table.concat(log, ","))
  assert(#told == 1 and told[1] == "relay: the connector has ended", table.concat(told, ","))
end

local function test_a_connector_ended_already_is_told_to_lost_once_and_asked_nothing()
  local log: {string} = {}
  local told: {string} = {}
  Poll.run(function()
    local connect = Relay.handed({ connector = fake("gone", log, 0, false, true),
      lost = function(why: string)
        told[#told + 1] = why
      end })
    for _ = 1, 2 do
      local conn, why = connect("127.0.0.1", 443, WAIT)
      assert(conn == nil and why == "relay: the connector has ended", tostring(why))
    end
  end)
  assert(#log == 0, table.concat(log, ","))
  assert(#told == 1 and told[1] == "relay: the connector has ended", table.concat(told, ","))
  local ok, why = pcall(Relay.handed, { connector = fake("c", log), lost = 1 as any as function(string) })
  assert(not ok and tostring(why):find("handed.lost must be a function", 1, true) ~= nil, tostring(why))
  ok, why = pcall(Relay.handed, {} as Relay.Handed)
  assert(not ok and tostring(why):find("handed needs a connector", 1, true) ~= nil, tostring(why))
end

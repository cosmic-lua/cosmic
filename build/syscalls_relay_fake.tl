--- The fake of core/syscalls_relay_test.tl, a [`cosmic.fake`] main
--- started with a relay of listeners or without one. Its first argument
--- names the case and the rest are that case's words.

local Steps = require("cosmic.fake.steps")

local int = Steps.int

--- Each case, handed the words past its name.
local cases: {string:function({string}): integer} = {
  -- Says how many sockets it holds, then binds 127.0.0.1 at port
  -- `words[1]` and connects to it and to port `words[2]`, saying how
  -- each went.
  relayed = function(words: {string}): integer
    local first, second = int(words[1]!), int(words[2]!)
    return Steps.sockets_open() or Steps.bind_tcp("127.0.0.1", first) or
      Steps.connect_tcp("127.0.0.1", first) or Steps.connect_tcp("127.0.0.1", second) or 0
  end,
  sleep = function(words: {string}): integer return Steps.sleep(int(words[1]!)) or 0 end,
  append = function(words: {string}): integer return Steps.append(words[1]!, words[2]!) or 0 end,
  ["connect-tcp"] = function(words: {string}): integer
    return Steps.connect_tcp(words[1]!, int(words[2]!)) or 0
  end,
}

local function main(argv: {string}): integer
  return Steps.dispatch("syscalls relay fake", cases, argv)
end

return main

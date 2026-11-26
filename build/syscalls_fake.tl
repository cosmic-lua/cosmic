--- The fake of core/syscalls_test.tl, run as a [`cosmic.fake`] main. Its first argument
--- names the case and the rest are that case's words.

local Steps = require("cosmic.fake.steps")

local int = Steps.int

--- Each case, handed the words past its name.
local cases: {string:function({string}): integer} = {
  -- Ends with status `words[1]`, or 2 where it names none.
  exit = function(words: {string}): integer return math.tointeger(tonumber(words[1] or "")) or 2 end,
  append = function(words: {string}): integer return Steps.append(words[1]!, words[2]!) or 0 end,
  cat = function(words: {string}): integer return Steps.cat(words[1]!) or 0 end,
  sleep = function(words: {string}): integer return Steps.sleep(int(words[1]!)) or 0 end,
  -- Writes word pairs: each a descriptor and the line to write to it.
  ["write-fds"] = function(words: {string}): integer
    for i = 1, #words, 2 do
      local stopped = Steps.write_fd(int(words[i]!), words[i + 1]!)
      if stopped ~= nil then return stopped end
    end
    return 0
  end,
  -- Fails unless descriptors `words[1]` and `words[2]` are closed; then
  -- writes `handed` to `words[3]` and `kept` to `words[4]`.
  ["handed-only"] = function(words: {string}): integer
    return Steps.fd_closed(int(words[1]!)) or Steps.fd_closed(int(words[2]!)) or
      Steps.write_fd(int(words[3]!), "handed") or Steps.write_fd(int(words[4]!), "kept") or 0
  end,
}

local function main(argv: {string}): integer
  return Steps.dispatch("syscalls_fake", cases, argv)
end

return main

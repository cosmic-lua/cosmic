--- The fake of cosmic/fake/steps_test.tl, a [`cosmic.fake`] main whose
--- cases are the steps of cosmic/fake/steps.tl, one each, for the test
--- to check what each says and ends with.

local Steps = require("cosmic.fake.steps")

local int = Steps.int

--- Each case, handed the words past its name.
local cases: {string:function({string}): integer} = {
  -- Sends signal `words[1]` to pid `words[2]`, or to itself.
  signal = function(words: {string}): integer
    local pid = words[2]
    return Steps.signal(words[1]!, if pid ~= nil then int(pid) else nil end) or 0
  end,
  -- Runs the program and words that follow, as a shell runs one.
  run = function(argv: {string}): integer return Steps.run(argv) or 0 end,
  ["env-of"] = function(words: {string}): integer return Steps.env_of(words[1]!) or 0 end,
  ["write-fd"] = function(words: {string}): integer
    return Steps.write_fd(int(words[1]!), words[2]!) or 0
  end,
  ["status-field"] = function(words: {string}): integer
    return Steps.status_field(words[1]!) or 0
  end,
  connect = function(words: {string}): integer return Steps.connect(words[1]!) or 0 end,
  ["find-writable"] = function(words: {string}): integer
    return Steps.find_writable(words[1]!) or 0
  end,
  -- Fails quietly with `a || b`'s first step, then prints `taken up`.
  attempt = function(words: {string}): integer
    if Steps.attempt(function(): integer? return Steps.cat(words[1]!) end) then return 0 end
    return Steps.print("taken up") or 0
  end,
  ["sleep-forever"] = function(_: {string}): integer return Steps.sleep_forever() end,
}

local function main(argv: {string}): integer
  return Steps.dispatch("fake steps fake", cases, argv)
end

return main

--- The fake of cosmic/child_policy_test.tl, run as a [`cosmic.fake`]
--- main under each policy the test checks. Its first argument names
--- the case and the rest are that case's words; a path in place of a
--- case is a script it is the interpreter of (`#!` and its path), and it
--- prints that script's body past its first line.

local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Steps = require("build.fake_steps")

--- Each case, handed the words past its name.
local cases: {string:function({string}): integer} = {
  print = function(words: {string}): integer
    return Steps.print(table.concat(words, " ")) or 0
  end,
  cat = function(words: {string}): integer
    return Steps.cat(words[1]) or 0
  end,
  create = function(words: {string}): integer
    return Steps.create(words[1]!, words[2]!) or 0
  end,
  chmod = function(words: {string}): integer
    return Steps.chmod(words[1]!, words[2]!) or 0
  end,
  -- Each pair of words is a file and its text.
  write = function(words: {string}): integer
    for i = 1, #words, 2 do
      local stopped = Steps.write(words[i]!, words[i + 1]!)
      if stopped ~= nil then return stopped end
    end
    return 0
  end,
  env = function(names: {string}): integer
    for _, name in ipairs(names) do
      local stopped = Steps.env_of(name)
      if stopped ~= nil then return stopped end
    end
    return 0
  end,
  rlimits = function(names: {string}): integer
    for _, name in ipairs(names) do
      local stopped = Steps.rlimit(name)
      if stopped ~= nil then return stopped end
    end
    return 0
  end,
  ["fd-closed"] = function(words: {string}): integer
    return Steps.fd_closed(Steps.int(words[1] or "")) or 0
  end,
  -- Uses the directory the policy's `tmp` gives it: names it, writes
  -- its first word to a note there and reads it back, and, given
  -- `deep`, makes a file two directories down.
  ["use-tmp"] = function(words: {string}): integer
    local tmp = Env.get("TMPDIR") or ""
    local stopped = Steps.env_of("TMPDIR") or Steps.write(tmp .. "/note", words[1]!) or Steps.cat(tmp .. "/note")
    if stopped ~= nil or words[2] ~= "deep" then return stopped or 0 end
    return Steps.mkdirs(tmp .. "/sub/deeper") or Steps.create(tmp .. "/sub/deeper/f", "x") or 0
  end,
  -- Writes `$TMPDIR/f`, then sleeps until it is ended.
  ["write-tmp-and-wait"] = function(_: {string}): integer
    local stopped = Steps.write((Env.get("TMPDIR") or "") .. "/f", "x")
    if stopped ~= nil then return stopped end
    while true do assert(Clock.sleep(Clock.seconds(1))) end
  end,
}

local function main(argv: {string}): integer
  local name = argv[1] or ""
  local words: mut {string} = {}
  for i = 2, #argv do words[#words + 1] = argv[i] end
  if name:sub(1, 1) == "/" then
    local text, trouble = Fs.read(name)
    if text == nil then return Steps.fail(name, tostring(trouble)) end
    return Steps.put(1, text:match("^[^\n]*\n(.*)$") or "") or 0
  end
  local case = cases[name]
  if case == nil then return Steps.fail("child policy fake", "no case " .. name) end
  return case(words)
end

return main

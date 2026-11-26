--- The main of a reply fake ([`Fake.reply`]): it answers its first
--- argument with what the table [`Fake.place`] wrote beside the copy
--- names for it, and nothing else.

local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Shape = require("cosmic.shape")

--- One answer: what goes to stdout and stderr, as they are, and the
--- exit status. The same fields as [`Fake.Reply`], which a reply is
--- encoded from: a field added there is added here too.
local record Reply
  stdout?: string
  stderr?: string
  code?: integer
end

local REPLIES <const> = Shape.map(Shape.record_of("Reply"):strict().spec)

--- Says `why` on stderr and ends with status 127, as a shell does for a
--- command it cannot run.
local function refused(why: string): integer
  local _, _ = Fs.put(2, "fake: " .. why .. "\n")
  return 127
end

--- Answers `argv[1]` (the key "" with no arguments, then "*" for any
--- key the table lacks) from the table beside this copy.
--- @param argv {string} The command line past the program's own name
--- @return integer The exit status
local function main(argv: {string}): integer
  local self, _ = Proc.executable()
  if self == nil then return refused("this program cannot find its own path") end
  local text, trouble = Fs.read(self .. ".do")
  if text == nil then return refused("no replies beside " .. self .. ": " .. tostring(trouble)) end
  local replies, shape_trouble = Shape.decode_into(text, REPLIES)
  if replies == nil then
    return refused("the replies are no table of replies: " .. tostring(shape_trouble))
  end
  local key = if #argv == 0 then "" else argv[1] end
  local reply = replies[key] or replies["*"]
  if reply == nil then return refused("no reply for " .. string.format("%q", key)) end
  if reply.stdout ~= nil then local _, _ = Fs.put(1, reply.stdout) end
  if reply.stderr ~= nil then local _, _ = Fs.put(2, reply.stderr) end
  local code = reply.code or 0
  if code < 0 or code > 255 then
    return refused("the reply's code " .. tostring(code) .. " is no exit status (0 to 255)")
  end
  return code
end

return main

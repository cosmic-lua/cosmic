--- A failure as a value of its own: what a call answers in place of a
--- value, `(T) | (nil, Failure)`, where a `string` would carry only the
--- words. A failure keeps the words (`message`), the path it concerns
--- (`path`) and the errno that says why (`errno`) apart, so a caller tests
--- the cause (`why.errno == sys.ENOENT`) and does not match the words.
---
---     local function load(path: string): (string) | (nil, Failure)
---       local fd, _, errno = sys.open(path, sys.O_RDONLY)
---       if fd == nil then
---         return nil, Failure.system(errno, path)
---       end
---       ...
---     end
---
--- `tostring` gives the text a person reads, `path: message`, and so do
--- `print`, `error` and `assert` with a failure nothing catches. `..`
--- takes strings alone: write `tostring(why)` where text is wanted.

local sys = require("cosmic.sys")

--- What went wrong, where, and why, answered by [`Failure.new`] or
--- [`Failure.system`].
local class Failure
  --- What went wrong, in words: `No such file or directory`.
  message: string
  --- The path the failure concerns, nil when it concerns none.
  path?: string
  --- The errno that says why, as [`cosmic.sys`] names them
  --- ([`sys.ENOENT`]), or 0 where no system call failed.
  errno: integer

  --- `path: message`, or the message alone where the path is nil or empty.
  function __tostring(self): string
    local path = self.path
    if path == nil or path == "" then
      return self.message
    end
    return path .. ": " .. self.message
  end
end

--- A failure of `message`, about `path` when one is given, that no
--- system call answered: its errno is 0.
function Failure.new(message: string, path?: string): Failure
  return { message = message, path = path, errno = 0 }
end

--- The failure a system call answered with `errno`, about `path` when one
--- is given: its message is the errno's, the same words on every OS
--- ([`sys.errno_message`]).
function Failure.system(errno: integer, path?: string): Failure
  return { message = sys.errno_message(errno), path = path, errno = errno }
end

return Failure

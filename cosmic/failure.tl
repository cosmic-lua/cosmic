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

--- What went wrong, where, and why, answered by [`Failure.new`],
--- [`Failure.at`], [`Failure.system`], [`Failure.coded`],
--- [`Failure.timeout`] or [`Failure.cancelled`].
local class Failure
  --- What kind of failure it is, for a caller that acts on the cause
  --- rather than the words: `if why.kind == "timeout" then retry() end`.
  --- Each constructor gives one kind.
  enum Kind
    --- Nothing more is known than the words ([`Failure.new`]).
    "other"
    --- A system call failed; `errno` says why ([`Failure.system`]).
    "system"
    --- A text was refused at a place; `line` says where ([`Failure.at`]).
    "parse"
    --- A library answered its own code; `code` holds it
    --- ([`Failure.coded`]).
    "library"
    --- A wait ran past its time limit ([`Failure.timeout`]).
    "timeout"
    --- A wait was stopped from outside before it ended: a cancelled task
    --- of [`Poll.run`], or a signal the caller's [`Signal.guard`] holds
    --- ([`Failure.cancelled`]).
    "cancelled"
  end

  --- What kind of failure it is.
  kind: Kind
  --- What went wrong, in words: `No such file or directory`.
  message: string
  --- The path the failure concerns, nil when it concerns none.
  path?: string
  --- The errno that says why, as [`cosmic.sys`] names them
  --- ([`sys.ENOENT`]), or 0 where no system call failed.
  errno: integer
  --- The line of the text the failure is at, from 1, nil when it is at
  --- no place in a text: a decoder's refusal names one.
  line?: integer
  --- The column of that line, a byte from 1, nil when only the line is
  --- known.
  column?: integer
  --- The library's own code for the failure, as the library names it
  --- ([`Sqlite.BUSY`]), nil where no library answered one.
  code?: integer
  --- The detail the library gives beside `code` ([`cosmic.sqlite`]'s
  --- extended result code), nil where it gives none.
  extended_code?: integer

  --- The text a person reads. With a path: `path: message`, or
  --- `path:line:column: message` where the failure is at a place, as a
  --- compiler says it. With no path: the message, then ` at line N,
  --- column M` where it is at a place.
  function __tostring(self): string
    local path, line, column = self.path or "", self.line, self.column
    local has_path = path ~= ""
    if line == nil then
      if has_path then return path .. ": " .. self.message end
      return self.message
    end
    if has_path then
      local place = path .. ":" .. tostring(line)
      if column ~= nil then place = place .. ":" .. tostring(column) end
      return place .. ": " .. self.message
    end
    local place = "line " .. tostring(line)
    if column ~= nil then place = place .. ", column " .. tostring(column) end
    return self.message .. " at " .. place
  end
end

--- A failure of `message`, about `path` when one is given, that no
--- system call answered: its errno is 0.
function Failure.new(message: string, path?: string): Failure
  return { kind = "other", message = message, path = path, errno = 0, line = nil, column = nil, code = nil, extended_code = nil }
end

--- A failure of `message` at `line` (and `column`, a byte from 1, when
--- given) of a text, about `path` when one is given: what a decoder
--- answers for what it refuses. Its errno is 0.
function Failure.at(message: string, line: integer, column?: integer, path?: string): Failure
  return { kind = "parse", message = message, path = path, errno = 0, line = line, column = column, code = nil, extended_code = nil }
end

--- The failure a system call answered with `errno`, about `path` when one
--- is given: its message is the errno's, the same words on every OS
--- ([`sys.errno_message`]).
function Failure.system(errno: integer, path?: string): Failure
  return { kind = "system", message = sys.errno_message(errno), path = path, errno = errno, line = nil, column = nil, code = nil,
    extended_code = nil }
end

--- A failure of `message` that a library answered with its own `code`,
--- and `extended_code` where it gives one: what [`cosmic.sqlite`]
--- answers. Its kind is "cancelled" when `cancelled`, as a busy wait a
--- caught signal stopped is, else "library". Its errno is 0.
function Failure.coded(message: string, code: integer, extended_code?: integer, cancelled?: boolean): Failure
  return { kind = if cancelled == true then "cancelled" else "library" end, message = message, path = nil, errno = 0,
    line = nil, column = nil, code = code, extended_code = extended_code }
end

--- A wait that ran past its time limit, `message` saying which wait
--- ("timed out" when nil), about `path` when one is given. Its errno is 0.
---
---     return nil, Failure.timeout("connect to " .. host)
function Failure.timeout(message?: string, path?: string): Failure
  return { kind = "timeout", message = message or "timed out", path = path, errno = 0, line = nil, column = nil,
    code = nil, extended_code = nil }
end

--- A wait stopped from outside before it ended, `message` saying which
--- ("cancelled" when nil), about `path` when one is given. Its errno is 0.
function Failure.cancelled(message?: string, path?: string): Failure
  return { kind = "cancelled", message = message or "cancelled", path = path, errno = 0, line = nil, column = nil,
    code = nil, extended_code = nil }
end

return Failure

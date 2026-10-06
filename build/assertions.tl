--- The test worker's count of calls to `assert`, kept by a counting `assert`
--- of the core's own (core/assertions.c) rather than a Lua wrapper: a
--- wrapper's `return assert(...)` is a tail call, which loses the frame
--- whose position a failure reports.

local type Raw = require("cosmic.internal.assertions")

--- The counting `assert`, handed to this module only when it loads from
--- the binary's own tree (core/store.c's `raw_modules`).
local extra: any = select(2, ...)
local raw: Raw
if type(extra) == "table" then
  raw = extra as Raw
else
  raw = require("cosmic.internal.assertions")
end

local record assertions
  --- Replaces the global `assert` with the counting one, for the life of
  --- the process. Install it before a test's module loads, so a module that
  --- captures `local assert = assert` as it loads holds it.
  install: function()

  --- Calls to `assert` since [`reset`].
  count: function(): integer

  --- Starts the count again from 0.
  reset: function()
end

local installed = false

function assertions.install()
  if installed then return end
  installed = true
  rawset(_G, "assert", raw.assert)
end

assertions.count = raw.count
assertions.reset = raw.reset

return assertions

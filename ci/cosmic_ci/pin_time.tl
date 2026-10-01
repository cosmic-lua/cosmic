--- The spans a child's timeout takes, for the driver, which runs on the
--- pinned release and is also checked and run against the tree: the
--- release counts a timeout in milliseconds (`Child.Options.timeout_ms`,
--- `h:wait(ms)`) and has no [`Time.ms`], the tree in nanoseconds
--- (`timeout_ns`, `h:wait(ns)`).

local Child = require("cosmic.child")
local Time = require("cosmic.time")

local record PinTime
end

-- Read through `any`: the release's Time has no `ms` to name.
local tree_ms = (Time as any as {string:function(integer): integer}).ms

--- `ms` milliseconds as the integer a wait takes: the count itself on
--- the release, nanoseconds on the tree.
function PinTime.wait(ms: integer): integer
  -- TODO: once ci/cosmic-driver.pin names a release whose waits take
  -- nanoseconds and whose cosmic.time has `ms`, call Time.ms(ms) at each
  -- caller and drop this module.
  if tree_ms == nil then return ms end
  return tree_ms(ms)
end

--- `options` with a timeout of `ms` milliseconds when it is given (nil
--- leaves none): set under the release's field name and the tree's,
--- each of which ignores the other's.
function PinTime.options(options: Child.Options, ms?: integer): Child.Options
  if ms ~= nil then
    local fields = options as any as {string:integer}
    fields.timeout_ms = ms
    fields.timeout_ns = PinTime.wait(ms)
  end
  return options
end

return PinTime

--- Code that runs when a block ends, however it ends: held in a `<close>`
--- local, a [`Defer`] calls its function as the block returns, breaks or
--- raises, and as a task killed inside the block unwinds, where no code
--- after the block runs.
---
---     local function spool(req: Request): string
---       local settled = false
---       local _ <close> = Defer.new(function()
---         if not settled then discard(req) end
---       end)
---       ...
---       settled = true
---     end
---
--- It is the typed form of a table whose metatable has a [`__close`] that
--- closes over locals: a class method cannot reach them, and a [`Defer`]
--- carries them in its function.

--- A function to run when the `<close>` local that holds it goes out of
--- scope, made by [`Defer.new`].
local class Defer
  --- What runs at the end of the block.
  run: function()

  --- Runs the function: each time the [`Defer`] is closed, so one held in a field guards each block that closes it.
  function __close(self)
    self.run()
  end
end

--- A [`Defer`] that runs `run` when it is closed.
function Defer.new(run: function()): Defer
  return { run = run }
end

return Defer

--- The instruction budget provided by core/coverage.c, handed only to
--- `build.fuzz` when it loads from the binary's own tree.

local record budget
  --- Arms a budget of `count` VM instructions on the calling coroutine,
  --- and on every coroutine it makes while armed: spending them raises
  --- exactly "instruction budget exceeded". With no count, or 0,
  --- disarms. Coverage collection is unaffected: both share the one
  --- hook. A hang inside a single C call is out of its reach.
  budget: function(count?: integer)
end

return budget

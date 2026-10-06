--- A counting `assert`, provided by core/assertions.c and handed only to
--- [`build.test_worker`] when it loads from the binary's own tree.

local record assertions
  --- Lua's own `assert` -- the same results, the same messages, the same
  --- error positions, a failure in tail position included -- that also
  --- counts each call, whether it passes or fails.
  assert: function(...: any): any...

  --- How many calls `assert` has had since the last [`reset`], or since
  --- the state began.
  count: function(): integer

  --- Sets [`count`] to 0.
  reset: function()
end

return assertions

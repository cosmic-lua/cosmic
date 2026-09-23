--- Test instruments, as the core provides them (core/testing.h). Only
--- the checked core has the functions; every core has `configuration`,
--- its configuration's name, "sanitized" for the checked one.

local record testing
  --- The running core's configuration: "sanitized" for the checked one.
  configuration: string

  --- Grants the next `after` growing allocations and refuses every one
  --- past them, until `allow_allocations`: a refused one raises "not
  --- enough memory" wherever Lua asked for it.
  fail_allocations: function(after: integer)

  --- Grants every allocation again, and answers how many were refused
  --- since `fail_allocations`.
  allow_allocations: function(): integer

  --- How many statements are prepared and not yet finalized, across
  --- every database the store searches.
  open_statements: function(): integer
end

return testing

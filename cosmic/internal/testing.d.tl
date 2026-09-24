--- Test instruments, as the core provides them (core/testing.h). Every
--- core has every member, but only the checked core's functions
--- instrument: in any other, each raises "only the checked core has
--- test instruments". `configuration` says which core is running,
--- "sanitized" for the checked one.

local record testing
  --- The running core's configuration: "sanitized" for the checked one.
  configuration: string

  --- Grants the next `after` growing allocations and refuses every one
  --- past them, until `allow_allocations`: a refused one raises "not
  --- enough memory" wherever Lua asked for it. The core's own C heap
  --- (core/memory.h) draws from the same count, and a refusal there is
  --- the NULL its caller must handle.
  fail_allocations: function(after: integer)

  --- Grants every allocation again, and answers how many were refused
  --- since `fail_allocations`, Lua's and the C heap's together.
  allow_allocations: function(): integer

  --- How many statements are prepared and not yet finalized, across
  --- every database the store searches.
  open_statements: function(): integer

  --- The bytes, then the blocks, live on the core's own C heap: what
  --- its C allocated through core/memory.h and has not yet freed. A
  --- library's own allocations (curl's, liblzma's, bzlib's) are not
  --- among them.
  c_heap: function(): integer, integer

  --- Arms the fault point `point` (core/fault.h) to fail once, after
  --- letting `skip` calls through it (default 0); with no `point`,
  --- disarms. Either way, answers whether the point armed before was
  --- left unfired. The points are "curl_multi_init", "curl_easy_init",
  --- "curl_multi_add_handle", "curl_multi_poll", "curl_multi_perform",
  --- "curl_slist_append" and "curl_easy_setopt(CURLOPT_<NAME>)" for
  --- each option core/http.c sets; each makes its call report a failure
  --- of curl's own shape instead of being made.
  fail_at: function(point?: string, skip?: integer): boolean

  --- How many HTTP transfers hold curl state: made by an open, and not
  --- yet released by a close, a failure or the collector.
  live_transfers: function(): integer
end

return testing

unix.clock_gettime's new raise-on-invalid-clock (#277) validates a
TRUNCATED id: third_party/lua/lunix.c:1626 narrows luaL_optinteger's
lua_Integer to int, so unix.clock_gettime(4294967296) truncates to 0
and silently returns CLOCK_REALTIME instead of raising, and a
genuinely-invalid huge id raises with the truncated %d in its message.
The truncation predates the commit, but the commit's promise ("raises
on an invalid clock id") makes it observable as a false accept. Fix:
range-check the lua_Integer before narrowing (raise on anything
outside int, or outside the known clock set). Same-commit
definitions.lua and conformance updates were otherwise done right.

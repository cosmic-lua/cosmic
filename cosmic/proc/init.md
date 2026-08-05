# proc

 Current process management.
 Identity, session/group control, exec, and resource usage.

 The global `arg` table layout when running a script: arg[-1] is the
 cosmic interpreter binary's path (re-invoke it to spawn a child); arg[0]
 is the script path as the runtime sees it (/zip/main.lua when dispatched
 by the embedded entry point — NOT the interpreter path); arg[1..] are
 user arguments. `arg` is typed {string}: negative indices need
 `rawget(arg, -1) as string` to pass the strict type checker.

## Types

### ProcModule

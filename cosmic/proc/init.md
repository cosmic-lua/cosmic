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

### WaitResult

 Waits for a child process to change state.
 A raw passthrough: EINTR surfaces here, unlike child.Handle:wait.
 What wait(2) reaped. A record rather than (pid, status, rusage,
 err) returns: the old shape put the error in slot 4, unreachable
 from `local pid, err = ...` and from check.must.

```teal
local record WaitResult
  pid: integer
  --  Raw status word; decode with WIFEXITED/WEXITSTATUS/WIFSIGNALED/WTERMSIG.
  status: integer
  rusage: Rusage
end
```

### ProcModule

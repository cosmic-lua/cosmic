# run

 Fork / unshare / exec orchestration for cosmic.quicksand.Box:run.

 Pulled in lazily by box/init.tl so that hosts using only new() /
 merge() / close() don't load the entire sandbox plumbing on require.

 Flow:
   1. parent opens its own netns fd (if a net policy is requested) —
      the supervisor child inherits it and hands it to the proxy as
      upstream_ns_fd so the proxy can dial out from the outer ns.
   2. parent fork()s the supervisor and wait()s for it.
   3. supervisor unshares USER | NET | NS (+ UTS if hostname), writes
      uid_map / gid_map, brings up lo, optionally calls
      sethostname(2).
   4. supervisor starts the allowlist proxy sidecar if net.allow is
      set, and prepends HTTP(S)_PROXY into the workload env when
      net.proxy_env is not explicitly false.
   5. supervisor forks the workload. Workload does chdir, the
      sandbox fs policy (landlock), no_new_privs, drop_privs,
      pledge, then execvpe(argv, env).
   6. supervisor runs become_init(workload_pid, {sidecars={proxy_pid}})
      and os.exit()s with the returned code. parent maps wait status
      to an exit code and returns it from run().

 Setup failures are reported over a CLOEXEC error pipe (the same
 pattern proxy.start uses for its bound port): the supervisor and the
 pre-exec workload write the failing step there before exiting, and a
 successful execve closes the workload's end automatically. run()
 drains the pipe after wait() — a non-empty pipe always means setup
 failed before the workload ran, so run() returns nil + the message
 instead of masquerading the failure as a workload exit code.

## Types

### CapsModule

```teal
local record CapsModule
  capabilities: function(): types.Capabilities
end
```

### BoxRunModule

```teal
local record BoxRunModule
  run: function(opts: BoxOpts, argv: {string}): integer | nil, string
end
```

## Functions

### run

```teal
function run(opts: BoxOpts, argv: {string}): integer | nil, string
```

 Fork+orchestrate a Box policy around argv. Returns an integer exit
 code on success, or nil + string when setup failed — either before
 the fork (e.g. couldn't open the parent netns fd) or inside the
 supervisor / pre-exec workload (unshare, uid_map, landlock, pledge,
 execvpe, ...), which report over the error pipe. An integer return
 is therefore always the workload's own exit status.

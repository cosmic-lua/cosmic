# fs

 Pure translator: Box `fs` policy → `cosmic.landlock.RestrictOpts`.

 Keeps the fs → landlock mapping in one place so the Box orchestrator
 stays clear of access-mask juggling. No syscalls; the result is fed
 into `landlock.restrict{}` in the boxed child.

 Policy shape (input):
   fs = {
     ro   = { ... },  -- read + exec on listed paths
     rw   = { ... },  -- read + write on listed paths
     exec = { ... },  -- read + exec on listed paths (emphasis only)
     deny = { ... },  -- informational; landlock is allowlist-default,
                      -- so any path not listed in ro/rw/exec is denied
                      -- already. Recorded verbatim for diagnostics.
   }

 A nil or empty policy produces an empty `rules` list, which — when
 fed to landlock.restrict — denies everything. Callers that want
 "no sandboxing" should skip landlock entirely rather than calling
 plan_landlock with nil.

## Types

### FsOpts

```teal
local record FsOpts
  ro: {string}
  rw: {string}
  exec: {string}
  deny: {string}
end
```

### Rule

```teal
local record Rule
  path: string
  access: integer
end
```

### RestrictOpts

```teal
local record RestrictOpts
  handled: integer
  rules: {Rule}
  no_new_privs: boolean
end
```

### BoxFsModule

```teal
local record BoxFsModule
  plan_landlock: function(fs: FsOpts): RestrictOpts
end
```

## Functions

### plan_landlock

```teal
function plan_landlock(fs: FsOpts): RestrictOpts
```

 Translate an fs policy to a RestrictOpts suitable for
 `cosmic.landlock.restrict`. Pure: no syscalls, no side effects.
 `no_new_privs` is set to true so landlock applies even without
 CAP_SYS_ADMIN. Callers that want to orchestrate no_new_privs
 themselves can overwrite it on the returned table.

**Parameters:**

- `fs` (FsOpts) - nil treated as empty (deny-all)

**Returns:**

- RestrictOpts

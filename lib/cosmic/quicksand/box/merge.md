# merge

 Pure table-merge helpers for cosmic.quicksand.Box.

 Keeps policy composition as plain data: mixins, overlays, and
 per-environment overrides all go through `merge(...)` and yield a
 new policy table. No syscalls, no side effects.

 Field classes:
   scalar   hostname, cwd, uid, gid, pledge, log_level, ...
   list     fs.ro, fs.rw, fs.exec, fs.deny, env.keep
   map      net.allow, env.set

 Merge rules:
   scalar  later wins; nil is a no-op.
   list    concat in order, then de-duplicate by value (first seen wins).
   map     shallow key-by-key merge, later wins per key.

 The schema below names every mergeable field and its class. Unknown
 keys are treated as scalars, which is the right default for
 forward-compatible additions (e.g. new string/bool fields).

## Types

### Schema

 Pure table-merge helpers for cosmic.quicksand.Box.
 Keeps policy composition as plain data: mixins, overlays, and
 per-environment overrides all go through `merge(...)` and yield a
 new policy table. No syscalls, no side effects.
 Field classes:
   scalar   hostname, cwd, uid, gid, pledge, log_level, ...
   list     fs.ro, fs.rw, fs.exec, fs.deny, env.keep
   map      net.allow, env.set
 Merge rules:
   scalar  later wins; nil is a no-op.
   list    concat in order, then de-duplicate by value (first seen wins).
   map     shallow key-by-key merge, later wins per key.
 The schema below names every mergeable field and its class. Unknown
 keys are treated as scalars, which is the right default for
 forward-compatible additions (e.g. new string/bool fields).

```teal
local record Schema
  lists: {string: boolean}
  maps: {string: boolean}
end
```

### BoxMergeModule

```teal
local record BoxMergeModule
  merge: function(...: {string: any}): {string: any}
end
```

## Functions

### merge

```teal
function merge(...: {string: any}): {string: any}
```

 Merge any number of policy tables left-to-right.
 The last argument wins scalar conflicts; list fields concat and
 de-duplicate; map fields merge per key. Returns a fresh table.

**Parameters:**

- `...` ({string:) - any} policy tables; nil entries are skipped

**Returns:**

- {string: - any} merged policy

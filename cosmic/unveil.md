# unveil

 Restrict filesystem visibility to an allowlisted set of paths.

 Once a process unveils any path, the entire filesystem is hidden
 except for the paths that have been unveiled. Paths are revealed one
 at a time with `allow(path, permissions)`; when done, `commit()`
 seals the policy and further unveil calls become no-ops or errors.

 The API is fail-closed: unveil is enforceable on OpenBSD (natively)
 and on Linux kernels with Landlock (the libc's backing mechanism).
 Anywhere else `allow`/`commit` return `false, "unveil unsupported on
 this host"` instead of reporting a sandbox that does not exist.
 Callers that want fail-open behavior opt in explicitly with
 `best_effort = true`, or branch on `available()` themselves.

 Unveil pairs naturally with `cosmic.pledge`: pledge narrows which
 system calls are allowed; unveil narrows which files those calls can
 touch.

 Permissions (strings, combinable):

   r  read-only path operations (matches pledge "rpath")
   w  write operations           (matches pledge "wpath")
   x  execute operations         (matches pledge "exec" / "execnative")
   c  create and remove paths    (matches pledge "cpath")

## Types

### Options

 Options for `allow` / `commit`. `best_effort` turns an unsupported
 host into a successful no-op instead of an error — the explicit
 fail-open escape hatch.

```teal
local record Options
  best_effort: boolean
  --  The caller asserts the policy still permits the coverage dump,
  --  because it unveiled that directory itself. See the same field on
  --  `cosmic.landlock.RestrictOptions`.
  keep_coverage: boolean
end
```

### UnveilModule

```teal
local record UnveilModule
  allow: function(path: string, permissions: Perm, opts?: Options): boolean, string
  commit: function(opts?: Options): boolean, string
  available: function(): boolean
  apply: function(path: string, permissions: string): boolean, string
end
```

## Functions

### available

```teal
function available(): boolean
```

 True when unveil is actually enforceable on this host: OpenBSD, or
 Linux with Landlock ABI >= 1. Derived, never probed with unveil
 itself — `unix.unveil(nil, nil)` is the commit call, so probing it
 would lock this very process into a deny-all sandbox. The libc backs
 unveil with Landlock on Linux, so it enforces exactly when Landlock
 does; everywhere else the raw call deliberately fails open, which is
 precisely what this wrapper refuses to pass through. Cached.

**Returns:**

- boolean - True when unveil can be enforced

### allow

```teal
function allow(path: string, permissions: Perm, opts?: Options): boolean, string
```

 Unveil a path with the given permission set.
 Fail-closed: on a host where unveil cannot be enforced this returns
 `false, "unveil unsupported on this host"` rather than succeeding
 without a sandbox; pass `best_effort = true` to treat that case as a
 successful no-op.

**Parameters:**

- `path` (string) - Path to unveil
- `permissions` (string) - Permission string like "r", "rw", "rwxc"

**Returns:**

- boolean - True on success
- string? - Error message on failure

### commit

```teal
function commit(opts?: Options): boolean, string
```

 Commit the unveil policy: the allowlist becomes final and further
 unveil calls are rejected. Fail-closed like `allow`.

**Returns:**

- boolean - True on success
- string? - Error message on failure

### apply

```teal
function apply(path: string, permissions: string): boolean, string
```

 DEPRECATED compatibility shim: delegates to `allow(path,
 permissions)`, or to `commit()` when both arguments are nil. New
 code should call allow/commit directly.

**Parameters:**

- `path` (string|nil) - Path to unveil (nil to commit)
- `permissions` (string|nil) - Permission string (nil to commit)

**Returns:**

- boolean - True on success
- string? - Error message on failure

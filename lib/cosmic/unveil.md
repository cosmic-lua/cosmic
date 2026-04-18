# unveil

 Restrict filesystem visibility to an allowlisted set of paths.

 Once a process calls unveil with any path, the entire filesystem is
 hidden except for the paths that have been unveiled. Paths are then
 revealed one at a time with their allowed permission set. When done,
 call `apply(nil, nil)` to commit the policy; further unveil calls
 become no-ops or errors.

 Unveil pairs naturally with `cosmic.pledge`: pledge narrows which
 system calls are allowed; unveil narrows which files those calls can
 touch.

 Permissions (strings, combinable):

   r  read-only path operations (matches pledge "rpath")
   w  write operations           (matches pledge "wpath")
   x  execute operations         (matches pledge "exec" / "execnative")
   c  create and remove paths    (matches pledge "cpath")

## Types

### UnveilModule

```teal
local record UnveilModule
  apply: function(path: string, permissions: string): boolean, string
end
```

## Functions

### apply

```teal
function apply(path: string, permissions: string): boolean, string
```

 Unveil a path, or commit the policy.
 Call with a path and permission string to expose the path. Call with
 (nil, nil) to commit the policy and prevent further unveil calls.

**Parameters:**

- `path` (string|nil) - Path to unveil (nil to commit)
- `permissions` (string|nil) - Permission string like "r", "rw", "rwxc" (nil to commit)

**Returns:**

- boolean - True on success
- string? - Error message on failure

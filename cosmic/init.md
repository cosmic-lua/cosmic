# cosmic

 cosmic: a batteries-included Lua/Teal distribution built on
 Cosmopolitan Libc. Main entry point helper for cosmic programs.

## Types

### Env

 Environment with standard output and error streams.

```teal
local record Env
  stdout: FILE
  stderr: FILE
end
```

### VersionInfo

 Version information embedded at build time.

```teal
local record VersionInfo
  cosmic: string
  cosmos: string
end
```

### cosmic

```teal
local record cosmic
  _VERSION: string
  _DESCRIPTION: string
  main: function(fn: function(args: {string}, env: Env): number, string)
end
```

## Functions

### main

```teal
function main(fn: function(args: {string}, env: Env): number, string)
```

 Run a main function and exit with its return code.
 The function receives the command-line arguments and an environment
 with stdout/stderr, and returns an exit code plus an optional error
 message, which is written to stderr.
 It does NOT check `is_main` itself, and cannot: `cosmo.is_main()`
 answers for the chunk that CALLS it, and this chunk is always
 `cosmic/init.tl`, never your script. A guard here is therefore
 false every time, and every caller silently does nothing — a
 failure a test that asserts the function exists cannot see. A file
 that is both a module and a script asks in its OWN chunk, where the
 answer is about that file:
     if proc.is_main() then
       cosmic.main(function(args: {string}): number, string … end)
     end

**Parameters:**

- `fn` (function) - The main function to execute

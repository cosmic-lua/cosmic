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

# sys

 System information utilities.
 Wraps cosmo system functions for OS and architecture queries.

## Types

### SysModule

```teal
local record SysModule
  host_os: function(): string
  host_isa: function(): string
  platform: function(): string
end
```

## Functions

### host_os

```teal
function host_os(): string
```

 Get the operating system name.
 Returns lowercase strings: "linux", "macos", "windows", "freebsd", "openbsd", "netbsd".

**Returns:**

- string - The operating system name

### host_isa

```teal
function host_isa(): string
```

 Get the CPU architecture (instruction set architecture).
 Returns lowercase strings: "x86_64", "aarch64".

**Returns:**

- string - The CPU architecture

### platform

```teal
function platform(): string
```

 Get the platform identifier combining OS and architecture.
 Returns a string in the format "os-arch" (e.g., "linux-x86_64", "macos-aarch64").

**Returns:**

- string - The platform identifier

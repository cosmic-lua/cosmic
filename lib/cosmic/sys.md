# sys

 System information utilities.
 Wraps cosmo system functions for OS and architecture queries.

## Types

### Uname

 Operating system and hardware identification returned by `uname`.

```teal
local record Uname
  --  Operating system name (e.g. "Linux").
  sysname: string
  --  Network node hostname.
  nodename: string
  --  Operating system release.
  release: string
  --  Operating system version.
  version: string
  --  Hardware identifier (e.g. "x86_64").
  machine: string
  --  NIS or YP domain name.
  domainname: string
end
```

### SysModule

```teal
local record SysModule
  SC_ARG_MAX: number
  SC_CHILD_MAX: number
  SC_CLK_TCK: number
  SC_OPEN_MAX: number
  SC_PAGESIZE: number
  SC_NPROCESSORS_CONF: number
  SC_NPROCESSORS_ONLN: number
  host_os: function(): string
  host_isa: function(): string
  platform: function(): string
  sysconf: function(name: number): number, string
  nproc: function(): number, string
  nproc_configured: function(): number, string
  page_size: function(): number, string
  uname: function(): Uname, string
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

### sysconf

```teal
function sysconf(name: number): number, string
```

 Query a runtime system configuration value.
 `name` is one of the `unix.SC_*` constants (e.g. `unix.SC_PAGESIZE`,
 `unix.SC_NPROCESSORS_ONLN`). Returns nil plus an error message on failure.

**Parameters:**

- `name` (number) - One of the unix.SC_* constants

**Returns:**

- number - The configuration value
- string? - Error message on failure

### nproc

```teal
function nproc(): number, string
```

 Number of processors currently online (available to run threads).

**Returns:**

- number - The online processor count
- string? - Error message on failure

### nproc_configured

```teal
function nproc_configured(): number, string
```

 Number of processors configured in the system.
 May exceed `nproc()` when some processors are offline.

**Returns:**

- number - The configured processor count
- string? - Error message on failure

### page_size

```teal
function page_size(): number, string
```

 Memory page size in bytes.

**Returns:**

- number - The page size in bytes
- string? - Error message on failure

### uname

```teal
function uname(): Uname, string
```

 Get operating system and hardware identification.
 Returns a `Uname` record with `sysname`, `nodename`, `release`, `version`,
 `machine`, and `domainname` fields. Returns nil plus an error message on failure.

**Returns:**

- Uname - The system identification record
- string? - Error message on failure

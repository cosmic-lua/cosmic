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
  host_os: function(): HostOs
  host_isa: function(): string
  platform: function(): string
  nproc: function(): integer | nil, string
  page_size: function(): integer | nil, string
  uname: function(): Uname | nil, string
end
```

## Functions

### host_os

```teal
function host_os(): HostOs
```

 Get the operating system name.
 Returns one of: "linux", "macos", "windows", "freebsd", "openbsd",
 "netbsd", "metal" — or "unknown" if the C layer recognizes none
 (GetHostOs returns nil then; unreachable on shipped fat-binary
 targets, but the type admits it honestly).

**Returns:**

- HostOs - The operating system name

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

### nproc

```teal
function nproc(): integer | nil, string
```

 Number of processors currently online (available to run threads).

**Returns:**

- integer - | nil The online processor count
- string? - Error message on failure

### page_size

```teal
function page_size(): integer | nil, string
```

 Memory page size in bytes.

**Returns:**

- integer - | nil The page size in bytes
- string? - Error message on failure

### uname

```teal
function uname(): Uname | nil, string
```

 Get operating system and hardware identification.
 Returns a `Uname` record with `sysname`, `nodename`, `release`, `version`,
 `machine`, and `domainname` fields. Returns nil plus an error message on failure.

**Returns:**

- Uname - | nil The system identification record
- string? - Error message on failure

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
  host_os: function(): HostOs
  normalize_host_os: function(raw: string): HostOs
  host_isa: function(): string
  platform: function(): string
  sysconf: function(name: number): number | nil, string
  nproc: function(): number | nil, string
  nproc_configured: function(): number | nil, string
  page_size: function(): number | nil, string
  uname: function(): Uname | nil, string
end
```

## Functions

### normalize_host_os

```teal
function normalize_host_os(raw: string): HostOs
```

 Normalize a raw cosmopolitan OS token (e.g. "XNU", "Linux") to a HostOs.
 Unknown tokens are passed through lowercased.

**Parameters:**

- `raw` (string) - The raw OS token from cosmo.GetHostOs()

**Returns:**

- HostOs - The normalized operating system name

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

### sysconf

```teal
function sysconf(name: number): number | nil, string
```

 Query a runtime system configuration value.
 `name` is one of the `unix.SC_*` constants (e.g. `unix.SC_PAGESIZE`,
 `unix.SC_NPROCESSORS_ONLN`). Returns nil plus an error message on failure.

**Parameters:**

- `name` (number) - One of the unix.SC_* constants

**Returns:**

- number - | nil The configuration value
- string? - Error message on failure

### nproc

```teal
function nproc(): number | nil, string
```

 Number of processors currently online (available to run threads).

**Returns:**

- number - | nil The online processor count
- string? - Error message on failure

### nproc_configured

```teal
function nproc_configured(): number | nil, string
```

 Number of processors configured in the system.
 May exceed `nproc()` when some processors are offline.

**Returns:**

- number - | nil The configured processor count
- string? - Error message on failure

### page_size

```teal
function page_size(): number | nil, string
```

 Memory page size in bytes.

**Returns:**

- number - | nil The page size in bytes
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

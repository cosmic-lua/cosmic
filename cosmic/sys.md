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

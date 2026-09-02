# Platform support

the six operating systems one cosmic binary runs on, and every place a module
behaves differently on one of them.

cosmic ships one fat binary that runs on Linux, macOS, Windows, FreeBSD, OpenBSD
and NetBSD, on x86_64 and aarch64. the language, the compiler and almost all of
the standard library behave the same everywhere. the differences are listed
here, per module. `cosmic.sys` names the host at runtime:

```teal
local sys = require("cosmic.sys")
print(sys.host_os()) -- "linux", "macos", "windows", "freebsd", "openbsd", "netbsd"
print(sys.platform()) -- "linux-x86_64", "macos-aarch64", ...
```

## Module by OS

every module not in the table is pure Lua or a fully portable Cosmopolitan
binding, and works the same on all six OSes: ansi, benchmark, codec, compress,
deep, doc, embed, env, example, fetch, flags, format, fuzzy, hash, html, ip,
json, log, net, poll, re, rand, sqlite, sse, string, sys, teal, testrun, time,
url, uuid, zip.

modules with per-OS differences:

| module | linux | macos | windows | freebsd | openbsd | netbsd | notes |
|--------|-------|-------|---------|---------|---------|--------|-------|
| fs | full | full | full | full | full | full | symlink creation on Windows needs a privileged or Developer-Mode process |
| child | full | full | full | full | full | full | spawn is fork+execve; Cosmopolitan emulates fork on Windows, and it is slower there |
| proc | full | full | partial | full | full | full | `rusage_children` fails with ENOSYS on Windows |
| user | full | full | partial | full | full | full | uid/gid are polyfilled from getuid(); `set_uid`/`set_gid` return ENOSYS for any other id |
| signal | full | full | partial | full | full | full | Cosmopolitan emulates the core POSIX signals on Windows; timers and rare signals may degrade |
| tty | full | full | partial | full | full | full | termios on Windows maps onto the console API; not every flag is honored |
| shm | full | degraded | degraded | full | full | degraded | kernel futexes on Linux, FreeBSD and OpenBSD; elsewhere wait/wake fall back to sched_yield, which is correct but not scalable under contention |
| log.syslog_output | full | no-op | full | no-op | no-op | full | delivered via syslogd on Linux and NetBSD and ReportEvent() on Windows; silently dropped elsewhere |
| pledge | enforced | no-op* | no-op* | no-op* | enforced | no-op* | see the sandbox table below |
| unveil | enforced | no-op* | no-op* | no-op* | enforced | no-op* | see the sandbox table below |
| landlock | >=5.13 | no | no | no | no | no | Linux-only kernel feature |
| quicksand | full | no | no | no | no | no | Linux namespaces; elsewhere `capabilities().linux == false` and calls return ENOSYS-shaped errors |
| sandbox | enforced | fail-closed | fail-closed | fail-closed | enforced | fail-closed | facade over the three above |

\* "no-op" means the mechanism does not exist on that OS. the cosmic wrappers
are fail-closed, so a call returns an error instead of pretending. the next
section has the exact returns.

## Sandbox behavior per OS

the sandbox family is where the OSes differ most. all four modules are
fail-closed. on a host that cannot enforce a policy, `pledge.apply`,
`unveil.allow` and `unveil.commit` return `false, "... unsupported on this
host"`. `landlock.restrict` returns `nil, "... unsupported on this host"`.
`sandbox.apply` returns `nil, "sandbox: ... unsupported on this host"`. none of
them reports a sandbox that does not exist.

every module exposes `available()` so callers can branch. `best_effort = true`
skips a section the host cannot enforce instead of failing. `sandbox.apply`
then returns a per-section `Report`: a `state` of `"full"`, `"degraded"` or
`"skipped"`, plus the `mechanism` and `abi` that enforced it and what is
`missing`. a best-effort apply that skips every requested section refuses
outright, unless `allow_unenforced = true` says the caller expects that.

`sandbox.Fs` groups mean three things. `ro` is read-only, with no execute.
`exec` is read plus execute. `rw` is read plus write, with no execute.

| mechanism | enforced on | on violation | notes |
|-----------|------------|--------------|-------|
| pledge | Linux, OpenBSD | Linux: EPERM; OpenBSD: process killed | irreversible once applied |
| unveil | OpenBSD (native), Linux (backed by landlock, kernel >=5.13) | path invisible (ENOENT/EACCES) | `commit()` seals the policy |
| landlock | Linux >=5.13 | EACCES | inherited by children; only narrows |
| quicksand | Linux | n/a: setup fails fast | network namespaces + allowlist proxy |

`cosmic.sandbox` is the facade. it picks the mechanism per OS and applies the
fs policy before the sys policy. its `availability()` reports what the host can
enforce:

```teal
local sandbox = require("cosmic.sandbox")
if sandbox.availability().fs.available then
  assert(sandbox.apply {fs = {ro = {"/usr"}, rw = {"/tmp"}}})
end
```

## Paths on Windows

`cosmic.fs` path functions understand Windows-absolute forms on every OS, so a
path pasted from a Windows shell never gets the cwd glued onto it:

- `is_absolute(p)` is true for `/x`, `C:/x`, `C:\x` and UNC `\\server\share`.
- `normalize(p)` turns a drive-letter path into a forward-slash, uppercase-drive
  form (`"c:\a\..\b"` becomes `"C:/b"`). a UNC path keeps the backslash form.
  both collapse `.` and `..`.
- `abspath(p)` only normalizes a Windows-absolute path, and never prefixes the
  cwd.
- `relpath(p, base)` walks within one root. across roots (different drives,
  different UNC shares, drive against POSIX) no relative path exists, so it
  returns the normalized absolute target.

two deliberate limits:

- a single leading `\` or an interior `\` is an ordinary filename character.
  cosmic runs the same code on POSIX, where `\` is legal in names. only the
  unambiguous `C:/`, `C:\` and `\\server\share` forms are Windows roots.
- a drive-relative form (`C:foo`) is not absolute and is not resolved against a
  per-drive cwd.

Windows and Cosmopolitan accept forward slashes everywhere, so a normalized
drive path is directly usable in `fs.*` calls.

## Other Windows notes

- the first-run welcome marker lives in the per-user config dir:
  `%LOCALAPPDATA%\cosmic` on Windows, `$XDG_CONFIG_HOME/cosmic` or
  `$HOME/.config/cosmic` elsewhere. the installed binary is never modified, so
  release checksums stay valid.
- `proc.search_path` discovery expects programs installed without an `.exe` or
  `.com` suffix.
- `fs.home()` falls back from `$HOME` to `%USERPROFILE%`.
- `zip` and `embed` extraction rejects Windows-absolute and UNC target paths on
  every OS, as a zip-slip defense.

## CI coverage

Linux runs the full gate (`--make ci`). macOS and Windows run a smoke job on
every PR. the freshly built binary executes `-e`, `--docs reference.platforms`,
`--docs fs.read`, and the string, json and fs-path test files, including the
Windows path suite. the remaining BSDs are release-tested through Cosmopolitan
upstream, and a platform-specific bug there is reported as an issue.

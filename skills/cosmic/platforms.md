# Platform Support

cosmic ships one fat binary that runs on Linux, macOS, Windows, FreeBSD, OpenBSD, and NetBSD (x86_64 and aarch64). the language, compiler, and almost all of the standard library behave identically everywhere; the differences that exist are listed here, per module. detect the host at runtime with `cosmic.sys`:

```teal
local sys = require("cosmic.sys")
sys.host_os() -- "linux" | "macos" | "windows" | "freebsd" | "openbsd" | "netbsd"
sys.platform() -- "linux-x86_64", "macos-aarch64", ...
```

## Module × OS Matrix

everything not listed in a table below is pure Lua or a fully portable cosmopolitan binding and works the same on all six OSes: ansi, benchmark, codec, compress, doc, embed, env, envd, example, fetch, flags, format, fuzzy, getopt, hash, html, ip, json, log, net, poll, re, rand, sqlite, sse, string, sys, table, teal, testrun, time, url, uuid, zip.

modules with per-OS differences:

| module | linux | macos | windows | freebsd | openbsd | netbsd | notes |
|--------|-------|-------|---------|---------|---------|--------|-------|
| fs | full | full | full | full | full | full | symlink creation on Windows needs a privileged or Developer-Mode process |
| child | full | full | full | full | full | full | spawn is fork+execve; fork on Windows is emulated by cosmopolitan and is slower |
| proc | full | full | partial | full | full | full | `rusage_children` fails with ENOSYS on Windows |
| user | full | full | partial | full | full | full | uid/gid are polyfilled from getuid(); `set_uid`/`set_gid` return ENOSYS for any other id |
| signal | full | full | partial | full | full | full | cosmopolitan emulates the core POSIX signals on Windows; timers and rare signals may degrade |
| tty | full | full | partial | full | full | full | termios on Windows maps onto the console API; not every flag is honored |
| shm | full | degraded | degraded | full | full | degraded | kernel futexes on Linux/FreeBSD/OpenBSD; elsewhere wait/wake fall back to sched_yield — correct but not scalable under contention |
| syslog | full | no-op | full | no-op | no-op | full | delivered via syslogd on Linux/NetBSD and ReportEvent() on Windows; silently dropped elsewhere |
| pledge | enforced | no-op* | no-op* | no-op* | enforced | no-op* | see sandbox matrix below |
| unveil | enforced | no-op* | no-op* | no-op* | enforced | no-op* | see sandbox matrix below |
| landlock | >=5.13 | no | no | no | no | no | Linux-only kernel feature |
| quicksand | full | no | no | no | no | no | Linux namespaces; elsewhere `capabilities().linux == false` and calls return ENOSYS-shaped errors |
| sandbox | enforced | fail-closed | fail-closed | fail-closed | enforced | fail-closed | facade over the three above |

\* "no-op" means the mechanism does not exist on that OS — but the cosmic wrappers are fail-closed, so calls return an error instead of silently pretending (next section).

## Sandbox Behavior Per OS

the sandbox family is where OSes differ most. all four modules are **fail-closed**: on a host that cannot enforce a policy, the mechanism modules' `apply`/`allow`/`commit`/`restrict` return `false, "... unsupported on this host"` (and `sandbox.apply` returns `nil, "sandbox: ... unsupported on this host"`) rather than reporting a sandbox that does not exist. every module exposes `available()` so callers can branch, and `best_effort = true` opts into skip-if-unenforceable — `sandbox.apply` then reports which sections actually enforced via its returned `Availability` record. `sandbox.Fs` groups mean three things: `ro` read-only (no execute), `exec` read+execute, `rw` read+write (no execute).

| mechanism | enforced on | on violation | notes |
|-----------|------------|--------------|-------|
| pledge | Linux, OpenBSD | Linux: EPERM; OpenBSD: process killed | irreversible once applied |
| unveil | OpenBSD (native), Linux (backed by landlock, kernel >=5.13) | path invisible (ENOENT/EACCES) | `commit()` seals the policy |
| landlock | Linux >=5.13 | EACCES | inherited by children; only narrows |
| quicksand | Linux | n/a — setup fails fast | network namespaces + allowlist proxy |

`cosmic.sandbox` (the facade) picks the right mechanism per OS and applies fs policy before sys policy; use its `available()` to report what the host can enforce:

```teal
local sandbox = require("cosmic.sandbox")
if sandbox.available().fs then
  assert(sandbox.apply {fs = {ro = {"/usr"}, rw = {"/tmp"}}})
end
```

## Paths on Windows

`cosmic.fs` path functions understand Windows-absolute forms on every OS, so a path pasted from a Windows shell never gets cwd glued onto it:

- `is_absolute(p)` — true for `/x`, `C:/x`, `C:\x`, and UNC `\\server\share`.
- `normalize(p)` — drive-letter paths normalize to a forward-slash, uppercase-drive form (`"c:\a\..\b"` -> `"C:/b"`); UNC paths keep the backslash form; both collapse `.`/`..`.
- `abspath(p)` — Windows-absolute paths are only normalized, never prefixed with cwd.
- `relpath(p, base)` — walks within one root; across roots (different drives, different UNC shares, drive vs POSIX) no relative path exists, so the normalized absolute target is returned.

two deliberate limits:

- a single leading `\` or interior `\` is an ordinary filename character: cosmic runs the same code on POSIX, where `\` is legal in names. only the unambiguous `C:/`, `C:\`, and `\\server\share` forms are treated as Windows roots.
- drive-relative forms (`C:foo`) are not absolute and are not resolved against a per-drive cwd.

forward slashes are accepted by Windows and by cosmopolitan everywhere, so normalized drive paths are directly usable in `fs.*` calls.

## Other Windows Notes

- the first-run welcome marker lives in the per-user config dir (`%LOCALAPPDATA%\cosmic`, or `$XDG_CONFIG_HOME/cosmic` / `$HOME/.config/cosmic` elsewhere); the installed binary is never modified, so release checksums stay valid.
- `proc.search_path` discovery expects programs installed without an `.exe`/`.com` suffix.
- `fs.home()` falls back from `$HOME` to `%USERPROFILE%`.
- `zip`/`embed` extraction rejects Windows-absolute and UNC target paths on every OS (zip-slip defense).

## CI Coverage

Linux runs the full gate (`--make ci`). macOS and Windows run smoke jobs on every PR: the freshly built binary executes `-e`, `--docs guide.platforms`, and the string/json/fs-path test files. the remaining BSDs are release-tested via cosmopolitan upstream; platform-specific bugs there are tracked as issues.

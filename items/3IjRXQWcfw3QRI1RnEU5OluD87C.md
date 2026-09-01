## Goal

G3, via the cosmo-contracts container — unix.nanosleep's declared
failure shape (`integer|nil remseconds, integer|string remnanos,
unix.Errno? errno, integer? eintr_remseconds, integer? eintr_remnanos`,
tool/net/definitions.lua:5891-5899) is the archetype the census names
for a class-2 environmental tuple deviation — an interrupted sleep's
error string shares the slot the success remainder occupies. The
annotation is already honest (fixed by #253, `definitions: nanosleep's
EINTR remainder slots sit where the C puts them`); nothing currently
PINS that shape with a test, so a future edit to LuaUnixNanosleep or
its annotation could silently drift back to the pre-#253 shape. This
capture adds the missing regression coverage; it changes no contract.

## Evidence

Measured against cosmic-lua/cosmopolitan master `275b73b1d`.

`third_party/lua/cosmo/lunix.c:1677-1705`, `LuaUnixNanosleep`: on
success (`!nanosleep(&req, &rem)`) pushes two integers (0, 0); on
`EINTR` it calls `LuaUnixSysretErrno` (3 values: nil, error string,
errno) then pushes the kernel's own remainder (2 more integers),
returning 5 values total; any other failure returns the plain 3-value
tuple.

`tool/net/definitions.lua:5889-5900` already declares this honestly:
`---@return integer|nil remseconds`, `---@return integer|string
remnanos` (with the comment "failure returns exactly `nil, error,
errno`, so the error lands in this slot, not in a slot of its own"),
`---@return unix.Errno? errno`, `---@return integer? eintr_remseconds`,
`---@return integer? eintr_remnanos`.

Probe transcript, from the cosmopolitan repo root:

```
$ o//tool/lua/lua -e '
local unix = require("unix")
unix.sigaction(unix.SIGALRM, function() end)
unix.setitimer(unix.ITIMER_REAL, 0, 0, 0, 200000000)
print(unix.nanosleep(2, 0))
'
nil	nanosleep: EINTR: Interrupted	4	1	797544049
```

(5 values: nil, the error string in the `remnanos` slot, errno `4`
(EINTR) in the `errno` slot, then the kernel's own remaining
seconds/nanoseconds.)

`grep -n 'nanosleep' tool/lua/test_definitions_conformance.lua
tool/lua/test_signal.lua tool/lua/test_unix_misc.lua`: only
`tool/lua/test_signal.lua` mentions it (one success-path assertion,
"a completed sleep has no remainder"); no test in the tree exercises
the EINTR failure shape.

Cosmic-side spend: `grep -n 'unix.nanosleep' cosmic/time.tl` →
`cosmic/time.tl:83`, inside `sleep_remaining_ms`, which destructures
`rem_s, rem_ns, eno, eintr_s, eintr_ns = unix.nanosleep(...)` and
branches on `rem_s ~= nil`, then on failure reads `rem_ns` as the
error string (comment at line 86: "Slot 2 is slot-accurate since the
pin bump") — concrete proof a real caller relies on exactly this
positional sharing today.

## Change

`tool/lua/test_signal.lua` only, appended after the existing "An
uninterrupted nanosleep..." block (currently the last block before
`print("PASS")`):

```lua
-- An interrupted nanosleep shares two return slots with its own
-- success values (tool/net/definitions.lua): the error string lands
-- where the success remainder-nanoseconds would sit, and the errno
-- where nothing sits on success. Pin that shape live.
do
  unix.sigaction(unix.SIGALRM, function() end)
  unix.setitimer(unix.ITIMER_REAL, 0, 0, 0, 200000000) -- fires once, ~200ms
  local remseconds, remnanos, eno, eintr_s, eintr_ns = unix.nanosleep(2, 0)
  assert(remseconds == nil,
    "an interrupted sleep must report nil in the slot 0 occupies on success")
  assert(type(remnanos) == "string",
    "the error string must land in the slot the remainder occupies on success")
  assert(eno == unix.EINTR, "errno must be EINTR, got " .. tostring(eno))
  assert(math.type(eintr_s) == "integer" and math.type(eintr_ns) == "integer",
    "the kernel's own remainder must follow the errno")
  unix.sigaction(unix.SIGALRM, unix.SIG_DFL)
end
```

## Non-goals

- No change to `third_party/lua/cosmo/lunix.c` or
  `tool/net/definitions.lua` — the C behavior and the annotation are
  already correct (#253); this is coverage only.
- No change to the pure-function `PROBES` ratchet in
  `tool/lua/test_definitions_conformance.lua` — nanosleep blocks and
  installs a real itimer, so it is not the "zero-risk... no side
  effects" binding that file's header scopes itself to; the
  behavioral test file `tool/lua/test_signal.lua`, which already
  exercises sigaction/setitimer/raise/sigprocmask, is the precedented
  home.
- No change to `cosmic/time.tl` or any cosmic-side wrapper — this
  capture is cosmopolitan-only.

## Acceptance

Run from the cosmopolitan repo root:

- `make -j$(nproc) o//tool/lua/test` exits 0, and `test_signal` still
  ends by printing `PASS`.
- `grep -c 'eintr_s' tool/lua/test_signal.lua` reports 1 or more
  (today 0).

## Enablement

none needed. Independent of every other capture in this batch —
touches only `tool/lua/test_signal.lua`, appended at the end.

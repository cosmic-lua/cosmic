## Evidence

Reported by the builder of cosmic-lua/cosmopolitan#339 while rewriting
the neighbouring `localtime` example in `tool/net/help.txt`. The
`unix.Stat:birthtim()` example (around line 5411 at `25aebd9c`;
re-locate with `grep -n 'birthtim' tool/net/help.txt`, #339 moved the
neighbourhood) has two pre-existing defects unrelated to return shapes:

- the `Write('%.4d-…%.2d % {` line is missing the closing quote before
  `%`, so the example is not valid Lua;
- `math.abs(gmtoffsec) % 60` computes seconds where the format wants
  the offset's minutes.

Measured by the first pull of this item: the hour term must not be a
bare floor division either. Lua's `//` floors, so for a negative offset
that is not a whole hour it rounds the hour away from zero:

```
$ o//tool/lua/lua -e 'print(-9000 // 3600, -12600 // 3600, math.abs(-12600) // 60 % 60)'
-3	-4	30
$ TZ=America/St_Johns o//tool/lua/lua birthtim.lua   # `Write` swapped for `print`
2026-03-31T11:01:51.000000000-0330
$ TZ=America/St_Johns date -d @1774963911 '+%FT%T%z'
2026-03-31T11:01:51-0230
```

So hours and minutes both come from the offset's MAGNITUDE, with the
sign printed separately.

## Change

`tool/net/help.txt`, the `unix.Stat:birthtim()` example only: close the
format string, and print the zone offset as sign, hours, minutes
computed from the magnitude:

```lua
local off = t.gmtoffsec
local sign = off < 0 and "-" or "+"
local hh = math.abs(off) // 3600
local mm = math.abs(off) // 60 % 60
-- ... '%s%.2d%.2d' % {sign, hh, mm} in the format string's zone field
```

(adapt the names to the example's existing locals; the point is
`math.abs` on both terms and an explicit sign). Confirm by hand with
`Write` swapped for `print` and `unix = require 'cosmo.unix'` prepended
(redbean has `unix` as a global; plain `lua` does not), under
`TZ=UTC`, `TZ=Asia/Kolkata` (+0530) and `TZ=America/St_Johns` (-0230 in
summer), comparing against `date -d @<secs> '+%FT%T%z'`. Documentation
only.

## Non-goals

- No other `help.txt` section; shape drift is `3IkQwEbETsx7M5Cp4c2dldpfLCr`.
- No change to the example's prose about Linux's min-of-atim/mtim/ctim
  fallback.

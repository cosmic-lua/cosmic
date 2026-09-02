## Evidence

Reported by the builder of cosmic-lua/cosmopolitan#339 while rewriting
the neighbouring `localtime` example in `tool/net/help.txt`. The
`unix.Stat:birthtim()` example (around line 5411 at `25aebd9c`) has two
pre-existing defects unrelated to return shapes:

- the `Write('%.4d-…%.2d % {` line is missing the closing quote before
  `%`, so the example is not valid Lua;
- `math.abs(gmtoffsec) % 60` computes seconds where the format wants
  the offset's minutes (`// 60 % 60`).

Re-locate with `grep -n 'birthtim' tool/net/help.txt`.

## Change

`tool/net/help.txt`, the `unix.Stat:birthtim()` example only: close the
format string, and compute the offset's hours and minutes as
`gmtoffsec // 3600` and `math.abs(gmtoffsec) // 60 % 60`. Paste the
corrected example into `o//tool/lua/lua` once by hand to confirm it
runs and prints a plausible timestamp. Documentation only.

## Non-goals

- No other `help.txt` section; shape drift is `3IkQwEbETsx7M5Cp4c2dldpfLCr`.

# startup_bench

 End-to-end binary scenarios: process startup and Teal compilation.
 Spawns the cosmic binary itself, so these numbers cover the whole
 cosmopolitan stack: APE loader, zip filesystem, Lua runtime boot,
 and (for the compile scenario) the embedded Teal compiler.

 These are the scenarios that move when whilp/cosmopolitan (the cosmos
 pin) changes. Set PERF_BIN to benchmark a different binary.

## Types

### Point

```teal
local record Point
  x: number
  y: number
end
```

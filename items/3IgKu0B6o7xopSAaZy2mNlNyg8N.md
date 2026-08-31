## Goal

`plaA_uCdm` ("deflate the embedded .lua payload: the cosmic binary
drops ~2.0 MB (-19%)") proposed deflating every embedded `.lua` entry
unconditionally, on the premise that the per-launch inflate cost of
the boot-path modules is immaterial against startup. That premise is
now falsified twice, independently:

- 2026-08-30T14:17 drop: measured baseline `startup_run_lua` (plain-Lua
  bare boot) is ~2.4ms, not the spec's assumed ~13ms; the deflate
  change's reproducible +20-30% regression (~0.7-1ms) is roughly a
  third of measured startup, not a rounding error. `perf-compare`
  FAILs; confirmed via 3 independent interleaved rounds plus a raw
  shell-loop timing check.
- 2026-08-30T16:32 drop: re-pulled and re-verified independently, same
  falsification. Full-suite compare: `startup_run_teal +46.7%`,
  `startup_compile_teal +30.8%` (accepted cost) plus other scenarios.
  A second startup-focused higher-sample run (`--only startup --samples
  15`): `startup_run_lua +10.9%`, `startup_run_teal +134.1%`.

The size claim holds in both runs (~2.0MB / -19%, matching the spec's
number almost exactly) — only the startup-immateriality premise is
dead. `plaA_uCdm`'s own Non-goals section anticipated this outcome:
"If the compare gate shows a real startup regression, do not tune this
diff... the follow-up — store exactly the measured boot set, deflate
the rest — is its own item." This item is that follow-up.

## Change

In `cosmic/embed/init.tl`'s embed policy (near the `is_lua` local
around lines 394-397), keep the current per-entry method decision but
narrow the "store" branch from "every `.lua` entry" to "every `.lua`
entry in the measured boot set", deflating everything else including
the rest of the `.lua` corpus.

The measured boot set (from `plaA_uCdm`'s evidence, `./cosmic-lua -e
'for k in pairs(package.loaded) do print(k) end'` against a bare boot,
cross-referenced against `/zip`-resolved modules): 16 modules summing
54,816 bytes — `main`, `_cli.args`, `_cli.main_handlers`,
`_cli.require_hints`, `_cli.run`, `cosmic._fields`, `cosmic.env`,
`cosmic.errno`, `cosmic.flags` (and its submodules), `cosmic.
instrument`, `cosmic.searcher`, `cosmic.tty`. Re-measure this set
against the current tree rather than assuming the list is unchanged
since 2026-08-29 — module boundaries may have shifted.

The two heavyweight entries that drove the original size win
(`.docs/index.lua`, `tl.lua`) are NOT in the boot set (they load only
on `--docs` and type-check paths) — they deflate under this policy,
recovering most of the original ~2.0MB claim without the startup cost.

## Non-goals

- No zstd, no new zip method vocabulary (per `plaA_uCdm`'s own
  non-goals, still binding).
- No change to `cosmic.zip`'s public `AddOptions` or explicit per-add
  `method` behavior.

## Acceptance

- `bin/cosmic --make ci` passes with the updated
  `cosmic/embed_test.tl` policy assertions (boot-set modules pinned at
  method 0/stored, everything else pinned at method 8/deflate).
- The `optimize` skill's loop: baseline `origin/main`, change, A/A
  selfcheck, compare gate — `perf-compare` PASSes on `startup_run_lua`
  and `startup_run_teal` (no regression beyond noise floor), and the
  binary-size scenario shows a real reduction (expect less than the
  original ~2.0MB claim, since the boot set stays stored, but still
  positive).
- If the compare gate fails again on this narrower policy, that is
  evidence the boot set itself needs revisiting (re-measure, don't
  retry the same set) — not grounds to fall back to unconditional
  deflate.

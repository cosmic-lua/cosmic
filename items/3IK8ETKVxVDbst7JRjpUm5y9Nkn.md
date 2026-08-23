Research pass: 2026-08-23, per skills/optimize ("running a research
pass"), driven by four round-1 agents (full-suite baseline read, cosmic
sweep, C-layer/startup sweep, literal-vs-json probe) plus a round-2
verification pass. Tree at main 0fb444d6-equivalent; binary o/bin/cosmic
built from it; full-suite baseline in that session (json_decode_large
929µs, fs_walk_tree 354.7µs/73KB, format_module_source 6.83ms/1478KB,
startup_run_lua 2.35ms cw0.07, embed_extract_tree 59.9ms cw1.01). All
probe numbers below are SCOUTING numbers (os.clock/shell loops, medians
of 3+), not the _perf gate; accept/reject stays with the harness.

## Problem
Un-assimilated (MZ) cosmic pays an exec tax (scouting): spawned from
a cosmopolitan parent, 2467µs vs 2215µs assimilated (~250µs, ≈10% of
startup_run_lua, re-execing through the APE loader and re-loading the
10MB image). From a NON-cosmopolitan parent with no binfmt_misc
(this host), each exec is a 3-execve chain (execve → ENOEXEC →
/bin/sh reads the MZ header → execs the ape loader): 5.1ms vs 1.08ms
for raw lua — every bash loop, git hook and CI step running cosmic
pays ~4ms/exec.

## Change (hypothesis)
Packaging, not C: assimilate the LOCAL dev binary (cosmos.zip already
ships o/3p/cosmos/assimilate) and/or register binfmt_misc in CI
images; releases stay fat. Candidate mechanisms: --make emits an
assimilated o/bin/cosmic variant beside the fat one on Linux, or CI
images pre-register APE binfmt. A pure-C fix (loader avoiding the
image re-read, fexecve-style handoff) is invasive — record it as the
ambitious extension, don't start there.

## Constraints
An assimilated binary is no longer fat: never ship one; repro lane
byte-compares artifacts, so any assimilated variant must stay out of
release payloads. The harness measures the fat binary by design —
changing what startup_run_* measures is a scenario-contract question
for plan, not a silent swap.

## Risk
Low mechanically; the risk is measurement honesty (which binary does
the suite measure). Evidence agent: C-layer sweep, kernel strace of
the 3-exec chain.

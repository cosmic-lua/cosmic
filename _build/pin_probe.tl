#!/usr/bin/env cosmic
--- Decide whether a probe DISCRIMINATES two cosmic binaries, instead of
--- leaving that judgement to a reader.
---
--- The carried tl patch (`3p/tl/tl_patch/`) reaches builders only
--- through `bin/cosmic.pin`, so a pin bump that means to obtain a
--- checker rule has to prove the candidate binary carries it. The proof
--- is one probe file that the two binaries answer with OPPOSITE EXIT
--- STATUSES — one refuses it, the other accepts it. A differing error
--- MESSAGE is not proof: a probe both binaries refuse says nothing
--- about the rule, however far apart the two messages read.
---
---   cosmic _build/pin_probe.tl <probe.tl> <baseline-binary> <candidate-binary>
---
--- Both binaries are run as `<binary> --check types <probe.tl>`. The
--- two transcripts are printed in full — that is what shows a reader
--- the messages differed while the statuses did not — and the verdict
--- line comes last:
---
---   pin-probe: DISCRIMINATES (baseline refuses, candidate accepts)
---   pin-probe: DISCRIMINATES (baseline accepts, candidate refuses)
---   pin-probe: VACUOUS (both accept)
---   pin-probe: VACUOUS (both refuse; a differing message is not discrimination)
---
--- Exit codes: 0 when the probe discriminates, 1 when it is vacuous, 2
--- when the run could not be made at all (wrong argument count, an
--- unreadable probe, a binary that would not run). 2 is never either
--- verdict, so a broken invocation cannot read as a proof.
---
--- `_build/testdata/packn_probe.tl` is a worked example: `table.pack`'s
--- `n` field, which the patch narrows from `any` to `integer`.

local child = require("cosmic.child")
local env = require("cosmic.env")
local fs = require("cosmic.fs")
local proc = require("cosmic.proc")

local USAGE < const > =
"usage: cosmic _build/pin_probe.tl <probe.tl> <baseline-binary> " ..
"<candidate-binary>\n"

--- A signaled child has no exit status. 128 stands in for one: it is
--- non-zero, so a crashed run can never read as an acceptance.
local SIGNALED_CODE < const > = 128

--- One binary's answer to the probe.
local record Run
  --- "baseline" or "candidate" — how the block is labelled.
  label: string
  --- The binary that was run.
  path: string
  --- Its combined stdout and stderr.
  output: string
  --- Its exit status; SIGNALED_CODE when a signal ended it.
  code: integer
end

--- The verdict for a pair of exit statuses. Discrimination is opposite
--- statuses and nothing else — same status is vacuous whatever the two
--- runs printed.
--- @param baseline_code integer The baseline binary's exit status
--- @param candidate_code integer The candidate binary's exit status
--- @return string The verdict line
--- @return boolean True when the probe discriminates the two binaries
local function verdict(baseline_code: integer,
    candidate_code: integer): string, boolean
  if baseline_code ~= 0 and candidate_code == 0 then
    return "pin-probe: DISCRIMINATES (baseline refuses, candidate accepts)",
    true
  end
  if baseline_code == 0 and candidate_code ~= 0 then
    return "pin-probe: DISCRIMINATES (baseline accepts, candidate refuses)",
    true
  end
  if baseline_code == 0 and candidate_code == 0 then
    return "pin-probe: VACUOUS (both accept)", false
  end
  return "pin-probe: VACUOUS (both refuse; a differing message is not " ..
  "discrimination)", false
end

--- Type-check `probe` under one binary and record what it answered.
---
--- COSMIC_COVERAGE off in the child for the same reason
--- `_build/coldbuild_test.tl` does it: an instrumented child would dump
--- .cov files for its own embedded sources into the caller's coverage
--- directory.
--- @param label string "baseline" or "candidate"
--- @param binary string The cosmic binary to run
--- @param probe string The probe source to check
--- @return Run|nil The run, or nil when the binary could not be run
--- @return string The error message on failure
local function probe_run(label: string, binary: string,
    probe: string): Run | nil, string
  local argv: {string} = {binary, "--check", "types", probe}
  local r, err = child.run(argv,
    {env = env.list({set = {COSMIC_COVERAGE = "0"}})})
  if r == nil then
    return nil, "could not run " .. binary .. ": " .. tostring(err)
  end
  local code = r.code
  if code == nil then
    code = SIGNALED_CODE
  end
  return {
    label = label,
    path = binary,
    output = r.stdout .. r.stderr,
    code = code,
  }
end

--- One run as its printed block: the label and binary, the combined
--- output, then its exit status.
--- @param r Run The run to render
--- @return string The block, newline-terminated
local function block(r: Run): string
  local out = r.output
  if out ~= "" and not out:match("\n$") then
    out = out .. "\n"
  end
  return r.label .. ": " .. r.path .. "\n" .. out ..
  "exit=" .. tostring(r.code) .. "\n"
end

--- Run the probe under both binaries and judge the pair.
---
--- Infallible by type: an operational failure comes back as the report
--- TEXT with exit code 2 rather than a nil, so every caller has
--- something to print and no failure path can be mistaken for a
--- verdict.
--- @param probe string The probe source to check under both binaries
--- @param baseline string The binary the candidate is measured against
--- @param candidate string The binary under test
--- @return string The report: both transcripts, then the verdict line
--- @return integer 0 discriminates, 1 vacuous, 2 the run could not be made
local function report(probe: string, baseline: string,
    candidate: string): string, integer
  if not fs.is_file(probe) then
    return "pin-probe: cannot read probe file: " .. probe, 2
  end
  local base, berr = probe_run("baseline", baseline, probe)
  if base == nil then
    return "pin-probe: " .. tostring(berr), 2
  end
  local cand, cerr = probe_run("candidate", candidate, probe)
  if cand == nil then
    return "pin-probe: " .. tostring(cerr), 2
  end
  local line, discriminates = verdict(base.code, cand.code)
  local text = block(base) .. block(cand) .. line
  if discriminates then
    return text, 0
  end
  return text, 1
end

--- CLI entry point.
--- @param ... string The probe, the baseline binary, the candidate binary
--- @return integer The exit code
local function main(...: string): integer
  local argv = {...}
  if #argv ~= 3 then
    io.stderr:write(USAGE)
    return 2
  end
  local text, code = report(argv[1], argv[2], argv[3])
  if code == 2 then
    io.stderr:write(text .. "\n")
    return code
  end
  print(text)
  return code
end

if proc.is_main() then
  os.exit(main(...)) -- exits: process boundary; the verdict IS the status
end

local record PinProbeModule
  type Run = Run
  verdict: function(baseline_code: integer, candidate_code: integer): string, boolean
  report: function(probe: string, baseline: string, candidate: string): string, integer
  main: function(...: string): integer
end

local M: PinProbeModule = {
  verdict = verdict,
  report = report,
  main = main,
}

return M

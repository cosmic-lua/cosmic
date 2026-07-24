#!/usr/bin/env lua

-- Unused-grant audit by leave-one-out (whilp/cosmopolitan#210 item 3,
-- #756 item 4).
--
-- The question worth answering is not "was this path touched?" but
-- "would removing this grant break the rule?" — the second is what you
-- act on, and the kernel answers it directly. So: rebuild a target with
-- one grant entry withheld. If it still succeeds, that entry was not
-- needed for that target, and the shared set can shrink with evidence
-- instead of guesswork.
--
-- Withholding needs no makefile edits. The grant sets are composed from
-- make variables (`unveil_base`, `unveil_dev`, `unveil_hostx`, ...), and
-- a command-line assignment overrides the makefile's, so passing
-- `unveil_hostx=<all entries but one>` reaches every rule that composes
-- it. Note that a target-specific `.UNVEIL` can NOT be used for this:
-- landlock-make unveils the global, pattern, and target sets additively,
-- so a narrower per-target assignment adds grants rather than replacing
-- them.
--
-- Two things this deliberately does not do. It never edits a makefile —
-- it reports candidates, a human removes them. And its verdicts are
-- scoped to the targets it audited: an entry unused by every audited
-- target may still be needed by a rule that was not audited, so the
-- report names its own coverage rather than implying the set is safe to
-- empty.

local child = require("cosmic.child")
local fs = require("cosmic.fs")
local proc = require("cosmic.proc")
local unveil = require("cosmic.unveil")

local record Entry
  perm: string
  path: string
  raw: string
end

local record Verdict
  target: string
  var: string
  entry: string
  needed: boolean
end

local record Options
  make: string
  targets: {string}
  vars: {string}
  allow_no_enforcement: boolean
end

local record Report
  verdicts: {Verdict}
  unused: {string: {string}} -- var -> entries no audited target needed
  skipped: {string}
end

--- Split a grant set value ("rx:/usr r:/etc") into entries.
--- @param value string Whitespace-separated grant entries
--- @return {Entry} Parsed entries; malformed ones are dropped
local function parse_entries(value: string): {Entry}
  local out: {Entry} = {}
  for raw in value:gmatch("%S+") do
    local perm, path = raw:match("^([rwcx]+):(.+)$")
    if perm and path then
      out[#out + 1] = { perm = perm, path = path, raw = raw }
    end
  end
  return out
end

--- Read the expanded value of each named variable from make's database.
--- `-p -n -q` prints the database without running anything.
--- @param make string make binary to invoke
--- @param vars {string} Variable names to look up
--- @return {string: string} | nil Map of name to expanded value
--- @return string Error message on failure
local function read_vars(make: string, vars: {string}): {string: string} | nil, string
  local res, serr = child.run({ make, "-p", "-n", "-q" })
  if not res then
    return nil, "could not run " .. make .. ": " .. tostring(serr)
  end
  local r = res as child.Result -- cast: record union after guard
  local wanted: {string: boolean} = {}
  for _, v in ipairs(vars) do
    wanted[v] = true
  end
  local found: {string: string} = {}
  for line in (r.stdout .. "\n" .. r.stderr):gmatch("[^\n]+") do
    local name, value = line:match("^([%w_]+)%s*:?=%s*(.*)$")
    if name and wanted[name] and not found[name] then
      found[name] = value
    end
  end
  for _, v in ipairs(vars) do
    if not found[v] then
      return nil, "variable not found in make database: " .. v
    end
  end
  return found
end

--- Rebuild a target from scratch, returning whether it succeeded and the
--- set of grant paths landlock-make applied to it.
--- Removing the target first is what forces the rule to run; --debug=j is
--- what makes the grants observable.
--- @param make string make binary to invoke
--- @param target string Target path to rebuild
--- @param override string Extra `var=value` argument, or nil
--- @return boolean Whether the rebuild succeeded
--- @return {string: boolean} Set of paths unveiled for the target
local function rebuild(make: string, target: string, override?: string): boolean, {string: boolean}
  fs.rmrf(target)
  local argv = { make, target, "--debug=j" }
  if override then
    argv[#argv + 1] = override
  end
  local res = child.run(argv)
  local paths: {string: boolean} = {}
  if not res then
    return false, paths
  end
  local r = res as child.Result -- cast: record union after guard
  for line in (r.stdout .. "\n" .. r.stderr):gmatch("[^\n]+") do
    local path = line:match("^Unveil (.+) with permissions ")
    if path and path ~= "(null)" then
      paths[path] = true
    end
  end
  return r.ok, paths
end

--- Whether a target's rule actually composes a grant variable.
--- Blanking the variable entirely and comparing the applied grant set is
--- the only reliable test: entries overlap between sets (unveil_hostx
--- repeats unveil_dev's device nodes), so matching an entry's PATH
--- against the applied set would credit a rule with using a variable it
--- never referenced — and report the entry as removable on that
--- rule's evidence.
--- @param make string make binary to invoke
--- @param target string Target path to rebuild
--- @param var string Grant variable to blank
--- @param baseline {string: boolean} Grants applied with the full sets
--- @return boolean Whether blanking the variable changed the grants
local function var_referenced(make: string, target: string, var: string,
                              baseline: {string: boolean}): boolean
  local _, applied = rebuild(make, target, var .. "=")
  for path in pairs(baseline) do
    if not applied[path] then
      return true
    end
  end
  return false
end

--- Rebuild with one entry withheld from a grant variable.
--- @param make string make binary to invoke
--- @param target string Target path to rebuild
--- @param var string Grant variable to shrink
--- @param entries {Entry} The variable's full entry list
--- @param drop integer Index of the entry to withhold
--- @return boolean Whether the target still built without that grant
local function rebuild_without(make: string, target: string, var: string,
                               entries: {Entry}, drop: integer): boolean
  local kept: {string} = {}
  for i, e in ipairs(entries) do
    if i ~= drop then
      kept[#kept + 1] = e.raw
    end
  end
  local ok = rebuild(make, target, var .. "=" .. table.concat(kept, " "))
  return ok
end

--- Audit every (target, variable, entry) triple.
--- An entry the target never had applied is not reported at all: the rule
--- does not compose that variable, so withholding it proves nothing.
--- @param opts Options Audit configuration
--- @return Report | nil Findings, or nil if a baseline rebuild failed
--- @return string Error message on failure
local function audit(opts: Options): Report | nil, string
  local found, err = read_vars(opts.make, opts.vars)
  if not found then
    return nil, err
  end
  local values = found as {string: string} -- cast: map union after guard
  local report: Report = { verdicts = {}, unused = {}, skipped = {} }
  local needed_anywhere: {string: {string: boolean}} = {}
  local seen_anywhere: {string: {string: boolean}} = {}
  for _, var in ipairs(opts.vars) do
    needed_anywhere[var] = {}
    seen_anywhere[var] = {}
  end

  for _, target in ipairs(opts.targets) do
    local ok, applied = rebuild(opts.make, target)
    if not ok then
      -- A target that cannot build with its full grants tells us nothing
      -- about which of them matter.
      report.skipped[#report.skipped + 1] = target
      io.stderr:write("audit-unveil: baseline build failed, skipping: ",
        target, "\n")
    else
      for _, var in ipairs(opts.vars) do
        if var_referenced(opts.make, target, var, applied) then
          local entries = parse_entries(values[var])
          for i, e in ipairs(entries) do
            if applied[e.path] then
              seen_anywhere[var][e.raw] = true
              local still = rebuild_without(opts.make, target, var, entries, i)
              report.verdicts[#report.verdicts + 1] = {
                target = target, var = var, entry = e.raw, needed = not still,
              }
              if not still then
                needed_anywhere[var][e.raw] = true
              end
            end
          end
        end
      end
    end
  end

  for _, var in ipairs(opts.vars) do
    local unused: {string} = {}
    for entry in pairs(seen_anywhere[var]) do
      if not needed_anywhere[var][entry] then
        unused[#unused + 1] = entry
      end
    end
    table.sort(unused)
    report.unused[var] = unused
  end
  return report
end

--- Render the report. Candidates are per-audited-target evidence, not a
--- license to empty the set — the coverage line says so explicitly.
--- @param report Report Findings to print
--- @param opts Options Audit configuration, for the coverage note
local function render(report: Report, opts: Options)
  local by_target: {string: {Verdict}} = {}
  for _, v in ipairs(report.verdicts) do
    by_target[v.target] = by_target[v.target] or {}
    local list = by_target[v.target]
    list[#list + 1] = v
  end
  for _, target in ipairs(opts.targets) do
    local list = by_target[target]
    if list then
      print(target)
      for _, v in ipairs(list) do
        print(("  %-8s %-28s %s"):format(
          v.needed and "needed" or "UNUSED", v.entry, v.var))
      end
    end
  end
  print("")
  print("candidates for removal (unused by every audited target):")
  local any = false
  for _, var in ipairs(opts.vars) do
    local unused = report.unused[var]
    if #unused > 0 then
      any = true
      print(("  %s: %s"):format(var, table.concat(unused, " ")))
    end
  end
  if not any then
    print("  (none)")
  end
  print("")
  print(("coverage: %d target(s) audited; entries are candidates for THESE "):format(#opts.targets)
    .. "rules only —")
  print("a rule outside this list may still need them. Per-rule literal")
  print("grants (not composed from a variable) are not covered.")
  if #report.skipped > 0 then
    print("skipped (baseline build failed): " .. table.concat(report.skipped, " "))
  end
end

--- Parse argv into Options.
--- @param argv {string} Command-line arguments
--- @return Options | nil Parsed options
--- @return string Error message on failure
local function parse_args(argv: {string}): Options | nil, string
  local opts: Options = {
    make = "bin/cosmo-make", targets = {}, vars = {},
    allow_no_enforcement = false,
  }
  local i = 1
  while i <= #argv do
    local a = argv[i]
    if a == "--make" then
      i = i + 1
      opts.make = argv[i]
    elseif a == "--target" then
      i = i + 1
      opts.targets[#opts.targets + 1] = argv[i]
    elseif a == "--var" then
      i = i + 1
      opts.vars[#opts.vars + 1] = argv[i]
    elseif a == "--allow-no-enforcement" then
      opts.allow_no_enforcement = true
    else
      return nil, "unknown argument: " .. a
    end
    if i > #argv then
      return nil, "missing value for " .. a
    end
    i = i + 1
  end
  if #opts.vars == 0 then
    opts.vars = { "unveil_base", "unveil_dev", "unveil_hostx" }
  end
  if #opts.targets == 0 then
    return nil, "no --target given"
  end
  return opts
end

local function main(argv: {string}): integer
  local parsed, err = parse_args(argv)
  if not parsed then
    io.stderr:write("audit-unveil: ", err, "\n")
    return 2
  end
  local opts = parsed as Options -- cast: record union after guard
  -- Without enforcement every withheld grant "passes" and the whole
  -- report reads as "remove everything" — the exact wrong answer,
  -- delivered confidently.
  if not unveil.available() then
    if not opts.allow_no_enforcement then
      io.stderr:write(
        "audit-unveil: Landlock unavailable — every verdict would be\n",
        "  UNUSED for the wrong reason. Run on a Landlock host, or pass\n",
        "  --allow-no-enforcement to exercise the harness anyway.\n")
      return 1
    end
    io.stderr:write("audit-unveil: WARNING — no enforcement; verdicts are ",
      "meaningless, harness exercise only\n")
  end
  local report, aerr = audit(opts)
  if not report then
    io.stderr:write("audit-unveil: ", aerr, "\n")
    return 1
  end
  render(report, opts)
  return 0
end

if proc.is_main() then
  os.exit(main(arg))
end

return {
  parse_entries = parse_entries,
  parse_args = parse_args,
  audit = audit,
  render = render,
  main = main,
}

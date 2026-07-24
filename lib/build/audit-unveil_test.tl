local audit = require("build.audit-unveil")
local check = require("cosmic.check")
local fs = require("cosmic.fs")

-- A stand-in for make, so the engine is exercised without Landlock (and
-- without a real build). It models ONE rule: the target composes
-- unveil_dev and its own target directory, and it fails when
-- rw:/dev/null is withheld — i.e. exactly one entry is genuinely needed,
-- the other two are not, and unveil_hostx is never referenced at all.
local fake_make = [[#!/bin/sh
for a in "$@"; do
  case "$a" in
    -p) echo 'unveil_dev := rw:/dev/null r:/dev/random r:/dev/urandom'
        echo 'unveil_hostx := rx:/usr rx:/bin'
        echo 'unveil_base := r:lib'
        exit 0 ;;
  esac
done
dev='rw:/dev/null r:/dev/random r:/dev/urandom'
base='r:lib'
broken=
for a in "$@"; do
  case "$a" in
    unveil_dev=*) dev=${a#unveil_dev=} ;;
    unveil_base=*) base=${a#unveil_base=} ;;
    o/out/broken) broken=1 ;;
  esac
done
echo "Unveil o/out with permissions rwc" >&2
for e in $dev $base; do
  echo "Unveil ${e#*:} with permissions ${e%%:*}" >&2
done
if [ -n "$broken" ]; then exit 1; fi
case " $dev " in
  *" rw:/dev/null "*) exit 0 ;;
  *) exit 1 ;;
esac
]]

--- Write the fake make into TEST_TMPDIR and return its path.
local function write_fake_make(): string
  local tmpdir = check.must(os.getenv("TEST_TMPDIR"))
  local path = fs.join(tmpdir, "fake-make")
  check.must(fs.write(path, fake_make))
  fs.chmod(path, 493) -- 0755
  return path
end

local function test_parse_entries()
  local e = audit.parse_entries("rx:/usr r:/etc rw:/dev/null")
  assert(#e == 3, "got: " .. tostring(#e))
  assert(e[1].perm == "rx", "got: " .. e[1].perm)
  assert(e[1].path == "/usr", "got: " .. e[1].path)
  assert(e[3].raw == "rw:/dev/null", "got: " .. e[3].raw)
end

local function test_parse_entries_skips_malformed()
  -- A bare path with no permission prefix is not a grant entry; dropping
  -- it keeps the leave-one-out override faithful to what make composes.
  local e = audit.parse_entries("rx:/usr notagrant r:/etc")
  assert(#e == 2, "got: " .. tostring(#e))
  assert(e[2].path == "/etc", "got: " .. e[2].path)
end

local function test_parse_entries_keeps_colons_in_path()
  local e = audit.parse_entries("r:/weird:path")
  assert(#e == 1, "got: " .. tostring(#e))
  assert(e[1].path == "/weird:path", "got: " .. e[1].path)
end

local function test_parse_args_defaults()
  local opts = check.must(audit.parse_args({ "--target", "o/x.lua" }))
  assert(#opts.targets == 1, "got: " .. tostring(#opts.targets))
  assert(opts.targets[1] == "o/x.lua", "got: " .. opts.targets[1])
  assert(#opts.vars == 3, "got: " .. tostring(#opts.vars))
  assert(opts.vars[1] == "unveil_base", "got: " .. opts.vars[1])
  assert(not opts.allow_no_enforcement, "default must require enforcement")
end

local function test_parse_args_explicit()
  local opts = check.must(audit.parse_args({
    "--make", "m", "--target", "a", "--target", "b",
    "--var", "unveil_hostx", "--allow-no-enforcement",
  }))
  assert(opts.make == "m", "got: " .. opts.make)
  assert(#opts.targets == 2, "got: " .. tostring(#opts.targets))
  assert(#opts.vars == 1, "got: " .. opts.vars[1])
  assert(opts.allow_no_enforcement, "flag must parse")
end

local function test_parse_args_requires_target()
  local opts, err = audit.parse_args({ "--var", "unveil_dev" })
  assert(opts == nil, "must reject an audit with nothing to audit")
  assert(err:match("no %-%-target"), "got: " .. err)
end

local function test_parse_args_rejects_unknown()
  local opts, err = audit.parse_args({ "--nope" })
  assert(opts == nil, "must reject unknown arguments")
  assert(err:match("unknown"), "got: " .. err)
end

local function test_parse_args_rejects_dangling_value()
  -- `--target` with nothing after it must not silently audit nothing.
  local opts, err = audit.parse_args({ "--target" })
  assert(opts == nil, "must reject a flag with no value")
  assert(err ~= nil, "must explain why")
end

local function test_audit_separates_needed_from_unused()
  local opts = check.must(audit.parse_args({
    "--make", write_fake_make(), "--target", "o/out/thing",
    "--var", "unveil_dev",
  }))
  local report = check.must(audit.audit(opts))
  local by_entry: {string: boolean} = {}
  for _, v in ipairs(report.verdicts) do
    by_entry[v.entry] = v.needed
  end
  assert(by_entry["rw:/dev/null"] == true,
    "the entry the rule cannot build without must read needed")
  assert(by_entry["r:/dev/random"] == false, "unneeded entry must read UNUSED")
  assert(by_entry["r:/dev/urandom"] == false, "unneeded entry must read UNUSED")
  local unused = report.unused["unveil_dev"]
  assert(#unused == 2, "got: " .. tostring(#unused))
  assert(#report.skipped == 0, "baseline built, nothing should be skipped")
end

local function test_audit_skips_unreferenced_variable()
  -- unveil_hostx is not composed by this rule. Withholding its entries
  -- changes nothing, so reporting them as removable would credit this
  -- rule with evidence it never produced.
  local opts = check.must(audit.parse_args({
    "--make", write_fake_make(), "--target", "o/out/thing",
    "--var", "unveil_hostx",
  }))
  local report = check.must(audit.audit(opts))
  assert(#report.verdicts == 0,
    "an unreferenced variable must yield no verdicts, got: "
    .. tostring(#report.verdicts))
  assert(#report.unused["unveil_hostx"] == 0, "and no removal candidates")
end

local function test_audit_skips_target_whose_baseline_fails()
  -- o/out/broken fails in the fake even with its FULL grants, standing in
  -- for a target that cannot build at all: it can say nothing about which
  -- of its grants matter, so withholding them proves nothing.
  local broken = check.must(audit.parse_args({
    "--make", write_fake_make(), "--target", "o/out/broken",
    "--var", "unveil_dev",
  }))
  local report = check.must(audit.audit(broken))
  assert(#report.skipped == 1, "an unbuildable target must be skipped")
  assert(#report.verdicts == 0, "and must produce no verdicts")
end

local function test_read_vars_reports_missing_variable()
  local opts = check.must(audit.parse_args({
    "--make", write_fake_make(), "--target", "o/out/thing",
    "--var", "unveil_nonexistent",
  }))
  local report, err = audit.audit(opts)
  assert(report == nil, "a variable make does not define must be an error")
  assert(err:match("unveil_nonexistent"), "got: " .. tostring(err))
end

local function test_render_does_not_throw()
  local opts = check.must(audit.parse_args({
    "--make", write_fake_make(), "--target", "o/out/thing",
    "--var", "unveil_dev",
  }))
  local report = check.must(audit.audit(opts))
  audit.render(report, opts)
end

test_parse_entries()
test_parse_entries_skips_malformed()
test_parse_entries_keeps_colons_in_path()
test_parse_args_defaults()
test_parse_args_explicit()
test_parse_args_requires_target()
test_parse_args_rejects_unknown()
test_parse_args_rejects_dangling_value()
test_audit_separates_needed_from_unused()
test_audit_skips_unreferenced_variable()
test_audit_skips_target_whose_baseline_fails()
test_read_vars_reports_missing_variable()
test_render_does_not_throw()

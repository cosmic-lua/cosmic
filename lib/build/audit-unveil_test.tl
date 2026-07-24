local audit = require("build.audit-unveil")
local check = require("cosmic.check")

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

test_parse_entries()
test_parse_entries_skips_malformed()
test_parse_entries_keeps_colons_in_path()
test_parse_args_defaults()
test_parse_args_explicit()
test_parse_args_requires_target()
test_parse_args_rejects_unknown()
test_parse_args_rejects_dangling_value()

--- The running tool's shared-cache maintenance, independent of any project.

local Verb = require("cosmic.cli.cache")
local Flags = require("cosmic.flags")
local Json = require("cosmic.json")
local bare = require("build.bare")
local maintenance = require("build.cache_maintenance")
local verb_spec = require("build.verb_spec")

local record verb
  mut spec: verb_spec.Spec
  record Io
    out: function(string): boolean, string
    err: function(string)
  end
end

local standard: verb.Io = { out = bare.out, err = bare.err }
local usage = "cosmic cache trim compiles PATH --since-ns N [--restored PATH] [--json]; " ..
  "cosmic cache trim verdicts PATH... (--since-ns N | --whole) [--json]"

--- Runs the explicit operation; neither a cache path nor a cutoff is inferred.
function verb.run(argv: {string}, io?: verb.Io): integer
  local to = io or standard
  local complain = bare.complainer("cache", to.err)
  local function refuse(why: string): integer
    complain(why .. "; " .. usage)
    return 2
  end
  if argv[2] ~= "trim" then return refuse("give the trim operation") end
  local family = argv[3]
  if not (family is maintenance.Family) then return refuse("give compiles or verdicts") end
  local trim = assert((Verb.subcommands or {})["trim"])
  local described = assert((trim.subcommands or {})[family])
  local parsed, why = Flags.parse(argv, 4, described.spec or {})
  if parsed == nil then return refuse("trim " .. family .. ": " .. why) end
  local paths: mut {string} = {}
  for _, path in ipairs(parsed.words) do
    if path:sub(1, 1) ~= "/" or path:find("\0", 1, true) ~= nil then
      return refuse("cache paths must be absolute and contain no NUL")
    end
    paths[#paths + 1] = path
  end
  if #paths == 0 or (family == "compiles" and #paths ~= 1) then
    return refuse("compiles takes one path; verdicts takes one or more")
  end
  local whole = parsed.set["--whole"] == true
  local since = parsed.integers["--since-ns"]
  if whole == (since ~= nil) then
    return refuse("give --since-ns or --whole")
  end
  local restored = parsed.values["--restored"]
  if restored ~= nil and (restored:sub(1, 1) ~= "/" or restored:find("\0", 1, true) ~= nil) then
    return refuse("restored is an absolute snapshot path")
  end
  local options: maintenance.Options = {
    family = family, paths = paths, since_ns = since, whole = whole, restored = restored,
  }
  local result = maintenance.run(options)
  local report, complete = result.report, result.complete
  for _, file in ipairs(report.files) do
    if file.state == "failed" then complain(file.path .. ": " .. file.reason) end
  end
  for _, warning in ipairs(report.warnings) do complain(warning) end
  local output: string
  if parsed.set["--json"] == true then
    Json.array(report.files) -- checked: not_assignable
    Json.array(report.warnings)
    for _, file in ipairs(report.files) do
      Json.array(file.unknown_tables)
      Json.array(file.unstamped_tables)
      Json.array(file.removed_set_aside)
    end
    output = assert(Json.encode(report)) .. "\n" -- checked: not_assignable
  else
    local lines: mut {string} = {}
    for _, file in ipairs(report.files) do
      local line = file.path .. ": " .. file.state
      local kept, removed = file.kept, file.removed
      if kept ~= nil and removed ~= nil then
        line = line .. "; kept " .. tostring(kept) .. ", removed " .. tostring(removed)
      end
      if #file.unknown_tables > 0 then
        line = line .. "; unknown tables kept: " .. table.concat(file.unknown_tables, ", ")
      end
      if #file.removed_set_aside > 0 then
        line = line .. "; retired files removed: " .. table.concat(file.removed_set_aside, ", ")
      end
      lines[#lines + 1] = line
    end
    local digest = report.digest
    if digest ~= nil then lines[#lines + 1] = "digest " .. digest end
    local fresh = report.fresh
    if fresh ~= nil then lines[#lines + 1] = "fresh " .. tostring(fresh) end
    output = table.concat(lines, "\n") .. "\n"
  end
  if not bare.delivered(complain, to.out(output)) then return 1 end
  return if complete then 0 else 1 end
end

verb.spec = {
  name = "cache", run = verb.run, bare = true,
  takes = "trim, compiles or verdicts, and explicit absolute cache paths",
  exits = "`cache` prints maintenance results, or one JSON report, and exits 0 when complete, 1 when incomplete, and 2 for an invalid command line.",
  passthrough = "its report is data for CI; exit status says whether maintenance completed (build/cache_test.tl)",
  guide = "none: shared-cache maintenance for CI, independent of a candidate project",
  tests = { "build.cache_test", "build.cache_tool_test" },
}

return verb

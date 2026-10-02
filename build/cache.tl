--- The running tool's shared-cache maintenance, independent of any project.

local Cli = require("cosmic.cli")
local Flags = require("cosmic.flags")
local Json = require("cosmic.json")
local bare = require("build.bare")
local maintenance = require("build.cache_maintenance")
local verb_spec = require("build.verb_spec")

local record verb
  spec: verb_spec.Spec
  record Io
    out: function(string): boolean, string
    err: function(string)
  end
end

local standard: verb.Io = { out = bare.out, err = bare.err }
local usage = "cosmic cache trim compiles PATH --since-ns N [--restored PATH] [--json]; " ..
  "cosmic cache trim verdicts PATH... (--since-ns N | --whole) [--json]"

--- Runs the explicit operation; neither a cache path nor a cutoff is inferred.
function verb.run(argv: {integer:string}, io?: verb.Io): integer
  local to = io or standard
  local complain = bare.complainer("cache", to.err)
  local function refuse(why: string): integer
    complain(why .. "; " .. usage)
    return 2
  end
  local parsed, why = Flags.parse(argv, 2, Cli.verbs.cache.spec)
  if parsed == nil then return refuse(why) end
  if parsed.words[1] ~= "trim" then return refuse("give the trim operation") end
  local family = parsed.words[2]
  if not (family is maintenance.Family) then return refuse("give compiles or verdicts") end
  local paths: {string} = {}
  for i = 3, #parsed.words do
    local path = parsed.words[i]
    if path:sub(1, 1) ~= "/" or path:find("\0", 1, true) then
      return refuse("cache paths must be absolute and contain no NUL")
    end
    paths[#paths + 1] = path
  end
  if #paths == 0 or (family == "compiles" and #paths ~= 1) then
    return refuse("compiles takes one path; verdicts takes one or more")
  end
  local whole = parsed.set["--whole"] == true
  local since: integer
  local raw_since = parsed.values["--since-ns"]
  if raw_since ~= nil then
    if not raw_since:match("^%d+$") then return refuse("since-ns must be a nonnegative integer") end
    since = math.tointeger(tonumber(raw_since))
    if since == nil or since < 0 then return refuse("since-ns is outside the integer range") end
  end
  if whole == (since ~= nil) or (whole and family ~= "verdicts") then
    return refuse("give --since-ns, or --whole for verdicts only")
  end
  local restored = parsed.values["--restored"]
  if restored ~= nil and (family ~= "compiles" or restored:sub(1, 1) ~= "/" or
      restored:find("\0", 1, true)) then
    return refuse("restored is an absolute snapshot path for compiles only")
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
    Json.array(report.files)
    Json.array(report.warnings)
    for _, file in ipairs(report.files) do
      Json.array(file.unknown_tables)
      Json.array(file.unstamped_tables)
      Json.array(file.removed_set_aside)
    end
    output = assert(Json.encode(report)) .. "\n"
  else
    local lines: {string} = {}
    for _, file in ipairs(report.files) do
      local line = file.path .. ": " .. file.state
      if file.kept ~= nil then line = line .. "; kept " .. file.kept .. ", removed " .. file.removed end
      if #file.unknown_tables > 0 then line = line .. "; unknown tables kept: " .. table.concat(file.unknown_tables, ", ") end
      if #file.removed_set_aside > 0 then line = line .. "; retired files removed: " .. table.concat(file.removed_set_aside, ", ") end
      lines[#lines + 1] = line
    end
    if report.digest ~= nil then lines[#lines + 1] = "digest " .. report.digest end
    if report.fresh ~= nil then lines[#lines + 1] = "fresh " .. report.fresh end
    output = table.concat(lines, "\n") .. "\n"
  end
  if not bare.delivered(complain, to.out(output)) then return 1 end
  return complete and 0 or 1
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

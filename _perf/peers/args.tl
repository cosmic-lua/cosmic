--- Command-line parsing for _perf/peers/run.tl, split out to keep that
--- file to the CLI's control flow: the flag spec, parsing, and the
--- --bin resolution precedence (--bin, then PERF_BIN, then arg[-1]).

local flags = require("cosmic.flags")
local fs = require("cosmic.fs")
local harness = require("_perf.harness")

local USAGE < const > = [[
usage: run.lua [--bin PATH] [--out FILE] [--md FILE] [--samples N]
               [--min-secs S] [--only ID]
]]

local SPEC: flags.Spec = {
  name = "run.lua",
  flags = {
    {long = "bin", arg = "PATH",
      help = "cosmic binary to measure (default: PERF_BIN, else the running interpreter)"},
    {long = "out", arg = "FILE", help = "write JSON results here"},
    {long = "md", arg = "FILE", help = "write the rendered markdown table here"},
    {long = "samples", arg = "N", help = "samples per peer"},
    {long = "min-secs", arg = "S", help = "minimum sample duration"},
    {long = "only", arg = "ID", help = "measure only the peer with this exact id"},
  },
}

local record Args
  bin: string
  out: string
  md: string
  samples: integer
  min_secs: number
  only: string
  help: boolean
  err: string
end

--- Parse command-line arguments.
--- @param argv {string} Raw arguments
--- @return Args Parsed arguments; Args.err is set on parse failure
local function parse_args(argv: {string}): Args
  local a: Args = {
    samples = harness.DEFAULT_SAMPLES,
    min_secs = harness.DEFAULT_MIN_SAMPLE_SECS,
  }
  local parsed, perr = flags.parse(SPEC, argv)
  if not parsed then
    a.err = "argument parse failed: " .. tostring(perr)
    return a
  end
  a.bin = parsed.values["bin"]
  a.out = parsed.values["out"]
  a.md = parsed.values["md"]
  if parsed.values["samples"] then
    local n = math.tointeger(tonumber(parsed.values["samples"]))
    if n == nil or n < 1 then
      a.err = "--samples requires a positive integer, got: "
      .. tostring(parsed.values["samples"])
    else
      a.samples = n
    end
  end
  if parsed.values["min-secs"] then
    local secs = tonumber(parsed.values["min-secs"])
    if secs == nil or secs <= 0 then
      a.err = "--min-secs requires a positive number, got: "
      .. tostring(parsed.values["min-secs"])
    else
      a.min_secs = secs
    end
  end
  a.only = parsed.values["only"]
  a.help = parsed.help
  return a
end

--- Locate the cosmic binary to measure. --bin wins; then PERF_BIN; then
--- the interpreter running this script (arg[-1]).
--- @param explicit string The --bin flag's value, if given
--- @return string | nil Path to the binary, or nil if none was found
local function find_bin(explicit: string): string | nil
  if explicit and #explicit > 0 then
    return explicit
  end
  local envbin = os.getenv("PERF_BIN")
  if envbin and #envbin > 0 then
    return envbin
  end
  local last = rawget(arg, -1)
  if last is string then
    return last
  end
  return nil
end

--- Create the parent directory of `path`, if it does not already exist.
--- @param path string A file path about to be written
--- @return boolean Success
--- @return string Reason, on failure
local function ensure_parent(path: string): boolean, string
  local dir = fs.dirname(path)
  if dir == "" or fs.is_dir(dir) then
    return true
  end
  return fs.make_dirs(dir)
end

local record args_module
  type Args = Args
  USAGE: string
  parse_args: function(argv: {string}): Args
  find_bin: function(explicit: string): string | nil
  ensure_parent: function(path: string): boolean, string
end

local M: args_module = {
  USAGE = USAGE,
  parse_args = parse_args,
  find_bin = find_bin,
  ensure_parent = ensure_parent,
}

return M

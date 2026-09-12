--- Journal the diagnostic child's most recent execution checkpoint.
--- A Context belongs to one run; it never attributes bytes to the original child.
local checkpoint = require("_fuzz.checkpoint")
local fs = require("cosmic.fs")
local source = require("_fuzz.source")

local record Context
  path: string
  seed: integer
  iters: integer
  iteration: integer
  stage: integer
  draws: integer
  failed: boolean
  error: string
end

local function new(dir: string, seed: integer, iters: integer): Context
  return {path = fs.join(dir, "checkpoint"), seed = seed, iters = iters,
    iteration = 1, stage = 1, draws = 0, failed = false, error = ""}
end

local function configure(context: Context, iteration: integer, stage: integer)
  context.iteration, context.stage = iteration, stage
end

local function publish(context: Context, phase: integer, input: string, draws: integer): boolean
  if context.failed then return false end
  local ok, err = checkpoint.write(context.path, {
      seed = context.seed, iters = context.iters, iteration = context.iteration,
      phase = phase, stage = context.stage, draws = draws, input = input,
    })
  if not ok then
    context.failed, context.error = true, err
    return false
  end
  return true
end

local function generating(context: Context): boolean
  context.draws = 0
  return publish(context, 1, "", 0)
end

local function generated(context: Context, recorder: source.Recorder)
  context.draws = #recorder.draws
end

local function checking(context: Context, input: string): boolean
  return publish(context, 2, input, context.draws)
end

local function between(context: Context): boolean
  return publish(context, 3, "", 0)
end

local record ObserveModule
  type Context = Context
  new: function(dir: string, seed: integer, iters: integer): Context
  configure: function(context: Context, iteration: integer, stage: integer)
  generating: function(context: Context): boolean
  generated: function(context: Context, recorder: source.Recorder)
  checking: function(context: Context, input: string): boolean
  between: function(context: Context): boolean
end

local M: ObserveModule = {new = new, configure = configure, generating = generating,
  generated = generated, checking = checking, between = between}
return M

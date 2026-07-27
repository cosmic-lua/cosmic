--- The help surface: which verbs exist, and how to say so.
---
--- Split from the registry because it is what a PERSON reads, and the
--- registry is what the dispatcher walks. `--make help` is answered
--- from here, before a project is opened -- "what are the verbs" is the
--- question you have when you are not yet standing in one.

local types = require("_make.types")

local type Verb = types.Verb

--- The registry, injected: this module reads the rows, and the
--- registry file owns them.
local rows: {Verb} = {}

--- Point the help surface at the registry.
--- @param verbs {Verb} The registry rows, in order
local function bind(verbs: {Verb})
  rows = verbs
end

--- The verb names of one disposition, in registry order.
--- @param planned boolean Whether to list the planned verbs
--- @return {string} The names
local function names(planned: boolean): {string}
  local out: {string} = {}
  for _, v in ipairs(rows) do
    if (v.planned or false) == planned then
      out[#out + 1] = v.name
    end
  end
  return out
end

--- Usage: what `help` prints, and what a bare `--make` or an unknown
--- verb prints to explain itself.
---
--- `help` is named here rather than in `VERBS` because every registered
--- verb is dispatched against an open project, and the one question a
--- reader asks from outside a project root is what the verbs are.
--- @return string The usage text, without a trailing newline
local function usage(): string
  return "usage: cosmic --make <verb> [paths…]\n" ..
  "make: verbs: " .. table.concat(names(false), ", ") .. ", help\n" ..
  "make: planned: " .. table.concat(names(true), ", ")
end

local record HelpModule
  bind: function(verbs: {Verb})
  names: function(planned: boolean): {string}
  usage: function(): string
end

local M: HelpModule = {
  bind = bind,
  names = names,
  usage = usage,
}

return M

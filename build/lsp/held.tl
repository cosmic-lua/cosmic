--- The program a session of `cosmic lsp` ([`build.lsp.check`]) checks its documents in under the new checker
--- (`COSMIC_GRAMMAR=new`, [`build.grammar_mode`]): one [`Driver.Build`] for the project, kept between checks, in which the
--- document being checked is the module's full source and every other module is the stub it serves its dependents
--- ([`build.lsp.source`]).
---
--- A check puts the document's text in the program ([`Driver.Build.replace`]), which lowers the modules again from the
--- syntax they already have, and not the document's requires from their sources: what an edit costs is the standard
--- library's declarations, the stubs the document reaches, and the document. Moving to another document puts the
--- document just checked back as the stub it serves, so that the program reads each module as a build reads it for its
--- dependents. A module that is served otherwise than it was (an open document edited, the stage derived another stub) is
--- put in the same way ([`held.put`]).
---
--- A program cannot forget a module, so the session makes it again (`dead` of [`held.Program`]) when one is lost: a module the
--- stage no longer lists, or a document that stood for a file the stage does not list and is left.
local Driver = require("build.driver")
local Pipeline = require("build.pipeline")
local TreeProgram = require("build.tree_program")

local record held
  --- The document being checked: the module it is and the source the program was given for it.
  record Focus
    module: string
    source: Driver.Source
  end

  --- Where the program finds the document being checked, which it reads in place of what serves the module.
  record Slot
    focus: Focus?
  end

  --- One session's program.
  record Program
    options: Pipeline.Options
    build: Driver.Build
    --- What answers a `require`: the document being checked, then what serves the module.
    standard: Driver.Provider
    slot: Slot
    --- What serves the module `module` to the program as the stub it serves its dependents (nil where none does).
    serve: function(module: string): Driver.Source?
    --- Whether the program holds a module it should not, so the next check makes it again.
    mut dead: boolean
  end
end

local type Program = held.Program

--- Nothing of the index is left out.
local function none(_: string): boolean
  return false
end

--- A program over the options `options`, whose modules but the document are served by `serve`.
function held.new(options: Pipeline.Options, serve: function(module: string): Driver.Source?): Program
  local slot: held.Slot = { focus = nil }
  local index = Driver.index({}, none)
  --- The document's source while it is the focus, then what serves the module.
  local function provider(module: string): Driver.Source?
    local focus = slot.focus
    if focus ~= nil and focus.module == module then return focus.source end
    return serve(module)
  end
  local build = TreeProgram.build(index, options.globals, true, nil, provider)
  return {
    options = options,
    build = build,
    standard = provider,
    slot = slot,
    serve = serve,
    dead = false,
  }
end

--- Puts `text`, a module's text as the program reads it, in place of what the program holds of `module`, which it must have met.
local function replaced(self: Program, module: string, text: string)
  local outcome = self.build:parsed(module)
  if outcome == nil then
    self.dead = true
    return
  end
  if outcome.text ~= text then self.build:replace(module, text) end
end

--- Puts the source `served` in the program as the module it is, as the stub it serves: for a module that is served otherwise
--- than it was. The document being checked is the program's reading of its module, which nothing served changes.
function held.put(self: Program, served: Driver.Source)
  local focus = self.slot.focus
  if focus ~= nil and focus.module == served.module then return end
  replaced(self, served.module, served.text)
end

-- TODO: keep the declarations of the standard library and of the stubs across an edit, once a [`Declarations.Program`] can forget
-- a module (the TODO of [`Driver.Build.replace`]): every replacement begins a program, so an edit lowers them again, about
-- 90 ms of the ~150 ms an edit of build/lsp/check.tl takes on the 4-core host (a leaf document needs none of it again).

--- Makes the module `source` is the document being checked, and the module that was before it the stub it serves again.
--- Answers the program's reading of the document, or nil where the program lost a module on the way (`dead`): it holds the
--- document it left as full source still, so nothing is checked in it, and the caller makes the program again.
function held.document(self: Program, source: Driver.Source): Driver.Outcome?
  local before = self.slot.focus
  if before ~= nil and before.module ~= source.module then
    local served = self.serve(before.module)
    if served == nil then
      -- The module left is served no more (a document of a file the stage does not list, a template that does not compile).
      self.dead = true
      return nil
    else
      replaced(self, before.module, served.text)
    end
  end
  self.slot.focus = { module = source.module, source = source }
  local outcome = self.build:parsed(source.module)
  if outcome == nil then
    return nil
  end
  -- A module the program just met was read from the source given; one it held is read from the text again.
  if outcome.source ~= source then return self.build:replace(source.module, source.text) end
  return outcome
end

--- Puts `text` in place of the document's, which the calls of [`Shape.record_of`] it makes are resolved in.
function held.respell(self: Program, text: string): Driver.Outcome?
  local focus = self.slot.focus
  if focus == nil then return nil end
  return self.build:replace(focus.module, text)
end

--- The program as [`Pipeline.review`] reads it for the document `text`, the file `file`, the module `module`: the index it
--- judges a standard-library module's stub by is made of the document alone.
function held.built(self: Program, file: string, text: string, module: string, tests: boolean): Pipeline.Built
  local index = Driver.index({ { file, text, module } }, none, function(_: string, _: string): Driver.Extra
    return { tests = tests }
  end)
  return { build = self.build, ceilings = self.options.ceilings, index = index, globals = self.options.globals,
    standard = self.standard, types = true, given = {}, stubs = nil, stubbed = nil }
end

return held

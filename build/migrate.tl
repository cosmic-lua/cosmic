--- `cosmic migrate`, removed: the verb that rewrote a project written in the fork's grammar into the new checker's. The
--- tool reads the new grammar alone, and a project still in the old one is rewritten to it by hand, which
--- [`doc/guides/project.md`] ("moving a project to the new grammar") says how to do. The verb stays so that a script
--- that still runs it is told so, not left with "no such verb".
local Fs = require("cosmic.fs")
local bare = require("build.bare")
local verb_spec = require("build.verb_spec")

local record Migrate
  --- What the verb says in place of what it did.
  mut MESSAGE: string

  --- The `cosmic migrate` command line, whatever it is: says the verb was removed, and answers 2.
  main: function(argv: {string}, err?: function(text: string)): integer

  --- The verb's registration: see build/verb_spec.tl.
  mut spec: verb_spec.Spec
end

Migrate.MESSAGE = "cosmic migrate was removed. The tool reads the new grammar only: rewrite a project written in the fork's " ..
  "grammar to it by hand, as doc/guides/project.md (\"moving a project to the new grammar\") says."

function Migrate.main(_argv: {string}, err?: function(text: string)): integer
  if err ~= nil then
    err(Migrate.MESSAGE .. "\n")
  else
    local _, _ = Fs.put(Fs.stderr, Migrate.MESSAGE .. "\n")
  end
  return bare.refused
end

--- The `migrate` verb as [`build/verb_list.tl`] lists it. It reads nothing, so it is never stale-checked.
Migrate.spec = {
  name = "migrate",
  guide = "none: the verb was removed; it says so and exits 2",
  tests = { "build.migrate_test" },
  run = function(argv: {string}): integer return Migrate.main(argv) end,
  bare = true,
  takes = "nothing: the verb was removed",
  exits = "`migrate` says that it was removed and exits 2, whatever it is given.",
  passthrough = "it does nothing but say it was removed, so there is no pass or fail to hold it to (build/migrate_test.tl)",
}

return Migrate

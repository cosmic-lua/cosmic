--- The verbs `cosmic` dispatches to a module of their own, in the order
--- `cosmic help exit` lists them after the verbs that name a file to run
--- (`run`, `standalone`, `eval`, `version`) and before `help`, which
--- build/dispatch.tl holds itself. Each entry loads its module's `spec`
--- (build/verb_spec.tl) only when asked, so a command line loads the one
--- verb it runs.
---
--- Adding a verb takes a module with a `spec`, a line here, its
--- `Cli.<name>` prose and options, and its place in `Cli.order`
--- (build/verb_list_test.tl holds the list, `Cli.order` and the verbs
--- dispatch reaches to agree). The spec also names a `guide` and `tests`
--- (build/tree_checks.tl's `verbs` holds them to the quickstart and the
--- tree's tests).

local verb_spec = require("build.verb_spec")

local record verb_list
  --- A verb and how to load its spec.
  record Entry
    name: string
    load: function(): verb_spec.Spec
  end

  --- Each verb, in help's order.
  entries: {Entry}
end

verb_list.entries = {
  { name = "sandbox", load = function(): verb_spec.Spec return require("build.sandbox").spec end },
  { name = "test", load = function(): verb_spec.Spec return require("build.test").spec end },
  { name = "fix", load = function(): verb_spec.Spec return require("build.fix").spec end },
  { name = "build", load = function(): verb_spec.Spec return require("build.embed").spec end },
  { name = "db", load = function(): verb_spec.Spec return require("build.databases").spec end },
  { name = "sql", load = function(): verb_spec.Spec return require("build.sql").spec end },
  { name = "cache", load = function(): verb_spec.Spec return require("build.cache").spec end },
  { name = "json", load = function(): verb_spec.Spec return require("build.json").spec end },
  { name = "hash", load = function(): verb_spec.Spec return require("build.hash").spec end },
  { name = "codec", load = function(): verb_spec.Spec return require("build.codec").spec end },
  { name = "archive", load = function(): verb_spec.Spec return require("build.archive").spec end },
  { name = "fetch", load = function(): verb_spec.Spec return require("build.fetch").spec end },
  { name = "time", load = function(): verb_spec.Spec return require("build.time").spec end },
  { name = "rand", load = function(): verb_spec.Spec return require("build.rand").spec end },
  { name = "docs", load = function(): verb_spec.Spec return require("build.docs").spec end },
  { name = "uses", load = function(): verb_spec.Spec return require("build.docs").uses_spec end },
  { name = "todos", load = function(): verb_spec.Spec return require("build.todos").spec end },
  { name = "bom", load = function(): verb_spec.Spec return require("build.bom").spec end },
  { name = "refresh", load = function(): verb_spec.Spec return require("build.refresh").spec end },
}

--- Every verb's spec, in help's order.
function verb_list.specs(): {verb_spec.Spec}
  local specs: {verb_spec.Spec} = {}
  for _, entry in ipairs(verb_list.entries) do
    specs[#specs + 1] = entry.load()
  end
  return specs
end

--- The spec of the verb `name`, loading that verb's module alone, or nil
--- when no listed verb has that name.
function verb_list.find(name: string): verb_spec.Spec | nil
  for _, entry in ipairs(verb_list.entries) do
    if entry.name == name then
      return entry.load()
    end
  end
  return nil
end

return verb_list

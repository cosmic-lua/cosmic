--- The verbs `cosmic` dispatches to a module of their own, each by how
--- to load its `spec` (build/verb_spec.tl), loaded only when asked, so a
--- command line loads the one verb it runs. The verbs that name a file
--- to run (`run`, `standalone`, `eval`, `version`) have none, and `help`
--- is build/dispatch.tl's own. It also names the verbs that run at the
--- root of their tree (`tree_paths`), so a verb not among them loads no
--- [`build.tree_root`].
---
--- Adding a verb takes a module with a `spec`, a line here, and in
--- [`cosmic.cli`] its prose, its `verbs` entry and its place in a group,
--- which sets its order in help (build/verb_list_test.tl holds the
--- verbs here to be those groups name). The spec also names a `guide`
--- and `tests` (build/tree_checks.tl's `verbs` holds them to the
--- quickstart and the tree's tests).

local verb_spec = require("build.verb_spec")

local record verb_list
  --- How to load a verb's spec.
  type Load = function(): verb_spec.Spec

  --- How to load each verb's spec, by its name.
  loads: {string: Load}

  --- The verbs that run at the root of the tree they are started in ([`build.tree_root`]), each by which of its
  --- words are paths to read from where it was started: all of them ("all"), all but the first ("rest"), only those
  --- naming something that exists ("named"), or none that matter ("none": `docs`). `sql` looks in the working
  --- directory only, by its documentation. Kept here, which every verb's command line loads, so a verb not among them
  --- loads no [`build.tree_root`].
  tree_paths: {string: string}
end

verb_list.tree_paths = {
  test = "named", fix = "all", build = "all", db = "all", uses = "rest", todos = "named",
  docs = "none",
}

verb_list.loads = {
  test = function(): verb_spec.Spec return require("build.test").spec end,
  fix = function(): verb_spec.Spec return require("build.fix").spec end,
  build = function(): verb_spec.Spec return require("build.embed").spec end,
  db = function(): verb_spec.Spec return require("build.databases").spec end,
  lsp = function(): verb_spec.Spec return require("build.lsp").spec end,
  sql = function(): verb_spec.Spec return require("build.sql").spec end,
  cache = function(): verb_spec.Spec return require("build.cache").spec end,
  json = function(): verb_spec.Spec return require("build.json").spec end,
  hash = function(): verb_spec.Spec return require("build.hash").spec end,
  codec = function(): verb_spec.Spec return require("build.codec").spec end,
  archive = function(): verb_spec.Spec return require("build.archive").spec end,
  fetch = function(): verb_spec.Spec return require("build.fetch").spec end,
  time = function(): verb_spec.Spec return require("build.time").spec end,
  rand = function(): verb_spec.Spec return require("build.rand").spec end,
  qr = function(): verb_spec.Spec return require("build.qr").spec end,
  acme = function(): verb_spec.Spec return require("build.acme").spec end,
  tailscale = function(): verb_spec.Spec return require("build.tailscale").spec end,
  mcp = function(): verb_spec.Spec return require("build.mcp").spec end,
  compile = function(): verb_spec.Spec return require("build.compile").spec end,
  docs = function(): verb_spec.Spec return require("build.docs").spec end,
  uses = function(): verb_spec.Spec return require("build.docs").uses_spec end,
  todos = function(): verb_spec.Spec return require("build.todos").spec end,
  bom = function(): verb_spec.Spec return require("build.bom").spec end,
  refresh = function(): verb_spec.Spec return require("build.refresh").spec end,
  release = function(): verb_spec.Spec return require("build.release").spec end,
  sandbox = function(): verb_spec.Spec return require("build.sandbox").spec end,
  agent = function(): verb_spec.Spec return require("build.agent").spec end,
}

--- Every verb's spec, in help's order ([`cosmic.cli.order`]).
function verb_list.specs(): mut {verb_spec.Spec}
  local Cli = require("cosmic.cli")
  local specs: mut {verb_spec.Spec} = {}
  for _, name in ipairs(Cli.order) do
    local loader = verb_list.loads[name]
    if loader ~= nil then specs[#specs + 1] = loader() end
  end
  return specs
end

--- The spec of the verb `name`, loading that verb's module alone, or nil
--- when no listed verb has that name.
function verb_list.find(name: string): verb_spec.Spec?
  local loader = verb_list.loads[name]
  if loader == nil then return nil end
  return loader()
end

return verb_list

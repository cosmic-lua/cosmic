--- The workflows under .github/workflows/, and the local actions under
--- .github/actions/ (each an `action.yml`), every one written in YAML's
--- flow style: each opens with `{` after its leading comments, and keeps
--- to the subset that YAML and JSON5 read with `#` comments
--- (`cosmic.json`'s `hash_comments`) read alike, so the tree can read
--- what GitHub runs without a YAML parser. A step's script longer than a
--- line or two lives under .github/scripts/, where it reads as a script
--- rather than as one string of `\n`-joined lines; an action's is one
--- line. Each is also in [`build.flow`]'s layout, which `cosmic fix`
--- writes.
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Shape = require("cosmic.shape")
local Test = require("cosmic.test")
local flow = require("build.flow")
local String = require("cosmic.string")

--- The workflows and actions, and the programs and pins they name.
Test.policy{
  grants = {
    { path = ".github/", letters = "r" },
    { path = "bin/cosmic-bootstrap", letters = "r" },
    { path = "ci/cosmic-driver.pin", letters = "r" },
    { path = "ci/cosmic_ci", letters = "r" },
    { path = "ci/images", letters = "r" },
  },
}

local DIR <const> = ".github/workflows"
local ACTIONS <const> = ".github/actions"
local READ <const>: Json.DecodeOptions = { json5 = true, hash_comments = true }

--- A step; `with` holds strings, booleans and numbers, so its values stay `any`.

-- TODO: type `with` per action, as that action's declared inputs, once the
-- tree holds a table of the actions the workflows use.
local record Step
  id?: string
  name?: string
  uses?: string
  run?: string
  shell?: string
  ["if"]?: string
  ["working-directory"]?: string
  ["continue-on-error"]?: boolean
  ["timeout-minutes"]?: integer
  env?: {string: string}
  with?: {string: any}
end
local record Strategy
  ["fail-fast"]?: any
  matrix?: {string: any}
end
local record Job
  name?: string
  ["runs-on"]?: string
  needs?: any
  ["if"]?: string
  ["timeout-minutes"]?: integer
  env?: {string: string}
  outputs?: {string: string}
  permissions?: {string: string}
  defaults?: {string: {string: string}}
  ["continue-on-error"]?: boolean
  container?: any
  concurrency?: {string: any}
  strategy?: Strategy
  steps: {Step}
end
local record Branches
  paths?: {string}
  ["paths-ignore"]?: {string}
  branches?: {string}
end
local record Workflow
  name: string
  ["on"]: {string: any}
  env?: {string: string}
  permissions?: {string: string}
  concurrency?: {string: any}
  defaults?: {string: {string: string}}
  jobs: {string: Job}
end
local record Runs
  using: string
  steps: {Step}
end
local record Action
  name: string
  description?: string
  inputs?: {string: any}
  outputs?: {string: {string: string}}
  runs: Runs
end
local BRANCHES <const> = Shape.record_of("Branches")
local WORKFLOW <const> = Shape.record_of("Workflow")
local ACTION <const> = Shape.record_of("Action")
local STEP <const> = Shape.record_of("Step")

--- The `typed` record `text` holds, read once; a file of another shape, or
--- with a key no record names, fails, naming `path`.

-- TODO: ask the shape for a strict record, and drop the re-encoding below,
-- once [`Shape.record_of`] has a strict form (cosmic/shape.tl carries the TODO).
local function read_as<T>(typed: Shape.Typed<T>, path: string, text: string): T
  local raw = assert(Json.decode(text, READ))
  local record, err = typed:into(raw)
  assert(record, path .. ": " .. tostring(err))
  local kept, given = assert(Json.encode_any(record)), assert(Json.encode_any(raw))
  local at = 1
  while kept:byte(at) == given:byte(at) and at <= #given do at = at + 1 end
  assert(kept == given, path .. ": a key no record names, or a number it writes otherwise, near " ..
      given:sub(math.max(at - 40, 1), at + 40))
  return record
end

--- Of `paths`, the ones in flow style, each with its text: a file whose
--- first line that is neither blank nor a comment opens with `{` or
--- `[` ([`flow.is_flow`]).
local function flow_files(paths: {string}): {string: string}
  local out: mut {string: string} = {}
  for _, path in ipairs(paths) do
    local text = (assert(Fs.read(path)))
    if flow.is_flow(text) then out[path] = text end
  end
  return out
end

--- The flow-style workflows: each file under DIR in flow style, with its
--- text.
local function flow_workflows(): {string: string}
  local paths: mut {string} = {}
  for _, name in ipairs((assert(Fs.list(DIR)))) do
    if name:match("%.ya?ml$") then paths[#paths + 1] = DIR .. "/" .. name end
  end
  return flow_files(paths)
end

--- Every local action's metadata file: each `action.yml` or
--- `action.yaml` under ACTIONS, at any depth.
local function action_paths(): {string}
  local paths: mut {string} = {}
  if Fs.is_dir(ACTIONS) ~= true then return paths end
  for _, relative in ipairs((assert(Fs.walk(ACTIONS)))) do
    local name = relative:match("[^/]+$")
    if name == "action.yml" or name == "action.yaml" then
      paths[#paths + 1] = ACTIONS .. "/" .. relative
    end
  end
  return paths
end

local function test_flow_workflows_keep_to_the_shared_subset()
  local count = 0
  for path, text in pairs(flow_workflows()) do
    count = count + 1
    local found = flow.problems(text)
    assert(#found == 0, path .. ": " .. table.concat(found, "; "))
    read_as(WORKFLOW, path, text)
  end
  assert(count > 0, "no workflow under " .. DIR .. " is in flow style")
end

--- Every workflow under DIR is in flow style, so none can drift back to
--- a block style the subset check never sees.
local function test_every_workflow_is_in_flow_style()
  local workflows = flow_workflows()
  for _, name in ipairs((assert(Fs.list(DIR)))) do
    local path = DIR .. "/" .. name
    assert(workflows[path] ~= nil, path .. " is not in flow style")
  end
end

--- Each local action keeps to the same subset, and is a composite
--- action whose `run` steps each name their shell -- a job's
--- `defaults.run` does not reach them -- and are one line: a longer
--- script lives under .github/scripts/.
local function test_flow_actions_keep_to_the_shared_subset()
  local actions = flow_files(action_paths())
  local count = 0
  for path, text in pairs(actions) do
    count = count + 1
    local found = flow.problems(text)
    assert(#found == 0, path .. ": " .. table.concat(found, "; "))
    local runs = read_as(ACTION, path, text).runs
    assert(runs.using == "composite", path .. ": not a composite action")
    assert(#runs.steps > 0, path .. ": no steps")
    for i, step in ipairs(runs.steps) do
      local run = step.run
      if run ~= nil then
        assert(not run:find("\n", 1, true),
          path .. ": step " .. tostring(i) .. "'s run is not one line: put it under .github/scripts/")
        assert(step.shell ~= nil, path .. ": step " .. tostring(i) .. " runs with no shell")
      end
    end
  end
  for _, path in ipairs(action_paths()) do
    assert(actions[path] ~= nil, path .. " is not in flow style")
  end
  assert(count > 0, "no action under " .. ACTIONS)
end

--- The expressions in an action's text: each `${{ ... }}`, and each
--- step's `if`, which is one whole without them.
local function expressions(text: string, action: Action): {string}
  local out: mut {string} = {}
  for expression in text:gmatch("%${{(.-)}}") do out[#out + 1] = expression end
  for _, step in ipairs(action.runs.steps) do
    local condition = step["if"]
    if condition ~= nil and not condition:find("${{", 1, true) then
      out[#out + 1] = condition
    end
  end
  return out
end

--- The inputs `expression` reads, as `inputs.<name>` or
--- `inputs['<name>']`.
local function inputs_read(expression: string): {string}
  local out: mut {string} = {}
  for name in expression:gmatch("inputs%.([%w_%-]+)") do out[#out + 1] = name end
  for name in expression:gmatch("inputs%[%s*['\"]([^'\"]+)['\"]%s*%]") do out[#out + 1] = name end
  return out
end

--- Each input an action's expressions read is one it declares: a
--- misspelt input reads as empty.
-- TODO: hold the other expressions in the workflows and actions, as
-- actionlint would: that each context one names is available where it
-- stands, that `needs.<job>` names a job its job needs, that
-- `steps.<id>` names a step before it, and that `with` passes a local
-- action only inputs it declares. Only an action's
-- `inputs` are held today, so such a mistake fails at the run.
local function test_an_action_reads_only_the_inputs_it_declares()
  local count = 0
  for path, text in pairs(flow_files(action_paths())) do
    local action = read_as(ACTION, path, text)
    local names = action.inputs or {}
    for _, expression in ipairs(expressions(text, action)) do
      for _, name in ipairs(inputs_read(expression)) do
        count = count + 1
        assert(names[name] ~= nil, path .. " reads inputs." .. name .. ", which it does not declare")
      end
    end
  end
  assert(count > 0, "no action reads an input")
end

local function test_an_input_is_read_however_it_is_written()
  local action = read_as(ACTION, "synthetic", [=[{ name: "a", runs: { using: "composite", steps: [
    { "if": "inputs.owner != ''" }, { "if": "${{ inputs.a }}" } ] } }]=])
  local got = expressions("${{ inputs['b'] }} ${{ inputs.a }}", action)
  assert(#got == 3 and got[3] == "inputs.owner != ''", table.concat(got, "|"))
  local names = inputs_read([=[inputs.zig-cache == 'true' && inputs[ "x y" ] || inputs['z']]=])
  assert(table.concat(names, ",") == "zig-cache,x y,z", table.concat(names, ","))
end

--- Each decoded flow-style workflow, by path.
local function decoded_workflows(): {string: Workflow}
  local out: mut {string: Workflow} = {}
  for path, text in pairs(flow_workflows()) do
    out[path] = read_as(WORKFLOW, path, text)
  end
  return out
end

local function ci_workflow(): Workflow
  return (assert(decoded_workflows()[DIR .. "/ci.yml"]))
end

local function step_with_id(steps: {Step}, id: string): Step, integer
  for i, step in ipairs(steps) do
    if step["id"] == id then return step, i end
  end
  error("no step has the id " .. id)
end

local function step_named(steps: {Step}, name: string, where?: string): Step, integer
  for i, step in ipairs(steps) do
    if step.name == name then return step, i end
  end
  error((where or "") .. "no step is named " .. name)
end

local function job_of(jobs: {string: Job}, name: string): Job
  return (assert(jobs[name], "no job " .. name))
end

local function with_of(step: Step): {string: any}
  return step.with or {}
end

--- The string input `key` of `step`'s `with`; a step that has none fails.
local function param(step: Step, key: string): string
  local value = with_of(step)[key]
  assert(value is string, "step " .. tostring(step.name or step.uses) .. " has no input " .. key)
  return value
end

local function map_of(map: {string: string}?): {string: string}
  return map or {}
end

--- The kinds of run the platform job's legs differ by, in the order its
--- `include` expression chooses between them: the merge queue's and a pull
--- request's (`queue`), a push to main's (`push`), and every other (`full`:
--- the scheduled and a manual run).
local KIND_CHOICE <const> = "^%${{ fromJSON%(%(github%.event_name == 'merge_group' || github%.event_name == 'pull_request'%) && " ..
  "'(%[[^']-%])' || github%.event_name == 'push' && '(%[[^']-%])' || '(%[[^']-%])'%) }}$"

local function strings_of(value: any, what: string): {string}
  local list, err: {string}?, string = Shape.into(value, Shape.list(Shape.string))
  return (assert(list, what .. ": " .. err))
end

local function needs_of(job: Job): {string}
  local needs = job.needs
  if needs == nil then return {} end
  if needs is string then return { needs } end
  return strings_of(needs, "needs")
end

--- `map`'s values as text: a string as it is, any other value as `json:` and
--- its JSON, so a boolean never equals the string that spells it.
local function texts_of(map: {string: any}): {string: string}
  local out: mut {string: string} = {}
  for k, v in pairs(map) do
    out[k] = if v is string then v else "json:" .. assert(Json.encode_any(v)) end
  end
  return out
end

--- A matrix's `include` or `exclude` entries, each value as its text.
local function entries_of(value: any): {{string: string}}
  if value == nil then return {} end
  local list, err: {{string: any}}?, string = Shape.into(value, Shape.list(Shape.map(Shape.any)))
  local out: mut {{string: string}} = {}
  for _, entry in ipairs((assert(list, "a matrix entry: " .. err))) do
    out[#out + 1] = texts_of(entry)
  end
  return out
end

--- A matrix's combinations on a run of `kind` (`queue` or `full`,
--- [`KIND_CHOICE`]), each the values it gets, as GitHub's docs
--- ("Expanding or adding matrix configurations") expand them: every
--- combination of the dimensions, less each one an `exclude` entry matches (every
--- dimension it names holds the value it gives, a partial match), then
--- each `include` entry added to every one of those
--- original combinations whose dimensions it does not contradict,
--- overwriting what an earlier entry added, or, where it contradicts
--- all of them, a combination of its own, which no later entry is
--- added to. With no dimension, each entry is a combination. An
--- `include` that is an expression ([`KIND_CHOICE`]) is the list `kind`
--- takes.
local function expand(matrix: {string: Json.Value}, kind: string): {{string: string}}
  local dims: mut {string} = {}
  for key in pairs(matrix) do
    if key ~= "include" and key ~= "exclude" then dims[#dims + 1] = key end
  end
  table.sort(dims)
  local combos: mut {{string: string}} = {}
  if #dims > 0 then combos = { {} } end
  for _, dim in ipairs(dims) do
    local value = matrix[dim]
    local next_combos: mut {{string: string}} = {}
    for _, combo in ipairs(combos) do
      for _, v in ipairs(strings_of(value, "matrix " .. dim)) do
        local c: mut {string: string} = {}
        for k, x in pairs(combo) do c[k] = x end
        c[dim] = v
        next_combos[#next_combos + 1] = c
      end
    end
    combos = next_combos
  end
  -- GitHub's docs: "All include combinations are processed after
  -- exclude", so an entry never takes back an excluded combination,
  -- and an exclusion holds back none an entry creates.
  local kept: mut {{string: string}} = {}
  for _, combo in ipairs(combos) do
    local excluded = false
    for _, entry in ipairs(entries_of(matrix["exclude"])) do
      local matches = true
      for k, v in pairs(entry) do
        assert(combo[k] ~= nil or matrix[k] ~= nil, "an exclusion names no dimension: " .. k)
        if combo[k] ~= v then matches = false end
      end
      if matches then excluded = true end
    end
    if not excluded then kept[#kept + 1] = combo end
  end
  combos = kept
  -- An original combination's dimensions are never overwritten, so
  -- each still holds its own.
  local created: mut {{string: string}} = {}
  local include: Json.Value? = matrix["include"]
  if include is string then
    local queue, push, full = include:match(KIND_CHOICE)
    assert(full ~= nil, "the include is chosen other than by the kind of run: " .. include)
    local chosen = if kind == "queue" then queue elseif kind == "push" then push else full end
    assert(kind == "queue" or kind == "push" or kind == "full", "no kind of run " .. kind)
    include = assert(Json.decode(assert(chosen)))
  end
  for _, entry in ipairs(entries_of(include)) do
    local added = false
    for _, combo in ipairs(combos) do
      local fits = true
      for _, dim in ipairs(dims) do
        if entry[dim] ~= nil and entry[dim] ~= combo[dim] then fits = false end
      end
      if fits then
        added = true
        for k, v in pairs(entry) do combo[k] = v end -- checked: view_written
      end
    end
    if not added then
      local c: mut {string: string} = {}
      for k, v in pairs(entry) do c[k] = v end
      created[#created + 1] = c
    end
  end
  for _, c in ipairs(created) do combos[#combos + 1] = c end
  return combos
end

--- A job's matrix legs on a run of `kind`, as [`expand`] gives them.
local function legs_of(job: Job, kind: string): {{string: string}}
  return expand(assert(Json.to_object(assert(assert(job.strategy).matrix))), kind)
end

--- [`expand`] gives the combinations GitHub's docs give for their
--- example of `include`: an entry that fits no original combination
--- is one of its own, which a later entry does not extend.
local function test_a_matrix_expands_as_githubs_docs_say()
  local got = expand(assert(Json.decode_object([=[{
    "fruit": ["apple", "pear"], "animal": ["cat", "dog"],
    "include": [
      { "color": "green" }, { "color": "pink", "animal": "cat" }, { "fruit": "apple", "shape": "circle" },
      { "fruit": "banana" }, { "fruit": "banana", "animal": "cat" } ] }]=])), "full")
  local lines: mut {string} = {}
  for _, combo in ipairs(got) do
    local parts: mut {string} = {}
    for k, v in pairs(combo) do parts[#parts + 1] = k .. "=" .. v end
    table.sort(parts)
    lines[#lines + 1] = table.concat(parts, ",")
  end
  table.sort(lines)
  assert(table.concat(lines, " ") == table.concat({
    "animal=cat,color=pink,fruit=apple,shape=circle",
    "animal=cat,color=pink,fruit=pear",
    "animal=cat,fruit=banana",
    "animal=dog,color=green,fruit=apple,shape=circle",
    "animal=dog,color=green,fruit=pear",
    "fruit=banana",
  }, " "), "the docs' example expands to " .. table.concat(lines, " "))
end

--- The platform legs by name, on a run of `kind`.
local function platform_legs(kind: string): {string: {string: string}}
  local ci = ci_workflow()
  local out: mut {string: {string: string}} = {}
  for _, leg in ipairs(legs_of(assert(ci.jobs["platform"]), kind)) do
    local name = assert(leg["name"])
    assert(out[name] == nil, "two legs named " .. name)
    out[name] = leg
  end
  return out
end

--- The names of `legs`, sorted, as one line.
local function names_of(legs: {string: {string: string}}): string
  local out: mut {string} = {}
  for name in pairs(legs) do out[#out + 1] = name end
  table.sort(out)
  return table.concat(out, " ")
end

--- The path and branch filters of each trigger in `on`; `schedule` takes none.
local function filters_of(on: {string: any}): {string: Branches}
  local out: mut {string: Branches} = {}
  for trigger, raw in pairs(on) do
    if not Json.is_array(raw) then
      local spec, err = BRANCHES:into(raw)
      out[trigger] = assert(spec, trigger .. ": " .. tostring(err))
    end
  end
  return out
end

--- A workflow runs only when a path its filters name changes, so a
--- path that no longer exists is a check that silently stops running,
--- or one that never stops: every trigger's `paths` and `paths-ignore`
--- must name what exists.
local function test_each_path_filter_names_what_exists()
  local count = 0
  for path, workflow in pairs(decoded_workflows()) do
    for trigger, spec in pairs(filters_of(workflow["on"])) do
      for _, field in ipairs({ "paths", "paths-ignore" }) do
        local entries = if field == "paths" then spec.paths else spec["paths-ignore"] end
        local where = path .. "'s " .. trigger .. "." .. field
        assert(entries == nil or #entries > 0, where .. " is empty")
        for _, entry in ipairs(entries or {}) do
          count = count + 1
          -- A `!` excludes what it names, which must exist all the same.
          local fixed = entry:gsub("^!", ""):gsub("/%*%*$", "")
          assert(not fixed:find("*", 1, true), where .. ": " .. entry .. ": only a trailing /** is checked")
          assert(Fs.exists(fixed), entry .. " is in " .. where .. ", and does not exist")
        end
      end
    end
  end
  assert(count > 0, "no workflow has a path filter")
end

local SCRIPTS <const> = ".github/scripts"

--- `path` with its `.` and `..` segments resolved. One that climbs out
--- of the checkout's root raises: a step that starts somewhere other
--- than its author thought -- a composite action's step, which takes no
--- job's `working-directory` -- would otherwise find a script there all
--- the same.
local function normal(path: string): string
  local parts: mut {string} = {}
  for part in path:gmatch("[^/]+") do
    if part == ".." then
      if #parts == 0 then error(path .. " climbs out of the checkout", 0) end
      table.remove(parts)
    elseif part ~= "." then
      parts[#parts + 1] = part
    end
  end
  return table.concat(parts, "/")
end

--- The directory under the checkout a step's `run` starts in: the
--- step's own `working-directory`, else each of `holders`' default in
--- turn (a job's `defaults`, then its workflow's; a composite action's
--- steps take none), else the checkout's root.
local function directory(step: Step, holders: {{string: string}}): string
  if step["working-directory"] ~= nil then return assert(step["working-directory"]) end
  for _, holder in ipairs(holders) do
    if holder["working-directory"] ~= nil then return assert(holder["working-directory"]) end
  end
  return "."
end

--- The defaults for `run` steps of `job`, then of its `workflow`.
local function run_defaults(job: Job, workflow: Workflow): {{string: string}}
  local out: mut {{string: string}} = {}
  for _, defaults in ipairs({ job.defaults or {}, workflow.defaults or {} }) do
    if defaults["run"] ~= nil then out[#out + 1] = assert(defaults["run"]) end
  end
  return out
end

--- What an `actions/checkout` step brings in: nil for the whole tree,
--- else the paths its `sparse-checkout` names, without their slashes at
--- either end.
local function checked_out(step: Step): {string}?
  local sparse = with_of(step)["sparse-checkout"]
  if not sparse is string then return nil end
  local paths: mut {string} = {}
  for line in sparse:gmatch("[^\n]+") do
    paths[#paths + 1] = (line:gsub("^%s*/?", ""):gsub("/?%s*$", ""))
  end
  return paths
end

--- Whether a checkout of `sparse` (nil for the whole tree) holds `path`:
--- it is, or lies under, a path `sparse` names.
local function holds(sparse: {string}?, path: string): boolean
  if sparse == nil then return true end
  for _, prefix in ipairs(sparse) do
    if path == prefix or String.starts_with(path, prefix .. "/") then return true end
  end
  return false
end

--- The metadata file of the local action in `dir`, its `action.yml` or
--- `action.yaml`, or nil when it has neither.
local function action_file(dir: string): string?
  for _, name in ipairs({ "action.yml", "action.yaml" }) do
    local st = Fs.stat(dir .. "/" .. name)
    if st ~= nil and st.kind == "file" then return dir .. "/" .. name end
  end
  return nil
end

--- What a job's steps have checked out so far, and what they ran.
local record Walk
  mut checkout: boolean
  mut sparse?: {string}
  scripts: mut {string}
  actions: mut {string: boolean}
end

--- Checks `steps` in order against what `walk` has checked out, as
--- `where` (a job, or an action a job uses) runs them, their `run`
--- starting where `directory` says with `holders` for defaults.
--- A `uses: ./...` step runs a local action from the checkout, so it
--- needs a checkout before it that holds the action's directory, and
--- its own steps are walked in turn, their scripts held to the same
--- checkout.
local function walk_steps(where: string, steps: {Step}, holders: {{string: string}}, walk: Walk)
  for _, step in ipairs(steps) do
    local uses = step.uses
    if uses is string and uses:match("^actions/checkout@") ~= nil then
      walk.checkout, walk.sparse = true, checked_out(step)
    elseif uses is string and uses:match("^%./") ~= nil then
      local dir = normal(uses)
      assert(walk.checkout, where .. " uses " .. dir .. " before any checkout")
      assert(holds(walk.sparse, dir), where .. "'s sparse checkout does not hold " .. dir ..
          ", the action a step uses")
      local file = action_file(dir)
      assert(file ~= nil, where .. " uses " .. dir .. ", which holds no action.yml")
      walk.actions[dir] = true
      walk_steps(where .. " (through " .. dir .. ")", read_as(ACTION, file, (assert(Fs.read(file)))).runs.steps, {}, walk)
    end
    local run = step.run
    local sparse = walk.sparse
    if run is string and walk.checkout and sparse ~= nil then
      -- A `run` step starts in its working directory, so a sparse
      -- checkout must hold it: be it, or lie under or over a path it
      -- names.
      local here = normal(directory(step, holders))
      if here ~= "" then
        local present = false
        for _, prefix in ipairs(sparse) do
          if here == prefix or String.starts_with(here, prefix .. "/") or
              String.starts_with(prefix, here .. "/") then
            present = true
          end
        end
        assert(present, where .. "'s sparse checkout does not hold " .. here .. ", where a step runs")
      end
    end
    -- What `text` names under SCRIPTS, from `base` (a `run` starts in its
    -- step's working directory; the files a `hashFiles` hashes lie
    -- under the checkout's root wherever the step starts).
    local function scripts_in(text: string, base: string)
      for named in text:gmatch("[%w_./%-]*%.github/scripts/[%w_./%-]+") do
        local script = normal(base .. "/" .. named)
        assert(walk.checkout, where .. " runs " .. script .. " before any checkout")
        assert(holds(walk.sparse, script), where .. "'s sparse checkout does not hold " .. script)
        walk.scripts[#walk.scripts + 1] = script
      end
    end
    local texts: mut {string} = {}
    if run is string then texts[#texts + 1] = run end
    for _, value in pairs(map_of(step.env)) do texts[#texts + 1] = value end
    for _, text in ipairs(texts) do
      local hashed: mut {string} = {}
      local rest = text:gsub("hashFiles%b()", function(call: string): string
        hashed[#hashed + 1] = call
        return ""
      end)
      -- Only a `run` runs what it names; an `env` value names what it hashes.
      if text == run then scripts_in(rest, directory(step, holders)) end
      for _, call in ipairs(hashed) do scripts_in(call, ".") end
    end
  end
end

--- Every script under SCRIPTS a step of `workflow` runs, as the path from
--- the checkout's root its `run` resolves to from where it starts, and
--- every local action a step uses, by its directory. A job that runs
--- either must check out a tree holding it first: it comes from the
--- checkout, and a job that runs only on main would otherwise find it
--- missing only there. A sparse checkout must also hold the directory
--- each `run` step starts in. An action's own steps count as the job's.
-- TODO: hold a sparse checkout to what the scripts it runs read in
-- turn, as cosmic-driver.sh reads bin/cosmic-bootstrap and ci/'s pin:
-- that needs each script to declare what it reads (a header line the
-- test could parse), since finding it in the shell text is guesswork.
local function scripts_run(path: string, workflow: Workflow): {string}, {string: boolean}
  local walk: Walk = { checkout = false, scripts = {}, actions = {} }
  for name, job in pairs(workflow.jobs) do
    walk.checkout, walk.sparse = false, nil
    walk_steps(path .. ": job " .. name, job.steps, run_defaults(job, workflow), walk)
  end
  return walk.scripts, walk.actions
end

--- The scripts the workflows run are the ones under SCRIPTS: each one a
--- step names is a file there, found from where the step starts, and
--- each file there is one some step or its script names. So are the local actions
--- under ACTIONS: each is one some workflow uses.
local function test_the_workflows_run_the_scripts_there_are()
  local named: mut {string: boolean} = {}
  local used: mut {string: boolean} = {}
  for path, workflow in pairs(decoded_workflows()) do
    local scripts, actions = scripts_run(path, workflow)
    for _, script in ipairs(scripts) do
      named[script] = true
      local st = Fs.stat(script)
      assert(st ~= nil and st.kind == "file", path .. " runs " .. script .. ", which is no file")
    end
    for dir in pairs(actions) do used[dir] = true end
  end
  -- A wrapper may compile or run another file here. Follow its literal
  -- checkout-root names as dependencies, including files that no step
  -- names directly; dynamic script dependencies still need a declaration.
  local pending: mut {string} = {}
  for script in pairs(named) do pending[#pending + 1] = script end
  local at = 1
  while at <= #pending do
    local script = pending[at]
    at = at + 1
    local text = assert(Fs.read(assert(script)))
    for reference in text:gmatch("%.github/scripts/[%w_./%-]+") do
      local dependency = normal(reference)
      local st = Fs.stat(dependency)
      assert(st ~= nil and st.kind == "file", assert(script) .. " names " .. dependency .. ", which is no file")
      if named[dependency] ~= true then
        named[dependency] = true
        pending[#pending + 1] = dependency
      end
    end
  end
  for _, name in ipairs((assert(Fs.list(SCRIPTS)))) do
    local script = SCRIPTS .. "/" .. name
    assert(named[script], script .. " is named by no workflow or its scripts")
  end
  for _, file in ipairs(action_paths()) do
    local dir = file:match("^(.*)/[^/]+$")
    assert(used[assert(dir)], assert(dir) .. " is used by no workflow")
  end
end

--- What [`scripts_run`] refuses in a workflow of one job with `steps`,
--- or "" when it takes it.
local function refusal(steps: {Step}): string
  local ok, err = pcall(scripts_run, "w.yml", read_as(WORKFLOW, "w.yml",
    '{"name":"w","on":{},"jobs":{"j":{"steps":' .. assert(Json.encode_any(steps)) .. '}}}'))
  if ok then return "" end
  return tostring(err)
end

local CHECKOUT <const> = "actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd"
local DRIVER <const> = "./.github/actions/cosmic-driver"

local function test_a_local_action_needs_a_checkout_before_it()
  local got = refusal({ { uses = DRIVER }, { uses = CHECKOUT } })
  assert(got:find("job j uses .github/actions/cosmic-driver before any checkout", 1, true), got)
  assert(refusal({ { uses = CHECKOUT }, { uses = DRIVER } }) == "")
end

local function test_a_sparse_checkout_holds_the_local_actions_a_job_uses()
  local function sparse(paths: string): Step
    return read_as(STEP, "a checkout", '{"uses":"' .. CHECKOUT .. '","with":{"sparse-checkout":' ..
        assert(Json.encode(paths)) .. '}}')
  end
  local got = refusal({ sparse("/ci/\n/bin/cosmic-bootstrap\n/.github/scripts/cosmic-driver.sh\n"), { uses = DRIVER } })
  assert(got:find("job j's sparse checkout does not hold .github/actions/cosmic-driver, the action", 1, true), got)
  -- The action's own steps are the job's: the script it runs must be
  -- there too, and the directory it starts in.
  got = refusal({ sparse("/ci/\n/.github/actions/cosmic-driver/\n"), { uses = DRIVER } })
  assert(got:find("(through .github/actions/cosmic-driver)'s sparse checkout does not hold " ..
      ".github/scripts/cosmic-driver.sh", 1, true), got)
  got = refusal({ sparse("/.github/\n"), { uses = DRIVER } })
  assert(got:find("does not hold ci, where a step runs", 1, true), got)
  assert(refusal({ sparse("/ci/\n/.github/scripts/cosmic-driver.sh\n/.github/actions/cosmic-driver/\n"),
    { uses = DRIVER } }) == "")
end

--- A job whose `run` steps default to a shell of their own -- one that
--- drops to an unprivileged user -- passes that shell to each local
--- action it uses that takes one, since `defaults.run` does not reach a
--- composite action's steps: its bootstrap would otherwise run as root.
--- In a job container, where an action restores as root, it names that
--- user as the action's `owner` too, where it takes one, or what the
--- action restores stays root's; a job whose actions run on the host
--- (ci.yml's platform job, whose Linux legs start their container in a
--- step) restores as the host's user already.
local function test_a_job_passes_its_shell_to_its_actions()
  local count = 0
  for path, workflow in pairs(decoded_workflows()) do
    for name, job in pairs(workflow.jobs) do
      local shell: string? = nil
      for _, holder in ipairs(run_defaults(job, workflow)) do
        shell = shell or holder["shell"]
      end
      for _, step in ipairs(if shell ~= nil then job.steps else {} end) do -- checked: literal_needs_type
        local uses = step.uses
        local dir = uses is string and uses:match("^%./") and normal(uses) or nil
        local file = dir and action_file(dir) or nil
        if dir ~= nil and file ~= nil then
          local inputs = read_as(ACTION, file, (assert(Fs.read(file)))).inputs or {}
          if inputs["shell"] ~= nil then
            count = count + 1
            local given = param(step, "shell")
            assert(given == shell, path .. ": job " .. name .. " runs its steps with " .. tostring(shell) ..
                ", and passes " .. dir .. " the shell " .. tostring(given))
            if inputs["owner"] ~= nil and job.container ~= nil then
              local owner = param(step, "owner")
              assert(owner is string and owner ~= "", path .. ": job " .. name .. " runs its steps with " ..
                  tostring(shell) .. ", and names " .. dir .. " no owner to hand what it restores")
            end
          end
        end
      end
    end
  end
  assert(count > 0, "no job with a shell of its own uses an action that takes one")
end

local function test_a_path_that_climbs_out_of_the_checkout_is_refused()
  assert(normal("ci/../.github/scripts/cosmic-driver.sh") == ".github/scripts/cosmic-driver.sh")
  local ok, err = pcall(normal, "./../.github/scripts/cosmic-driver.sh")
  assert(not ok and tostring(err):find("climbs out of the checkout", 1, true) ~= nil, tostring(err))
end

local function test_a_local_action_is_one_there_is()
  local got = refusal({ { uses = CHECKOUT }, { uses = "./.github/actions/nowhere" } })
  assert(got:find("uses .github/actions/nowhere, which holds no action.yml", 1, true), got)
end

--- Every workflow and action is already in [`build.flow`]'s layout, so a
--- program that reads one and writes it back -- its tree, or its value
--- over its tree -- changes no byte it did not mean to: `cosmic fix
--- <path>` lays one out.
local function test_each_workflow_and_action_is_laid_out()
  local count = 0
  for _, files in ipairs({ flow_workflows(), flow_files(action_paths()) }) do
    for path, text in pairs(files) do
      count = count + 1
      local out, why = flow.format(text)
      assert(out ~= nil, path .. ": " .. tostring(why))
      assert(out == text, path .. " is not laid out: run `cosmic fix " .. path .. "`")
      -- Its own value written back over its tree changes nothing, so
      -- a program that regenerates it keeps every comment.
      local doc = assert(flow.parse(text))
      local value = Json.decode(text, { json5 = true, hash_comments = true, null_value = Json.null })
      doc.root = flow.update(doc.root, value)
      assert(flow.render(doc) == text, path .. ": written back over itself, it changes")
    end
  end
  assert(count > 0, "no workflow or action")
end

--- Each of CI's images is pinned to one digest in every workflow that
--- names it -- the platform job's legs and fuzz.yml's -- so moving one
--- leaves none of them on the old one.
local function test_each_image_has_one_digest_everywhere()
  local seen: mut {string: string} = {}
  local where: mut {string: string} = {}
  local count = 0
  for path, text in pairs(flow_workflows()) do
    for image, digest in text:gmatch("(ghcr%.io/[%w%-_./]+)@sha256:(%x+)") do
      count = count + 1
      local before = seen[image]
      if before ~= nil and before ~= digest then
        error(path .. " pins " .. image .. " to " .. digest .. ", " .. assert(where[image]) .. " to " .. before)
      end
      seen[image], where[image] = digest, path
    end
  end
  assert(count > 0, "no workflow pins an image by digest")
end

--- A leg's verdict cache is named by the host's features as well as its
--- container, or on macOS its runner (the driver's `leg-host-id`, which
--- takes the features itself, so it runs after the driver is
--- bootstrapped, and in ci/ with the driver's other commands): every
--- declared-key verdict's key holds them (build/declared_key.tl's
--- `host_identity`), and a leg's runners do not share one set, so a
--- cache named by the container alone could restore another host's
--- verdicts, none of which would stand.
local function test_the_verdict_cache_is_named_by_the_host_too()
  local ci = ci_workflow()
  local jobs = ci.jobs
  local named, bootstrapped, cached = false, false, 0
  for _, step in ipairs(job_of(jobs, "platform").steps) do
    if step.id == "driver" then bootstrapped = true end
    if step.id == "host-id" then
      local run = assert(step.run)
      assert(run:find("cosmic-driver cosmic_ci/driver.tl leg-host-id ", 1, true) == 1, run)
      assert(run:find("host-features", 1, true) == nil, "the features are no argument: " .. run)
      assert(step["working-directory"] == nil, "the driver runs in ci/, the job's own directory")
      assert(bootstrapped, "the host is named before the driver is bootstrapped")
      -- STARTED is what names the container's options inside every
      -- verdict key: an input moved renames every verdict cache.
      assert(map_of(step.env)["STARTED"] == "${{ hashFiles('.github/seccomp/**', " ..
          "'.github/scripts/leg-container.sh', '.github/scripts/seccomp-profile.sh') }}", run)
      assert(run:find('"$STARTED"', 1, true) ~= nil, run)
      named = true
    end
    local with = with_of(step)
    if step.with ~= nil and (with["path"] == "${{ runner.temp }}/verdicts" or with["path"] == "${{ runner.temp }}/verdicts-commit") then
      cached = cached + 1
      assert(param(step, "key"):find("steps.host-id.outputs.verdicts", 1, true) ~= nil,
        "a verdict cache named by its container alone: " .. param(step, "key"))
      local restore = with["restore-keys"]
      assert(restore == nil or restore is string and restore:find("steps.host-id.outputs.verdicts", 1, true) ~= nil,
        "a verdict cache restored by its container alone: " .. tostring(restore))
    end
  end
  assert(named, "the host-id step is gone")
  assert(cached == 2, "the restore and the save: " .. tostring(cached))
end

--- The condition on which a push to main and the scheduled run, and
--- no other, save a cache: ci.yml's COSMIC_CI_SAVES, which each save's
--- condition reads.
local MAIN_SAVES <const> = "${{ github.ref == 'refs/heads/main' && " ..
  "(github.event_name == 'push' || github.event_name == 'schedule') }}"
local SAVES <const> = "env.COSMIC_CI_SAVES == 'true'"

--- The step of `steps` whose `run` holds `text`, and where it stands.
local function step_running(steps: {Step}, text: string): Step, integer
  for i, step in ipairs(steps) do
    local run = step.run
    if run is string and run:find(text, 1, true) ~= nil then return step, i end
  end
  error("no step runs " .. text)
end

local CACHE_NAMES <const> = "./.github/actions/cache-names"

local function cache_names(): Action
  return read_as(ACTION, CACHE_NAMES, (assert(Fs.read(CACHE_NAMES .. "/action.yml"))))
end

--- A job that moves its tree (`driver.tl place-tree`, ci/cosmic_ci/place_tree.tl)
--- moves it once, after the driver's bootstrap, and puts it back once,
--- after its last other step that runs the CI driver, only where the
--- bootstrap succeeded (the move came after it) and before checkout's
--- post step: place-tree keeps the tree
--- one directory deep, as deep as the workspace, so actions/cache's
--- paths relative to the workspace resolve with it moved and nothing
--- puts it back for a save. What a cache step names while it is moved
--- is under the runner's temporary directory, which those paths reach.
local function test_a_job_moves_its_tree_once_and_puts_it_back_once()
  local placed = 0
  for path, workflow in pairs(decoded_workflows()) do
    for job_name, job in pairs(workflow.jobs) do
      local where = path .. " " .. job_name
      local steps = job.steps
      local moves: mut {integer} = {}
      local backs: mut {integer} = {}
      local last_driver = 0
      for i, step in ipairs(steps) do
        local run = step.run
        if run is string then
          if run:match("driver%.tl place%-tree%s*$") ~= nil then moves[#moves + 1] = i end
          if run:find("driver.tl place-tree --restore", 1, true) ~= nil then
            backs[#backs + 1] = i
          elseif run:find("cosmic-driver ", 1, true) ~= nil then
            last_driver = i
          end
        end
        if step.uses == DRIVER then last_driver = i end
      end
      if #moves > 0 or #backs > 0 then
        placed = placed + 1
        assert(#moves == 1, where .. " moves its tree " .. tostring(#moves) .. " times")
        assert(#backs == 1, where .. " puts its tree back " .. tostring(#backs) .. " times")
        local move, back = moves[1], backs[1]
        assert(move < back, where .. " puts its tree back before it moves it")
        assert(last_driver < back, where .. " runs the CI driver after it puts its tree back")
        assert(assert(steps[back])["if"] == "always() && steps.driver.outcome == 'success'",
          where .. " puts its tree back only where the job has not failed, or without a driver: " ..
            tostring(assert(steps[back])["if"]))
        -- The bootstrap is the step with id "driver", and comes first.
        local bootstrap = 0
        for i, step in ipairs(steps) do
          if step.id == "driver" and step.uses == DRIVER then bootstrap = i end
        end
        assert(bootstrap > 0 and bootstrap < move, where .. " moves its tree before it bootstraps the driver")
        assert(assert(steps[move])["working-directory"] ~= ".", where .. " runs the driver outside ci/")
        for i = move + 1, back - 1 do
          local uses = (assert(steps[i]).uses or "")
          if uses:find("^actions/cache") ~= nil then
            local cached = param(assert(steps[i]), "path")
            assert(cached:find("^%${{ runner%.temp }}/") ~= nil,
              where .. " caches " .. cached .. " with its tree moved")
          end
        end
      end
    end
  end
  assert(placed >= 3, "only " .. tostring(placed) .. " jobs move their tree")
end

--- A job whose steps drop to an unprivileged user (a `setpriv` default
--- shell) has one cosmic cache for them all, and none of its steps runs
--- the tree's tools as the container's root. The build directory
--- (build/paths.tl) and the launcher's cores lie under $XDG_CACHE_HOME:
--- a step that lacks the build step's value looks for the built tool in
--- another directory, and the root's launcher refuses a cache leaf the
--- user made.
local function test_an_unprivileged_job_shares_one_cache_and_runs_its_tools_as_that_user()
  local checked = 0
  for path, workflow in pairs(decoded_workflows()) do
    for job_name, job in pairs(workflow.jobs) do
      local shell = ""
      for _, defaults in ipairs(run_defaults(job, workflow)) do
        shell = defaults["shell"] or shell
      end
      if shell:find("setpriv", 1, true) ~= nil then
        checked = checked + 1
        local where = path .. " " .. job_name
        local set = 0
        local first_tool = 0
        for i, step in ipairs(job.steps) do
          local what = where .. " step " .. tostring(step.name)
          local run = step.run
          local named = map_of(step.env)["XDG_CACHE_HOME"] ~= nil
          local sets = false
          if run is string then
            local assigns = run:find("XDG_CACHE_HOME%s*=") ~= nil or run:find("export%s+XDG_CACHE_HOME") ~= nil
            sets = assigns and run:find("GITHUB_ENV", 1, true) ~= nil
            named = named or (assigns and not sets)
            local padded = " " .. run
            local tool = padded:find("[%s;&|(\"']%.*/*bin/[%a-]") ~= nil or
              padded:find("[%s;&|(]cosmic%-driver%f[^%w_%-]") ~= nil
            if tool then
              if first_tool == 0 then first_tool = i end
              assert(step.shell == nil or step.shell:find("setpriv", 1, true) ~= nil,
                what .. " runs the tree's tools as root")
            end
          end
          assert(not named, what .. " names a cache of its own")
          local uses = step.uses
          if uses is string and uses:find("^%./") ~= nil then
            assert(step.shell == nil or step.shell:find("setpriv", 1, true) ~= nil,
              what .. " runs a local action as root")
          end
          if sets and set == 0 then
            set = i
            assert(step["if"] == nil, what .. " shares the cache only under a condition")
          end
        end
        assert(set > 0, where .. " never names the cache its steps share")
        assert(first_tool == 0 or set < first_tool,
          where .. " names the shared cache after a step that uses the tree's tools")
      end
    end
  end
  assert(checked >= 1, "no job drops to an unprivileged user")
end

--- A job a push to a branch starts and skips still shows as a
--- check on the branch's PR, a skipped one whose matrix, if it has one,
--- never expands in its name. So a job that runs only on main or on
--- other events -- one whose `if` names main's ref, or refuses a push --
--- lives in a workflow a branch push does not start: one on a
--- workflow_run from main (prerelease.yml, ci-images-publish.yml), or on
--- a push to main alone; or it is steps of a job that always runs, as
--- ci.yml's provenance join is. A step may still skip on a branch. So
--- does a job that runs only where a job it needs found something (an
--- output `!= ''`), which a branch push's never does. Two jobs are
--- skipped on a branch all the same, named in SKIPPED_ON_A_BRANCH:
--- ci.yml's `seed`, whose TODO says what would end the exception, and
--- its `reuse`, which runs on a push to main alone: run on a branch push
--- with nothing to do, it held the legs, which need it, for a runner's
--- start (some 6 s, up to about 100 s in a burst). Its `prune` and
--- `invalidate` are too: run on a branch push with every step skipped,
--- each took a runner's start (up to about 170 s in a burst) to show a
--- check that did nothing.
local BRANCH_SKIPS <const> = { "refs/heads/main", "ref_name == 'main'", "event_name != 'push'" }
local SKIPPED_ON_A_BRANCH <const>: {string: boolean} = {
  [DIR .. "/ci.yml seed"] = true,
  [DIR .. "/ci.yml reuse"] = true,
  [DIR .. "/ci.yml prune"] = true,
  [DIR .. "/ci.yml invalidate"] = true,
  -- The checked suite's shares and the checked narrowing run, of a full run only: a branch push runs no
  -- checked suite, and the job's boot costs what a runner's start does.
  [DIR .. "/ci.yml checked-shard"] = true,
  [DIR .. "/ci.yml checked-narrowing"] = true,
  [DIR .. "/ci.yml checked-narrowing-merge"] = true,
}

--- Every job of the run gates it: none continues on error, so a failed
--- job always fails the run.
local function test_every_job_gates_the_run()
  local jobs = ci_workflow().jobs
  for id, job in pairs(jobs) do
    assert(job["continue-on-error"] ~= true, id .. " fails without gating")
  end
end

local function test_a_branch_push_starts_no_job_it_skips()
  local count = 0
  for path, workflow in pairs(decoded_workflows()) do
    local push = filters_of(workflow["on"])["push"]
    local branches = push and push.branches
    local main_only = branches ~= nil and #branches == 1 and branches[1] == "main"
    if push ~= nil and not main_only then
      for name, job in pairs(workflow.jobs) do
        count = count + 1
        local condition = job["if"] or ""
        local excepted = SKIPPED_ON_A_BRANCH[path .. " " .. name]
        for _, skip in ipairs(BRANCH_SKIPS) do
          assert(excepted == true or condition:find(skip, 1, true) == nil,
            path .. ": job " .. name .. "'s if names " .. skip .. ", so a branch push shows it skipped")
        end
        assert(excepted == true or condition:find("needs%.[%w_-]+%.outputs%.[%w_-]+ != ''") == nil,
          path .. ": job " .. name ..
            " runs only where a job it needs found something, so a branch push shows it skipped")
      end
    end
  end
  assert(count > 0, "no workflow a branch push starts")
end

--- A value of a workflow expression: a string, or a comparison's
--- boolean.
local type Value = string | boolean

--- What `${{ <text> }}` answers on a run of `event` to `ref`, for a leg
--- of `leg`'s values, in as much of GitHub's expression syntax as a
--- leg's switches use: string literals, `matrix.<key>`,
--- `github.event_name`, `github.ref` and `needs.reuse.outputs.run` (`reuse`,
--- empty unless given), `==`, `!=`, `!`, `&&`, `||` and parentheses. As GitHub's docs ("Operators") say, '' and false are
--- falsy, and `a && b` and `a || b` answer an operand, not a boolean.
--- It compares two strings ignoring case, as GitHub does, so a
--- literal cased otherwise than the value it names answers as it would
--- there; a comparison of a string with a boolean, which GitHub coerces
--- to numbers, it refuses.
local function evaluate(text: string, leg: {string: string}, event: string, ref: string, reuse?: string): Value
  local inner = assert(text:match("^%${{ (.*) }}$"), "not an expression: " .. text)
  local tokens: mut {string} = {}
  local at = 1
  while at <= #inner do
    local space = inner:match("^%s+", at)
    if space ~= nil then
      at = at + #space
    else
      local token = inner:match("^'[^']*'", at) or inner:match("^[%a_][%w_.-]*", at) or
        inner:match("^[=!]=", at) or inner:match("^&&", at) or inner:match("^||", at) or
        inner:match("^[!()]", at)
      assert(token ~= nil, "an expression this test cannot read: " .. inner:sub(at))
      tokens[#tokens + 1] = token
      at = at + #token
    end
  end
  local i = { value = 1 }
  local function truthy(v: Value): boolean return v ~= "" and v ~= false end
  local disjunction: function(): Value
  local function primary(): Value -- checked: not_assigned
    local token = assert(tokens[assert(i["value"])], "an expression ends early: " .. inner)
    i["value"] = assert(i["value"]) + 1
    if token == "(" then
      local v = disjunction()
      assert(tokens[assert(i["value"])] == ")", "an unclosed parenthesis: " .. inner)
      i["value"] = assert(i["value"]) + 1
      return v
    elseif token == "!" then
      return not truthy(primary())
    elseif token:sub(1, 1) == "'" then
      return token:sub(2, -2)
    elseif token:sub(1, 7) == "matrix." then
      return leg[token:sub(8)] or ""
    elseif token == "github.event_name" then
      return event
    elseif token == "github.ref" then
      return ref
    elseif token == "needs.reuse.outputs.run" then
      return reuse or ""
    end
    error("a name this test cannot answer: " .. token)
  end
  local function comparison(): Value
    local left = primary()
    local op = tokens[assert(i["value"])]
    if op == "==" or op == "!=" then
      i["value"] = assert(i["value"]) + 1
      local right = primary()
      assert(left is string and right is string,
        "a comparison of other than two strings this test cannot answer: " .. inner)
      local same = left:lower() == right:lower()
      if op == "==" then return same end
      return not same
    end
    return left
  end
  local function conjunction(): Value
    local v = comparison()
    while tokens[assert(i["value"])] == "&&" do
      i["value"] = assert(i["value"]) + 1
      local right = comparison()
      if truthy(v) then v = right end
    end
    return v
  end
  disjunction = function(): Value
    local v = conjunction()
    while tokens[assert(i["value"])] == "||" do
      i["value"] = assert(i["value"]) + 1
      local right = conjunction()
      if not truthy(v) then v = right end
    end
    return v
  end
  local v = disjunction()
  assert(tokens[assert(i["value"])] == nil, "an expression with more after its end: " .. inner)
  return v
end

--- [`evaluate`] answers as GitHub does where `&&` and `||` choose
--- between strings, and where a comparison is grouped.
local function test_an_expression_evaluates_as_github_says()
  local leg = { name = "linux-x86_64" }
  local function e(text: string, event: string): Value
    return evaluate("${{ " .. text .. " }}", leg, event, "refs/heads/main")
  end
  assert(e("matrix.name == 'linux-x86_64' && 'run' || 'skip'", "push") == "run")
  assert(e("matrix.name == 'alpine-x86_64' && 'run' || 'skip'", "push") == "skip")
  assert(e("(matrix.name == 'linux-x86_64' && github.event_name != 'merge_group') && 'run' || 'skip'",
    "merge_group") == "skip")
  assert(e("!(github.event_name == 'push') && 'a' || 'b'", "schedule") == "a")
  assert(e("matrix.image && '1' || '0'", "push") == "0", "an empty value is truthy")
  assert(e("github.ref == 'refs/heads/main'", "push") == true)
  assert(e("github.event_name == 'Merge_Group' && 'a' || 'b'", "merge_group") == "a",
    "a comparison of strings minds their case")
  assert(e("github.event_name != 'MERGE_GROUP' && 'a' || 'b'", "merge_group") == "b",
    "a comparison of strings minds their case")
end

--- The vendor part of the zig build cache's key hashes the vendored
--- trees and their records, but not the applier, [`build/patch.tl`],
--- which names each patched tree by the bytes it writes: an edit to it
--- that writes the same trees moves no object's path, so it must not
--- move the key and send main's next run to a cold cache (main
--- restores no other vendor part's entry).
local function test_the_vendor_part_hashes_the_trees_and_records_but_not_the_applier()
  local action = cache_names()
  local named = assert(action.runs.steps[1])
  local vendor = map_of(named.env)["VENDOR"]
  assert(vendor == "${{ hashFiles('bin/zig.pin', 'build.zig', 'build.zig.zon', 'build/zig.tl', " ..
      "'vendor/**', '!vendor/tzdata/**', '!vendor/cacert/**', '!vendor/onecrl/**', '!vendor/htmx/**', '!vendor/htmx-ext-sse/**', '!vendor/wpt-url/**', '!vendor/html5lib-tokenizer/**', '!vendor/wpt-html-parsing/**', 'patch/**', " ..
      "'core/ares_config.h', 'core/curl_config.h', 'core/mbedtls_cosmic_config.h', 'core/xz_config/**', " ..
      "'core/darwin-compat/**') }}", "the vendor cache hashes different inputs: " .. assert(vendor))
  for _, wanted in ipairs({ "'vendor/**'", "'patch/**'", "'build.zig'", "'build/zig.tl'" }) do
    assert(assert(vendor):find(wanted, 1, true), "the vendor part hashes no " .. wanted .. ": " .. assert(vendor))
  end
  assert(not assert(vendor):find("build/patch.tl", 1, true),
    "the vendor part hashes the applier, whose edits write the same trees: " .. assert(vendor))
end

--- Both jobs receive the same cache-name outputs before restoring or
--- moving the checkout. A change to this policy invalidates either
--- job's passing driver marker.
local function test_cache_names_reach_both_jobs_before_their_restores()
  local action = cache_names()
  local steps = action.runs.steps
  assert(#steps == 1 and steps[1].id == "names" and steps[1].shell == "sh" and
      steps[1]["working-directory"] == ".", "cache names run outside the host checkout")
  local env = map_of(steps[1].env)
  assert(env["LEG"] == "${{ inputs.leg }}" and
      env["CORE"] == "${{ hashFiles('core/*.c', 'core/*.h', 'core/*.zig', 'test/portable/*.c') }}",
    "cache names use another leg or core inputs")
  local outputs = assert(action.outputs)
  for _, name in ipairs({ "vendor", "core", "since" }) do
    assert(assert(outputs[name])["value"] == "${{ steps.names.outputs." .. name .. " }}",
      "the action does not forward " .. name)
  end
  local jobs = ci_workflow().jobs
  for _, job in ipairs({ "platform", "checked" }) do
    local named = false
    for _, step in ipairs(job_of(jobs, job).steps) do
      if step.id == "names" then
        assert(step.uses == CACHE_NAMES and step["if"] == nil, job .. " does not always name its caches")
        named = true
      end
      if step.id == "zig-cache-restore" or step.id == "compiles-restore" or
          step.name == "move the tree to a path of its own" then
        assert(named, job .. " names its caches after restoring them or moving the tree")
      end
    end
    assert(named, job .. " has no cache names")
  end
end

--- A project-script proof may write build metadata. It must not run
--- between the native suite's snapshot and its delayed comparison.
local function test_the_credential_proof_follows_the_native_database_boundary()
  local jobs = ci_workflow().jobs
  local steps = job_of(jobs, "platform").steps
  local _, suite = step_running(steps, "driver.tl platform local-suite")
  local _, boundary = step_running(steps, "driver.tl platform local-boundary")
  local compile, compiled = step_running(steps, "credentials-build.sh")
  local proof, proved = step_running(steps, "credentials-proof.sh")
  local wrapper = assert(Fs.read(SCRIPTS .. "/credentials-build.sh"))
  assert(wrapper:find('"$root/bin/zig" cc', 1, true) and
      wrapper:find('"$root/.github/scripts/credentials-probe.c"', 1, true),
    "credential proof wrapper does not compile the transition helper")
  assert(suite < boundary and boundary < compiled and compiled < proved,
    "credential proof setup or dispatch writes across the native database boundary")
  assert(compile["if"] == "runner.os == 'Linux' && github.event_name != 'merge_group' && github.event_name != 'pull_request'" and proof["if"] == compile["if"],
    "credential proof must remain required on every Linux leg past the merge queue")
  assert(proof.shell == "leg-shell --root {0}" and proof["continue-on-error"] == nil,
    "credential proof lost its privileged failure gate")
  local runner, ran = step_running(steps, "run-local-proof.sh")
  assert(proved < ran, "local runner proof must follow the credential proof and database boundary")
  assert(runner["if"] == compile["if"] and runner.shell == "leg-shell --root {0}" and
      runner["continue-on-error"] == nil, "local runner proof lost its required privileged Linux gate")
end

--- The proof runs as root with caches of its own, under which the
--- resolver would name another build directory than the one the build
--- step built the helper in (and would refuse the runner's): the build
--- step publishes its directory, and the proof takes it from there and
--- resolves none itself. Root sets up its own caches before it runs
--- anything, and runs the proof driver standalone, building nothing.
local function test_the_credential_proof_takes_the_build_steps_directory_and_its_own_caches()
  local build = assert(Fs.read(SCRIPTS .. "/credentials-build.sh"))
  assert(build:find("COSMIC_CREDENTIALS_BUILD=%s", 1, true) and build:find('>> "$GITHUB_ENV"', 1, true),
    "the build step does not publish its build directory")
  local proof = assert(Fs.read(SCRIPTS .. "/credentials-proof.sh"))
  assert(proof:find("output=${COSMIC_CREDENTIALS_BUILD:?", 1, true),
    "the credential proof does not take the build step's directory")
  assert(not proof:find("build/paths.tl", 1, true), "the credential proof resolves a build directory itself")
  local cache = assert(proof:find('export XDG_CACHE_HOME="$proof/cache"', 1, true))
  local portable = assert(proof:find('export COSMIC_PORTABLE_CACHE="$proof/cache/cores"', 1, true))
  local standalone = assert(proof:find("export COSMIC_STANDALONE=1", 1, true))
  local run = assert(proof:find('"$output/credentials-probe" setup', 1, true))
  assert(cache < run and portable < run and standalone < run,
    "credential proof runs before isolating root's caches")
end

--- Each leg that runs a suite (the platform legs of a light and a full run,
--- and the checked job) has an entry in ci/cosmic_ci/capabilities.json, and
--- each entry is such a leg: a renamed or mistyped leg would promise
--- nothing, silently.
local function test_every_leg_has_its_promises_and_no_other_does()
  local record Capabilities
    legs: {string: {string}}
  end
  local CAPABILITIES <const> = Shape.record_of("Capabilities")
  local text = assert(Fs.read("ci/cosmic_ci/capabilities.json"))
  local loaded, why = CAPABILITIES:decode_into(text)
  assert(loaded ~= nil, why)
  local promised: mut {string: boolean} = {}
  for name in pairs(loaded.legs) do promised[name] = true end
  local ran: mut {string: boolean} = {}
  for _, kind in ipairs({ "queue", "push", "full" }) do
    for name in pairs(platform_legs(kind)) do ran[name] = true end
  end
  ran[assert(map_of(assert(ci_workflow().jobs["narrowing"]).env)["COSMIC_WORKER"])] = true
  local ci = ci_workflow()
  local checked = ci.jobs["checked"]
  ran[assert(map_of(assert(checked).env)["COSMIC_WORKER"])] = true
  for name in pairs(ran) do
    assert(promised[name], name .. ": a leg with no entry in capabilities.json")
  end
  for name in pairs(promised) do
    assert(ran[name], name .. ": capabilities.json names no such leg")
  end
end

local DOWNLOAD <const> = "actions/download-artifact@"
local RETRY_IF <const> = "^steps%.([%w_-]+)%.outcome == 'failure'$"

local function is_download(step: Step): boolean
  local uses = step.uses
  return uses ~= nil and String.starts_with(uses, DOWNLOAD) == true
end

--- A download that fails its job is tried twice. GitHub's artifact service
--- fails a download now and then; in a merge queue each such failure ejects
--- the entry. The first try has an `id` and `continue-on-error: true`. The
--- second try has the same inputs, no `continue-on-error`, and runs `if:
--- steps.<id>.outcome == 'failure'`, so an artifact that is absent still
--- fails the job. Between them a step with that `if` sleeps and removes
--- what the first try may have left: its `path`, or for a `path` of
--- $RUNNER_TEMP itself (which holds more than the download) exactly the
--- paths queue_stage.tl stages. A download that tolerates failure and has no
--- second try (its consumer goes on without it) is not held to this.
local function test_a_gating_download_is_tried_twice()
  local retries = 0
  for file, workflow in pairs(decoded_workflows()) do
    for name, job in pairs(workflow.jobs) do
      local retried: mut {string: integer} = {}
      for i, step in ipairs(job.steps) do
        local where = file .. " " .. name .. " step " .. tostring(i) .. " " .. (step.name or "")
        local first_id = (step["if"] or ""):match(RETRY_IF)
        if is_download(step) and first_id ~= nil then
          retries = retries + 1
          assert(step["continue-on-error"] ~= true, where .. ": a second try that tolerates failure passes where the artifact is absent")
          local first, at = step_with_id(job.steps, first_id)
          assert(at < i, where .. ": the first try " .. first_id .. " comes after it")
          assert(is_download(first) and first["continue-on-error"] == true,
            where .. ": " .. first_id .. " is not a download that tolerates its failure")
          assert(first.uses == step.uses, where .. ": " .. first_id .. " is another action")
          assert(Json.encode_any(first.with) == Json.encode_any(step.with),
            where .. ": " .. first_id .. " downloads other inputs")
          retried[first_id] = (retried[first_id] or 0) + 1
          local waits = 0
          for k = at + 1, i - 1 do
            local between = assert(job.steps[k])
            if between["if"] == step["if"] and (between.run or ""):find("sleep ", 1, true) ~= nil then
              waits = waits + 1
              local run = assert(between.run)
              local path = param(first, "path")
              assert(String.starts_with(run, 'rm -rf "' .. path .. '"; sleep '), where .. ": the wait does not remove " .. path)
            end
          end
          assert(waits == 1, where .. ": " .. tostring(waits) .. " steps between the tries sleep and clear, under its `if`")
        elseif is_download(step) then
          assert(step["continue-on-error"] == true, where .. ": no first try; run it first with continue-on-error and an id, then retry it `if: steps.<id>.outcome == 'failure'`")
        end
      end
      for id, count in pairs(retried) do
        assert(count == 1, file .. " " .. name .. ": " .. id .. " has " .. tostring(count) .. " retries")
      end
    end
  end
  assert(retries > 0, "no retried download found: the test reads nothing")
end

--- The merge queue runs linux-x86_64's leg alone, a light and fast gate; a
--- push to main every leg but macOS, which the daily scheduled run and a
--- manual run add, the runs prerelease.yml publishes from. A leg has the same values whatever the
--- run, every entry sets the same values, and alpine-x86_64,
--- linux-x86_64's runner and target in the alpine image, is the only leg in
--- that image.
local function test_each_kind_of_run_has_its_legs()
  local queue, push, full = platform_legs("queue"), platform_legs("push"), platform_legs("full")
  assert(names_of(queue) == "linux-x86_64", "the queue's legs: " .. names_of(queue))
  assert(names_of(push) == "alpine-x86_64 linux-aarch64 linux-x86_64", "a push's legs: " .. names_of(push))
  assert(names_of(full) == "alpine-x86_64 linux-aarch64 linux-x86_64 macos-aarch64",
    "a full run's legs: " .. names_of(full))
  local keys <const>: {string} = { "name", "runner", "target", "image" }
  for name, leg in pairs(full) do
    local count = 0
    for _ in pairs(leg) do count = count + 1 end
    assert(count == #keys, name .. " sets other values than " .. table.concat(keys, ", "))
    for _, key in ipairs(keys) do
      assert(leg[key] ~= nil, name .. " has no " .. key)
      for _, other in ipairs({ queue[name] or leg, push[name] or leg }) do
        assert(other[key] == leg[key], name .. "'s " .. key .. " differs between runs")
      end
    end
    local alpine = assert(leg["image"]):find("^ghcr%.io/cosmic%-lua/cosmic%-ci%-alpine@sha256:") ~= nil
    assert(alpine == (name == "alpine-x86_64"), name .. "'s image: " .. assert(leg["image"]))
  end
  local alpine = assert(full["alpine-x86_64"])
  assert(alpine["runner"] == "ubuntu-24.04" and alpine["target"] == "x86_64-linux-musl",
    "alpine-x86_64's values: " .. tostring(alpine["runner"]) .. " " .. tostring(alpine["target"]))
  assert(assert(full["macos-aarch64"])["image"] == "", "macos-aarch64 has an image")
  local platform = job_of(ci_workflow().jobs, "platform")
  assert(platform.name == "${{ matrix.name }}" and map_of(platform.env)["COSMIC_WORKER"] == "${{ matrix.name }}",
    "the legs' names: " .. tostring(platform.name))
  assert(assert(platform.strategy)["fail-fast"] == false, "a failed leg cancels the others")
end

--- What only main's runs run (main's push, the weekly and a manual run):
--- not the merge queue, nor a pull request.
local QUEUE_SKIPS <const> = "github.event_name != 'merge_group' && github.event_name != 'pull_request'"
--- What a pull request skips beside.
local PR_SKIPS <const> = "github.event_name != 'pull_request'"

--- The format check's runs: linux-x86_64's, on every run but main's push
--- and the daily one.
local FORMAT_RUNS <const> = "matrix.name == 'linux-x86_64' && github.event_name != 'push' && " ..
  "github.event.schedule != '41 3 * * 1-6'"

--- The phases the platform job's steps run on a run that skips the steps
--- whose condition holds `skips`: the portable boundary runs where the
--- portable suite did.
local function phases_unless(steps: {Step}, skips: string): string
  local out: mut {string} = {}
  for _, step in ipairs(steps) do
    local phase = (step.run or ""):match("driver%.tl platform ([%w-]+)")
    local condition = step["if"] or ""
    local after_portable = condition:find("steps.portable-suite.outcome != 'skipped'", 1, true) ~= nil
    if phase ~= nil and condition:find(skips, 1, true) == nil and not after_portable then
      out[#out + 1] = phase
    end
  end
  return table.concat(out, " ")
end

--- In the merge queue, the leg boots, runs its native suite and its
--- boundary, checks the bootstrap's scripts, the tree's format and,
--- where the change reaches its tests, the pinned driver, and probes the
--- sandbox: everything past that (assemble,
--- the regressions, the portable suite, the attestation and the product,
--- the credential proofs, the declared-types tests) is main's, and so are
--- the checked and narrowing jobs, which the queue skips.
local function test_the_merge_queue_runs_the_native_suite_and_the_format_check_alone()
  local jobs = ci_workflow().jobs
  local steps = job_of(jobs, "platform").steps
  local in_queue = phases_unless(steps, QUEUE_SKIPS)
  assert(in_queue == "boot local-suite local-boundary format darwin-suite sandbox", "the queue's leg runs " .. in_queue)
  for _, name in ipairs({ "build local portable and checked artifacts", "run runtime, launcher, rebuild, and identity regressions",
      "run the product suite from fresh tracked source", "attest the exact executed product bytes", "upload the attested product" }) do
    assert(step_named(steps, name)["if"] == QUEUE_SKIPS, name .. " runs in the merge queue")
  end
  for _, name in ipairs({ "checked", "narrowing" }) do
    assert(job_of(jobs, name)["if"] == QUEUE_SKIPS, name .. " runs in the merge queue")
  end
  local suite = step_named(steps, "run release Cosmic's native suite")
  assert(suite["if"] == PR_SKIPS, "the native suite is skipped on some run but a pull request's: " .. tostring(suite["if"]))
  local format = step_named(steps, "check the tree's format")
  assert(format["if"] == FORMAT_RUNS and map_of(format.env)["COSMIC_CI_FORMAT"] == "run" and
      map_of(job_of(jobs, "platform").env)["COSMIC_CI_FORMAT"] == "skip",
    "the format check runs elsewhere than on linux-x86_64, or in assemble too")
end

--- Main moves only through the merge queue, so main's push tests the very
--- commit the queue just checked: it repeats neither the format check nor
--- the pinned driver's, which the daily, weekly and a manual run make on
--- every leg. The queue checks the pinned driver only where what the
--- commit changed reaches what its tests read (ci/ and .github/), or where
--- the paths changed are not known.
local function test_mains_push_repeats_nothing_the_queue_checked()
  local steps = job_of(ci_workflow().jobs, "platform").steps
  local base = step_named(steps, "find the base the markers are held to")
  assert(base["if"] == FORMAT_RUNS, "the markers' base is found on main's push: " .. tostring(base["if"]))
  local check = step_running(steps, "cosmic-driver test cosmic_ci")
  assert(check["if"] == "github.event_name == 'schedule' || github.event_name == 'workflow_dispatch' || " ..
      "steps.reach.outputs.driver == 'run'" and map_of(check.env)["COSMIC_TEST_SANDBOX"] == "0",
    "the pinned driver is checked on other runs: " .. tostring(check["if"]))
  local reach, at = step_with_id(steps, "reach")
  local _, check_at = step_named(steps, "check the pinned CI driver")
  local _, changed_at = step_with_id(steps, "changed")
  assert(changed_at < at and at < check_at, "the driver's check is asked of the paths changed out of order")
  assert(reach["if"] == "matrix.name == 'linux-x86_64' && github.event_name == 'merge_group'" and
      map_of(reach.env)["PATHS"] == "${{ steps.changed.outputs.paths }}" and
      (reach.run or ""):find("[ -z \"$PATHS\" ] || grep -qE '^(ci|\\.github)/' \"$PATHS\"", 1, true) ~= nil,
    "the queue asks otherwise whether the change reaches the driver's tests")
  local islands = step_named(steps, "type-check the bootstrap's scripts on the pinned driver")
  assert(islands["if"] == "matrix.name == 'linux-x86_64' && github.event_name != 'push'", "the bootstrap's scripts")
end

--- Only main's push and the weekly run save a cache (COSMIC_CI_SAVES):
--- every save holds it, or follows a step that does. Nothing is relayed
--- between runs: no job downloads another run's artifacts, and none
--- holds `actions: write`.
local function test_only_main_saves_and_no_run_relays_to_another()
  local ci = ci_workflow()
  assert(map_of(ci.env)["COSMIC_CI_SAVES"] == MAIN_SAVES, "the saves' condition: " .. tostring(map_of(ci.env)["COSMIC_CI_SAVES"]))
  for name, job in pairs(ci.jobs) do
    assert(map_of(job.permissions)["actions"] == nil, name .. " holds actions permission")
    local gated: mut {string: boolean} = {}
    for _, step in ipairs(job.steps) do
      local condition = step["if"] or ""
      if condition:find(SAVES, 1, true) ~= nil and step.id ~= nil then
        gated[assert(step.id)] = true
      end
      if (step.uses or ""):find("actions/cache/save@", 1, true) ~= nil then
        local held = condition:find(SAVES, 1, true) ~= nil
        for id in pairs(gated) do
          held = held or condition:find("steps." .. id .. ".outputs", 1, true) ~= nil
        end
        assert(held, name .. "'s " .. tostring(step.name) .. " saves off main: " .. condition)
      end
      assert(with_of(step)["run-id"] == nil, name .. "'s " .. tostring(step.name) .. " takes another run's artifact")
    end
  end
end

--- The gate (`ci`, the one check a ruleset requires) needs every job and
--- fails on any that failed or was cancelled; the checked and narrowing
--- jobs read as passed in the merge queue, which skips them. On every
--- other run it compares the legs' products: a push's three, the
--- scheduled and a manual run's four, which prerelease.yml publishes from
--- alone.
local function test_the_gate_needs_every_job_and_compares_four_products()
  local jobs = ci_workflow().jobs
  local gate = job_of(jobs, "ci")
  assert(table.concat(needs_of(gate), ",") == "platform,checked,narrowing" and gate["if"] == "always()",
    "the gate needs " .. table.concat(needs_of(gate), ","))
  local env = map_of(assert(gate.steps[1]).env)
  assert(env["RESULT"] == "${{ needs.platform.result }}" and
      env["CHECKED"] == "${{ (github.event_name == 'merge_group' || github.event_name == 'pull_request') && 'success' || " ..
      "needs.checked.result }}" and
      env["NARROWING"] == "${{ (github.event_name == 'merge_group' || github.event_name == 'pull_request') && 'success' || " ..
      "needs.narrowing.result }}",
    "the gate reads other results")
  local compare = step_named(gate.steps, "compare the Cosmic bytes executed on every native host")
  assert(compare["if"] == QUEUE_SKIPS and
      map_of(compare.env)["COSMIC_CI_PRODUCTS"] == "${{ github.event_name == 'push' && '3' || '4' }}",
    "the join compares other than main's products: " .. tostring(map_of(compare.env)["COSMIC_CI_PRODUCTS"]))
  local function count(legs: {string: {string: string}}): integer
    local n = 0
    for _ in pairs(legs) do n = n + 1 end
    return n
  end
  assert(count(platform_legs("push")) == 3 and count(platform_legs("full")) == 4, "the runs' legs")
  -- prerelease.yml publishes four lanes, so only from a run of all four:
  -- the scheduled and a manual run of main, never a push.
  local prerelease = assert(Fs.read(DIR .. "/prerelease.yml"))
  assert(prerelease:find("(github.event.workflow_run.event == 'schedule' || " ..
      "github.event.workflow_run.event == 'workflow_dispatch')", 1, true) ~= nil and
      prerelease:find("workflow_run.event == 'push'", 1, true) == nil,
    "prerelease.yml publishes from a run of fewer than four legs")
  for name in pairs(jobs) do
    assert(name == "platform" or name == "checked" or name == "narrowing" or name == "ci", "ci.yml has a job " .. name)
  end
end

--- A pull request runs the light check alone, the `ci` check the merge
--- queue requires of it: linux-x86_64's leg, as the queue's, boots the tree
--- and checks its format over the paths the pull request changed since its
--- merge base with main (`fix --check --changed`, every check spanning files
--- over the whole tree), the markers held to that base, and checks the
--- bootstrap's scripts. No suite, no saved cache, and no other job.
local function test_a_pull_request_runs_the_light_check_alone()
  local ci = ci_workflow()
  assert(ci["on"]["pull_request"] ~= nil, "a pull request runs nothing")
  local steps = job_of(ci.jobs, "platform").steps
  local phases = phases_unless(steps, PR_SKIPS)
  assert(phases == "boot format", "a pull request's leg runs " .. phases)
  local changed = step_named(steps, "name the paths the commit changed")
  assert(changed["if"] == "matrix.name == 'linux-x86_64' && (github.event_name == 'merge_group' || " ..
      "github.event_name == 'pull_request') && " ..
      "steps.ceilings-base.outputs.sha != ''" and map_of(changed.env)["BASE"] == "${{ steps.ceilings-base.outputs.sha }}" and
      (changed.run or ""):find("driver.tl changed-paths", 1, true) ~= nil, "the paths changed are named otherwise")
  assert(map_of(step_named(steps, "check the tree's format").env)["COSMIC_CI_FORMAT_CHANGED"] ==
      "${{ steps.changed.outputs.paths }}", "the check is not given the paths changed")
  local base = step_named(steps, "find the base the markers are held to")
  assert(base["if"] == FORMAT_RUNS, "the markers are held to no base on a pull request")
  assert(names_of(platform_legs("queue")) == "linux-x86_64", "a pull request's legs")
  for _, name in ipairs({ "checked", "narrowing" }) do
    assert(job_of(ci.jobs, name)["if"] == QUEUE_SKIPS, name .. " runs on a pull request")
  end
end

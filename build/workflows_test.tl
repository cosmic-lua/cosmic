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
  types?: {string}
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
  local raw, raw_trouble = Json.decode(text, READ)
  assert(raw ~= nil, raw_trouble)
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
  if not assert(Fs.status(ACTIONS)).is_dir then return paths end
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

--- No `env` of a workflow or a job reads the `runner` context, which
--- GitHub gives only a job's steps: one that does makes the workflow
--- file invalid, and its run fails before any job starts.
local function test_no_job_env_reads_the_runner_context()
  local count = 0
  for path, text in pairs(flow_workflows()) do
    local workflow = read_as(WORKFLOW, path, text)
    local function held(env: {string: string}?, where: string)
      for name, value in pairs(env or {}) do
        count = count + 1
        assert(not tostring(value):find("runner%."), where .. "'s env " .. name .. " reads the runner context")
      end
    end
    held(workflow.env, path)
    for job_name, job in pairs(workflow.jobs) do held(job.env, path .. " job " .. job_name) end
  end
  assert(count > 0, "no workflow or job has an env")
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
--- request's (`queue`), a push to main's (`push`), the scheduled run, a
--- manual run of main and one that asks for macOS (`full`), and every other
--- manual run (`dispatch`: a branch's checks before the queue). An
--- include that names no `dispatch` list ([`FOUR_KINDS`]) gives it `full`'s.
--- What else a manual run asks for to be `full` is the include's own
--- (the platform job's `inputs.macos`); [`full_condition`] answers it.
local KIND_CHOICE <const> = "^%${{ fromJSON%(github%.event_name == 'pull_request' && '(%[[^']-%])' || " ..
  "github%.event_name == 'merge_group' && '(%[[^']-%])' || github%.event_name == 'push' && '(%[[^']-%])' || " ..
  "%((github%.event_name == 'schedule' || github%.ref == 'refs/heads/main'[^)]-)%) && '(%[[^']-%])' || " ..
  "'(%[[^']-%])'%) }}$"
--- How a pull request's list is chosen where a draft's differs
--- (`draft`): a draft's list, then a ready one's (`pr`).
local DRAFT_CHOICE <const> = "github%.event_name == 'pull_request' && %(github%.event%.pull_request%.draft && " ..
  "'(%[[^']-%])' || '(%[[^']-%])'%)"
--- `include` with a pull request's choice of [`DRAFT_CHOICE`] made the ready one's list, and the draft's list, nil
--- where no draft choice is made.
local function ready_include(include: string): string, string?
  local draft, ready = include:match(DRAFT_CHOICE)
  if ready == nil then return include, nil end
  local chosen = include:gsub(DRAFT_CHOICE, function(): string
    return "github.event_name == 'pull_request' && '" .. ready .. "'"
  end)
  return chosen, draft
end
local FOUR_KINDS <const> = "^%${{ fromJSON%(github%.event_name == 'pull_request' && '(%[[^']-%])' || " ..
  "github%.event_name == 'merge_group' && '(%[[^']-%])' || github%.event_name == 'push' && '(%[[^']-%])' || " ..
  "'(%[[^']-%])'%) }}$"

--- What every run but a pull request's runs: the merge queue, main's
--- push, the scheduled and a manual run.
local PR_SKIPS <const> = "github.event_name != 'pull_request'"
--- How a job that restores a cache starts: in the merge queue, only where
--- the merge-queue ref's check (`queue-ref`) passed.
local QUEUE_REF <const> = "!cancelled() && (github.event_name != 'merge_group' || needs.queue-ref.result == 'success')"
--- A batch's pull request: a branch of this repository that build/batch.tl
--- stacked (`claude/batch-*`), whose legs and driver check are skipped and
--- read as passed, the merge queue testing the batch.
local BATCH_PR <const> = "github.event_name == 'pull_request' && " ..
  "github.event.pull_request.head.repo.full_name == github.repository && startsWith(github.head_ref, 'claude/batch-')"
--- The parts of a leg ([`expand`]'s `part`) a step runs in: a whole leg
--- (`all`) runs every part, and the queue runs a leg as its `suite` and
--- its `product` in two jobs at once, beside linux-x86_64's `format`.
local SUITE_PART <const> = "(matrix.part == 'all' || matrix.part == 'suite')"
local PRODUCT_PART <const> = "(matrix.part == 'all' || matrix.part == 'product' || matrix.part == 'portable')"
--- The steps every part that makes or checks the product runs: assemble, and the regressions (not `portable`'s).
local ASSEMBLE_PART <const> = "(matrix.part == 'all' || matrix.part == 'product' || matrix.part == 'portable' || " ..
  "matrix.part == 'regressions' || matrix.part == 'rebuild')"
local REGRESSIONS_PART <const> = "(matrix.part == 'all' || matrix.part == 'product' || matrix.part == 'regressions' || " ..
  "matrix.part == 'rebuild')"
local FORMAT_PART <const> = "(matrix.part == 'all' || matrix.part == 'format')"
--- What follows a leg's native suite on its host, which every run but a
--- pull request's runs, in the queue in its `suite` job. The native suite
--- and the darwin suite run on a pull request too ([`SUITE_PART`] alone).
local SUITE_RUNS <const> = PR_SKIPS .. " && " .. SUITE_PART
--- A leg's assemble, regressions, portable suite and product, which every
--- run but a pull request's runs, in the queue in its `product` job.
local PRODUCT_RUNS <const> = PR_SKIPS .. " && " .. PRODUCT_PART

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
    local ready, draft = ready_include(include)
    include = ready
    local pr, queue, push, _, full, dispatch = include:match(KIND_CHOICE)
    if dispatch == nil then
      pr, queue, push, full = include:match(FOUR_KINDS)
      dispatch = full
    end
    assert(dispatch ~= nil, "the include is chosen other than by the kind of run: " .. include)
    local chosen = if kind == "draft" then (draft or pr) elseif kind == "pr" then pr elseif kind == "queue" then queue elseif kind == "push" then push
      elseif kind == "full" then full else dispatch end
    assert(kind == "draft" or kind == "pr" or kind == "queue" or kind == "push" or kind == "full" or kind == "dispatch",
      "no kind of run " .. kind)
    local chosen_include, include_trouble = Json.decode(assert(chosen))
    assert(chosen_include ~= nil, include_trouble)
    include = chosen_include
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

--- The condition under which `job`'s include gives a manual run `full`'s
--- list, not `dispatch`'s ([`KIND_CHOICE`]); nil where it names no
--- `dispatch` list.
local function full_condition(job: Job): string?
  local include = assert(Json.to_object(assert(assert(job.strategy).matrix)))["include"]
  if not (include is string) then return nil end
  local _, _, _, condition = (ready_include(include)):match(KIND_CHOICE)
  return condition
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
          assert(assert(Fs.status(fixed)).exists, entry .. " is in " .. where .. ", and does not exist")
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
    local st, _ = Fs.stat(dir .. "/" .. name)
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
      local st, _ = Fs.stat(script)
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
      local st, _ = Fs.stat(dependency)
      assert(st ~= nil and st.kind == "file", assert(script) .. " names " .. dependency .. ", which is no file")
      if named[dependency] ~= true then
        named[dependency] = true
        pending[#pending + 1] = dependency
      end
    end
  end
  for _, name in ipairs((assert(Fs.list(SCRIPTS)))) do
    local script = SCRIPTS .. "/" .. name
    assert(named[script] == true, script .. " is named by no workflow or its scripts")
  end
  for _, file in ipairs(action_paths()) do
    local dir = file:match("^(.*)/[^/]+$")
    assert(used[assert(dir)] == true, assert(dir) .. " is used by no workflow")
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
      local value, _ = Json.decode(text, { json5 = true, hash_comments = true, null_value = Json.null })
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

--- What `${{ <text> }}` gives on a run of `event` to `ref`, for a leg
--- of `leg`'s values, in as much of GitHub's expression syntax as a
--- leg's switches use: string literals, `matrix.<key>`,
--- `github.event_name`, `github.ref`, `needs.reuse.outputs.run` (`reuse`,
--- empty unless given) and any other name `named` holds, `==`, `!=`, `!`, `&&`, `||` and parentheses. As GitHub's docs ("Operators") say, '' and false are
--- falsy, and `a && b` and `a || b` give an operand, not a boolean.
--- It compares two strings ignoring case, as GitHub does, so a
--- literal cased otherwise than the value it names compares as it would
--- there; a comparison of a string with a boolean, which GitHub coerces
--- to numbers, it refuses.
local function evaluate(text: string, leg: {string: string}, event: string, ref: string, reuse?: string,
                        named?: {string: Value}): Value
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
    local v = if named ~= nil then named[token] else nil end
    if v ~= nil then return v end
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

--- [`evaluate`] returns what GitHub does where `&&` and `||`
--- choose between strings, and where a comparison is grouped.
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

--- Every job that names COSMIC_CI_EVENT gives it `push`, which stands on
--- verdicts (cosmic_ci/orchestration.tl's `stands`), on a push, the daily
--- scheduled run and a manual run, and keeps the run's own event, which
--- runs every test, on the weekly run and a manual run with `every_test`.
local function test_a_manual_run_stands_on_verdicts_unless_it_asks_for_every_test()
  local record Case
    event: string
    schedule: string
    every: boolean
    want: string
  end
  local cases: {Case} = {
    { event = "push", schedule = "", every = false, want = "push" },
    { event = "schedule", schedule = "41 3 * * 1-6", every = false, want = "push" },
    { event = "schedule", schedule = "41 3 * * 0", every = false, want = "schedule" },
    { event = "workflow_dispatch", schedule = "", every = false, want = "push" },
    { event = "workflow_dispatch", schedule = "", every = true, want = "workflow_dispatch" },
  }
  local seen = 0
  for id, job in pairs(ci_workflow().jobs) do
    local text = if job.env ~= nil then job.env["COSMIC_CI_EVENT"] else nil end
    if text ~= nil then
      seen = seen + 1
      for _, case in ipairs(cases) do
        local got = evaluate(text, {}, case.event, "refs/heads/main", nil,
          { ["github.event.schedule"] = case.schedule, ["inputs.every_test"] = case.every })
        assert(got == case.want, id .. " on " .. case.event .. " " .. case.schedule ..
            " every_test=" .. tostring(case.every) .. ": " .. tostring(got))
      end
    end
  end
  assert(seen == 3, "jobs that name COSMIC_CI_EVENT: " .. tostring(seen))
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
  assert(compile["if"] == "runner.os == 'Linux' && " .. SUITE_RUNS and proof["if"] == compile["if"],
    "credential proof must remain required on every Linux leg's suite but a pull request's")
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
  for _, kind in ipairs({ "draft", "pr", "queue", "push", "full", "dispatch" }) do
    for _, leg in pairs(platform_legs(kind)) do ran[assert(leg["leg"])] = true end
  end
  ran[assert(map_of(assert(ci_workflow().jobs["narrowing"]).env)["COSMIC_WORKER"])] = true
  local ci = ci_workflow()
  local checked = ci.jobs["checked"]
  ran[assert(map_of(assert(checked).env)["COSMIC_WORKER"])] = true
  for name in pairs(ran) do
    assert(promised[name] == true, name .. ": a leg with no entry in capabilities.json")
  end
  for name in pairs(promised) do
    assert(ran[name] == true, name .. ": capabilities.json names no such leg")
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
          assert(assert(Json.encode_any(first.with)) == assert(Json.encode_any(step.with)),
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

--- A pull request runs linux-x86_64's leg and macOS's suite, a light gate; the merge
--- queue every leg but macOS, and macOS's suite; a push to main, the daily scheduled
--- run and a manual run of main all four. A leg has the same values whatever the
--- run, every entry sets the same values, and alpine-x86_64,
--- linux-x86_64's runner and target in the alpine image, is the only leg in
--- that image.
local function test_each_kind_of_run_has_its_legs()
  local pr, queue, push, full = platform_legs("pr"), platform_legs("queue"), platform_legs("push"), platform_legs("full")
  assert(names_of(pr) == "linux-x86_64 macos-aarch64", "a pull request's legs: " .. names_of(pr))
  local pr_mac = assert(pr["macos-aarch64"])
  -- The queue runs a push's legs, each as its suite and its product at once, linux-x86_64's format check beside, and
  -- macOS's suite, which a push does not run: only the daily run met its failures, and they held up the prerelease.
  assert(names_of(queue) == "alpine-x86_64 alpine-x86_64-portable alpine-x86_64-rebuild alpine-x86_64-regressions " ..
      "linux-aarch64 linux-aarch64-product linux-aarch64-rebuild linux-x86_64 linux-x86_64-format linux-x86_64-product " ..
      "linux-x86_64-rebuild macos-aarch64",
    "the queue's legs: " .. names_of(queue))
  local mac, full_mac = assert(queue["macos-aarch64"]), assert(full["macos-aarch64"])
  assert(mac["part"] == "suite" and mac["leg"] == "macos-aarch64", "the queue runs macOS otherwise")
  for key, value in pairs(mac) do
    assert(pr_mac[key] == value, "a pull request runs macOS otherwise than the queue: " .. key)
  end
  for _, key in ipairs({ "runner", "target", "image" }) do
    assert(mac[key] == full_mac[key], "the queue runs macOS on another host: " .. key)
  end
  -- Each Linux leg's self-rebuild regression is a job of its own (`rebuild`), which the leg's product or regressions
  -- job skips; every other run runs it in the leg's own job.
  assert(map_of(job_of(ci_workflow().jobs, "platform").env)["COSMIC_CI_SELF_REBUILD"] ==
      "${{ matrix.part == 'rebuild' && 'only' || (matrix.part == 'product' || matrix.part == 'regressions') && 'skip' " ..
      "|| 'run' }}", "the self-rebuild regression runs in some job other than its own, or in none")
  -- The product's boot of its own tree (the self-driven fixture's) proves the next pin: main's push and the daily run
  -- run it, the queue does not.
  assert(map_of(job_of(ci_workflow().jobs, "platform").env)["COSMIC_CI_SELF_BOOT"] ==
      "${{ github.event_name == 'merge_group' && 'skip' || 'run' }}", "the queue runs the product's self-boot, or main does not")
  -- alpine-x86_64's product, the longest, is two jobs: its portable suite and its regressions. macOS's suite, of a
  -- push too, is pinned above.
  for name, leg in pairs(push) do
    if name == "macos-aarch64" then continue end
    local parts: {string} = if name == "alpine-x86_64" then { "suite", "portable", "regressions", "rebuild" } else
      { "suite", "product", "rebuild" } end
    for _, part in ipairs(parts) do
      local job = assert(queue[if part == "suite" then name else name .. "-" .. part end], name .. " has no " .. part)
      assert(job["part"] == part and job["leg"] == name, "the queue's jobs split " .. name .. " otherwise")
      for _, key in ipairs({ "runner", "target", "image" }) do
        assert(job[key] == leg[key], "the queue runs " .. name .. " on another host: " .. key)
      end
    end
  end
  local format = assert(queue["linux-x86_64-format"])
  assert(format["part"] == "format" and format["leg"] == "linux-x86_64", "the queue's format job")
  for _, key in ipairs({ "runner", "target", "image" }) do
    assert(format[key] == assert(push["linux-x86_64"])[key], "the queue's format job runs on another host: " .. key)
  end
  -- A push runs all four legs whole, macOS among them, so every commit that lands is tested on each platform within a
  -- run (the queue runs macOS's suite alone). macOS's job stands on the queue's verdicts and saves macOS's caches for
  -- the queue's next runs, which otherwise only the daily run saved (the queue's macOS job booted cold, 7.3 of its
  -- 18.2 min on 45475769968).
  assert(names_of(push) == "alpine-x86_64 linux-aarch64 linux-x86_64 macos-aarch64", "a push's legs: " .. names_of(push))
  local push_mac = assert(push["macos-aarch64"])
  assert(push_mac["part"] == "all", "a push runs part of macOS's leg: " .. tostring(push_mac["part"]))
  for _, key in ipairs({ "runner", "target", "image" }) do
    assert(push_mac[key] == mac[key], "a push runs macOS otherwise than the queue: " .. key)
  end
  -- A suite job's zig build outputs are its boot's alone, saved apart (`<vendor>boot-`), so that the daily run, which
  -- assembles the whole leg, still saves the leg's `<vendor>full-` entry.
  local zig_save = step_named(job_of(ci_workflow().jobs, "platform").steps, "save zig build outputs")
  assert(tostring(with_of(zig_save)["key"]):find("matrix.part == 'suite' && format('{0}boot-", 1, true) ~= nil and
      (zig_save["if"] or ""):find("format('{0}boot-', steps.names.outputs.vendor)", 1, true) ~= nil,
    "a suite job saves its boot as the leg's whole entry")
  assert(names_of(full) == "alpine-x86_64 linux-aarch64 linux-x86_64 macos-aarch64",
    "a full run's legs: " .. names_of(full))
  -- A branch's manual run, its checks before the queue, runs the full run's legs but macOS, which the queue runs on
  -- every entry: its macOS jobs held the few macOS runners the queue's waited for (45561589392, 35 min).
  assert(full_condition(job_of(ci_workflow().jobs, "platform")) ==
      "github.event_name == 'schedule' || github.ref == 'refs/heads/main' || inputs.macos",
    "a manual run runs macOS otherwise: " .. tostring(full_condition(job_of(ci_workflow().jobs, "platform"))))
  local dispatch = platform_legs("dispatch")
  assert(names_of(dispatch) == "alpine-x86_64 linux-aarch64 linux-x86_64", "a branch's manual run's legs: " .. names_of(dispatch))
  for name, leg in pairs(dispatch) do
    for _, key in ipairs({ "name", "leg", "part", "runner", "target", "image" }) do
      assert(leg[key] == assert(full[name])[key], "a branch's manual run runs " .. name .. " otherwise: " .. key)
    end
  end
  local function object_of(value: any, what: string): {string: any}
    local map, err: {string: any}?, string = Shape.into(value, Shape.map(Shape.any))
    return (assert(map, what .. ": " .. tostring(err)))
  end
  local inputs = object_of(object_of(ci_workflow()["on"]["workflow_dispatch"], "workflow_dispatch")["inputs"], "inputs")
  local macos = object_of(inputs["macos"], "the macos input")
  assert(macos["type"] == "boolean" and macos["default"] == false,
    "a manual run cannot ask for macOS, or asks by default")
  local keys <const>: {string} = { "name", "leg", "part", "runner", "target", "image" }
  for name, leg in pairs(full) do
    local count = 0
    for _ in pairs(leg) do count = count + 1 end
    assert(count == #keys, name .. " sets other values than " .. table.concat(keys, ", "))
    for _, key in ipairs(keys) do
      assert(leg[key] ~= nil, name .. " has no " .. key)
      for _, other in ipairs({ pr[name] or leg, push[name] or leg }) do
        assert(other[key] == leg[key] or key == "part" and name == "macos-aarch64" and (other == push[name] or other == pr[name]),
          name .. "'s " .. key .. " differs between runs")
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
  assert(platform.name == "${{ matrix.name }}" and map_of(platform.env)["COSMIC_WORKER"] == "${{ matrix.leg }}",
    "the legs' names: " .. tostring(platform.name))
  assert(assert(platform.strategy)["fail-fast"] == false, "a failed leg cancels the others")
end

--- What a pull request runs where a path it changed reaches the launcher
--- and startup fixtures (driver.tl changed-paths).
local function pr_fixtures(part: string): string
  return "(" .. PR_SKIPS .. " && " .. part .. ") || (github.event_name == 'pull_request' && " ..
    "steps.changed.outputs.fixtures != 'skip')"
end
local PR_ASSEMBLE <const> = pr_fixtures(ASSEMBLE_PART)
local PR_FIXTURES <const> = pr_fixtures(REGRESSIONS_PART)

--- The format check's runs: linux-x86_64's, on every run but main's push
--- and the daily one.
local FORMAT_RUNS <const> = "matrix.leg == 'linux-x86_64' && " .. FORMAT_PART .. " && github.event_name != 'push' && " ..
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

--- The merge queue runs what main's push runs, so a commit that would
--- break a push breaks its queue entry first: every leg's native suite,
--- assemble, the fixtures, the regressions, the portable suite, the
--- attestation and the product, the credential proofs, and the checked
--- and narrowing jobs. Beside, linux-x86_64's format check runs as a job
--- of its own, which skips all of that.
local function test_the_merge_queue_runs_what_mains_push_runs()
  local jobs = ci_workflow().jobs
  local steps = job_of(jobs, "platform").steps
  for _, step in ipairs(steps) do
    assert((step["if"] or ""):find("github.event_name != 'merge_group'", 1, true) == nil,
      tostring(step.name) .. " is skipped in the merge queue")
  end
  for _, name in ipairs({ "run the product suite from fresh tracked source", "attest the exact executed product bytes",
      "upload the attested product" }) do
    assert(step_named(steps, name)["if"] == PRODUCT_RUNS, name .. " is skipped in the merge queue, or runs in its suite job")
  end
  assert(step_named(steps, "build local portable and checked artifacts")["if"] == PR_ASSEMBLE,
    "assemble is skipped in the merge queue, or ungated on a pull request")
  assert(step_named(steps, "run runtime, launcher, rebuild, and identity regressions")["if"] == PR_FIXTURES,
    "the regressions are skipped in the merge queue, or ungated on a pull request")
  for _, name in ipairs({ "checked", "narrowing" }) do
    assert(job_of(jobs, name)["if"] == QUEUE_REF .. " && " .. PR_SKIPS, name .. " is skipped in the merge queue")
  end
  -- Each queue job runs its part's phases, as GitHub would choose them: the suite job the native suite and what
  -- follows it on the host, the product job assemble and what follows it, the format job the format check.
  local named <const>: {string: Value} = {
    ["runner.os"] = "Linux", ["github.event.schedule"] = "", ["steps.changed.outputs.fixtures"] = "skip",
    ["steps.ceilings-base.outputs.sha"] = "base",
  }
  local want <const>: {string: string} = {
    suite = "boot local-suite local-boundary darwin-suite sandbox",
    product = "boot assemble fixtures portable attest",
    portable = "boot assemble portable attest",
    regressions = "boot assemble fixtures",
    rebuild = "boot assemble fixtures",
    format = "boot format",
  }
  for name, leg in pairs(platform_legs("queue")) do
    local ran: mut {string} = {}
    for _, step in ipairs(steps) do
      local phase = (step.run or ""):match("driver%.tl platform ([%w-]+)")
      local condition = step["if"]
      -- The portable boundary follows the portable suite wherever it ran (always()).
      if phase ~= nil and phase ~= "portable-boundary" then
        local runs: Value = true
        if condition ~= nil then
          runs = evaluate("${{ " .. condition .. " }}", leg, "merge_group", "refs/heads/gh-readonly-queue/main", nil, named)
        end
        if runs ~= false and runs ~= "" then ran[#ran + 1] = phase end
      end
    end
    local part = assert(leg["part"])
    local expected = assert(want[part], name .. "'s part " .. part)
    assert(table.concat(ran, " ") == expected, name .. " runs " .. table.concat(ran, " "))
  end
  local suite = step_named(steps, "run release Cosmic's native suite")
  -- Skipped in the queue's format and product jobs alone: a pull request runs it too.
  assert(suite["if"] == SUITE_PART,
    "the native suite is skipped on some run: " .. tostring(suite["if"]))
  local format = step_named(steps, "check the tree's format")
  assert(format["if"] == FORMAT_RUNS and map_of(format.env)["COSMIC_CI_FORMAT"] == "run" and
      map_of(job_of(jobs, "platform").env)["COSMIC_CI_FORMAT"] == "skip",
    "the format check runs elsewhere than on linux-x86_64, or in assemble too")
end

--- Main moves only through the merge queue, so main's push tests the very
--- commit the queue just checked: it repeats neither the format check nor
--- the pinned driver's, which the daily, weekly and a manual run make on
--- every leg. The queue checks the pinned driver in a job of its own
--- (`driver`), which boots nothing, beside its legs' jobs, and on the
--- macOS leg, whose host keeps its programs elsewhere (/sbin), each
--- only where what the commit changed reaches what its tests read (ci/
--- and .github/: changed_paths.tl writes `driver=skip` where it does
--- not), or where the paths changed are not known.
local function test_mains_push_repeats_nothing_the_queue_checked()
  local jobs = ci_workflow().jobs
  local steps = job_of(jobs, "platform").steps
  local macos_queue <const> = "(matrix.leg == 'macos-aarch64' && github.event_name == 'merge_group')"
  local base = step_named(steps, "find the base the markers are held to")
  assert(base["if"] == "(" .. FORMAT_RUNS .. ") || " .. macos_queue,
    "the markers' base is found on main's push: " .. tostring(base["if"]))
  assert(step_named(steps, "name the base the ceilings are held to")["if"] ==
      "matrix.leg == 'linux-x86_64' && steps.ceilings-base.outputs.sha != ''",
    "a leg but linux-x86_64 holds the ceilings to a base")
  local leg_changed, leg_changed_at = step_with_id(steps, "changed")
  assert(leg_changed["run"] == "cosmic-driver cosmic_ci/driver.tl changed-paths" and
      (leg_changed["if"] or ""):find(macos_queue, 1, true) ~= nil,
    "the macOS leg names no paths changed in the queue: " .. tostring(leg_changed["if"]))
  local check, leg_check_at = step_running(steps, "cosmic-driver test cosmic_ci")
  assert(check["if"] == "github.event_name == 'schedule' || github.event_name == 'workflow_dispatch' || " ..
      "(github.event_name == 'merge_group' && matrix.leg == 'macos-aarch64' && steps.changed.outputs.driver != 'skip')" and
      map_of(check.env)["COSMIC_TEST_SANDBOX"] == "${{ runner.os == 'Linux' && '1' || '0' }}" and
      map_of(check.env)["COSMIC_SANDBOX"] == "${{ runner.os == 'Linux' && 'must' || '' }}",
    "the legs check the pinned driver on other runs, sandboxed on Linux: " .. tostring(check["if"]))
  assert(leg_changed_at < leg_check_at, "the macOS leg asks of the paths changed after its check")
  local driver = job_of(jobs, "driver")
  assert(driver["if"] == QUEUE_REF .. " && (github.event_name == 'merge_group' || github.event_name == 'pull_request') && " ..
      "!(" .. BATCH_PR .. ")" and
      table.concat(needs_of(driver), ",") == "queue-ref",
    "the pinned driver's own job runs on other runs than the queue's and a pull request's, or waits on another job")
  local own = driver.steps
  -- Its unprivileged builder cannot write the default ~/.cache, and it
  -- has no `zig-cache` to name another.
  local named, named_at = step_named(own, "name the cosmic cache every later step shares")
  local _, bootstrap_at = step_with_id(own, "driver")
  assert(named_at < bootstrap_at and (named.run or ""):find("XDG_CACHE_HOME=$RUNNER_TEMP/cache", 1, true) ~= nil,
    "the driver's job names no cosmic cache its builder can write")
  for _, s in ipairs(own) do
    assert((s.run or ""):find("platform boot", 1, true) == nil, "the driver's job boots the tree")
  end
  local queued = step_running(own, "cosmic-driver test cosmic_ci")
  assert(queued["if"] == "steps.changed.outputs.driver != 'skip'" and map_of(queued.env)["COSMIC_TEST_SANDBOX"] == "1" and
      map_of(queued.env)["COSMIC_SANDBOX"] == "must",
    "the queue checks the pinned driver otherwise: " .. tostring(queued["if"]))
  local _, check_at = step_named(own, "check the pinned CI driver")
  local _, placed_at = step_named(own, "move the tree to a path of its own")
  local _, back_at = step_named(own, "move the tree back to where it was checked out")
  local changed, changed_at = step_with_id(own, "changed")
  assert(changed_at < placed_at and placed_at < check_at and check_at < back_at,
    "the driver's job checks the tree where it was checked out")
  assert(step_with_id(own, "ceilings-base")["continue-on-error"] == true,
    "the driver's job fails where it finds no base, rather than check every test")
  assert(changed["run"] == "cosmic-driver cosmic_ci/driver.tl changed-paths" and
      changed["if"] == "steps.ceilings-base.outputs.sha != ''",
    "the driver's job names the paths changed otherwise")
  for _, s in ipairs(own) do
    assert(s["id"] ~= "reach", "the driver's job asks in a shell whether the change reaches its tests")
  end
  for _, s in ipairs(steps) do
    assert((s.run or ""):find("check-islands", 1, true) == nil,
      "a step checks the bootstrap's scripts apart from the tree's format, which `fix --check` already runs on the pinned release")
  end
  -- The queue's suite job runs the native suite and its boundary, its product and format jobs neither.
  assert(step_named(steps, "run release Cosmic's native suite")["if"] == SUITE_PART,
    "the native suite runs in the queue's format or product job")
  assert(step_named(steps, "verify the delayed native database boundary")["if"] == SUITE_PART,
    "the boundary runs in the queue's format or product job")
end

--- The terms `condition` ANDs at its top level, outside any parentheses.
local function conjuncts(condition: string): {string}
  local terms: mut {string} = {}
  local depth, start, at = 0, 1, 1
  while at <= #condition do
    local c = condition:sub(at, at)
    if c == "(" then
      depth = depth + 1
    elseif c == ")" then
      depth = depth - 1
    elseif depth == 0 and condition:sub(at, at + 3) == " && " then
      terms[#terms + 1] = condition:sub(start, at - 1)
      start = at + 4
      at = at + 3
    elseif depth == 0 and condition:sub(at, at + 3) == " || " then
      return {}
    end
    at = at + 1
  end
  terms[#terms + 1] = condition:sub(start)
  return terms
end

--- Only main's push and the weekly run save a cache (COSMIC_CI_SAVES):
--- every save ANDs it at the top of its own condition. Two things are
--- relayed between runs: main's push of a commit takes the verdicts the
--- merge queue's run of the same commit reached (cosmic_ci/queue_verdicts.tl),
--- and the memo of its tree checks (build/check_memo.tl).
--- No other step downloads another run's artifacts, only the jobs that
--- relay verdicts read the runs (`actions: read`), and none holds
--- `actions: write`.
local function test_only_main_saves_and_only_the_queue_relays_to_main()
  local ci = ci_workflow()
  assert(map_of(ci.env)["COSMIC_CI_SAVES"] == MAIN_SAVES, "the saves' condition: " .. tostring(map_of(ci.env)["COSMIC_CI_SAVES"]))
  for name, job in pairs(ci.jobs) do
    local actions = map_of(job.permissions)["actions"]
    assert(actions == nil or ((name == "platform" or name == "checked" or name == "narrowing" or name == "queue-ref" or name == "ci") and actions == "read"), name .. " holds actions permission")
    for _, step in ipairs(job.steps) do
      local condition = step["if"] or ""
      if (step.uses or ""):find("actions/cache/save@", 1, true) ~= nil then
        local held = false
        for _, term in ipairs(conjuncts(condition)) do held = held or term == SAVES end
        assert(held, name .. "'s " .. tostring(step.name) .. " saves off main: " .. condition)
      end
      assert(with_of(step)["run-id"] == nil or step.id == "queue-download" or step.id == "tried-download" or step.id == "queue-checks" or
          step.id == "queue-compiles",
        name .. "'s " .. tostring(step.name) .. " takes another run's artifact")
    end
  end
  -- Each verdicts' save holds the saves' condition itself: the queue trims them too, for the
  -- relay and the next try, and a save on a queue ref fails the run (`queue-ref`).
  for _, name in ipairs({ "platform", "checked", "narrowing" }) do
    local save = step_named(job_of(ci.jobs, name).steps, "save test verdicts")
    assert((save["if"] or ""):find(SAVES, 1, true) ~= nil, name .. " saves its verdicts in the queue: " .. tostring(save["if"]))
  end
end

--- A merge-queue run takes in what the last failed try of its pull
--- request reached, before each job's suite: what each release leg, checked
--- shard and the narrowing suite uploaded under the job's own name, or a
--- release leg's suite's verdicts for main's push. None of the steps takes
--- part outside the queue or fails the job.
local function test_a_queue_try_stands_on_its_pull_requests_last_failed_try()
  -- Each job that runs a suite in the queue: its suite step, its artifact, what its upload
  -- of its rows waits on, and the artifact it reads where a try passed in a run that
  -- failed. A release leg's suite that passed left them for main's push
  -- ("upload the merge queue's verdicts"); the others upload theirs passing or failing.
  local release = "${{ matrix.part == 'suite' && format('queue-verdicts-{0}', matrix.leg) || '' }}"
  for _, leg in ipairs({
      { "platform", "release-suite", "queue-tried-verdicts-${{ matrix.name }}", "job.status == 'failure' && ", release },
      { "checked", "checked-suite", "queue-tried-verdicts-${{ matrix.name }}", "", "" },
      { "narrowing", "checked-narrowing", "queue-tried-verdicts-${{ matrix.name }}", "", "" } }) do
    local job_name, suite, name, waits, passed = leg[1]!, leg[2]!, leg[3]!, leg[4]!, leg[5]!
    local steps = job_of(ci_workflow().jobs, job_name).steps
    local find, find_at = step_with_id(steps, "tried-run")
    local download, download_at = step_with_id(steps, "tried-download")
    local taken, taken_at = step_named(steps, "take in the last failed try's verdicts")
    local _, restore_at = step_with_id(steps, "verdicts-restore")
    local _, suite_at = step_with_id(steps, suite)
    local trim, trim_at = step_with_id(steps, "verdicts-trim")
    local upload, upload_at = step_named(steps, if waits == "" then "upload what this try in the merge queue reached"
      else "upload what this failed try in the merge queue reached" end)
    assert(restore_at < find_at and find_at < download_at and download_at < taken_at and taken_at < suite_at and
        trim_at < upload_at, "the tried verdicts are taken in out of order")
    local env = map_of(find.env)
    -- On the runner's own shell: a leg's container takes in only some of the step's env.
    assert(find["if"] == "github.event_name == 'merge_group'" and find["continue-on-error"] == true and find.shell == "sh" and
        env["ARTIFACT"] == name and env["HEAD_REF"] == "${{ github.event.merge_group.head_ref }}" and
        env["RUN_ID"] == "${{ github.run_id }}" and env["BASE_SHA"] == "${{ github.event.merge_group.base_sha }}" and
        env["SHA"] == "${{ github.sha }}" and env["GH_TOKEN"] == "${{ github.token }}" and
        (env["PASSED_ARTIFACT"] or "") == passed and
        (find.run or ""):find("driver.tl queue-tried-run", 1, true) ~= nil,
      "the tried run's lookup")
    -- By the artifact's id, which the lookup checked, not its name: an
    -- attempt again uploads another of the same name.
    assert(download["if"] == "steps.tried-run.outputs.artifact != ''" and download["continue-on-error"] == true and
        with_of(download)["name"] == nil and with_of(download)["pattern"] == nil and
        param(download, "artifact-ids") == "${{ steps.tried-run.outputs.artifact }}" and
        with_of(download)["merge-multiple"] == true and param(download, "run-id") == "${{ steps.tried-run.outputs.run }}",
      "the tried verdicts' download")
    -- A failed try in the queue keeps only the rows it used, as a passing one does.
    assert(trim["if"] == "always() && steps.driver.outcome == 'success' && " ..
        "(env.COSMIC_CI_SAVES == 'true' || github.event_name == 'merge_group')", job_name .. "'s trim: " .. tostring(trim["if"]))
    assert((trim.run or ""):find("(job.status == 'success' || github.event_name == 'merge_group') && " ..
        "steps.names.outputs.since || 'whole'", 1, true) ~= nil, "a failed try uploads the rows it restored")
    assert(taken["if"] == "steps.tried-download.outcome == 'success'" and taken["continue-on-error"] == true and
        (taken.run or ""):find("driver.tl verdicts-merge \"" .. param(download, "path") .. "\"", 1, true) ~= nil,
      "the tried verdicts are taken in otherwise")
    assert(upload["if"] == "always() && github.event_name == 'merge_group' && " .. waits ..
        "steps.verdicts-trim.outputs.digest != ''" and upload["continue-on-error"] == true and
        param(upload, "name") == name and param(upload, "path") == "${{ runner.temp }}/verdicts/*.db" and
        with_of(upload)["retention-days"] == 1,
      "the tried verdicts' upload: " .. tostring(upload["if"]))
    assert(map_of(job_of(ci_workflow().jobs, job_name).permissions)["actions"] == "read", job_name .. " cannot read the runs")
  end
  -- The lookup reads a tried run's ref checks by these names
  -- (QueueVerdicts.REF_JOB, GATE_JOB, the key of a job with no name, and
  -- RECHECK_STEP); a name changed here turns the lookup off.
  local jobs = ci_workflow().jobs
  assert(job_of(jobs, "queue-ref").name == "merge-queue ref" and job_of(jobs, "ci").name == nil,
    "the tried run's ref job, or the gate, is named otherwise")
  local _ = step_named(job_of(jobs, "ci").steps, "refuse a cache the merge-queue ref saved, after every job")
end

--- A merge-queue run whose own ref holds a cache runs no job that
--- restores one: each waits on `queue-ref`, which restores none and fails
--- on such a cache, and runs only where it did not fail.
local function test_a_queue_run_refuses_its_own_refs_caches()
  local jobs = ci_workflow().jobs
  local gate = job_of(jobs, "queue-ref")
  assert(gate["if"] == "github.event_name == 'merge_group'", "the queue ref's check runs otherwise")
  local checked_at = 0
  for at, step in ipairs(gate.steps) do
    assert((step.uses or ""):find("actions/cache", 1, true) == nil and (step.uses or ""):find("cosmic-driver", 1, true) == nil,
      "the queue ref's check restores a cache: " .. tostring(step.name))
    if (step.run or ""):find("driver.tl queue-ref-caches", 1, true) ~= nil then
      checked_at = at
      assert(step["if"] == nil and step["continue-on-error"] == nil and map_of(step.env)["GH_TOKEN"] == "${{ github.token }}",
        "the queue ref's check passes a job otherwise")
    end
  end
  assert(checked_at > 0, "the queue ref's caches are never checked")
  for name, job in pairs(jobs) do
    local restores = false
    for _, step in ipairs(job.steps) do
      local uses = step.uses or ""
      restores = restores or uses:find("actions/cache", 1, true) ~= nil or uses:find("cosmic-driver", 1, true) ~= nil
    end
    -- The gate restores only outside the merge queue (below).
    if restores and name ~= "ci" then
      local needs = needs_of(job)
      local waits = false
      for _, each in ipairs(needs) do waits = waits or each == "queue-ref" end
      local condition = job["if"] or ""
      local rest = condition:sub(#QUEUE_REF + 1)
      assert(waits and condition:sub(1, #QUEUE_REF) == QUEUE_REF and (rest == "" or rest:sub(1, 4) == " && ") and
          -- An `||` only inside parentheses cannot run the job past the queue ref's check; a
          -- string literal is emptied first, so a parenthesis in one pairs with none outside it.
          ((rest:gsub("'[^']*'", "''")):gsub("%b()", "")):find("||", 1, true) == nil,
        name .. " restores a cache without waiting on the queue ref's check")
    end
  end
  -- The gate, which restores none, lists the ref's caches again once every job has restored its own.
  -- It does so before it reads the jobs' results, so a run that failed is checked too, on a driver no restore wrote.
  local ci = job_of(jobs, "ci")
  local recheck, recheck_at = step_named(ci.steps, "refuse a cache the merge-queue ref saved, after every job")
  local fetch, fetch_at = step_with_id(ci.steps, "driver-fetch")
  local _, passed_at = step_named(ci.steps, "every job passed")
  local action, action_at = step_with_id(ci.steps, "driver")
  assert(recheck["if"] == "github.event_name == 'merge_group'" and recheck["continue-on-error"] == nil and
      map_of(recheck.env)["GH_TOKEN"] == "${{ github.token }}" and
      (recheck.run or ""):find("driver.tl queue-ref-caches", 1, true) ~= nil and fetch["if"] == "github.event_name == 'merge_group'" and
      (fetch.run or ""):find("cosmic-driver.sh", 1, true) ~= nil and fetch_at < recheck_at and recheck_at < passed_at and
      passed_at < action_at and (action["if"] or ""):find("github.event_name != 'merge_group'", 1, true) ~= nil,
    "the gate checks the queue ref's caches otherwise")
  -- In the queue the gate restores nothing: each restore it has runs on other events alone.
  for _, step in ipairs(ci.steps) do
    local uses = step.uses or ""
    if uses:find("actions/cache", 1, true) ~= nil or uses:find("cosmic-driver", 1, true) ~= nil then
      assert((step["if"] or ""):find("github.event_name != 'merge_group'", 1, true) ~= nil and
          (step["if"] or ""):find("||", 1, true) == nil, "the gate restores in the merge queue: " .. tostring(step.name))
    end
  end
  local summary = step_named(ci.steps, "summarize provenance operations")
  assert(summary["if"] == "always() && (steps.driver.outcome == 'success' || steps.driver-fetch.outcome == 'success')",
    "the gate's summary runs on neither driver: " .. tostring(summary["if"]))
  -- Both list the ref's caches, which takes actions: read.
  assert(map_of(gate.permissions)["actions"] == "read" and map_of(ci.permissions)["actions"] == "read",
    "the queue ref's caches cannot be listed")
end

local function relay_workflow(): Workflow
  return (assert(decoded_workflows()[DIR .. "/relay.yml"]))
end

--- The format check stands on the memo of the tree checks main keeps,
--- apart from the compiles: restored before the check, and, in the queue,
--- sealed and uploaded once the check passed. The relay of the commit
--- (relay.yml) downloads that, holds it to a memo with rows, and saves it;
--- main's push, which runs no format check, takes no part. No step of the
--- relay fails it.
local function test_the_format_check_takes_the_queues_memo_through_main()
  local steps = job_of(ci_workflow().jobs, "platform").steps
  local _, compiles_at = step_with_id(steps, "compiles-restore")
  local restore, restore_at = step_named(steps, "restore the tree checks' memo")
  local _, format_at = step_with_id(steps, "format")
  local seal, seal_at = step_with_id(steps, "checks-seal")
  local upload, upload_at = step_named(steps, "upload the merge queue's tree checks memo")
  assert(compiles_at < restore_at and restore_at < format_at and format_at < seal_at and seal_at < upload_at,
    "the memo is made and uploaded out of order")
  for _, step in ipairs(steps) do
    local uses = step.uses
    assert(with_of(step)["name"] ~= "queue-checks-${{ matrix.leg }}" or uses == nil or
        uses:find("actions/upload-artifact@", 1, true) ~= nil,
      "main's push takes the queue's memo: " .. tostring(step.name))
  end
  local file = "${{ runner.temp }}/cache/cosmic/build/checks.db"
  -- The memo is apart from the compiles, whose save takes their whole directory.
  assert(param(step_named(steps, "save compiles and parses"), "path") == "${{ runner.temp }}/build-cache")
  assert(seal["if"] == "github.event_name == 'merge_group' && steps.format.outcome == 'success'" and
      seal["continue-on-error"] == true and (seal.run or ""):find("driver.tl checks-seal \"" .. file .. "\" \"${{ steps.names.outputs.since }}\"", 1, true) ~= nil,
    "the queue seals its memo otherwise: " .. tostring(seal.run))
  assert(restore["if"] == FORMAT_RUNS and param(restore, "path") == file and
      param(restore, "key") == "checks-${{ matrix.leg }}-", "the memo's restore: " .. tostring(restore["if"]))
  assert(upload["if"] == "steps.checks-seal.outcome == 'success'" and
      param(upload, "path") == file and param(upload, "name") == "queue-checks-${{ matrix.leg }}" and
      upload["continue-on-error"] == true, "the memo's upload: " .. tostring(upload["if"]))
  local relayed = job_of(relay_workflow().jobs, "relay").steps
  local _, find_at = step_with_id(relayed, "queue-run")
  local download, download_at = step_with_id(relayed, "queue-checks")
  local held, held_at = step_with_id(relayed, "queue-checks-held")
  local save, save_at = step_named(relayed, "save the tree checks' memo")
  assert(find_at < download_at and download_at < held_at and held_at < save_at, "the memo is relayed out of order")
  -- linux-x86_64's format job alone seals the memo, so the other legs' relays look for none.
  assert(download["if"] == "matrix.leg == 'linux-x86_64' && steps.queue-run.outputs.run != ''" and
      download["continue-on-error"] == true and param(download, "name") == "queue-checks-linux-x86_64" and
      param(download, "path") == "${{ runner.temp }}/cache/cosmic/build" and
      param(download, "run-id") == "${{ steps.queue-run.outputs.run }}", "the memo's download")
  assert(held["if"] == "steps.queue-checks.outcome == 'success'" and held["continue-on-error"] == true and
      (held.run or ""):find("driver.tl checks-seal \"" .. file .. "\"", 1, true) ~= nil, "the relay holds the memo otherwise")
  assert(save["if"] == "steps.queue-checks-held.outcome == 'success'" and param(save, "path") == file and
      param(save, "key") == "checks-linux-x86_64-${{ github.sha }}" and save["continue-on-error"] == true,
    "the memo's save: " .. tostring(save["if"]))
end

--- Main's push boots on the compiles and parses of the queue's run of its
--- commit, in place of the entry it restored, and leaves their save to the
--- relay (relay.yml), which saves them a minute after the merge; main's own
--- save is then skipped. The queue uploads them where its native suite
--- passed, as main's save would keep them; the relay never fails a job.
local function test_mains_push_saves_the_queues_compiles_at_once()
  local steps = job_of(ci_workflow().jobs, "platform").steps
  local _, find_at = step_with_id(steps, "queue-run")
  local _, restore_at = step_with_id(steps, "compiles-restore")
  local download, download_at = step_with_id(steps, "queue-compiles")
  local taken, taken_at = step_with_id(steps, "queue-compiles-taken")
  local _, boot_at = step_with_id(steps, "boot")
  local trim, trim_at = step_with_id(steps, "compiles-trim")
  local upload, upload_at = step_named(steps, "upload the merge queue's compiles and parses")
  local late = step_named(steps, "save compiles and parses")
  assert(find_at < download_at and restore_at < download_at and download_at < taken_at and taken_at < boot_at and
      trim_at < upload_at, "the compiles are taken in out of order")
  local dir = "${{ runner.temp }}/build-cache"
  assert(download["if"] == "steps.queue-run.outputs.run != ''" and download["continue-on-error"] == true and
      param(download, "name") == "queue-compiles-${{ matrix.leg }}" and
      param(download, "run-id") == "${{ steps.queue-run.outputs.run }}" and param(download, "path") ~= dir,
    "the compiles' download")
  assert(taken["if"] == "steps.queue-compiles.outcome == 'success'" and taken["continue-on-error"] == true,
    "the compiles are taken in otherwise")
  assert(trim["if"] == "always() && steps.driver.outcome == 'success' && (" .. SAVES .. " || github.event_name == 'merge_group')",
    "the compiles' trim: " .. tostring(trim["if"]))
  assert(upload["if"] == "github.event_name == 'merge_group' && job.status == 'success' && " ..
      "steps.release-suite.outcome == 'success' && steps.compiles-trim.outputs.digest != ''" and
      upload["continue-on-error"] == true and param(upload, "path") == dir and
      param(upload, "name") == "queue-compiles-${{ matrix.leg }}", "the compiles' upload: " .. tostring(upload["if"]))
  -- The trim runs in the queue too, so main's own save holds the saves' condition itself. Where it took the queue's
  -- compiles it saves them under the relay's name, which a relay that saved them leaves as it is, and a push main
  -- moved past saves none.
  assert(late["if"] == "always() && " .. SAVES .. " && (matrix.leg == 'macos-aarch64' || steps.main-newest.outputs.newest != 'false') && " ..
      "steps.release-suite.outcome == 'success' && steps.compiles-trim.outputs.digest != '' && " ..
      "steps.compiles-restore.outputs.cache-matched-key != format('compiles-{0}-{1}', matrix.leg, steps.compiles-trim.outputs.digest)",
    "main's own save of the compiles: " .. tostring(late["if"]))
  assert(param(late, "key") == "${{ steps.queue-compiles-taken.outcome == 'success' && " ..
      "format('compiles-{0}-queue-{1}', matrix.leg, github.sha) || " ..
      "format('compiles-{0}-{1}', matrix.leg, steps.compiles-trim.outputs.digest) }}", "main's own compiles' name")
  local newest, newest_at = step_with_id(steps, "main-newest")
  local _, late_at = step_named(steps, "save compiles and parses")
  local _, verdicts_at = step_named(steps, "save test verdicts")
  local _, moved_at = step_named(steps, "move the tree back to where it was checked out")
  assert(newest_at < moved_at and moved_at < late_at and moved_at < verdicts_at and
      newest["if"] == "always() && steps.queue-run.outcome != 'skipped' && steps.driver.outcome == 'success'" and
      newest["continue-on-error"] == true and map_of(newest.env)["SHA"] == "${{ github.sha }}" and
      (newest.run or ""):find("driver.tl main-newest", 1, true) ~= nil, "a push asks otherwise whether main moved")
  assert((step_named(steps, "save test verdicts")["if"] or ""):find("(matrix.leg == 'macos-aarch64' || steps.main-newest.outputs.newest != 'false')", 1, true) ~= nil,
    "a push main moved past saves its verdicts")
  local relayed = job_of(relay_workflow().jobs, "relay").steps
  local _, relay_find_at = step_with_id(relayed, "queue-run")
  local fetched, fetched_at = step_with_id(relayed, "queue-compiles")
  local save, save_at = step_named(relayed, "save the merge queue's compiles and parses")
  assert(relay_find_at < fetched_at and fetched_at < save_at, "the compiles are relayed out of order")
  assert(fetched["if"] == "steps.queue-run.outputs.run != ''" and fetched["continue-on-error"] == true and
      param(fetched, "name") == "queue-compiles-${{ matrix.leg }}" and param(fetched, "path") == dir and
      param(fetched, "run-id") == "${{ steps.queue-run.outputs.run }}", "the relay's download of the compiles")
  assert(save["if"] == "steps.queue-compiles.outcome == 'success'" and save["continue-on-error"] == true and
      param(save, "path") == dir and param(save, "key") == "compiles-${{ matrix.leg }}-queue-${{ github.sha }}",
    "the relay's save of the compiles")
end

--- The relay runs on main's pushes alone, apart from ci.yml's concurrency,
--- one at a time and never cancelled: it reads the runs (`actions: read`)
--- and holds no write. It saves the queue's verdicts under the cache the
--- queue's own host named (driver.tl verdicts-name, verdicts-key), merged
--- into main's newest of that cache, and no step fails the job.
local function test_the_relay_saves_the_queues_verdicts_under_the_queues_name()
  local relay = relay_workflow()
  local triggers: mut {string} = {}
  for trigger in pairs(relay["on"]) do triggers[#triggers + 1] = trigger end
  local push = filters_of(relay["on"])["push"]
  local branches = push and push.branches
  assert(#triggers == 1 and branches ~= nil and #branches == 1 and branches[1] == "main",
    "the relay runs on other events: " .. table.concat(triggers, ", "))
  local concurrency = relay.concurrency or {}
  assert(concurrency["group"] == "relay" and concurrency["cancel-in-progress"] == false,
    "the relay is not in a group of its own, or is cancelled")
  local job = job_of(relay.jobs, "relay")
  -- A job a leg main's push runs, each relaying its own leg's: the queue's macOS suite has no push to relay to.
  local relayed: mut {string} = {}
  local queue_legs = platform_legs("queue")
  for _, entry in ipairs(legs_of(job, "full")) do
    local leg = assert(entry["leg"])
    relayed[#relayed + 1] = leg
    assert(job["runs-on"] == "${{ matrix.runner }}" and entry["runner"] == assert(queue_legs[leg])["runner"],
      "the relay of " .. leg .. " runs on another runner than its leg's")
  end
  table.sort(relayed)
  local pushed: mut {string} = {}
  for _, leg in pairs(platform_legs("push")) do
    -- macOS's push job saves its own: no relay runs on a macOS runner.
    if leg["leg"] == "macos-aarch64" then continue end
    pushed[#pushed + 1] = assert(leg["leg"])
    assert(assert(queue_legs[assert(leg["leg"])])["part"] == "suite", "the queue runs no suite of " .. tostring(leg["leg"]))
  end
  table.sort(pushed)
  assert(table.concat(relayed, " ") == table.concat(pushed, " "),
    "the relay's legs " .. table.concat(relayed, " ") .. " are not a push's " .. table.concat(pushed, " "))
  assert(map_of(job.permissions)["actions"] == "read" and map_of(job.permissions)["contents"] == "read",
    "the relay's permissions")
  local steps = job.steps
  local find = step_with_id(steps, "queue-run")
  assert(map_of(find.env)["SHA"] == "${{ github.sha }}" and
      map_of(find.env)["ARTIFACT"] == "queue-verdicts-${{ matrix.leg }}", "the relay looks for another run")
  local _, find_at = step_with_id(steps, "queue-run")
  local download, download_at = step_with_id(steps, "queue-download")
  local key, key_at = step_with_id(steps, "verdicts-key")
  local restore, restore_at = step_with_id(steps, "verdicts-restore")
  local merge, merge_at = step_with_id(steps, "verdicts-merged")
  local save, save_at = step_named(steps, "save test verdicts")
  assert(find_at < download_at and download_at < key_at and key_at < restore_at and restore_at < merge_at and
      merge_at < save_at, "the verdicts are relayed out of order")
  assert(param(download, "name") == "queue-verdicts-${{ matrix.leg }}" and
      param(download, "run-id") == "${{ steps.queue-run.outputs.run }}", "the relay's download of the verdicts")
  assert((key.run or ""):find("driver.tl verdicts-key \"${{ runner.temp }}/queue-verdicts\" ${{ matrix.leg }}", 1, true) ~= nil,
    "the cache's name is read otherwise")
  local named = "${{ steps.verdicts-key.outputs.verdicts }}"
  assert(param(restore, "key") == named and param(restore, "restore-keys") == named .. "\n" and
      param(restore, "path") == "${{ runner.temp }}/verdicts", "the relay restores another cache")
  assert(map_of(merge.env)["COSMIC_VERDICT_CACHE"] == "${{ runner.temp }}/verdicts/verdicts.db" and
      (merge.run or ""):find("driver.tl verdicts-merge", 1, true) ~= nil, "the verdicts are merged otherwise")
  assert(param(save, "key") == named .. "queue-${{ github.sha }}" and param(save, "path") == "${{ runner.temp }}/verdicts" and
      save["if"] == "steps.verdicts-merged.outcome == 'success'", "the relay saves the verdicts otherwise")
  for _, step in ipairs(steps) do
    assert(step.id == "driver" or step["continue-on-error"] == true or
        (step.uses or ""):find("actions/checkout@", 1, true) == 1,
      tostring(step.name) .. " can fail the relay")
  end
  -- The queue names its cache beside the verdicts it uploads.
  local platform = job_of(ci_workflow().jobs, "platform").steps
  local named_step, named_at = step_with_id(platform, "verdicts-named")
  local upload, upload_at = step_named(platform, "upload the merge queue's verdicts")
  assert(named_at < upload_at and map_of(named_step.env)["VERDICTS"] == "${{ steps.host-id.outputs.verdicts }}" and
      (named_step.run or ""):find("driver.tl verdicts-name \"${{ runner.temp }}/verdicts\"", 1, true) ~= nil and
      named_step["if"] == upload["if"] and named_step["continue-on-error"] == true, "the queue names its cache otherwise")
  assert(param(upload, "path") == "${{ runner.temp }}/verdicts/*.db\n${{ runner.temp }}/verdicts/cache-key",
    "the queue uploads its cache's name otherwise")
end

--- Each queue leg's suite job uploads the verdicts it trimmed where
--- its native suite passed, and main's push of the leg finds that run by
--- its commit, downloads them and merges them in after it restores its
--- cache and before its suites. The relay never fails the leg.
local function test_mains_push_takes_the_queues_verdicts_before_its_suites()
  local steps = job_of(ci_workflow().jobs, "platform").steps
  local _, restore_at = step_with_id(steps, "verdicts-restore")
  local find, find_at = step_with_id(steps, "queue-run")
  local download, download_at = step_with_id(steps, "queue-download")
  local merge, merge_at = step_named(steps, "take in the merge queue's verdicts")
  local _, suite_at = step_with_id(steps, "release-suite")
  assert(restore_at < find_at and find_at < download_at and download_at < merge_at and merge_at < suite_at,
    "the queue's verdicts are taken in out of order")
  assert(find["if"] == "github.event_name == 'push' && github.ref == 'refs/heads/main'" and
      map_of(find.env)["SHA"] == "${{ github.sha }}" and
      map_of(find.env)["ARTIFACT"] == "queue-verdicts-${{ matrix.leg }}" and
      (find.run or ""):find("driver.tl queue-run", 1, true) ~= nil,
    "the queue's run is looked for otherwise: " .. tostring(find["if"]))
  assert(download["if"] == "steps.queue-run.outputs.run != ''" and
      with_of(download)["run-id"] == "${{ steps.queue-run.outputs.run }}" and
      with_of(download)["name"] == "queue-verdicts-${{ matrix.leg }}",
    "the queue's verdicts are downloaded otherwise")
  assert((merge.run or ""):find("driver.tl verdicts-merge", 1, true) ~= nil and
      merge["if"] == "steps.queue-download.outcome == 'success'", "the queue's verdicts are merged otherwise")
  local upload, upload_at = step_named(steps, "upload the merge queue's verdicts")
  for _, step in ipairs({ find, download, merge, upload }) do
    assert(step["continue-on-error"] == true, tostring(step.name) .. " can fail the leg")
  end
  local _, trim_at = step_with_id(steps, "verdicts-trim")
  assert(trim_at < upload_at and suite_at < upload_at, "the queue uploads its verdicts before its suite and their trim")
  assert(upload["if"] == "github.event_name == 'merge_group' && job.status == 'success' && " ..
      "steps.release-suite.outcome == 'success' && steps.verdicts-trim.outputs.digest != ''" and
      with_of(upload)["name"] == "queue-verdicts-${{ matrix.leg }}",
    "the queue uploads its verdicts otherwise: " .. tostring(upload["if"]))
end

--- The merge queue and a manual run of a branch run the checked narrowing suite in three shares at once too, each a
--- job named for its share: whole and standing on no verdict, it took 1276 and 1289 s of its 1260 s deadline (#4241,
--- #4245). Main's push and the scheduled run, which save its verdicts, run it whole. Each share's uploads are its own.
local function test_the_queue_runs_the_narrowing_suite_in_three_shares()
  local narrowing = job_of(ci_workflow().jobs, "narrowing")
  assert(narrowing.name == "${{ matrix.name }}", "the narrowing job is not named for its share")
  local function shares(kind: string): string
    local out: mut {string} = {}
    for _, entry in ipairs(legs_of(narrowing, kind)) do
      out[#out + 1] = assert(entry["name"]) .. "=" .. assert(entry["shard"])
    end
    table.sort(out)
    return table.concat(out, " ")
  end
  local three = "linux-x86_64-checked-narrowing-1=1/3 linux-x86_64-checked-narrowing-2=2/3 linux-x86_64-checked-narrowing-3=3/3"
  assert(shares("queue") == three, "the queue's narrowing shares: " .. shares("queue"))
  assert(shares("dispatch") == three, "a branch's manual run's narrowing shares: " .. shares("dispatch"))
  for _, kind in ipairs({ "push", "full" }) do
    assert(shares(kind) == "linux-x86_64-checked-narrowing=", kind .. " runs the narrowing suite in shares: " .. shares(kind))
  end
  assert(full_condition(narrowing) == "github.event_name == 'schedule' || github.ref == 'refs/heads/main'",
    "the narrowing suite is whole on other manual runs: " .. tostring(full_condition(narrowing)))
  local env = map_of(narrowing.env)
  assert(env["COSMIC_CI_NARROWING_SHARD"] == "${{ matrix.shard }}" and env["COSMIC_WORKER"] == "linux-x86_64-checked-narrowing",
    "the share does not reach the suite, or a share keys its verdicts apart")
  for _, step in ipairs(narrowing.steps) do
    if step.uses ~= nil and step.uses:find("upload-artifact", 1, true) ~= nil then
      local name = tostring(with_of(step)["name"])
      assert(name:find("${{ matrix.name }}", 1, true) ~= nil, "two shares upload under one name: " .. name)
    end
  end
end

--- The merge queue and a manual run of a branch run the checked suite in three shares at once, each a job named for
--- its share, which saves no verdicts; every other run runs it whole, as one job, `linux-x86_64-checked`, whose run checks the C functions,
--- which a share cannot (build/test.tl). The performance fixture runs in the third share, and once elsewhere.
--- Each job's uploads are named for it, so the shares' do not collide.
local function test_the_queue_runs_the_checked_suite_in_three_shares()
  local checked = job_of(ci_workflow().jobs, "checked")
  assert(checked.name == "${{ matrix.name }}", "the checked job is not named for its share")
  local function shares(kind: string): string
    local out: mut {string} = {}
    for _, entry in ipairs(legs_of(checked, kind)) do
      out[#out + 1] = assert(entry["name"]) .. "=" .. assert(entry["shard"]) .. "=" .. assert(entry["performance"])
    end
    table.sort(out)
    return table.concat(out, " ")
  end
  assert(shares("queue") == "linux-x86_64-checked-1=1/3=skip linux-x86_64-checked-2=2/3=skip linux-x86_64-checked-3=3/3=run",
    "the queue's shares: " .. shares("queue"))
  for _, kind in ipairs({ "push", "full" }) do
    assert(shares(kind) == "linux-x86_64-checked==run", kind .. " runs the checked suite in shares: " .. shares(kind))
  end
  -- A manual run of a branch runs the queue's shares: whole, the suite took 1738-1749 s of its 1860 s deadline and
  -- missed it on slower runners (45557741219). The scheduled run and a manual run of main run it whole.
  assert(shares("dispatch") == shares("queue"), "a branch's manual run's shares: " .. shares("dispatch"))
  assert(full_condition(checked) == "github.event_name == 'schedule' || github.ref == 'refs/heads/main'",
    "the checked suite is whole on other manual runs: " .. tostring(full_condition(checked)))
  local env = map_of(checked.env)
  assert(env["COSMIC_CI_CHECKED_SHARD"] == "${{ matrix.shard }}" and env["COSMIC_WORKER"] == "linux-x86_64-checked",
    "the share does not reach the suite, or a share keys its verdicts apart")
  local performance = step_named(checked.steps, "check performance fixture histories on the checked core")
  assert(performance["if"] == "matrix.performance == 'run'", "the performance fixture runs in no share or in several")
  for _, step in ipairs(checked.steps) do
    if step.uses ~= nil and step.uses:find("upload-artifact", 1, true) ~= nil then
      local name = tostring(with_of(step)["name"])
      assert(name:find("${{ matrix.name }}", 1, true) ~= nil, "two shares upload " .. name)
    end
  end
  local trim = step_with_id(checked.steps, "verdicts-trim")
  assert((trim["if"] or ""):find("env.COSMIC_CI_SAVES == 'true'", 1, true) ~= nil, "a share saves verdicts")
end

--- The gate (`ci`, the one check a ruleset requires) needs every job and
--- fails on any that failed or was cancelled, but for a pull request's
--- cancelled run, which skips it. The checked and narrowing jobs read as
--- passed on a pull request, which skips them. On every
--- other run it compares the legs' products: the queue's three, a push's, the
--- scheduled and a manual run's four (prerelease.yml publishes from the
--- last two).
local function test_the_gate_needs_every_job_and_compares_the_legs_products()
  local jobs = ci_workflow().jobs
  local gate = job_of(jobs, "ci")
  assert(table.concat(needs_of(gate), ",") == "queue-ref,platform,checked,narrowing,driver" and
      gate["if"] == "always() && !(cancelled() && github.event_name == 'pull_request')",
    "the gate needs " .. table.concat(needs_of(gate), ","))
  local passed = step_named(gate.steps, "every job passed")
  local env = map_of(passed.env)
  assert(env["RESULT"] == "${{ (" .. BATCH_PR .. ") && 'success' || needs.platform.result }}" and
      env["CHECKED"] == "${{ github.event_name == 'pull_request' && 'success' || needs.checked.result }}" and
      env["NARROWING"] == "${{ github.event_name == 'pull_request' && 'success' || needs.narrowing.result }}" and
      env["DRIVER"] == "${{ (" .. BATCH_PR .. ") && 'success' || " ..
      "(github.event_name == 'merge_group' || github.event_name == 'pull_request') && needs.driver.result || 'success' }}" and
      env["QUEUE_REF"] == "${{ github.event_name == 'merge_group' && needs.queue-ref.result || 'success' }}" and
      (passed.run or ""):find("[ \"$DRIVER\" = success ]", 1, true) ~= nil and
      (passed.run or ""):find("[ \"$QUEUE_REF\" = success ]", 1, true) ~= nil,
    "the gate reads other results")
  local compare = step_named(gate.steps, "compare the Cosmic bytes executed on every native host")
  assert(compare["if"] == PR_SKIPS and
      map_of(compare.env)["COSMIC_CI_PRODUCTS"] ==
      "${{ (github.event_name == 'schedule' || github.event_name == 'push' || github.event_name == 'workflow_dispatch' && " ..
      "(github.ref == 'refs/heads/main' || inputs.macos)) && '4' || '3' }}",
    "the join compares other than main's products: " .. tostring(map_of(compare.env)["COSMIC_CI_PRODUCTS"]))
  local function count(legs: {string: {string: string}}): integer
    local n = 0
    for _ in pairs(legs) do n = n + 1 end
    return n
  end
  assert(count(platform_legs("push")) == 4 and count(platform_legs("full")) == 4, "the runs' legs")
  -- The queue's three products, one a leg's product job (alpine-x86_64's `portable`).
  local queued = 0
  for _, leg in pairs(platform_legs("queue")) do
    if leg["part"] == "product" or leg["part"] == "portable" then queued = queued + 1 end
  end
  assert(queued == 3, "the queue's products")
  -- prerelease.yml publishes four lanes, so only from a run of all four:
  -- the scheduled and a manual run of main, never a push. Its `follow`
  -- job alone reads a push's run, which publishes nothing.
  local prerelease = assert(decoded_workflows()[DIR .. "/prerelease.yml"])
  local publish = job_of(prerelease.jobs, "publish")["if"] or ""
  assert(publish:find("(github.event.workflow_run.event == 'schedule' || " ..
      "github.event.workflow_run.event == 'workflow_dispatch')", 1, true) ~= nil and
      publish:find("workflow_run.event == 'push'", 1, true) == nil,
    "prerelease.yml publishes from a run of fewer than four legs")
  assert(publish:sub(-#"|| needs.sweep.outputs.run_id != '')") == "|| needs.sweep.outputs.run_id != '')",
    "prerelease.yml publishes no run that sweep names: " .. publish)
  -- publish follows sweep, runs where sweep is skipped (a full run's
  -- end), and reads the run sweep names before the event's, so a push
  -- run's end publishes the run sweep names, never the push run.
  local publish_job = job_of(prerelease.jobs, "publish")
  assert(publish:find("!cancelled() && ", 1, true) == 1, "prerelease.yml's publish waits on a sweep it may skip: " .. publish)
  local needs = needs_of(publish_job)
  assert(#needs == 1 and needs[1] == "sweep", "prerelease.yml's publish does not follow sweep")
  local text = assert(Fs.read(DIR .. "/prerelease.yml"))
  local _, ids = text:gsub("needs%.sweep%.outputs%.run_id || github%.event%.workflow_run%.id", "")
  local _, shas = text:gsub("needs%.sweep%.outputs%.head_sha || github%.event%.workflow_run%.head_sha", "")
  local _, bare = text:gsub("{{ github%.event%.workflow_run%.id }}", "")
  local _, bare_shas = text:gsub("{{ github%.event%.workflow_run%.head_sha }}", "")
  assert(ids == 3 and shas == 4 and bare == 1 and bare_shas == 1,
    "prerelease.yml's publish reads other than the run workflow_run or sweep names: " ..
      tostring(ids) .. " ids, " .. tostring(shas) .. " commits, " .. tostring(bare) .. " bare ids")
  local sweep = job_of(prerelease.jobs, "sweep")
  assert(map_of(sweep.permissions)["contents"] == "read" and map_of(sweep.permissions)["actions"] == "write" and
      sweep["if"] == "github.repository == 'cosmic-lua/cosmic' && (github.event_name == 'schedule' || " ..
      "(github.event_name == 'workflow_run' && github.event.workflow_run.event == 'push' && " ..
      "github.event.workflow_run.head_branch == 'main'))",
    "prerelease.yml's sweep job runs other than hourly and after a push run of main, or holds more than it needs")
  local follow = job_of(prerelease.jobs, "follow")
  assert(map_of(follow.permissions)["contents"] == "read" and map_of(follow.permissions)["actions"] == "write" and
      map_of(follow.permissions)["issues"] == "write",
    "prerelease.yml's follow job's permissions")
  local follows = follow["if"] or ""
  assert(follows:find("github.repository == 'cosmic-lua/cosmic' && github.event.workflow_run.head_branch == 'main' && ", 1, true) == 1 and
      follows:find("pull_request", 1, true) == nil and follows:find("merge_group", 1, true) == nil,
    "prerelease.yml's follow job runs after a run of another repository, branch or event: " .. follows)
  assert(follows:find("(github.event.workflow_run.event == 'push' && (github.event.workflow_run.conclusion == 'success' || " ..
      "github.event.workflow_run.conclusion == 'failure'))", 1, true) ~= nil,
    "prerelease.yml's follow job does not run after a green and a red push run: " .. follows)
  local follow_env: mut {string: string} = {}
  for _, step in ipairs(follow.steps) do
    for name, value in pairs(map_of(step.env)) do follow_env[name] = value end
  end
  for _, name in ipairs({ "EVENT", "CONCLUSION", "ATTEMPT", "RUN_ID", "BRANCH", "HEAD_SHA", "REPOSITORY", "GH_TOKEN" }) do
    assert(follow_env[name] ~= nil, "prerelease.yml's follow job does not set " .. name .. ", which prerelease-follow needs")
  end
  for name in pairs(jobs) do
    assert(name == "queue-ref" or name == "platform" or name == "checked" or name == "narrowing" or name == "driver" or
        name == "ci",
      "ci.yml has a job " .. name)
  end
end

--- A pull request runs the `ci` check the merge queue requires of it, lighter than the queue's: linux-x86_64's leg, as
--- the queue's, boots the tree, runs its native suite and checks its format over the paths the pull request changed
--- since its merge base with main (`fix --check --changed`, every check spanning files over the whole tree), the
--- markers held to that base; and, where a path it changed reaches them, the
--- launcher and startup fixtures and the artifacts they run. macOS's leg runs its native suite and darwin suite. Each
--- suite stands on main's verdicts, so it runs the tests the change reaches, and a failure the queue would meet there
--- shows on the pull request first. No saved cache, and no other job.
local function test_a_pull_request_runs_the_suites_and_the_light_check()
  local ci = ci_workflow()
  assert(ci["on"]["pull_request"] ~= nil, "a pull request runs nothing")
  local steps = job_of(ci.jobs, "platform").steps
  local phases = phases_unless(steps, PR_SKIPS)
  assert(phases == "boot local-suite local-boundary format darwin-suite", "a pull request's leg runs " .. phases)
  -- Beside, where a path it changed reaches them, or the paths changed are not known, the launcher and startup
  -- fixtures and the artifacts they run, which the steps before them make.
  local gated: mut {string} = {}
  for _, step in ipairs(steps) do
    local phase = (step.run or ""):match("driver%.tl platform ([%w-]+)")
    if step["if"] == PR_FIXTURES or step["if"] == PR_ASSEMBLE then
      gated[#gated + 1] = phase or "?"
    end
  end
  assert(table.concat(gated, " ") == "assemble fixtures", "a pull request gates " .. table.concat(gated, " "))
  local _, at_changed = step_running(steps, "driver.tl changed-paths")
  local _, at_assemble = step_running(steps, "driver.tl platform assemble")
  assert(at_changed < at_assemble, "the fixtures' gate is read before the step that names the paths changed")
  local changed = step_named(steps, "name the paths the commit changed")
  assert(changed["if"] == "((matrix.leg == 'linux-x86_64' && " .. FORMAT_PART .. " && (github.event_name == 'merge_group' || " ..
      "github.event_name == 'pull_request')) || (matrix.leg == 'macos-aarch64' && github.event_name == 'merge_group')) && " ..
      "steps.ceilings-base.outputs.sha != ''" and map_of(changed.env)["BASE"] == "${{ steps.ceilings-base.outputs.sha }}" and
      (changed.run or ""):find("driver.tl changed-paths", 1, true) ~= nil, "the paths changed are named otherwise")
  assert(map_of(step_named(steps, "check the tree's format").env)["COSMIC_CI_FORMAT_CHANGED"] ==
      "${{ steps.changed.outputs.paths }}", "the check is not given the paths changed")
  local base = step_named(steps, "find the base the markers are held to")
  assert(base["if"] == "(" .. FORMAT_RUNS .. ") || (matrix.leg == 'macos-aarch64' && github.event_name == 'merge_group')",
    "the markers are held to no base on a pull request")
  -- The step fails the job where it finds no base, as the check would minutes later: a failure it tolerated would only
  -- be met there. A pull request for main reads its base from the checkout, so the step is told the branch.
  assert(base["continue-on-error"] == nil, "a run that finds no base goes on to the format check")
  assert(map_of(base.env)["PR_BASE_REF"] == "${{ github.base_ref }}", "the base step is not told the branch a pull request is for")
  -- Both fetch from origin with the checkout's credentials, which git finds only at the checkout's own path
  -- (actions/checkout's `includeIf.gitdir`), so they run before the tree moves.
  local _, moved = step_running(steps, "driver.tl place-tree")
  local _, based = step_running(steps, "driver.tl ceilings-base")
  local _, listed = step_running(steps, "driver.tl changed-paths")
  assert(based < moved and listed < moved, "a step fetches from origin after the tree moved, without the checkout's credentials")
  assert(names_of(platform_legs("pr")) == "linux-x86_64 macos-aarch64", "a pull request's legs")
  -- Marking a pull request ready runs the check again, with macOS's leg (ci/README.md).
  assert(names_of(platform_legs("draft")) == "linux-x86_64", "a draft's legs")
  local types = table.concat(filters_of(ci["on"])["pull_request"]!.types or {}, " ")
  assert(types == "opened synchronize reopened ready_for_review", "marking a pull request ready does not run its check: " ..
      types)
  for _, name in ipairs({ "checked", "narrowing" }) do
    assert(job_of(ci.jobs, name)["if"] == QUEUE_REF .. " && " .. PR_SKIPS, name .. " runs on a pull request")
  end
end

--- A batch's pull request runs no leg and no driver check, and its gate
--- passes: build/batch.tl stacks it from members whose newest `ci` passed,
--- and the merge queue tests the batch on every leg. Only a branch of this
--- repository takes it, so a fork's pull request named like one still runs.
local function test_a_batchs_pull_request_skips_its_legs_and_passes()
  local jobs = ci_workflow().jobs
  local skip = " && !(" .. BATCH_PR .. ")"
  assert(job_of(jobs, "platform")["if"] == QUEUE_REF .. skip,
    "a batch's pull request runs its legs: " .. tostring(job_of(jobs, "platform")["if"]))
  local driver = job_of(jobs, "driver")["if"] or ""
  assert(driver:sub(-#skip) == skip, "a batch's pull request runs the driver check: " .. driver)
  assert(BATCH_PR:find("head.repo.full_name == github.repository", 1, true) ~= nil,
    "a fork's pull request named like a batch skips its legs")
  for _, name in ipairs({ "checked", "narrowing" }) do
    assert(job_of(jobs, name)["if"] == QUEUE_REF .. " && " .. PR_SKIPS, name .. " runs on a batch's pull request")
  end
end

--- Each share of the checked suite uploads the C functions its tests did
--- not enter, and the `ci` gate joins every share's list, so a function no
--- test enters fails the merge queue, not main's push alone, which runs
--- the suite whole.
local function test_the_gate_joins_the_checked_shares_c_functions()
  local jobs = ci_workflow().jobs
  local upload = step_named(job_of(jobs, "checked").steps, "upload the C functions this share's tests did not enter")
  assert(upload["if"] == "matrix.shard != ''", tostring(upload["if"]))
  assert(with_of(upload)["name"] == "checked-unentered-${{ matrix.name }}", tostring(with_of(upload)["name"]))
  assert(with_of(upload)["overwrite"] == true, "a share's job run again cannot upload its list again")
  local gate = job_of(jobs, "ci").steps
  local download = step_with_id(gate, "unentered-download")
  assert(tostring(download["if"]):find("github.event_name == 'merge_group'", 1, true) ~= nil, tostring(download["if"]))
  assert(with_of(download)["pattern"] == "checked-unentered-*", tostring(with_of(download)["pattern"]))
  local join = step_named(gate, "fail for a C function no checked share entered")
  assert(tostring(join.run):find("driver.tl unentered-join", 1, true) ~= nil, tostring(join.run))
end

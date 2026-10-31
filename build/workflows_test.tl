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
  ["fail-fast"]?: boolean
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

local function at_of(at: {string: integer}, name: string): integer
  return (assert(at[name], "no step " .. name))
end

local function step_at(steps: {Step}, at: {string: integer}, name: string): Step
  return (assert(steps[at_of(at, name)]))
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

local function position(steps: {Step}, step: Step): integer
  for i, other in ipairs(steps) do
    if other == step then return i end
  end
  error("no such step among " .. tostring(#steps))
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

--- The condition a job takes a run as `full` on: the `scope` job's output
--- is anything but `light` (it is empty where the job is skipped, as on every
--- run but a branch push, or failed). ci.yml's COSMIC_CI_SCOPE is this, and
--- a matrix, which cannot read `env`, tests it again.
local FULL_RUN <const> = "needs.scope.outputs.scope != 'light'"

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

--- A matrix's combinations on a run of `scope` (`full` or `light`),
--- each the values it gets, as GitHub's docs ("Expanding or adding
--- matrix configurations") expand them: every combination of the
--- dimensions (a dimension FULL_RUN chooses between two lists, as
--- `${{ fromJSON(FULL_RUN && '[...]' || '[...]') }}`, is the one its
--- scope takes), less each one an `exclude` entry matches (every
--- dimension it names holds the value it gives, a partial match), then
--- each `include` entry added to every one of those
--- original combinations whose dimensions it does not contradict,
--- overwriting what an earlier entry added, or, where it contradicts
--- all of them, a combination of its own, which no later entry is
--- added to. With no dimension, each entry is a combination.
local function expand(matrix: {string: any}, scope: string): {{string: string}}
  local dims: mut {string} = {}
  for key in pairs(matrix) do
    if key ~= "include" and key ~= "exclude" then dims[#dims + 1] = key end
  end
  table.sort(dims)
  local combos: mut {{string: string}} = {}
  if #dims > 0 then combos = { {} } end
  for _, dim in ipairs(dims) do
    local value = matrix[dim]
    if value is string then
      local condition, full, light = value:match("^%${{ fromJSON%((.-) && '(%[.-%])' || '(%[.-%])'%) }}$")
      assert(condition == FULL_RUN, "matrix " .. dim .. " is chosen other than by the scope: " .. value)
      value = assert(Json.decode(assert(if scope == "full" then full else light end)))
    end
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
  for _, entry in ipairs(entries_of(matrix["include"])) do
    local added = false
    for _, combo in ipairs(combos) do
      local fits = true
      for _, dim in ipairs(dims) do
        if entry[dim] ~= nil and entry[dim] ~= combo[dim] then fits = false end
      end
      if fits then
        added = true
        for k, v in pairs(entry) do combo[k] = v end
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

--- A job's matrix legs on a run of `scope`, as [`expand`] gives them.
local function legs_of(job: Job, scope: string): {{string: string}}
  return expand(assert(assert(job.strategy).matrix), scope)
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

--- The platform job's name, and its COSMIC_WORKER, for a leg: the
--- leg's own, or `<leg>-shard` for a leg's second share.
local LEG_NAME <const> = "${{ matrix.shard == '2/2' && format('{0}-shard', matrix.name) || matrix.name }}"

--- The share of linux-x86_64's native suite a leg runs (COSMIC_CI_SHARD).
local LEG_SHARD <const> = "${{ matrix.name == 'linux-x86_64' && matrix.shard || '' }}"

--- [`LEG_NAME`] and [`LEG_SHARD`] of `leg`, as GitHub evaluates them.
local function leg_name(leg: {string: string}): string
  if leg["shard"] == "2/2" then return assert(leg["name"]) .. "-shard" end
  return assert(leg["name"])
end
local function leg_shard(leg: {string: string}): string
  if leg["name"] == "linux-x86_64" and leg["shard"] ~= "" then return assert(leg["shard"]) end
  return ""
end

--- The platform legs by job name ([`LEG_NAME`]), on a run of `scope`.
local function platform_legs(scope: string): {string: {string: string}}
  local ci = ci_workflow()
  local out: mut {string: {string: string}} = {}
  for _, leg in ipairs(legs_of(assert(ci.jobs["platform"]), scope)) do
    local name = leg_name(leg)
    assert(out[name] == nil, "two legs named " .. name)
    out[name] = leg
  end
  return out
end

--- A branch push (`light`) runs three platform legs, every other run
--- all four, each with its own values: alpine-x86_64, which a light
--- run leaves out, is linux-x86_64's runner and target in the alpine
--- image, and an entry of alpine-x86_64's values that another leg's did
--- not wholly overwrite would run that leg in the alpine image.
local function test_a_branch_push_runs_no_alpine_leg()
  local full, light = platform_legs("full"), platform_legs("light")
  local function names(legs: {string: {string: string}}): string
    local out: mut {string} = {}
    for name in pairs(legs) do out[#out + 1] = name end
    table.sort(out)
    return table.concat(out, " ")
  end
  assert(names(full) == "alpine-x86_64 linux-aarch64 linux-x86_64 macos-aarch64", "a full run's legs: " .. names(full))
  assert(names(light) == "linux-aarch64 linux-x86_64 linux-x86_64-shard macos-aarch64",
    "a light run's legs: " .. names(light))
  -- Each leg's entry sets every value the first, alpine-x86_64's, sets:
  -- one it left out would be alpine-x86_64's on that leg.
  local include = entries_of(assert(assert(job_of(ci_workflow().jobs, "platform").strategy).matrix)["include"])
  local first = assert(include[1])
  assert(first["name"] == nil, "the first entry names a leg: " .. tostring(first["name"]))
  for i = 2, #include do
    local entry = assert(include[i])
    assert(entry["name"] ~= nil, "entry " .. tostring(i) .. " names no leg")
    for key in pairs(first) do
      assert(entry[key] ~= nil, assert(entry["name"]) .. " keeps alpine-x86_64's " .. key)
    end
  end
  local alpine = assert(full["alpine-x86_64"])
  assert(alpine["runner"] == "ubuntu-24.04" and alpine["target"] == "x86_64-linux-musl" and
      assert(alpine["image"]):find("^ghcr%.io/cosmic%-lua/cosmic%-ci%-alpine@sha256:") ~= nil and
      assert(alpine["prepare"]):find("^adduser ") ~= nil and alpine["shell"] == "leg-shell {0}",
    "alpine-x86_64's values: " .. tostring(alpine["image"]) .. " " .. tostring(alpine["prepare"]))
  local keys: mut {string} = {}
  for key in pairs(alpine) do keys[#keys + 1] = key end
  for name, leg in pairs(full) do
    for _, key in ipairs(keys) do assert(leg[key] ~= nil, name .. " has no " .. key) end
    if name ~= "alpine-x86_64" then
      assert(assert(leg["image"]):find("alpine", 1, true) == nil and (leg["prepare"] or ""):find("adduser", 1, true) == nil,
        name .. " runs as alpine-x86_64 does: " .. assert(leg["image"]))
    end
    local other = light[name]
    for _, key in ipairs(keys) do
      -- A light run's share is its own (test_a_branch_push_splits_linux_x86_64s_suite_in_two).
      assert(other == nil or key == "shard" or other[key] == leg[key],
        name .. "'s " .. key .. " differs on a light run")
    end
  end
  assert(assert(full["macos-aarch64"])["image"] == "" and assert(full["macos-aarch64"])["prepare"] == "", "macos-aarch64 has an image")
end

--- A branch push (`light`) splits linux-x86_64's native suite, the
--- longest of its legs', in two: two legs of linux-x86_64's own
--- values, the first with COSMIC_CI_SHARD 1/2 and the second, named
--- linux-x86_64-shard, 2/2, each restoring and keying as that leg does
--- (its `name` in the matrix is the leg's) and uploading under a name
--- of its own; every other leg, and every leg of a full run, runs its
--- suite whole. The gate needs every leg.
local function test_a_branch_push_splits_linux_x86_64s_suite_in_two()
  local jobs = ci_workflow().jobs
  local platform = job_of(jobs, "platform")
  local env = map_of(platform.env)
  assert(platform.name == LEG_NAME, "the legs' name: " .. tostring(platform.name))
  assert(env["COSMIC_WORKER"] == LEG_NAME, "the legs' COSMIC_WORKER: " .. tostring(env["COSMIC_WORKER"]))
  assert(env["COSMIC_CI_SHARD"] == LEG_SHARD, "the legs' COSMIC_CI_SHARD: " .. tostring(env["COSMIC_CI_SHARD"]))
  local light, full = platform_legs("light"), platform_legs("full")
  local first, second = light["linux-x86_64"], light["linux-x86_64-shard"]
  assert(first ~= nil and second ~= nil, "a light run has no second linux-x86_64 leg")
  assert(leg_shard(first) == "1/2" and leg_shard(second) == "2/2",
    "linux-x86_64's shares: " .. leg_shard(first) .. " " .. leg_shard(second))
  for key, value in pairs(first) do
    assert(key == "shard" or second[key] == value, "linux-x86_64-shard's " .. key .. " differs")
  end
  for key in pairs(second) do assert(first[key] ~= nil, "linux-x86_64-shard has " .. key) end
  assert(second["name"] == "linux-x86_64", "the second share restores by " .. tostring(second["name"]))
  for name, leg in pairs(light) do
    if leg["name"] ~= "linux-x86_64" then
      assert(leg_shard(leg) == "", name .. " runs a share of its suite")
    end
  end
  for name, leg in pairs(full) do
    assert(leg_shard(leg) == "" and leg["shard"] == "", name .. " runs a share of a full run's suite")
    assert(leg_name(leg) == leg["name"], name .. " is named apart on a full run")
  end
  -- Every artifact a light run's leg uploads is named apart, by the
  -- job's name: two of one name would fail the second upload.
  for _, step in ipairs(platform.steps) do
    local uses = (step.uses or "")
    if uses:find("^actions/upload%-artifact@") then
      local condition = (step["if"] or "")
      local light_too = not (condition:find("COSMIC_CI_SCOPE == 'full'", 1, true) or
        condition:find("github.event_name == 'merge_group'", 1, true))
      if light_too then
        local upload_name = param(step, "name")
        assert(upload_name:find("${{ env.COSMIC_WORKER }}", 1, true) and not upload_name:find("matrix.name", 1, true),
          "a light run's legs upload " .. upload_name .. " under one name")
      end
    end
  end
  local needs = needs_of(job_of(jobs, "ci"))
  local gated = false
  for _, need in ipairs(needs) do
    if need == "platform" then gated = true end
  end
  assert(gated, "the gate does not need the legs")
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
      for _, step in ipairs(if shell ~= nil then job.steps else {} end) do
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
  assert(cached == 4, "the base's lookup, the restore, the save by content and its name under the commit: " .. tostring(cached))
end

--- The key a restore of the verdicts under `prefix` (an expression)
--- takes: the entry main named under the tree's base on main, where
--- `driver.tl merge-base` found that base and the lookup a name, else
--- `prefix` alone, whose restore-keys then take the newest.
local function at_the_base(prefix: string): string
  local inner = assert(prefix:match("^%${{ (.-) }}$"), prefix)
  return "${{ steps.verdicts-base.outputs.key || " .. inner .. " }}"
end

--- The prefix of the names under the tree's base that the lookup asks
--- for: each ends in the digest of the entry it names.
local function names_at_the_base(prefix: string): string
  local inner = assert(prefix:match("^%${{ (.-) }}$"), prefix)
  return "${{ format('{0}sha-{1}-', " .. inner .. ", steps.merge-base.outputs.sha) }}"
end

--- The key main names the entry of its verdicts under, under its commit.
local function under_the_commit(prefix: string): string
  return prefix .. "sha-${{ github.sha }}-${{ steps.verdicts-trim.outputs.digest }}"
end

--- Where main's name of a verdicts entry under a commit is saved from:
--- a path of its own, so an entry of another version than the verdicts',
--- which their restore by prefix never takes.
local VERDICTS_COMMIT <const> = "${{ runner.temp }}/verdicts-commit"

--- The steps that name, restore, trim and save a leg's test verdicts,
--- by id or by what they run or cache.
local function verdict_steps(steps: {Step}): mut {string: integer}
  local at: mut {string: integer} = {}
  for i, step in ipairs(steps) do
    local id = step.id or ""
    local run = (step.run or "")
    local with = with_of(step)
    if id == "host-id" or id == "merge-base" or id == "verdicts-base-lookup" or id == "verdicts-base" or
        id == "verdicts-restore" then
      at[id] = i
    elseif run:find("driver.tl verdicts-trim", 1, true) ~= nil then
      at["trim"] = i
    elseif with["path"] == "${{ runner.temp }}/verdicts" and
        assert(step.uses):find("actions/cache/save@", 1, true) ~= nil then
      at["save"] = i
    end
  end
  return at
end

--- Every leg keeps its test verdicts from one run to the next, the
--- macOS leg's too: its suites stand on them keyed by what each test
--- declares, with no sandbox to hold a worker to it
--- (COSMIC_CI_DECLARED_KEYS), on exactly the leg that is not required
--- sandboxed (COSMIC_CI_REQUIRE_SANDBOX). So no step of the cache turns
--- on the leg's image, and each comes in the order that serves it: the
--- host named, the tree's base on main found, the cache restored (the
--- base's entry, else the newest), the suites, the trim, the tree moved
--- back, and the save.
local function test_every_leg_keeps_its_verdicts()
  local jobs = ci_workflow().jobs
  local env = map_of(job_of(jobs, "platform").env)
  assert(env["COSMIC_CI_REQUIRE_SANDBOX"] == "${{ matrix.image && '1' || '0' }}",
    tostring(env["COSMIC_CI_REQUIRE_SANDBOX"]))
  assert(env["COSMIC_CI_DECLARED_KEYS"] == "${{ matrix.image && '0' || '1' }}",
    "the leg with no sandbox is not keyed by declarations: " ..
      tostring(env["COSMIC_CI_DECLARED_KEYS"]))
  local steps = job_of(jobs, "platform").steps
  local at = verdict_steps(steps)
  for i, step in ipairs(steps) do
    local id = step.id or ""
    if id == "boot" or id == "release-suite" or id == "portable-suite" then
      at[id] = i
    end
  end
  local order = { "host-id", "merge-base", "verdicts-base-lookup", "verdicts-base", "verdicts-restore", "boot",
    "release-suite", "portable-suite",
    "trim", "back", "save" }
  local _, back = step_named(steps, "move the tree back to where it was checked out")
  at["back"] = back
  for n, name in ipairs(order) do
    assert(at[name] ~= nil, "no step " .. name)
    if n > 1 then
      assert(at_of(at, assert(order[n - 1])) < at_of(at, name), assert(order[n - 1]) .. " comes after " .. name)
    end
    local condition = (step_at(steps, at, name)["if"] or "")
    assert(condition:find("matrix.image", 1, true) == nil,
      name .. " runs only on a leg with an image: " .. condition)
  end
  local restore = with_of(step_at(steps, at, "verdicts-restore"))
  assert(restore["key"] == at_the_base("${{ steps.host-id.outputs.verdicts }}"), restore["key"])
  assert(restore["restore-keys"] == "${{ steps.host-id.outputs.verdicts }}\n",
    restore["restore-keys"])
end

--- A job's `env` and each of its steps'.
local function envs_of(job: Job): {{string: string}}
  local out: mut {{string: string}} = { map_of(job.env) }
  for _, step in ipairs(job.steps) do out[#out + 1] = map_of(step.env) end
  return out
end

--- The condition on which a step of the checked job runs: a full run's,
--- or, for what that job runs in place of a leg on a branch push, a
--- light run's.
local FULL <const> = "env.COSMIC_CI_SCOPE == 'full'"
local LIGHT <const> = "env.COSMIC_CI_SCOPE == 'light'"

--- The condition on which a push to main and the scheduled run, and
--- no other, save a cache: ci.yml's COSMIC_CI_SAVES, which each save's
--- condition reads.
local MAIN_SAVES <const> = "${{ github.ref == 'refs/heads/main' && " ..
  "(github.event_name == 'push' || github.event_name == 'schedule') }}"
local SAVES <const> = "env.COSMIC_CI_SAVES == 'true'"

--- The prefix a branch's push saves its compiles under, for its own
--- later pushes, and restores them by first: `names`' output, which
--- names the leg and the compiler the compiles were made by.
local BRANCH_COMPILES <const> = "${{ steps.names.outputs.compiles }}"

--- Whether `key`, a save's, is a branch's compiles for its later pushes.
local function branch_compiles(key: string): boolean
  return key:find(BRANCH_COMPILES, 1, true) == 1
end

--- Holds each cache save of `steps`, a job's, to main's saves (below),
--- and counts them.
local function main_saves(steps: {Step}): integer
  local restores: mut {string: Step} = {}
  local trims: mut {string: string} = {}
  local saves = 0
  for _, step in ipairs(steps) do
    local uses = (step.uses or "")
    local with = with_of(step)
    local run = step.run
    if run is string then
      local verb = run:match("driver%.tl (%a+)%-trim")
      if verb ~= nil then
        assert(step.id ~= nil, verb .. "'s trim has no id")
        trims[verb] = assert(step.id)
      end
    end
    if uses:find("actions/cache/restore@", 1, true) ~= nil and step.id ~= nil then
      local path = param(step, "path")
      -- The one restore that turns on the ref: another vendor part's zig
      -- outputs, which main never takes. A restore only on a full run
      -- (`FULL`) is on every run main saves from: the checked job's
      -- verdicts, and the legs' driver check marker, which a light run
      -- checks in the checked job instead. There, a light run's lookup
      -- of linux-x86_64's marker (`LIGHT`) restores nothing, and that
      -- job saves no marker, which would find no restore here.
      local condition = (step["if"] or "")
      if condition:find(FULL, 1, true) == 1 then
        condition = condition:sub(#FULL + 5)
      end
      if condition == LIGHT and path == "${{ runner.temp }}/driver-checked" then
        assert(with["lookup-only"] == true, path .. " is restored on a light run")
      elseif path == VERDICTS_COMMIT then
        -- The name under the base, looked up where there is a base.
        assert(condition == "steps.merge-base.outputs.sha != ''" and with["lookup-only"] == true,
          path .. " is looked up where no base was found, or downloaded: " .. condition)
        restores[path] = step
      elseif condition ~= "" then
        assert(path == "${{ runner.temp }}/zig-build" and
            condition:find("github.ref != 'refs/heads/main'", 1, true) == 1,
          path .. " is restored only on some runs: " .. condition)
      else
        restores[path] = step
      end
    end
    if uses:find("actions/cache/save@", 1, true) ~= nil and
        not branch_compiles(param(step, "key")) then
      saves = saves + 1
      local path = param(step, "path")
      local condition = assert(step["if"])
      local key = param(step, "key")
      local restore = restores[path]
      assert(restore ~= nil, path .. " is saved but restored on no run before")
      assert(condition:find(SAVES, 1, true) ~= nil and
          not condition:find(SAVES .. " ||", 1, true) and not condition:find("|| " .. SAVES, 1, true),
        path .. " is saved off main, or by another of main's events: " .. condition)
      assert(not condition:find("merge_group", 1, true) and not key:find("event_name", 1, true),
        path .. "'s save turns on the merge queue: " .. condition .. " " .. key)
      local rkey = param(restore, "key")
      if path == VERDICTS_COMMIT then
        -- Whatever was restored: its own key is new each commit.
        local vrestore = restores["${{ runner.temp }}/verdicts"]
        local prefix = ((param(assert(vrestore), "restore-keys")):match("^([^\n]*)\n$"))
        assert(key == under_the_commit(assert(prefix)) and rkey == names_at_the_base(assert(prefix)),
          path .. " is saved under another key than the lookup asks for: " .. key)
        assert(not condition:find("cache-matched-key", 1, true) and
            condition:find("steps." .. assert(trims["verdicts"]) .. ".outputs.digest != ''", 1, true) ~= nil,
          path .. " is saved where the rows are an entry's, or where the trim named no digest: " .. condition)
      elseif key == "${{ steps." .. assert(restore.id) .. ".outputs.cache-primary-key }}" then
        assert(not rkey:find("github.sha", 1, true), path .. " is keyed by the commit: " .. rkey)
      else
        -- The trim of this cache, and the prefix the restore takes: the
        -- restore's key, or, for the verdicts, the base's entry first.
        local verdicts = path == "${{ runner.temp }}/verdicts"
        local trim = if verdicts then trims["verdicts"]
          elseif path == "${{ runner.temp }}/build-cache" then trims["compiles"] else nil end
        assert(trim ~= nil, path .. " is saved under a key of its own, cut by no trim: " .. key)
        -- Main's prefix last: a branch's compiles are asked for first
        -- (test_a_branch_saves_compiles_for_its_later_pushes).
        local rkeys = param(restore, "restore-keys")
        local prefix = rkeys:match("([^\n]*)\n$")
        if path == "${{ runner.temp }}/build-cache" then
          assert(rkey == BRANCH_COMPILES and rkeys == BRANCH_COMPILES .. "\n" .. assert(prefix) .. "\n",
            path .. " is restored by other prefixes than a branch's, then main's: " .. rkeys)
        else
          assert(rkeys == assert(prefix) .. "\n" and (rkey == prefix or verdicts and rkey == at_the_base(assert(prefix))),
            path .. " is restored by another prefix than it is saved under: " .. rkey)
        end
        local digest = "${{ steps." .. trim .. ".outputs.digest }}"
        assert(key == assert(prefix) .. digest, path .. " is not saved under its prefix and digest: " .. key)
        assert(condition:find("steps." .. trim .. ".outputs.digest != ''", 1, true) ~= nil,
          path .. " is saved where its trim named no digest: " .. condition)
      end
    end
  end
  return saves
end

--- Every cache the platform job and the checked job save, they save
--- from main alone -- a push or the scheduled run, never a branch's push
--- nor the merge queue's run -- and restore on every run, whatever its
--- event or ref, so a branch stands on what main saved and saves nothing
--- of its own but its compiles, for its own later pushes, under a prefix
--- of their own (test_a_branch_saves_compiles_for_its_later_pushes).
--- Main's pushes share one concurrency group that cancels nothing in
--- progress, so their saves land in commit order and a restore's newest
--- entry is never an older commit's saved late, with no lookup of the
--- newest entry before a save. A save's key is the restore's own, or,
--- for the caches a trim cuts to one run's rows, the restore's prefix
--- and the digest of those rows that the trim names: a run that kept
--- only what was saved already saves nothing new.
local function test_only_main_saves_a_cache_every_run_restores()
  local ci = ci_workflow()
  local concurrency = assert(ci.concurrency)
  local group = concurrency["group"]
  assert(group is string and not group:find("github.sha", 1, true),
    "main's pushes run in a group of each commit's own: " .. tostring(group))
  assert(concurrency["cancel-in-progress"] == "${{ github.ref != 'refs/heads/main' }}",
    "a run of main cancels another: " .. tostring(concurrency["cancel-in-progress"]))
  local saves_env = map_of(ci.env)["COSMIC_CI_SAVES"]
  assert(saves_env == MAIN_SAVES, "COSMIC_CI_SAVES is not main's push and schedule: " ..
      tostring(saves_env))
  local jobs = ci.jobs
  for name, job in pairs(jobs) do
    for _, env in ipairs(envs_of(job)) do
      assert(env["COSMIC_CI_SAVES"] == nil, "job " .. name .. " sets COSMIC_CI_SAVES again")
    end
  end
  assert(main_saves(job_of(jobs, "platform").steps) == 6,
    "the verdicts (by content and by commit), compiles, zig outputs, driver marker and pinned zig")
  assert(main_saves(job_of(jobs, "checked").steps) == 2,
    "the checked job's verdicts, by content and by commit")
end

--- The cache saves among `steps`, by the key each saves under: the
--- verdicts are saved by content, and named under the commit.
local function saves_of(steps: {Step}): {string: Step}
  local out: mut {string: Step} = {}
  for _, step in ipairs(steps) do
    if (step.uses or ""):find("actions/cache/save@", 1, true) ~= nil then
      local key = param(step, "key")
      assert(out[key] == nil, "two saves under " .. key)
      out[key] = step
    end
  end
  return out
end

--- The save among `steps` of `path` under a key that names no commit,
--- and the one that names it under the commit, from `<path>-commit`, if
--- any.
local function save_of(steps: {Step}, path: string): Step?, Step?
  local plain, commit: Step?, Step?
  for key, step in pairs(saves_of(steps)) do
    local from = param(step, "path")
    if from == path .. "-commit" and
        (key:find("sha-${{ github.sha }}-", 1, true) or key:find("outputs.verdicts-sha }}", 1, true)) ~= nil then
      commit = step
    elseif from == path then
      if branch_compiles(key) then
        -- A branch's, for its later pushes, which main never saves.
      else
        plain = step
      end
    end
  end
  return plain, commit
end

--- The step of `steps` whose `run` holds `text`, and where it stands.
local function step_running(steps: {Step}, text: string): Step, integer
  for i, step in ipairs(steps) do
    local run = step.run
    if run is string and run:find(text, 1, true) ~= nil then return step, i end
  end
  error("no step runs " .. text)
end

--- The index of the step of `steps` that bootstraps the pinned CI driver,
--- the first to use the local action.
local function driver_at(steps: {Step}): integer
  for i, step in ipairs(steps) do
    if step.uses == DRIVER then return i end
  end
  error("no step bootstraps the driver")
end

local CACHE_NAMES <const> = "./.github/actions/cache-names"

local function cache_names(): Action
  return read_as(ACTION, CACHE_NAMES, (assert(Fs.read(CACHE_NAMES .. "/action.yml"))))
end

--- What `names` hashes as the compiler a branch's compiles were made
--- by: the build's own modules, the new checker's source and Lua's pin and
--- patches, as the compiler's identity holds them (build.identity's
--- `compiler_identity`), and the rest of build/ beside.
local COMPILER_HASH <const> = "${{ hashFiles('build/**/*.tl', '!build/**/*_test.tl', " ..
  "'lang/**', '!lang/**/*_test.tl', 'vendor/lua/PIN', 'patch/lua/**') }}"

--- A branch's push saves its compiles for its own later pushes, where
--- its builds compiled more than a few dozen modules the entry it
--- restored lacked (`fresh`): a change to the compiler moves every
--- compile's key, and each later push would otherwise compile the whole
--- tree again on every leg. The save is a light run's alone (a branch's
--- push), once for linux-x86_64's two shares, under a prefix main never
--- saves under (`compiles-branch-`) that names the leg and the
--- compiler, trimmed to the run's rows and named by their digest as
--- main's are. Every restore of the compiles, the checked job's too,
--- asks for that prefix first and main's after, so a branch stands on
--- its own entry of the same compiler where there is one and main's
--- otherwise. The trim counts the fresh compiles against a copy of what
--- was restored, made before the boot.
local function test_a_branch_saves_compiles_for_its_later_pushes()
  local jobs = ci_workflow().jobs
  for job, leg in pairs({ platform = "${{ matrix.name }}", checked = "linux-x86_64" }) do
    local steps = job_of(jobs, job).steps
    local names = (step_with_id(steps, "names"))
    assert(names.uses == CACHE_NAMES and param(names, "leg") == leg,
      job .. " names a branch's compiles by another leg: " .. tostring(names.uses))
    local restore = texts_of(with_of((step_with_id(steps, "compiles-restore"))))
    assert(restore["key"] == BRANCH_COMPILES and
        restore["restore-keys"] == BRANCH_COMPILES .. "\ncompiles-" .. leg .. "-\n",
      job .. " restores other compiles than its branch's, then main's: " .. tostring(restore["restore-keys"]))
  end
  local action = cache_names()
  local names = assert(action.runs.steps[1])
  assert(map_of(names.env)["COMPILER"] == COMPILER_HASH,
    "the branch compiles hash different compiler inputs")
  assert(not ("compiles-branch-"):find("compiles-${{ matrix.name }}-", 1, true),
    "main's prefix takes a branch's entries")

  local steps = job_of(jobs, "platform").steps
  local branch: mut {Step} = {}
  for key, step in pairs(saves_of(steps)) do
    if branch_compiles(key) then branch[#branch + 1] = step end
  end
  assert(#branch == 1, "a branch's compiles are saved by " .. tostring(#branch) .. " steps")
  local with = with_of(branch[1])
  assert(with["path"] == "${{ runner.temp }}/build-cache" and
      with["key"] == BRANCH_COMPILES .. "${{ steps.compiles-trim.outputs.digest }}",
    "a branch's compiles are saved from elsewhere, or not by their digest: " .. tostring(with["key"]))
  local condition = assert(assert(branch[1])["if"])
  for _, part in ipairs({ "steps.release-suite.outcome == 'success'", "steps.compiles-trim.outputs.digest != ''",
      LIGHT, "matrix.shard != '2/2'", "fromJSON(steps.compiles-trim.outputs.fresh || '0') > 50" }) do
    assert(condition:find(part, 1, true) ~= nil, "a branch saves its compiles without " .. part .. ": " .. condition)
  end
  assert(not condition:find(SAVES, 1, true), "main saves a branch's compiles: " .. condition)
  for _, step in pairs(saves_of(job_of(jobs, "checked").steps)) do
    assert(not branch_compiles(param(step, "key")), "the checked job saves a branch's compiles")
  end

  -- The copy of what was restored: made after the restore and before
  -- the boot, where the trim reads it, outside the path saved.
  local _, restored = step_with_id(steps, "compiles-restore")
  local _, boot = step_named(steps, "build release Cosmic")
  local copier, copy = step_running(steps, "cp \"$RUNNER_TEMP/build-cache/cache.db\" " ..
      "\"$RUNNER_TEMP/compiles-restored.db\"")
  -- On a light run alone, since only it saves; a copy that fails
  -- only costs a save, so it never fails the leg.
  assert(copier["if"] == "env.COSMIC_CI_SCOPE == 'light'" and copier["continue-on-error"] == true and
      copier.shell == "sh", "the copy is made on a run that saves none, fails the leg, or runs in the container")
  assert(restored < copy and copy < boot,
    "the compiles restored are copied elsewhere than between their restore and the boot")
  local trim = step_running(steps, "driver.tl compiles-trim")
  assert(assert(trim.run):find("compiles-trim \"${{ steps.names.outputs.since }}\" " ..
      "\"${{ runner.temp }}/compiles-restored.db\"", 1, true) ~= nil,
    "the trim counts the fresh compiles against another file: " .. assert(trim.run))
end

--- A push to main tests the commit the merge queue just tested, so it
--- reuses that run where it finds it: `reuse` looks it up on a push to
--- main alone (a branch push's legs wait on no runner of its), the
--- platform legs run exactly where it found none, or was skipped, and
--- `seed` exactly where it found one, on the platform legs' own
--- runners and the checked job's, an entry's version hashing its path.
--- What `seed` downloads is the queue run's, and what it saves it saves
--- at the platform legs' paths under the keys the queue's leg named; it
--- relays each leg's product under the platform leg's name (the checked
--- job has none), and the join reads its result in place of theirs.
local function test_a_main_push_reuses_the_queue_run()
  local ci = ci_workflow()
  local jobs = ci.jobs
  local reuse, platform, seed = job_of(jobs, "reuse"), job_of(jobs, "platform"), job_of(jobs, "seed")
  -- A push to main alone: a branch push's legs wait on no runner of its.
  assert(reuse["if"] == "github.event_name == 'push' && github.ref == 'refs/heads/main'", tostring(reuse["if"]))
  assert(map_of(reuse.permissions)["actions"] == "read", "reuse cannot read the queue's run")
  for _, step in ipairs(reuse.steps) do
    assert(step["if"] == nil, "reuse skips a step of its own: " .. tostring(step["if"]))
  end
  local find, found_at = step_running(reuse.steps, "driver.tl queue-find")
  assert(find.id == "find" and find.run == "cosmic-driver cosmic_ci/driver.tl queue-find" and
      find["working-directory"] == "ci", tostring(find.run))
  -- The driver is bootstrapped before the lookup, and a driver that cannot be had is no
  -- lookup, which the legs meet as one that found nothing.
  local bootstrap = reuse.steps[driver_at(reuse.steps)]
  assert(driver_at(reuse.steps) < found_at and assert(bootstrap)["continue-on-error"] == true,
    "reuse looks up before it has the driver, or fails for want of it")
  assert(map_of(find.env)["SHA"] == "${{ github.sha }}", "reuse looks up another commit")
  -- A lookup that fails is none: the legs run, and the join reads theirs.
  assert(find["continue-on-error"] == true, "a failed lookup fails reuse")
  -- Its budget, from the driver's defaults, is under the job's timeout
  -- with a minute to spare for the checkout.
  local script = assert(Fs.read("ci/cosmic_ci/queue_seed.tl"))
  local tries = script:match('whole%(env, "TRIES", (%d+)%)')
  local wait = script:match('whole%(env, "WAIT_SECONDS", (%d+)%)')
  local call = script:match('whole%(env, "CALL_SECONDS", (%d+)%)')
  assert(tries ~= nil and wait ~= nil and call ~= nil, "queue_seed.tl's budget moved")
  local budget = assert(math.tointeger(assert(tonumber(tries)) * (assert(tonumber(wait)) + 2 * assert(tonumber(call)))))
  assert(budget + 60 <= assert(reuse["timeout-minutes"]) * 60, "reuse times out within its lookup's budget, " ..
      tostring(budget) .. " s: " .. tostring(reuse["timeout-minutes"]))
  assert(map_of(reuse.outputs)["run"] == "${{ steps.find.outputs.run }}", "reuse's output")

  -- `!cancelled()` runs the legs where `reuse` was skipped (every run but
  -- a push to main) or failed, as where it found nothing: without a
  -- status function, a job whose need was skipped is skipped too.
  assert(Json.encode_any(platform.needs) == '["reuse","scope"]' and
      platform["if"] == "!cancelled() && needs.reuse.outputs.run == ''",
    "the platform legs run other than where no queue run was found: " .. tostring(platform["if"]))
  assert(seed.needs == "reuse" and seed["if"] == "needs.reuse.outputs.run != ''",
    "seed runs other than where a queue run was found: " .. tostring(seed["if"]))
  assert(map_of(seed.permissions)["actions"] == "read", "seed cannot read the queue's run")

  local function legs(job: Job): mut {string: string}
    local out: mut {string: string} = {}
    for _, leg in ipairs(legs_of(job, "full")) do
      out[assert(leg["name"])] = assert(leg["runner"])
    end
    return out
  end
  local ours, theirs, count = legs(seed), legs(platform), 0
  local checked = job_of(jobs, "checked")
  local checked_name = map_of(checked.env)["COSMIC_WORKER"]
  theirs[assert(checked_name)] = assert(checked["runs-on"])
  assert(seed["runs-on"] == platform["runs-on"], "seed runs on another runner than its leg")
  for name, runner in pairs(theirs) do
    count = count + 1
    assert(ours[name] == runner, "seed's " .. name .. " runs on " .. tostring(ours[name]) .. ", its leg on " .. runner)
  end
  for name in pairs(ours) do
    assert(theirs[name] ~= nil, "seed has a leg the platform job has not: " .. name)
  end
  assert(count == 5, "legs: " .. tostring(count))
  -- Only the checked job's seed relays no product.
  local marked: mut {string: string} = {}
  for _, leg in ipairs(entries_of(assert(assert(seed.strategy).matrix)["include"])) do
    if leg["checked"] ~= nil then marked[assert(leg["name"])] = assert(leg["checked"]) end
  end
  for name in pairs(ours) do
    assert(marked[name] == (if name == checked_name then "json:true" else nil end), "seed's " .. name .. " is marked checked: " .. tostring(marked[name]))
  end
  -- The lookup asks for every leg's seed, and the checked job's.
  local named: mut {string} = {}
  for _, leg in ipairs(legs_of(platform, "full")) do
    named[#named + 1] = assert(leg["name"])
  end
  named[#named + 1] = assert(checked_name)
  assert(map_of(find.env)["LEGS"] == table.concat(named, " "),
    "reuse asks for other legs' seeds: " .. tostring(map_of(find.env)["LEGS"]))

  local steps = seed.steps
  local downloads: mut {string: boolean} = {}
  local uploads: mut {string: boolean} = {}
  for _, step in ipairs(steps) do
    local uses = (step.uses or "")
    local with = with_of(step)
    local artifact = uses:find("actions/download-artifact@", 1, true) ~= nil or
      uses:find("actions/upload-artifact@", 1, true) ~= nil
    -- The zig outputs' download is held apart, below.
    if artifact and with["name"] ~= "seed-zig-${{ matrix.name }}" then
      local product = with["name"] == "portable-product-${{ matrix.name }}"
      assert(step["if"] == (if product then "!matrix.checked" else nil end),
        "seed relays a product on the checked job's leg, or skips its seed there: " .. tostring(step["if"]))
    end
    if uses:find("actions/download-artifact@", 1, true) ~= nil then
      assert(with["run-id"] == "${{ needs.reuse.outputs.run }}" and with["github-token"] == "${{ github.token }}",
        "seed downloads " .. param(step, "name") .. " from another run than the queue's")
      downloads[param(step, "name")] = true
    elseif uses:find("actions/upload-artifact@", 1, true) ~= nil then
      uploads[param(step, "name")] = true
    end
  end
  assert(downloads["seed-${{ matrix.name }}"] == true and downloads["portable-product-${{ matrix.name }}"] == true,
    "seed downloads neither the leg's seed nor its product")
  assert(uploads["portable-product-${{ matrix.name }}"], "seed relays no product")
  local relayed = 0
  for _, step in ipairs(platform.steps) do
    local with = with_of(step)
    if with["name"] == "portable-product-${{ matrix.name }}" then
      relayed = relayed + 1
    end
  end
  assert(relayed == 1, "the platform legs upload their product under another name")

  -- Each key the leg's own, of the shape its save takes.
  local keys = step_running(steps, "seed.keys")
  -- Each key names the leg, then what only the leg's own key holds
  -- there (its host's hex, or its digest), so linux-x86_64's entry takes
  -- none of linux-x86_64-checked's.
  assert(keys.id == "keys" and keys.run == "grep -E '^(verdicts=verdicts-${{ matrix.name }}-[0-9a-f]{16}-[0-9a-f]+-" ..
      "[0-9a-f]+|verdicts-sha=verdicts-${{ matrix.name }}-[0-9a-f]{16}-[0-9a-f]+-sha-${{ github.sha }}-[0-9a-f]+|" ..
      "compiles=compiles-${{ matrix.name }}-[0-9a-f]+|" ..
      "zig-build=zig-build-${{ matrix.name }}-[0-9a-f]+-full-[0-9a-f]+-[0-9]+-[0-9]+|" ..
      "zig-build-exact=zig-build-${{ matrix.name }}-[0-9a-f]+-full-[0-9a-f]+-|" ..
      "driver-checked=driver-checked-v2-${{ matrix.name }}-" ..
      "[A-Za-z0-9._-]+-verdicts-${{ matrix.name }}-[0-9a-f]{16}-[0-9a-f]+)$' " ..
      "\"$RUNNER_TEMP/seed.keys\" >> \"$GITHUB_OUTPUT\" || :",
    "seed reads other keys: " .. tostring(keys.run))
  local theirs_saved: mut {string: boolean} = {}
  for _, step in pairs(saves_of(platform.steps)) do
    theirs_saved[param(step, "path")] = true
  end
  local saved = 0
  for key, step in pairs(saves_of(steps)) do
    saved = saved + 1
    local path = param(step, "path")
    assert(theirs_saved[path], "seed saves " .. path .. ", which no platform leg saves")
    local name = key:match("^%${{ steps%.keys%.outputs%.([%w-]+) }}$")
    assert(name ~= nil, path .. " is seeded under a key the queue did not name: " .. key)
    -- The zig outputs' save is held apart, below.
    if name ~= "zig-build" then
      assert(step["if"] == "steps.keys.outputs." .. name .. " != ''", path .. " is seeded where no key was named")
      assert(step["continue-on-error"] == nil, path .. "'s seed may fail unseen")
    end
  end
  assert(saved == 5, "the verdicts (by content, and their name under the commit), compiles, zig outputs and driver marker: " .. tostring(saved))
  -- The zig outputs, after the product's relay, and none of it a
  -- failure: a lookup by the prefix of their core and vendor part, a
  -- leg's restore's first, then, where it found none, the queue leg's
  -- artifact of them, the tar laid out with its modes, and the save.
  local zig_steps: mut {Step} = {}
  local relay: integer?
  for i, step in ipairs(steps) do
    local with = with_of(step)
    if with["name"] == "portable-product-${{ matrix.name }}" and
        assert(step.uses):find("actions/upload-artifact@", 1, true) ~= nil then
      relay = i
    end
    if relay ~= nil and i > relay then zig_steps[#zig_steps + 1] = step end
  end
  assert(#zig_steps == 4, "the zig outputs take other steps than four after the relay: " .. tostring(#zig_steps))
  for _, step in ipairs(zig_steps) do
    assert(step["continue-on-error"] == true, tostring(step.name or step.id) .. " can fail seed")
  end
  local lookup, download, unpack, zig = zig_steps[1], zig_steps[2], zig_steps[3], zig_steps[4]
  local lwith = with_of(assert(lookup))
  assert(assert(assert(lookup).uses):find("actions/cache/restore@", 1, true) ~= nil and lwith["lookup-only"] == true and
      assert(lookup)["if"] == "steps.keys.outputs.zig-build != ''" and
      lwith["path"] == "${{ runner.temp }}/zig-build" and lwith["key"] == "${{ steps.keys.outputs.zig-build }}" and
      lwith["restore-keys"] == "${{ steps.keys.outputs.zig-build-exact }}\n",
    "seed looks up another entry than one of the core and vendor part it saves")
  local dwith = with_of(assert(download))
  assert(assert(assert(download).uses):find("actions/download-artifact@", 1, true) ~= nil and
      dwith["name"] == "seed-zig-${{ matrix.name }}" and dwith["path"] == "${{ runner.temp }}" and
      assert(download)["if"] == "steps.keys.outputs.zig-build != '' && steps." .. assert(assert(lookup).id) ..
      ".outputs.cache-matched-key == ''",
    "seed downloads the zig outputs elsewhere, or where an entry of their core holds them: " .. tostring(assert(download)["if"]))
  assert(assert(unpack)["if"] == "steps." .. assert(assert(download).id) .. ".outcome == 'success'" and assert(unpack).run ==
      "tar -xf \"$RUNNER_TEMP/zig-build.tar\" -C \"$RUNNER_TEMP\" && rm \"$RUNNER_TEMP/zig-build.tar\"",
    "the zig outputs are laid out elsewhere, or on other runs, than downloaded: " .. tostring(assert(unpack).run))
  assert(save_of(steps, "${{ runner.temp }}/zig-build") == zig and
      assert(zig)["if"] == "steps." .. assert(unpack.id) .. ".outcome == 'success'",
    "the zig outputs are saved other than right after they are laid out: " .. tostring(assert(zig)["if"]))

  local join = job_of(jobs, "ci")
  local needs = needs_of(join)
  assert(table.concat(needs, ",") == "reuse,scope,platform,checked,checked-shard,checked-narrowing,format,seed",
    "the join needs " .. table.concat(needs, ","))
  -- The join passes on the legs, the checked job and its shares, and the
  -- checked narrowing run that ran, and (on a light run, and the scheduled
  -- one's that saves the check's memo) the format check,
  -- `seed`'s where a queue run was found, and on nothing of `reuse`'s but
  -- its output. What the scope does not run reads as passed.
  local check = join.steps[1]
  local check_env = map_of(assert(check).env)
  assert(check_env["RESULT"] == "${{ needs.reuse.outputs.run != '' && needs.seed.result || needs.platform.result }}",
    "the join reads the legs that ran: " .. tostring(check_env["RESULT"]))
  assert(check_env["CHECKED"] == "${{ needs.reuse.outputs.run != '' && needs.seed.result || needs.checked.result }}",
    "the join reads another checked suite than the one that ran: " .. tostring(check_env["CHECKED"]))
  local seeded = "needs.reuse.outputs.run != '' && needs.seed.result || "
  assert(check_env["SHARES"] == "${{ " .. seeded .. "env.COSMIC_CI_SCOPE == 'full' && needs.checked-shard.result || 'success' }}",
    "the join reads other shares than the ones that ran: " .. tostring(check_env["SHARES"]))
  assert(check_env["NARROWING"] == "${{ " .. seeded ..
      "env.COSMIC_CI_SCOPE == 'full' && needs.checked-narrowing.result || 'success' }}",
    "the join reads another checked narrowing run than the one that ran: " .. tostring(check_env["NARROWING"]))
  assert(check_env["FORMAT"] == "${{ (env.COSMIC_CI_SCOPE == 'light' || github.event_name == 'schedule') && " ..
      "needs.format.result || 'success' }}",
    "the join reads another format check than the one that ran: " .. tostring(check_env["FORMAT"]))
  assert(assert(check).run == "echo \"queue run: ${QUEUE_RUN:-(none)}; legs: $RESULT; checked suite: $CHECKED; " ..
      "shares: $SHARES; checked narrowing: $NARROWING; format: $FORMAT\"; " ..
      "[ \"$RESULT\" = success ] && [ \"$CHECKED\" = success ] && [ \"$SHARES\" = success ] && " ..
      "[ \"$NARROWING\" = success ] && [ \"$FORMAT\" = success ] || { [ \"$EVENT\" != merge_group ] || " ..
      "echo \"a failed leg cancels a queue run, so the other legs may read cancelled; " ..
      "an error annotation names the failed leg\"; exit 1; }",
    "the join passes on more or less than the legs and the checked suite: " .. tostring(assert(check).run))
  local reads <const>: {string: boolean} = { RESULT = true, CHECKED = true, SHARES = true, NARROWING = true,
    FORMAT = true, QUEUE_RUN = true, EVENT = true }
  for name, value in pairs(check_env) do
    assert(reads[name], "the join reads " .. name .. ": " .. value)
  end
end

--- A leg of the queue's run that passed keeps what main would have
--- saved, under the key main would have saved it under: its restore's
--- prefix and its trim's digest, where that is not the entry it
--- restored, and the driver check's marker, which holds its key. It
--- does so after both trims and its container's removal, with its tree
--- still moved (the driver runs before the tree is put back), and
--- uploads it as `seed-<leg>`, which `seed` downloads where it lays it
--- out again.
local function test_the_queue_keeps_what_main_would_save()
  local ci = ci_workflow()
  local jobs = ci.jobs
  local steps = job_of(jobs, "platform").steps
  local stage, at = step_running(steps, "driver.tl queue-stage")
  local QUEUE <const> = "success() && github.event_name == 'merge_group'"
  assert(stage["if"] == QUEUE, "the queue's legs keep their seed on other runs: " .. tostring(stage["if"]))
  -- On the host, from ci/ like every driver command, so the driver runs
  -- where the runner's $RUNNER_TEMP is.
  assert(stage.shell == "sh" and stage["working-directory"] == nil,
    "the seed is kept elsewhere than on the host from ci/")
  local env = map_of(stage.env)
  for cache, path in pairs({ VERDICTS = "${{ runner.temp }}/verdicts", COMPILES = "${{ runner.temp }}/build-cache" }) do
    local save = assert(save_of(steps, path))
    local key = param(save, "key")
    assert(assert(env[cache .. "_PREFIX"]) .. assert(env[cache .. "_DIGEST"]) == key,
      cache .. " is seeded under another key than main saves it under: " .. key)
    assert(env[cache .. "_RESTORED"] ~= nil and assert(save["if"]):find(
      assert((env[cache .. "_RESTORED"] or ""):match("^%${{ (.-) }}$")), 1, true) ~= nil,
      cache .. "'s seed is compared with another entry than main's save is")
  end
  -- The zig outputs under the key main's save names, the restore's own,
  -- except where that restore took an entry of this core and vendor
  -- part: the first prefix it asks for.
  local zig = assert(save_of(steps, "${{ runner.temp }}/zig-build"))
  local zkey = param(zig, "key")
  local restore = zkey:match("^%${{ steps%.([%w-]+)%.outputs%.cache%-primary%-key }}$")
  assert(restore ~= nil and env["ZIG_BUILD_KEY"] == zkey and
      env["ZIG_BUILD_RESTORED"] == "${{ steps." .. restore .. ".outputs.cache-matched-key }}",
    "the zig outputs are seeded under another key than main saves them under, or held to another entry: " ..
      tostring(env["ZIG_BUILD_KEY"]))
  local zrestore = step_with_id(steps, restore)
  local first = ((param(zrestore, "restore-keys")):match("^([^\n]*)\n"))
  assert(env["ZIG_BUILD_EXACT"] == first and assert(first):find("-${{ steps.names.outputs.core }}-", 1, true) ~= nil,
    "the zig outputs are held to another entry than one of this core: " .. tostring(env["ZIG_BUILD_EXACT"]))
  -- And the verdicts under the commit, which is the queue's merge.
  local _, saved_twin = save_of(steps, "${{ runner.temp }}/verdicts")
  local twin = assert(saved_twin)
  assert(env["SHA"] == "${{ github.sha }}" and
      under_the_commit(assert(env["VERDICTS_PREFIX"])) == param(twin, "key"),
    "the verdicts are seeded under another commit's key than main saves them under")
  local marker = assert(save_of(steps, "${{ runner.temp }}/driver-checked"))
  local _, checked = step_running(steps, "cosmic-driver test cosmic_ci")
  local writes = assert(assert(steps[checked]).run)
  assert(writes:find("echo \"" .. param(marker, "key") .. "\" > \"$RUNNER_TEMP/driver-checked/key\"",
    1, true) ~= nil, "the driver check's marker does not hold the key main saves it under: " .. writes)
  local _, trimmed = step_running(steps, "driver.tl verdicts-trim")
  local _, compiled = step_running(steps, "driver.tl compiles-trim")
  local _, back = step_named(steps, "move the tree back to where it was checked out")
  local _, gone = step_named(steps, "remove the leg's container")
  assert(trimmed < at and compiled < at and gone < at and at < back,
    "the seed is kept before a trim, beside the leg's container, or after the tree is put back")
  local upload = steps[at + 1]
  local with = with_of(assert(upload))
  assert(assert(upload)["if"] == QUEUE and with["name"] == "seed-${{ matrix.name }}" and with["path"] == "${{ runner.temp }}/seed" and
      assert(upload)["continue-on-error"] == nil, "the seed is not uploaded as the leg's, or may fail unseen")
  -- The zig outputs apart, where a failure fails nothing.
  local zupload = steps[at + 2]
  local zwith = with_of(assert(zupload))
  assert(assert(zupload)["if"] == QUEUE and assert(zupload)["continue-on-error"] == true and
      zwith["name"] == "seed-zig-${{ matrix.name }}" and zwith["path"] == "${{ runner.temp }}/seed-zig" and
      zwith["if-no-files-found"] == "ignore",
    "the zig outputs are uploaded other than apart from the seed, and failing nothing: " .. tostring(zwith["name"]))
  local found_download: {string: string}?
  for _, step in ipairs(job_of(jobs, "seed").steps) do
    local w = with_of(step)
    if w["name"] == "seed-${{ matrix.name }}" then found_download = texts_of(w) end
  end
  local download = assert(found_download, "the seed is downloaded by no step")
  assert(download["path"] == "${{ runner.temp }}", "the seed is laid out elsewhere than it was kept: " .. assert(download["path"]))

  -- The checked job keeps its verdicts alone, as a leg keeps its own,
  -- after its trim and with its container gone, under its own name.
  local cjob = job_of(jobs, "checked")
  local csteps = cjob.steps
  local cstage, cat = step_running(csteps, "driver.tl queue-stage")
  assert(cstage["if"] == QUEUE and cstage.shell == "sh" and cstage["working-directory"] == nil,
    "the checked job keeps its seed on other runs, or elsewhere: " .. tostring(cstage["if"]))
  local cenv = map_of(cstage.env)
  local saved_vsave, saved_vtwin = save_of(csteps, "${{ runner.temp }}/verdicts")
  local vsave, vtwin = assert(saved_vsave), assert(saved_vtwin)
  assert(assert(cenv["VERDICTS_PREFIX"]) .. assert(cenv["VERDICTS_DIGEST"]) == param(vsave, "key"),
    "the checked job's verdicts are seeded under another key than main saves them under")
  assert(cenv["SHA"] == "${{ github.sha }}" and
      under_the_commit(assert(cenv["VERDICTS_PREFIX"])) == param(vtwin, "key"),
    "the checked job's verdicts are seeded under another commit's key than main saves them under")
  assert(assert(vsave["if"]):find(assert((cenv["VERDICTS_RESTORED"] or ""):match("^%${{ (.-) }}$")), 1, true) ~= nil,
    "the checked job's seed is compared with another entry than main's save is")
  assert(cenv["COMPILES_PREFIX"] == nil and save_of(csteps, "${{ runner.temp }}/build-cache") == nil,
    "the checked job keeps compiles, which linux-x86_64's leg saves")
  assert(cenv["ZIG_BUILD_KEY"] == nil and save_of(csteps, "${{ runner.temp }}/zig-build") == nil,
    "the checked job keeps zig outputs, which linux-x86_64's leg saves under the same key")
  local _, ctrim = step_running(csteps, "driver.tl verdicts-trim")
  local _, removed = step_named(csteps, "remove the leg's container")
  local _, cback = step_named(csteps, "move the tree back to where it was checked out")
  assert(ctrim < cat and removed < cat and cat < cback,
    "the checked job's seed is kept before its trim, beside its container, or after its tree is put back")
  local cupload = csteps[cat + 1]
  local cwith = with_of(assert(cupload))
  assert(assert(cupload)["if"] == QUEUE and cwith["path"] == "${{ runner.temp }}/seed" and
      cwith["name"] == "seed-" .. assert(map_of(cjob.env)["COSMIC_WORKER"]),
    "the checked job's seed is not uploaded as its own: " .. tostring(cwith["name"]))
end

--- The linux-x86_64 leg of a full run: its matrix entry.
local function linux_x86_64_leg(platform: Job): {string: string}
  for _, entry in ipairs(legs_of(platform, "full")) do
    if entry["name"] == "linux-x86_64" then return entry end
  end
  error("no linux-x86_64 leg")
end

--- `value`, a step's text in the leg's job, as the leg `leg` has it: its
--- matrix put in, the host named `own_name` where that is not the leg's.
local function as_leg(leg: {string: string}, value: string, own_name?: string): string
  local values: {string: string} = { name = own_name or assert(leg["name"]), image = assert(leg["image"]),
    runner = assert(leg["runner"]), prepare = assert(leg["prepare"]) }
  local out = value:gsub("%${{ matrix%.(%w+) }}", function(field: string): string
    return (assert(values[field], "the leg's matrix has no " .. field))
  end)
  return out
end

--- Holds `mine` to `their`, the leg's, as the leg has it.
local function same_as_leg(leg: {string: string}, what: string, mine: string?, their: string?)
  if their is string then
    assert(mine == as_leg(leg, their), what .. " is not the leg's: " .. tostring(mine) .. " against " .. their)
  else
    assert(mine == their, what .. " is not the leg's: " .. tostring(mine) .. " against " .. tostring(their))
  end
end

--- Holds each field of the tables `mine` and `their` to the other's,
--- but for `spared`.
local function same_table_as_leg(leg: {string: string}, what: string, m: {string: string}, t: {string: string},
                                 spared?: string)
  for key, value in pairs(t) do same_as_leg(leg, what .. "'s " .. tostring(key), m[key], value) end
  for key, value in pairs(m) do
    if key ~= spared then same_as_leg(leg, what .. "'s " .. tostring(key), value, t[key]) end
  end
end

--- The names of the steps every job of the checked family (`checked`,
--- `checked-shard`, `checked-narrowing` and `format`) has from
--- linux-x86_64's leg, as the leg has them but for the matrix put in.
local SETUP_STEPS <const>: {string} = { "start the leg's container", "create the unprivileged builder",
  "restore the pinned zig", "name the zig build cache, and the run's start", "restore zig build outputs",
  "restore zig build outputs of another vendor part", "restore compiles and parses",
  "move the tree to a path of its own", "move the tree back to where it was checked out" }

--- The verdict steps of a job that looks up or restores the verdicts of
--- the tree's base, as the leg does.
local VERDICT_STEPS <const>: {string} = { "name the leg's host", "find the tree's base on main",
  "look up the verdicts entry of the tree's base", "name the verdicts entry of the tree's base",
  "restore test verdicts" }

--- `lists`' strings, in one list.
local function joined(lists: {{string}}): {string}
  local out: mut {string} = {}
  for _, list in ipairs(lists) do
    for _, name in ipairs(list) do out[#out + 1] = name end
  end
  return out
end

--- Holds the steps of `job`, a job of the checked family named `where`,
--- among `names` to the steps of linux-x86_64's leg of the same name:
--- the same action, shell, directory, script, inputs and variables, the
--- leg's matrix put in, and the condition `wanted` says for the step (nil
--- for none) where the leg's step has none a matrix names. A restore of
--- the verdicts may only look the entry up (`lookup-only`), which the
--- leg's does not.
local function held_to_the_leg(where: string, job: Job, platform: Job, names: {string},
                               wanted: function(name: string, theirs: string?): string?)
  local leg = linux_x86_64_leg(platform)
  local theirs, ours = platform.steps, job.steps
  for _, step_name in ipairs(names) do
    local at = where .. ": " .. step_name
    local our, their = (step_named(ours, step_name, at .. ": ")), (step_named(theirs, step_name, at .. ": "))
    same_as_leg(leg, at .. "'s action", our["uses"], their["uses"])
    same_as_leg(leg, at .. "'s id", our.id, their.id)
    same_as_leg(leg, at .. "'s shell", our.shell, their.shell)
    same_as_leg(leg, at .. "'s working-directory", our["working-directory"], their["working-directory"])
    local script = their["run"]
    if script is string then
      local own = if step_name == "name the leg's host" then "linux-x86_64-checked" else nil end
      same_as_leg(leg, at .. "'s script", our["run"], as_leg(leg, script, own))
    end
    local looked = step_name == "restore test verdicts" and with_of(our)["lookup-only"] == true
    same_table_as_leg(leg, at .. "'s with", texts_of(with_of(our)), texts_of(with_of(their)),
      if looked then "lookup-only" else nil end)
    same_table_as_leg(leg, at .. "'s env", map_of(our.env), map_of(their.env))
    local condition: string? = nil
    local raw = their["if"]
    if raw is string and not raw:find("matrix.", 1, true) then condition = raw end
    same_as_leg(leg, at .. "'s if", our["if"], wanted(step_name, condition))
  end
end

--- The phases a job of the checked family runs, in order, as
--- `cosmic-driver cosmic_ci/driver.tl platform <phase>`.
local function phases_of(job: Job): string
  local ran: mut {string} = {}
  for _, step in ipairs(job.steps) do
    local phase = (step.run or ""):match("^cosmic%-driver cosmic_ci/driver%.tl platform ([%w-]+)$")
    if phase ~= nil then ran[#ran + 1] = phase end
  end
  return table.concat(ran, " ")
end

--- The checked suite's gathering job (`checked`) runs beside the
--- platform legs where they run, after the shares of the suite that
--- `checked-shard` runs: it runs where the legs do unless a share
--- failed (a skipped share, a light run's, is none). It runs on
--- linux-x86_64's host: its runner, its image and its builder, with its
--- zig build outputs and compiles restored under that leg's names (which
--- that leg saves, and this job does not), and its verdicts under a name
--- of its own on the same COSMIC_HOST_ID, which it only looks up: the
--- run's own are the shares', merged into none, so nothing of main's
--- stands in the run it makes, and the entry it saves is
--- the shares'. It makes the whole run of the suite,
--- standing on those verdicts (`gather`), and the bounded performance
--- fixture. On a branch push's light run it runs none of that but the
--- pinned CI driver's check, which the legs make only on a full run.
local function test_the_checked_suite_is_gathered_in_a_job_of_its_own_on_linux_x86_64s_host()
  local jobs = ci_workflow().jobs
  local platform, checked = job_of(jobs, "platform"), job_of(jobs, "checked")
  assert(table.concat(needs_of(checked), ",") == "reuse,scope,checked-shard",
    "the checked job waits on " .. tostring((Json.encode_any(checked["needs"]))))
  -- Past a failed share it runs only where it saves (main's push, the
  -- nightly: a branch push has no shares to fail), to take the failed test's pass out of the cache, and fails.
  assert(checked["if"] == "!cancelled() && needs.reuse.outputs.run == '' && " ..
      "(needs.checked-shard.result != 'failure' || github.event_name == 'push' || github.event_name == 'schedule')",
    "the checked job runs other than where the legs do, unless a share failed off a saving run: " ..
      tostring(checked["if"]))
  local checked_steps = checked.steps
  local failing, failing_at = step_named(checked_steps, "fail where a share failed")
  local _, running_at = step_with_id(checked_steps, "checked-suite")
  assert(failing["if"] == "env.COSMIC_CI_SCOPE == 'full' && needs.checked-shard.result == 'failure'" and
      failing_at < running_at, "the checked job does not fail, before its suite, where a share failed")
  local gather_minutes = math.tointeger(checked["timeout-minutes"])
  assert(gather_minutes ~= nil and gather_minutes <= 20, "the checked job's time is not sized for a gather")
  assert(platform["if"] == "!cancelled() && needs.reuse.outputs.run == ''", tostring(platform["if"]))
  local penv, cenv = map_of(platform.env), map_of(checked.env)
  assert(penv["COSMIC_CI_CHECKED_SUITE"] == "skip", "a leg runs the checked suite: " ..
      tostring(penv["COSMIC_CI_CHECKED_SUITE"]))
  local leg = linux_x86_64_leg(platform)
  local name = checked["name"]
  assert(name == assert(leg["name"]) .. "-checked" and cenv["COSMIC_WORKER"] == name, "the checked job's name: " .. tostring(name))
  assert(checked["runs-on"] == leg["runner"], "the checked job runs on " .. tostring(checked["runs-on"]))
  assert(assert(assert(checked.defaults)["run"])["shell"] == leg["shell"],
    "the checked job's steps run through another shell than the leg's")
  assert(cenv["TARGET"] == leg["target"] and cenv["COSMIC_CI_CHECKED_SUITE"] == "gather" and
      cenv["COSMIC_CI_FORMAT"] == nil and
      cenv["COSMIC_CI_REQUIRE_SANDBOX"] == "1" and cenv["COSMIC_CI_DECLARED_KEYS"] == "0",
    "the checked job's switches are not linux-x86_64's with the checked suite gathered")
  for _, same in ipairs({ "COSMIC_CI_EVENT", "COSMIC_CI_BASE_SHA", "COSMIC_CI_SCOPE" }) do
    assert(cenv[same] == penv[same], "the checked job's " .. same .. " is not the legs': " .. tostring(cenv[same]))
  end
  local expected <const>: {string: boolean} = { COSMIC_WORKER = true, TARGET = true,
    COSMIC_CI_CHECKED_SUITE = true, COSMIC_CI_REQUIRE_SANDBOX = true,
    COSMIC_CI_DECLARED_KEYS = true, COSMIC_CI_SCOPE = true,
    COSMIC_CI_EVENT = true, COSMIC_CI_BASE_SHA = true }
  for key in pairs(cenv) do assert(expected[key], "the checked job sets " .. key) end
  for key in pairs(expected) do assert(cenv[key] ~= nil, "the checked job sets no " .. key) end
  -- Its steps, as the leg's of the same name: on every run where a light
  -- run's driver check needs them (BOTH), else only on a full run.
  local BOTH <const>: {string: boolean} = {
    ["start the leg's container"] = true, ["create the unprivileged builder"] = true,
    ["restore the pinned zig"] = true, ["name the zig build cache, and the run's start"] = true,
    ["restore zig build outputs"] = true, ["restore zig build outputs of another vendor part"] = true,
    ["restore compiles and parses"] = true, ["move the tree to a path of its own"] = true,
    ["move the tree back to where it was checked out"] = true,
  }
  held_to_the_leg("checked", checked, platform, joined({ SETUP_STEPS, VERDICT_STEPS }),
    function(step_name: string, theirs: string?): string?
      if BOTH[step_name] == true then return theirs end
      return if theirs then FULL .. " && " .. theirs else FULL end
    end)
  local steps = checked.steps
  assert(phases_of(checked) == "boot checked-build checked performance-checked",
    "the checked job runs " .. phases_of(checked))
  local at = verdict_steps(steps)
  local host_at, base_at, restore_at = assert(at["host-id"]), assert(at["merge-base"]), assert(at["verdicts-restore"])
  local trim_at, save_at = assert(at["trim"]), assert(at["save"])
  local _, suite = step_with_id(steps, "checked-suite")
  local _, back = step_running(steps, "driver.tl place-tree --restore")
  assert(host_at < base_at and base_at < restore_at and restore_at < suite and suite < trim_at and
      trim_at < save_at and back < save_at, "the checked job's verdict steps are out of order")
  -- It takes the verdicts the shares kept between its checked build and
  -- its suite, each share's into the cache, and none from main's entry,
  -- which it only looks up.
  assert(with_of(assert(steps[restore_at]))["lookup-only"] == true,
    "the checked job restores main's verdicts, which the suite it gathers would stand on")
  local _, built = step_running(steps, "platform checked-build")
  local download, downloaded = step_with_id(steps, "shares-download")
  local merge, merged = step_running(steps, "driver.tl verdicts-merge")
  assert(built < downloaded and downloaded < merged and merged < suite,
    "the checked job does not take the shares' verdicts after its build and before its suite")
  local pulled = with_of(download)
  assert(download["uses"] == "actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c" and
      pulled["pattern"] == "verdicts-linux-x86_64-checked-shard-*" and pulled["merge-multiple"] == nil and
      pulled["name"] == nil and pulled["run-id"] == nil and download["continue-on-error"] == nil and
      download["if"] == FULL,
    "the checked job takes the shares' verdicts from another run, merges them into one directory, or goes on without them")
  assert(merge["run"] == "for share in \"${{ runner.temp }}\"/verdicts-shares/*/; do " ..
      "cosmic-driver cosmic_ci/driver.tl verdicts-merge \"$share\" || exit 1; done" and
      merge["if"] == FULL and merge["continue-on-error"] == nil and
      pulled["path"] == "${{ runner.temp }}/verdicts-shares",
    "the checked job merges the shares' verdicts otherwise: " .. tostring(merge["run"]))
  -- It makes no run ahead of its own: the shares do, and it keeps no
  -- verdicts for the run behind, which takes theirs.
  for _, step in ipairs(steps) do
    local called = (step.run or "") .. (step.name or "")
    assert(not called:find("queue-ahead", 1, true) and not called:find("for the run behind", 1, true),
      "the checked job takes or keeps verdicts of the queue's runs: " .. called)
  end
  -- A light run runs the steps the driver's check needs, and nothing of
  -- the checked suite's: every other step's `if` names the full scope, or
  -- what a step skipped on a light run leaves unmet.
  local light <const>: mut {string: boolean} = { ["bootstrap the pinned CI driver"] = true,
    ["summarize worker operations"] = true,
    ["type-check the bootstrap's scripts on the pinned driver"] = true,
    ["describe the leg's container"] = true, ["remove the leg's container"] = true,
    ["preserve CI driver database"] = true,
    ["preserve checked suite failure diagnostics"] = true,
    [CHECKOUT] = true }
  for key in pairs(BOTH) do light[key] = true end
  local unmet <const> = { FULL, "github.event_name == 'merge_group'", "steps.verdicts-trim.outputs.digest != ''" }
  local only_light: mut {string} = {}
  for _, step in ipairs(steps) do
    local called = (step.name or "")
    if called == "" then called = (step.uses or "") end
    local condition = (step["if"] or "")
    if condition == LIGHT or condition:find(LIGHT .. " && ", 1, true) == 1 then
      only_light[#only_light + 1] = called
    else
      local held = false
      for conjunct in (condition .. " && "):gmatch("(.-) && ") do
        for _, text in ipairs(unmet) do held = held or conjunct == text end
      end
      assert(held == light[called] ~= true, "the checked job runs " .. called ..
          (if held then " only on a full run: " else " on a light run: " end) .. condition)
    end
  end
  assert(table.concat(only_light, ", ") == "name linux-x86_64's host, find a passing CI driver check, " ..
      "check the pinned CI driver",
    "the checked job runs on a light run alone: " .. table.concat(only_light, ", "))
  local mine, check = step_running(steps, "cosmic-driver test cosmic_ci")
  local bootstrap = 0
  for i, step in ipairs(steps) do
    if step["uses"] == DRIVER then bootstrap = i end
  end
  local legs = step_running(platform.steps, "cosmic-driver test cosmic_ci")
  assert(mine["run"] == "cosmic-driver test cosmic_ci", "the checked job checks the driver otherwise: " .. tostring(mine["run"]))
  same_table_as_leg(leg, "the driver check's env", assert(mine["env"]), assert(legs["env"]))
  local theirs = platform.steps
  local driver_step = (step_named(steps, "bootstrap the pinned CI driver"))
  assert(driver_step["id"] == "driver" and bootstrap > 0 and check > bootstrap,
    "the checked job checks the driver before bootstrapping it")
  -- A full run's legs check the driver; a light run's none do.
  local legs_lookup = (step_named(theirs, "find a passing CI driver check"))
  assert(tostring(legs["if"]):find(FULL .. " && ", 1, true) == 1 and legs_lookup["if"] == FULL,
    "a light run's legs check the driver: " .. tostring(legs["if"]))
  -- A light run skips its check where main's linux-x86_64 leg saved
  -- its marker under the key that leg looks up: that leg's host, named
  -- as the leg names it (its COSMIC_HOST_ID not kept), and what the
  -- leg's key hashes, looked up before the tree moves.
  local host = (step_named(steps, "name linux-x86_64's host", "a light run looks up no marker of linux-x86_64's: "))
  local lookup = (step_named(steps, "find a passing CI driver check"))
  local their_host = (step_named(theirs, "name the leg's host"))
  local their_lookup = legs_lookup
  assert(host["id"] == "driver-host" and host["continue-on-error"] == true and
      host["run"] == "GITHUB_ENV=/dev/null " .. as_leg(leg, tostring(their_host["run"])),
    "a light run names another host than linux-x86_64's, keeps it, or fails on it: " .. tostring(host["run"]))
  assert(host.shell == their_host.shell, "the host's shell")
  assert(host["working-directory"] == their_host["working-directory"], "the host's working-directory")
  same_table_as_leg(leg, "the host's environment", map_of(host.env), map_of(their_host.env))
  assert(lookup["id"] == "driver-check-restore" and lookup["uses"] == their_lookup["uses"],
    "a light run looks up the marker otherwise: " .. tostring(lookup["id"]))
  local by_image <const> = "${{ matrix.image && 'container' || steps.names.outputs.image }}"
  local their_key = assert(param(their_lookup, "key"))
  assert(their_key:find(by_image, 1, true) ~= nil and leg["image"] ~= "", their_key)
  local in_container = their_key:gsub(by_image:gsub("%p", "%%%0"), "container")
  local want = as_leg(leg, (in_container:gsub("steps%.host%-id%.outputs%.prefix", "steps.driver-host.outputs.prefix")))
  local wanted: mut {string: string} = {}
  wanted["path"], wanted["key"], wanted["lookup-only"] = param(their_lookup, "path"), want, "json:true"
  same_table_as_leg(leg, "the marker's lookup", texts_of(with_of(lookup)), wanted)
  local _, named = step_running(steps, "GITHUB_ENV=/dev/null cosmic-driver cosmic_ci/driver.tl leg-host-id")
  local looked = position(steps, lookup)
  local _, moved = step_running(steps, "driver.tl place-tree")
  assert(named < looked and looked < moved and looked < check,
    "a light run looks up linux-x86_64's marker after its check, or with the tree moved")
  assert(mine["if"] == LIGHT .. " && steps.driver-check-restore.outputs.cache-hit != 'true'",
    "a light run checks the driver over main's marker: " .. tostring(mine["if"]))
  for _, step in ipairs(platform.steps) do
    assert(not (step.run or ""):find("platform format", 1, true), "a leg checks the format apart from assemble")
  end
  -- Whatever failed, on either scope, it keeps its operations, as a leg
  -- does, under its own name.
  local kept = (step_named(steps, "preserve CI driver database"))
  local theirs_kept = (step_named(theirs, "preserve CI driver database"))
  assert(kept["if"] == "always()" and
      param(kept, "name") == "ci-driver-" .. tostring(name) and
      param(kept, "path") == param(theirs_kept, "path"),
    "the checked job keeps its operations only on some runs, or under another name: " .. tostring(kept["if"]))
end

--- The checked suite runs in shares of its tests (`cosmic test --shard
--- I/N`), one job each, `checked-shard`, on linux-x86_64's host as the
--- gathering job (`checked`) is, beside the legs and each other, on
--- a full run where the legs run: the longest of a merge queue run's
--- jobs was the whole suite in one. A share is the checked job's own
--- name on the same COSMIC_HOST_ID, restores the verdicts of the tree's
--- base and (in the merge queue) of the run ahead's same share, and
--- keeps, in every event, the rows its run used as the artifact the
--- gathering job merges, trimmed to them, after the suite and before it
--- ends. It saves nothing and seeds nothing, and the join needs it.
local function test_the_checked_suite_runs_in_shares_that_a_job_gathers()
  local jobs = ci_workflow().jobs
  local platform, checked = job_of(jobs, "platform"), job_of(jobs, "checked")
  local shard = assert(job_of(jobs, "checked-shard"), "no job runs a share of the checked suite")
  assert(Json.encode_any(shard["needs"]) == '["reuse","scope"]' and
      shard["if"] == "!cancelled() && needs.reuse.outputs.run == '' && " .. FULL_RUN,
    "a share runs elsewhere than on a full run where the legs run: " .. tostring(shard["if"]))
  local strategy = assert(shard.strategy)
  local parts, parts_err: {integer}?, string = Shape.into(assert(strategy.matrix)["part"], Shape.list(Shape.integer))
  parts = assert(parts, parts_err)
  assert(#parts >= 2 and strategy["fail-fast"] == false,
    "the checked suite is split in no shares, or one failing cancels the others")
  for i, part in ipairs(parts) do assert(part == i, "the shares are not numbered from 1") end
  assert(shard["name"] == "linux-x86_64-checked-shard-${{ matrix.part }}", "a share's name: " .. tostring(shard["name"]))
  local env = map_of(shard.env)
  local expected <const>: {string: string} = { COSMIC_WORKER = "linux-x86_64-checked", TARGET = "x86_64-linux-musl",
    COSMIC_CI_CHECKED_SUITE = "run", COSMIC_CI_CHECKED_SHARD = "${{ matrix.part }}/${{ strategy.job-total }}",
    COSMIC_CI_REQUIRE_SANDBOX = "1", COSMIC_CI_DECLARED_KEYS = "0",
    COSMIC_CI_EVENT = "${{ github.event_name }}",
    COSMIC_CI_BASE_SHA = "${{ github.event.merge_group.base_sha || needs.scope.outputs.base }}" }
  for key, value in pairs(expected) do
    assert(env[key] == value, "a share's " .. key .. ": " .. tostring(env[key]))
  end
  for key in pairs(env) do assert(expected[key] ~= nil, "a share sets " .. key) end
  assert(shard["runs-on"] == checked["runs-on"] and
      Json.encode_any(shard["defaults"]) == Json.encode_any(checked["defaults"]) and
      Json.encode_any(shard["permissions"]) == Json.encode_any(checked["permissions"]),
    "a share runs on another host than the checked job")
  -- A share's job holds its build and the suite's bound, and fewer
  -- minutes than the whole job had.
  local script = assert(Fs.read("ci/cosmic_ci/orchestration.tl"))
  local bound = math.tointeger(tonumber(script:match("checked_shard_timeout_ns <const> = Clock%.seconds%((%d+)%)")))
  assert(bound ~= nil and bound > 0, "a share has no bound of its own")
  local minutes = math.tointeger(shard["timeout-minutes"])
  assert(minutes ~= nil and minutes * 60 >= bound + 600 and minutes < 45,
    "a share's job holds " .. tostring(minutes) .. " minutes for its build and a bound of " .. tostring(bound) .. " s")
  held_to_the_leg("checked-shard", shard, platform, joined({ SETUP_STEPS, VERDICT_STEPS }),
    function(_: string, theirs: string?): string?
      return theirs
    end)
  assert(phases_of(shard) == "boot checked-build checked", "a share runs " .. phases_of(shard))
  local steps = shard.steps
  local at = verdict_steps(steps)
  local restore_at, trim_at = assert(at["verdicts-restore"]), assert(at["trim"])
  local suite_step, suite = step_with_id(steps, "checked-suite")
  assert(suite_step["run"] == "cosmic-driver cosmic_ci/driver.tl platform checked" and suite_step["if"] == nil,
    "a share's suite is gated, or is another phase: " .. tostring(suite_step["if"]))
  assert(with_of(assert(steps[restore_at]))["lookup-only"] == nil,
    "a share looks up the verdicts it stands on, not restores them")
  -- The run ahead's same share, between the build and the suite.
  local ahead, ahead_at = step_running(steps, "driver.tl queue-ahead")
  local aenv = map_of(ahead.env)
  assert(aenv["JOB"] == "linux-x86_64-checked-shard-${{ matrix.part }}" and
      aenv["ARTIFACT"] == "verdicts-linux-x86_64-checked-shard-${{ matrix.part }}" and
      aenv["READY_SECONDS"] == "600" and aenv["WITHIN_SECONDS"] == "90" and aenv["SUITE_STEP"] == nil,
    "a share takes the verdicts of another share or job than its own part's")
  assert(ahead_at > restore_at and ahead_at < suite, "a share takes the verdicts ahead out of its place")
  local trimmed = assert(steps[trim_at])
  assert(trimmed["if"] == "always() && steps.driver.outcome == 'success'" and trimmed["id"] == "verdicts-trim",
    "a share trims its verdicts only on some runs: " .. tostring(trimmed["if"]))
  local keep: Step?
  local kept_at: integer?
  for i, step in ipairs(steps) do
    if (step.uses or ""):find("actions/upload-artifact@", 1, true) ~= nil and
        param(step, "path"):find("${{ runner.temp }}/verdicts/", 1, true) == 1 then
      assert(keep == nil, "a share keeps its verdicts twice")
      keep, kept_at = step, i
    end
  end
  assert(keep ~= nil and kept_at ~= nil and kept_at > trim_at, "a share keeps no verdicts, or before it trims them")
  local kw = with_of(keep)
  assert(kw["name"] == "verdicts-linux-x86_64-checked-shard-${{ matrix.part }}" and
      kw["path"] == "${{ runner.temp }}/verdicts/checked.db*" and kw["retention-days"] == 1 and kw["overwrite"] == true and
      kw["if-no-files-found"] == "error" and keep["continue-on-error"] == nil and
      keep["if"] == "always() && steps.verdicts-trim.outcome == 'success'",
    "a share keeps other verdicts than the suite's, for long, or only on some runs: " .. tostring((Json.encode_any(kw))))
  -- The gathering job takes what the shares keep, by the name's pattern.
  local pattern = (tostring(kw["name"]):gsub("%${{ matrix%.part }}", "*"))
  assert(pattern == "verdicts-linux-x86_64-checked-shard-*", "the shares' artifacts are named " .. pattern)
  -- It saves and seeds nothing: only main's saves are `checked`'s.
  for _, step in ipairs(steps) do
    assert(not (step.uses or ""):find("actions/cache/save@", 1, true), "a share saves a cache")
    assert(not (step.run or ""):find("queue-stage", 1, true), "a share seeds main")
  end
  local kept_db = assert(param((step_named(steps, "preserve CI driver database")), "name"))
  assert(kept_db == "ci-driver-linux-x86_64-checked-shard-${{ matrix.part }}", "a share keeps its operations as " .. kept_db)
  local diag = (step_named(steps, "preserve checked suite failure diagnostics"))
  assert(param(diag, "name") == "platform-diagnostics-linux-x86_64-checked-shard-${{ matrix.part }}" and
      diag["if"] == "failure()", "a share keeps its diagnostics otherwise")
end

--- The checked narrowing run's shares check no C function is entered by
--- some test, which only a whole run does (build/test.tl). They need not:
--- a checked run enters no C function a plain one does not (the tests that
--- differ skip in it, and those that ask for one skip in every run,
--- build/type_watch.tl), and linux-x86_64's leg runs the whole native
--- suite on the same release core in every full run, with no share of it
--- and no selected files. This holds the leg to that.
local function test_a_full_runs_linux_x86_64_leg_holds_the_c_function_check_the_narrowing_shares_lack()
  local jobs = ci_workflow().jobs
  local platform = job_of(jobs, "platform")
  assert(map_of(platform.env)["COSMIC_CI_SHARD"] == LEG_SHARD, "the leg's share is another than the matrix's")
  local leg = assert(platform_legs("full")["linux-x86_64"], "a full run has no linux-x86_64 leg")
  assert(leg_shard(leg) == "" and leg["shard"] == "", "linux-x86_64 runs a share of a full run's suite")
  assert(phases_of(platform):find("local-suite", 1, true) ~= nil, "the legs run no native suite: " .. phases_of(platform))
  -- The step that runs the suite has no condition: every leg of a full run runs it.
  local suite_step = step_named(platform.steps, "run release Cosmic's native suite")
  assert(suite_step["if"] == nil and (suite_step.run or ""):find("platform local-suite", 1, true) ~= nil,
    "the legs' native suite is conditional or another: " .. tostring(suite_step["if"]))
  local step = step_named(platform.steps, "run the declared-types tests on a checked run")
  assert((step.run or ""):find("platform declared-types", 1, true) ~= nil, "the declared-types step is another")
end

--- The checked narrowing run, the whole suite on a checked run, is jobs
--- of their own, `checked-narrowing`, on a full run where the legs
--- run, a share of the tests each (`cosmic test --check-types --shard
--- I/N`): it stands on no verdict and uses no checked core, so it boots
--- and keeps no verdicts and saves nothing. A branch push's format check
--- is a job of its own too (`format`), which a full run does not run
--- (its legs make that check in assemble).
local function test_the_checked_narrowing_run_and_a_light_runs_format_check_have_jobs_of_their_own()
  local jobs = ci_workflow().jobs
  local platform = job_of(jobs, "platform")
  local narrowing = assert(job_of(jobs, "checked-narrowing"), "no job runs the checked narrowing")
  local format = assert(job_of(jobs, "format"), "no job runs the light format check")
  assert(Json.encode_any(narrowing["needs"]) == '["reuse","scope"]' and narrowing["if"] == job_of(jobs, "checked-shard")["if"],
    "the checked narrowing runs elsewhere than a share does: " .. tostring(narrowing["if"]))
  local strategy = assert(narrowing.strategy, "the checked narrowing is split in no shares")
  local parts, parts_err: {integer}?, string = Shape.into(assert(strategy.matrix)["part"], Shape.list(Shape.integer))
  parts = assert(parts, parts_err)
  assert(#parts >= 2 and strategy["fail-fast"] == false,
    "the checked narrowing is split in no shares, or one failing cancels the others")
  for i, part in ipairs(parts) do
    assert(part == i, "the narrowing shares are not numbered from 1")
  end
  assert(narrowing["name"] == "linux-x86_64-checked-narrowing-${{ matrix.part }}", tostring(narrowing["name"]))
  assert(phases_of(narrowing) == "boot checked-narrowing", "the checked narrowing runs " .. phases_of(narrowing))
  -- A share's job holds its boot and the share's bound, and fewer minutes
  -- than the whole run's job had.
  local script = assert(Fs.read("ci/cosmic_ci/orchestration.tl"))
  local bound = math.tointeger(tonumber(script:match("checked_narrowing_timeout_ns <const> = Clock%.seconds%((%d+)%)")))
  assert(bound ~= nil and bound > 0, "a narrowing share has no bound of its own")
  local minutes = math.tointeger(narrowing["timeout-minutes"])
  assert(minutes ~= nil and minutes * 60 >= bound + 600 and minutes < 45,
    "a narrowing share's job holds " .. tostring(minutes) .. " minutes for its boot and a bound of " .. tostring(bound) .. " s")
  local kept_db = assert(param((step_named(narrowing.steps, "preserve CI driver database")), "name"))
  assert(kept_db == "ci-driver-linux-x86_64-checked-narrowing-${{ matrix.part }}",
    "a narrowing share keeps its operations as " .. kept_db)
  held_to_the_leg("checked-narrowing", narrowing, platform, joined({ { "name the leg's host" }, SETUP_STEPS }),
    function(_: string, theirs: string?): string?
      return theirs
    end)
  for _, step in ipairs(narrowing.steps) do
    local uses = (step.uses or "")
    assert(uses:find("actions/cache/save@", 1, true) == nil and not uses:find("verdicts", 1, true),
      "the checked narrowing saves or restores a cache of verdicts")
    assert(not (step.run or ""):find("checked-build", 1, true), "the checked narrowing builds the checked core")
  end
  local nenv = map_of(narrowing.env)
  assert(nenv["COSMIC_WORKER"] == "linux-x86_64-checked" and nenv["COSMIC_CI_REQUIRE_SANDBOX"] == "1" and
      nenv["COSMIC_CI_DECLARED_KEYS"] == "0" and nenv["COSMIC_CI_CHECKED_SUITE"] == nil and nenv["COSMIC_CI_FORMAT"] == nil,
    "the checked narrowing is not run as the checked job was: " .. tostring((Json.encode(nenv))))
  assert(nenv["COSMIC_CI_NARROWING_SHARD"] == "${{ matrix.part }}/${{ strategy.job-total }}",
    "a narrowing share's COSMIC_CI_NARROWING_SHARD: " .. tostring(nenv["COSMIC_CI_NARROWING_SHARD"]))
  -- The format check: a branch push's and the scheduled run's, which
  -- names the paths the branch changed from the base it found, boots,
  -- and lays out only those.
  assert(Json.encode_any(format["needs"]) == '["reuse","scope"]' and
      format["if"] == "!cancelled() && needs.reuse.outputs.run == '' && " ..
      "((github.event_name == 'push' && github.ref_name != 'main' && needs.scope.outputs.scope == 'light') || " ..
      "github.event_name == 'schedule')",
    "the format check runs elsewhere than on a branch push or the scheduled run: " .. tostring(format["if"]))
  local fenv = map_of(format.env)
  assert(format["name"] == "linux-x86_64-format" and fenv["COSMIC_WORKER"] == format["name"])
  assert(fenv["COSMIC_CI_FORMAT"] == "run", "the format check is skipped")
  assert(phases_of(format) == "boot format", "the format check runs " .. phases_of(format))
  held_to_the_leg("format", format, platform, joined({ { "find the tree's base on main" }, SETUP_STEPS }),
    function(step_name: string, theirs: string?): string?
      -- The scheduled run checks the whole tree, to leave the memo.
      if step_name == "find the tree's base on main" then
        return "github.event_name != 'schedule'"
      end
      return theirs
    end)
end

--- The format check starts from the memo of what it found in each file
--- (build/check_memo.tl), which a branch has no build directory of its
--- own to hold: the newest the run's ref can read, that the scheduled
--- run saved under main, restored by prefix under a key no entry has, so
--- that nothing but the newest is taken. Only the scheduled run saves it
--- (a push to main does not run the job), from what a passing check left
--- in the directory the check is told of (COSMIC_CI_CHECK_MEMO), under a
--- key of its own run's: a cache entry is never overwritten.
local function test_the_format_check_starts_from_the_scheduled_runs_memo()
  local jobs = ci_workflow().jobs
  local steps = job_of(jobs, "format").steps
  local path <const> = "${{ runner.temp }}/check-memo"
  local key <const> = "check-memo-v1-${{ github.run_id }}-${{ github.run_attempt }}"
  local check, checked_at = step_with_id(steps, "format")
  local restored_at, saved_at: integer?, integer?
  local restore, save: Step?, Step?
  for i, step in ipairs(steps) do
    local uses = (step.uses or "")
    local with = with_of(step)
    if uses:find("actions/cache/restore@", 1, true) ~= nil and with["path"] == path then
      restore, restored_at = step, i
    end
    if uses:find("actions/cache/save@", 1, true) ~= nil and with["path"] == path then
      save, saved_at = step, i
    end
  end
  assert(restore ~= nil and restored_at ~= nil and save ~= nil and saved_at ~= nil,
    "the format job restores or saves no memo")
  assert(restored_at < checked_at and checked_at < saved_at, "the memo is restored after the check, or saved before it")
  local rwith, swith = with_of(restore), with_of(save)
  assert(rwith["key"] == key and rwith["restore-keys"] == "check-memo-v1-\n" and rwith["lookup-only"] == nil and
      restore["if"] == nil, "the memo is restored by another key than a prefix no entry has: " .. tostring(rwith["key"]))
  assert(swith["key"] == key and
      save["if"] == "steps.format.outcome == 'success' && env.COSMIC_CI_SAVES == 'true'",
    "the memo is saved by another run than main's scheduled one, or after a failed check: " .. tostring(save["if"]))
  local cenv = map_of(check.env)
  assert(cenv["COSMIC_CI_CHECK_MEMO"] == path,
    "the check is told another memo than the one restored: " .. tostring(cenv["COSMIC_CI_CHECK_MEMO"]))
  -- Whatever else saves a cache of memos: nothing.
  for name, job in pairs(jobs) do
    for _, step in ipairs(job.steps) do
      if (step.uses or ""):find("actions/cache/", 1, true) ~= nil and
          param(step, "key"):find("check-memo", 1, true) ~= nil then
        assert(name == "format", name .. " keeps the format check's memo")
      end
    end
  end
  -- The scheduled run is a full run, whose check of the tree is the whole
  -- tree's: the format job names no paths changed then.
  assert(cenv["COSMIC_CI_FORMAT_CHANGED"] == "${{ steps.changed.outputs.paths }}")
  assert(step_with_id(steps, "changed")["if"] == "github.event_name != 'schedule'",
    "the scheduled run's check lays out only what changed")
end

--- A light run's format check lays out only what the branch changed
--- since its base on main, whose tree main's run held to the whole
--- check: the format job finds that base, names the paths
--- (`changed-paths`, on the host, which fetches
--- the base with the credentials the checkout keeps) before its tree
--- moves, and hands the list to the format check, which checks the
--- whole tree where it named none. A full run's check, the
--- merge queue's, is the whole tree's.
local function test_a_light_format_check_lays_out_only_what_the_branch_changed()
  local jobs = ci_workflow().jobs
  local steps = job_of(jobs, "format").steps
  local base, found = step_running(steps, "driver.tl merge-base")
  assert(base["if"] == "github.event_name != 'schedule'",
    "the format job finds its base on the scheduled run, which checks the whole tree: " .. tostring(base["if"]))
  assert(driver_at(steps) < found, "the format job finds its base before it has the driver")
  local named, listed = step_running(steps, "driver.tl changed-paths")
  assert(named.id == "changed" and named["if"] == "github.event_name != 'schedule'" and named.shell == "sh" and
      named["working-directory"] == nil and named["continue-on-error"] == true,
    "the format job names what changed otherwise, or fails for it: " .. tostring(named["if"]))
  local env = map_of(named.env)
  assert(env["BASE"] == "${{ steps.merge-base.outputs.sha }}" and
      assert(env["OUT"]):find("${{ runner.temp }}/", 1, true) == 1,
    "the paths changed are named from another base, or kept outside the runner's temporary directory")
  local _, moved = step_running(steps, "driver.tl place-tree")
  assert(found < listed and listed < moved,
    "the format job names what changed before it finds the base, or with its tree moved")
  local checkout: Step? = nil
  for _, step in ipairs(steps) do
    if step.uses == CHECKOUT then checkout = step end
  end
  assert(checkout ~= nil and with_of(checkout)["persist-credentials"] == nil,
    "the format job keeps no credentials to fetch its base with")
  local format, checked_at = step_running(steps, "platform format")
  assert(checked_at > listed and format["if"] == nil and
      map_of(format.env)["COSMIC_CI_FORMAT_CHANGED"] == "${{ steps.changed.outputs.paths }}",
    "a light run's format check lays out other than what the branch changed")
  for job_name, job in pairs(jobs) do
    for _, step in ipairs(job.steps) do
      local run = (step.run or "")
      local e = map_of(step.env)
      assert(e["COSMIC_CI_FORMAT_CHANGED"] == nil or job_name == "format" and run:find("platform format", 1, true) ~= nil,
        "a step other than the format job's check reads what the branch changed: " .. job_name)
      assert(job_name == "format" or not run:find("driver.tl changed-paths", 1, true),
        job_name .. " names the paths a branch changed")
    end
  end
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

--- A failed job of the merge queue's run has the run cancelled,
--- so the gate reports without waiting on the legs still running. A job
--- of its own does it, the only job of the run that holds `actions: write`
--- besides the cache's `prune` and `invalidate`: it starts with the legs, needs nothing, is needed by
--- nothing (the gate, which a ruleset requires, never waits on it), and
--- is on the queue's run alone. The legs keep `actions: read`.
local function test_a_failed_queue_job_has_the_run_cancelled_by_a_job_of_its_own()
  local jobs = ci_workflow().jobs
  local cancel = job_of(jobs, "cancel")
  assert(cancel["if"] == "github.event_name == 'merge_group'", "cancel runs on: " .. tostring(cancel["if"]))
  assert(cancel.needs == nil, "cancel waits on a job, so it cannot start with the legs")
  local permissions = map_of(cancel.permissions)
  local count = 0
  for _ in pairs(permissions) do count = count + 1 end
  assert(count == 2 and permissions["actions"] == "write" and permissions["contents"] == "read",
    "cancel holds more than `contents: read` and `actions: write`")
  local checkout = cancel.steps[1]
  local with = with_of(assert(checkout))
  assert(assert(checkout).uses == CHECKOUT,
    "cancel's first step is no checkout")
  assert(with["persist-credentials"] == false and with["fetch-depth"] == 1 and
      with["sparse-checkout"] == "/.github/scripts/cancel-on-failure.sh\n",
    "cancel checks out more than its script, or keeps the token")
  assert(cancel.name == "cancel the run on a failed leg", "cancel's name: " .. tostring(cancel.name))
  assert((assert(cancel["timeout-minutes"])) > (assert(job_of(jobs, "platform")["timeout-minutes"])),
    "cancel stops before the legs may")
  for name, job in pairs(jobs) do
    for _, need in ipairs(needs_of(job)) do
      assert(need ~= "cancel", name .. " waits on the job that cancels the run")
    end
  end
  for _, name in ipairs({ "platform", "checked" }) do
    assert(map_of(job_of(jobs, name).permissions)["actions"] == "read", name .. " can write `actions`")
  end
  local env = map_of(assert(cancel.steps[2]).env)
  assert(env["SELF"] == cancel.name, "cancel does not know its own name")
  assert(assert(assert(cancel.steps[2]).run) == ".github/scripts/cancel-on-failure.sh",
    "cancel runs another script")
end

--- A branch several commits behind main restores the verdicts main
--- saved at its base rather than main's newest, whose tree it does not
--- have: main saves each job's verdicts once, under their content, and
--- names that entry under its commit, even where the content is an
--- entry's already, by a key ending in its digest, from a file of its
--- key at a path of its own, and `seed` does as the queue's leg named;
--- each restore looks up the name under the base, which driver.tl
--- merge-base finds (the merge queue's base, or a branch's merge base
--- with main through the API, with the job's token, and never failing
--- the job), takes the entry it names, and falls back to the newest.
--- `prune` deletes the names under a commit on a push to main, with the
--- one token that may write the cache, and never fails for it.
local function test_a_branch_restores_the_verdicts_of_its_base()
  local ci = ci_workflow()
  local jobs = ci.jobs
  local VERDICTS <const> = "${{ runner.temp }}/verdicts"
  for _, name in ipairs({ "platform", "checked" }) do
    local steps = job_of(jobs, name).steps
    local plain, twin = save_of(steps, VERDICTS)
    assert(plain ~= nil and twin ~= nil, name .. " names its verdicts under no commit")
    local key = param(plain, "key")
    local prefix = key:match("^(.-)%${{ steps%.verdicts%-trim%.outputs%.digest }}$")
    assert(prefix ~= nil and param(twin, "key") == under_the_commit(prefix),
      name .. "'s verdicts are named under another commit than the run's: " .. param(twin, "key"))
    -- The name is the file of the entry's key, written just before it is
    -- saved, on the host, where the save runs, and where it runs.
    local write, w = step_running(steps, "/verdicts-commit/key")
    assert(steps[w + 1] == twin and write.shell == "sh" and write["if"] == twin["if"] and
        write.run == "mkdir -p \"$RUNNER_TEMP/verdicts-commit\" && echo \"" .. key ..
        "\" > \"$RUNNER_TEMP/verdicts-commit/key\"",
      name .. " names another entry than the one it saves, or elsewhere: " .. tostring(write.run))
    local saved = position(steps, plain)
    assert(saved < w, name .. " names its verdicts' entry before it saves it")
    local at = verdict_steps(steps)
    local find = step_at(steps, at, "merge-base")
    assert(assert(at["merge-base"]) < assert(at["verdicts-restore"]), name .. " restores before it finds the base")
    -- On the host, where gh is, once the driver is bootstrapped.
    assert(find.run == "cosmic-driver cosmic_ci/driver.tl merge-base" and find.shell == "sh" and
        find["working-directory"] == nil and find["continue-on-error"] == true,
      name .. " finds the base elsewhere than on the host, or fails for it: " .. tostring(find.run))
    assert(driver_at(steps) < assert(at["merge-base"]), name .. " finds its base before it has the driver")
    local env = map_of(find.env)
    assert(env["GH_TOKEN"] == "${{ github.token }}" and env["REPOSITORY"] == "${{ github.repository }}" and
        env["SHA"] == "${{ github.sha }}" and env["EVENT"] == "${{ github.event_name }}" and
        env["REF"] == "${{ github.ref }}" and env["QUEUE_BASE"] == "${{ github.event.merge_group.base_sha }}",
      name .. " asks for another commit's base")
    -- The lookup of the base's name, which downloads nothing, the key
    -- of the entry it names, which the restore asks for first.
    assert(assert(at["merge-base"]) < at_of(at, "verdicts-base-lookup") and assert(at["verdicts-base-lookup"]) < at_of(at, "verdicts-base") and
        assert(at["verdicts-base"]) < at_of(at, "verdicts-restore"), name .. " restores before it names the base's entry")
    local lookup = step_at(steps, at, "verdicts-base-lookup")
    local lwith = with_of(assert(lookup))
    local names = names_at_the_base(prefix)
    assert(assert(assert(lookup).uses):find("actions/cache/restore@", 1, true) == 1 and lwith["lookup-only"] == true and
        lwith["path"] == VERDICTS_COMMIT and lwith["key"] == names and lwith["restore-keys"] == names .. "\n",
      name .. " looks up another name than one under its base, or downloads it: " .. tostring(lwith["key"]))
    local named = step_at(steps, at, "verdicts-base")
    local nenv = map_of(assert(named).env)
    assert(assert(named).shell == "sh" and named["working-directory"] == nil and
        assert(named["if"]):find("steps.verdicts-base-lookup.outputs.cache-matched-key != ''", 1, true) ~= nil and
        nenv["PREFIX"] == prefix and nenv["BASE"] == names and
        nenv["FOUND"] == "${{ steps.verdicts-base-lookup.outputs.cache-matched-key }}" and
        named.run == "echo \"key=$PREFIX${FOUND#\"$BASE\"}\" >> \"$GITHUB_OUTPUT\"",
      name .. " takes another key than the digest the base's name ends in: " .. tostring(named.run))
    local restore = with_of(step_at(steps, at, "verdicts-restore"))
    assert(restore["key"] == at_the_base(prefix) and restore["restore-keys"] == prefix .. "\n",
      name .. " restores another entry than its base's, else the newest: " .. tostring(restore["key"]))
    local permissions = map_of(job_of(jobs, name).permissions)
    assert(permissions["contents"] == "read", name .. " cannot compare commits")
  end
  -- seed saves the name the queue's leg kept, under this commit alone,
  -- after the rows it names.
  local steps = job_of(jobs, "seed").steps
  local plain, twin = save_of(steps, VERDICTS)
  assert(twin ~= nil and twin["if"] == "steps.keys.outputs.verdicts-sha != ''",
    "seed names no verdicts under the commit")
  assert(position(steps, assert(plain)) < position(steps, twin), "seed names its verdicts' entry before it saves it")
  local keys = step_running(steps, "seed.keys")
  assert(assert(keys.run):find("|verdicts-sha=verdicts-${{ matrix.name }}-[0-9a-f]{16}-[0-9a-f]+-sha-${{ github.sha }}-[0-9a-f]+|",
    1, true), "seed takes a name under another commit")

  -- The prune: a job of its own, the one whose token may write the
  -- cache, after every job that saves, whatever their result; on every
  -- push to main (the job's `if`, so a branch push starts no runner for
  -- steps it would all skip), running the pinned driver on ci/'s
  -- sources alone, from a main-only checkout that keeps no token.
  -- The join, the check a ruleset requires, waits on none of it.
  local prune = job_of(jobs, "prune")
  local permissions = map_of(prune.permissions)
  assert(permissions["actions"] == "write" and permissions["contents"] == "read",
    "prune cannot prune the cache, or may do more")
  for name, job in pairs(jobs) do
    local p = map_of(job.permissions)
    -- `cancel` writes `actions` to cancel the queue's run, and no more.
    assert(name == "prune" or name == "invalidate" or name == "cancel" or p["actions"] ~= "write",
      "job " .. name .. " may write the cache")
  end

  -- The invalidate: the prune's twin for a failed run of main. A cache
  -- entry is never overwritten and the restore takes the exact key of a
  -- branch's base first, so the entry under a commit that a failed
  -- recheck could not replace is deleted, once every job that saves
  -- has finished, and the checked shares and narrowing run, whose
  -- failure fails a run the legs saved in, whatever their result, by
  -- main's push or the scheduled run, and only where a job failed.
  local invalidate = job_of(jobs, "invalidate")
  local ipermissions = map_of(invalidate.permissions)
  assert(ipermissions["actions"] == "write" and ipermissions["contents"] == "read",
    "invalidate cannot delete from the cache, or may do more")
  assert(invalidate["if"] == "always() && contains(needs.*.result, 'failure') && " ..
      "(github.event_name == 'schedule' || (github.event_name == 'push' && github.ref == 'refs/heads/main'))",
    "invalidate runs on another event, or not after a failed job: " .. tostring(invalidate["if"]))
  assert(table.concat(needs_of(invalidate), ",") == "platform,checked,checked-shard,checked-narrowing,seed",
    "invalidate runs before a job that saves, or one whose failure fails a run that saved")
  for _, need in ipairs(needs_of(job_of(jobs, "ci"))) do
    assert(need ~= "invalidate", "the join waits on invalidate")
  end
  local isteps = invalidate.steps
  assert(#isteps == 3, "invalidate runs more than its checkout, its driver and its command")
  for _, step in ipairs(isteps) do
    assert(step["if"] == nil, "invalidate gates a step its job's `if` already gates: " .. tostring(step["if"]))
  end
  local command = isteps[3]
  assert(assert(command).run == "cosmic-driver cosmic_ci/driver.tl invalidate-commit-verdicts" and
      command["working-directory"] == "ci" and command["continue-on-error"] == nil and
      map_of(command.env)["COMMIT"] == "${{ github.sha }}",
    "invalidate runs another command: " .. tostring(command.run))
  assert(prune["if"] == "always() && github.event_name == 'push' && github.ref == 'refs/heads/main'",
    "prune runs on another event, or not after a failed job: " .. tostring(prune["if"]))
  assert(table.concat(needs_of(prune), ",") == "platform,checked,seed",
    "prune runs before a job that saves")
  for _, need in ipairs(needs_of(job_of(jobs, "ci"))) do
    assert(need ~= "prune", "the join waits on prune")
  end
  local psteps = prune.steps
  assert(#psteps == 3, "prune runs more than its checkout, its driver and its command")
  for _, step in ipairs(psteps) do
    assert(step["if"] == nil, "prune gates a step its job's `if` already gates: " .. tostring(step["if"]))
  end
  local checkout = with_of(assert(psteps[1]))
  assert(assert(assert(psteps[1]).uses):find("actions/checkout@", 1, true) == 1 and
      checkout["persist-credentials"] == false and
      checkout["sparse-checkout"] == "/ci/\n/bin/cosmic-bootstrap\n/.github/scripts/cosmic-driver.sh\n" ..
      "/.github/actions/cosmic-driver/\n",
    "prune checks out more than its driver, or keeps the token")
  assert(assert(psteps[2]).uses == DRIVER and assert(psteps[2])["continue-on-error"] == true,
    "prune bootstraps something else, or fails the run for it")
  local step = psteps[3]
  assert(assert(step).run == "cosmic-driver cosmic_ci/driver.tl prune-commit-verdicts" and
      step["working-directory"] == "ci" and step["continue-on-error"] == true,
    "the prune runs something else, or fails the run: " .. tostring(step.run))
  assert(map_of(step.env)["GH_TOKEN"] == "${{ github.token }}", "the prune has no token")
end

--- Only five jobs save a cache every run restores: the platform legs,
--- and the checked job, where COSMIC_CI_SAVES (main's push
--- and the scheduled run), the format check, whose memo only the scheduled
--- run saves, and `seed`, which runs only on a push to main
--- that found the queue's run.
local function test_only_the_legs_and_their_seed_save()
  local ci = ci_workflow()
  for name, job in pairs(ci.jobs) do
    local saves = 0
    for _ in pairs(saves_of(job.steps)) do saves = saves + 1 end
    assert(saves == 0 or name == "platform" or name == "checked" or name == "format" or
        name == "seed", "job " .. name .. " saves a cache")
  end
end

--- A leg saves only the verdicts its run relied on or reached,
--- where it passed: a file saved whole would carry several runs' rows,
--- most under keys no later run reaches. The trim runs where the suites
--- do (a Linux leg's container, the macOS runner itself), after every
--- suite that shares the file and before the save, and counts from a
--- time taken before the first suite.
local function test_a_leg_trims_its_verdicts_before_it_saves_them()
  local jobs = ci_workflow().jobs
  local at: mut {string: integer} = {}
  local trim: Step?
  for i, step in ipairs(job_of(jobs, "platform").steps) do
    local run = step.run
    if step.id ~= nil then at[assert(step.id)] = i end
    if step.name == "remove the leg's container" then at["removed"] = i end
    if run is string and run:find("driver.tl verdicts-trim", 1, true) ~= nil then
      at["trim"], trim = i, step
    end
    local path = with_of(step)["path"]
    if (step.uses or ""):find("actions/cache/save@", 1, true) ~= nil and
        path == "${{ runner.temp }}/verdicts" then
      at["save"] = i
    end
  end
  assert(trim ~= nil, "no step trims the verdicts")
  local condition = assert(trim["if"])
  assert(condition == "always() && steps.driver.outcome == 'success'",
    "the trim does not run on every leg's run: " .. condition)
  -- A run that failed keeps what it restored with what it reached.
  assert(assert(trim.run):find(
    "${{ job.status == 'success' && steps.names.outputs.since || 'whole' }}", 1, true) ~= nil,
    "the trim counts from no time taken before the suites, or trims a failed run: " ..
      assert(trim.run))
  -- `assemble` builds and verifies the checked core; its suite runs in
  -- the checked job, which trims its own verdicts.
  for _, suite in ipairs({ "release-suite", "assemble", "portable-suite" }) do
    assert(at[suite] ~= nil and assert(at[suite]) < at_of(at, "trim"), "the trim runs before " .. suite)
  end
  assert(assert(at["names"]) < at_of(at, "release-suite"), "the trim's time is taken after a suite")
  local steps = job_of(jobs, "platform").steps
  assert(step_at(steps, at, "names")["if"] == nil,
    "the trim's time is taken only on some legs: " .. tostring(step_at(steps, at, "names")["if"]))
  assert(assert(at["trim"]) < at_of(at, "removed") and assert(at["trim"]) < at_of(at, "save"),
    "the verdicts are trimmed after the container goes, or after they are saved")
end

--- A leg cuts its zig build outputs to what some manifest still vouches
--- for (cosmic_ci/zig_prune.tl) after its last build of them, the
--- assemble's, and before either save of them: main's upload and the
--- queue's seed, which held a day of core changes' outputs whole. It
--- runs where one of those saves follows -- the queue's where the
--- restore took no entry of this core, main's where its upload does --
--- and on no branch push, which saves nothing.
local function test_a_leg_prunes_its_zig_outputs_before_it_saves_them()
  local jobs = ci_workflow().jobs
  local steps = job_of(jobs, "platform").steps
  local prune, at = step_running(steps, "driver.tl zig-prune")
  local _, assembled = step_running(steps, "driver.tl platform assemble")
  local stage, staged = step_running(steps, "driver.tl queue-stage")
  local upload = assert(save_of(steps, "${{ runner.temp }}/zig-build"), "no step saves the zig outputs")
  local saved = position(steps, upload)
  assert(assembled < at and at < saved and at < staged,
    "the zig outputs are pruned before the assemble's builds, or after they are saved")
  for i = at + 1, staged do
    local run = assert(steps[i]).run
    assert(not (run is string and run:find("bin/zig", 1, true) ~= nil),
      "a build of zig's caches comes after the prune: " .. tostring(assert(steps[i]).name))
  end
  local condition = assert(prune["if"])
  local upload_condition = assert(upload["if"])
  local restored = upload_condition:match(
    "(!startsWith%(steps%.zig%-cache%-restore%.outputs%.cache%-matched%-key, format%('{0}full%-', steps%.names%.outputs%.vendor%)%))")
  assert(restored ~= nil, "main's upload is held to another restore than this test reads: " .. upload_condition)
  local exact = map_of(stage.env)["ZIG_BUILD_EXACT"]
  assert(exact == "${{ steps.names.outputs.vendor }}full-${{ steps.names.outputs.core }}-",
    "the queue seeds its zig outputs against another prefix: " .. tostring(exact))
  for _, clause in ipairs({
      "always() && steps.driver.outcome == 'success' && steps.assemble.outcome == 'success' && ",
      "github.event_name == 'merge_group' && " ..
        "!startsWith(steps.zig-cache-restore.outputs.cache-matched-key, " ..
        "format('{0}full-{1}-', steps.names.outputs.vendor, steps.names.outputs.core))",
      "env.COSMIC_CI_SAVES == 'true' && (github.event_name == 'schedule' || " .. restored .. ")",
  }) do
    assert(condition:find(clause, 1, true) ~= nil,
      "the prune runs other than where a save of the zig outputs follows: " .. condition)
  end
  assert(prune["continue-on-error"] == nil and
      assert(prune.run) == "cosmic-driver cosmic_ci/driver.tl zig-prune",
    "the prune runs otherwise than as the driver's verb, which never fails: " .. tostring(prune.run))
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
--- check that did nothing. So is `cancel`, which watches the merge
--- queue's run alone: its `if` is the event, as a leg of no other run
--- could cancel it.
local BRANCH_SKIPS <const> = { "refs/heads/main", "ref_name == 'main'", "event_name != 'push'" }
local SKIPPED_ON_A_BRANCH <const>: {string: boolean} = {
  [DIR .. "/ci.yml seed"] = true,
  [DIR .. "/ci.yml reuse"] = true,
  [DIR .. "/ci.yml prune"] = true,
  [DIR .. "/ci.yml invalidate"] = true,
  [DIR .. "/ci.yml cancel"] = true,
  -- The checked suite's shares and the checked narrowing run, of a full run only: a branch push runs no
  -- checked suite, and the job's boot costs what a runner's start does.
  [DIR .. "/ci.yml checked-shard"] = true,
  [DIR .. "/ci.yml checked-narrowing"] = true,
}

--- A run's scope is decided once, by ci.yml's `scope` job (a branch push's
--- alone: `light` unless its change touches a path of
--- .github/scripts/branch-scope.txt), and each job that reads it passes
--- the one answer on as its COSMIC_CI_SCOPE, which its steps and the
--- provenance join read: `full` unless the output says `light`, so that a
--- run the job did not decide (every run but a branch push) or could not
--- (it failed) takes the wider scope. A job that reads the output names
--- `scope` in its `needs`, or it reads it empty and runs `full` whatever
--- the branch changed; and one whose steps read COSMIC_CI_SCOPE sets it.
local function test_the_scope_is_decided_once()
  local ci = ci_workflow()
  assert(map_of(ci.env)["COSMIC_CI_SCOPE"] == nil, "the scope is decided for every job at once")
  local PASS <const> = "${{ needs.scope.outputs.scope == 'light' && 'light' || 'full' }}"
  local deciding = job_of(ci.jobs, "scope")
  assert(deciding.needs == nil and deciding["if"] == "github.event_name == 'push' && github.ref_name != 'main'",
    "the scope job runs on another run than a branch push, or waits: " .. tostring(deciding["if"]))
  local outputs = map_of(deciding.outputs)
  assert(outputs["scope"] == "${{ steps.decide.outputs.scope }}" and
      outputs["base"] == "${{ steps.decide.outputs.base }}", "the scope job's outputs")
  local reading = 0
  for name, job in pairs(ci.jobs) do
    local text = Json.encode_any(job) or ""
    local needs = Json.encode_any(job.needs) or ""
    local mine = map_of(job.env)["COSMIC_CI_SCOPE"] or ""
    if name ~= "scope" then
      if text:find("needs.scope.", 1, true) ~= nil then
        reading = reading + 1
        assert(needs:find('"scope"', 1, true) ~= nil, "job " .. name .. " reads the scope, and does not need it")
      end
      if text:find("env.COSMIC_CI_SCOPE", 1, true) ~= nil then
        assert(mine == PASS, "job " .. name .. " reads COSMIC_CI_SCOPE, which it does not pass on from `scope`")
      end
    end
    assert(mine == "" or mine == PASS, "job " .. name .. " decides its scope again: " .. mine)
    for _, step in ipairs(job.steps) do
      local step_env = map_of(step.env)
      assert((step_env["COSMIC_CI_SCOPE"] or "") == "" and (step_env["FULL"] or "") == "",
        "job " .. name .. " decides its scope again, in a step")
    end
  end
  assert(reading >= 6, "too few jobs read the scope: " .. tostring(reading))
end

--- Every job of the run gates it: none continues on error, so the job that cancels the run on a failed leg has no failure to
--- pass over, and the script names no exemption. A job that gates nothing needs the exemption back, with a test of its own.
local function test_every_job_gates_the_run_and_the_cancel_job_passes_over_none()
  local jobs = ci_workflow().jobs
  for id, job in pairs(jobs) do
    assert(job["continue-on-error"] ~= true, id .. " fails without gating, and the cancel job does not pass over it")
  end
  assert(map_of(assert(job_of(jobs, "cancel").steps[2]).env)["EXEMPT"] == nil, "the cancel job passes over a job")
  local script = assert(Fs.read(".github/scripts/cancel-on-failure.sh"))
  assert(script:find("EXEMPT", 1, true) == nil, "cancel-on-failure.sh still reads an exemption")
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

--- A queue run takes the verdicts of the run ahead of it in the queue,
--- which tests its base and whose verdicts main has not saved yet: each
--- leg keeps its suite's verdicts, on a queue run, the moment the suite
--- passes, and each share of the checked suite its share's, in every
--- event (the gathering job takes them), as `verdicts-<job>`, a name no
--- other job's shares, replacing a retried attempt's; and each, between its
--- boot and its suite, finds that run by its base (driver.tl queue-ahead),
--- with the job's own name and artifact, unless the restore took the
--- base's own entry, downloads what it kept from that run, and merges
--- it into what it restored (driver.tl verdicts-merge). None of it
--- fails the job, it needs `actions: read`, and the lookup's wait, with
--- its last round's calls, is under its step's timeout: a leg's is half
--- a minute at most, and only on a leg ahead that has begun its suite
--- (SUITE_STEP, the suite step's own name), since a longer wait, on a
--- leg still building or itself waiting, cost more than it saved; a
--- share's, whose share ahead keeps them later, is a minute and a
--- half and skips a share ahead that cannot keep them in time
--- (READY_SECONDS).
local function test_a_queue_run_takes_the_verdicts_of_the_run_ahead()
  local ci = ci_workflow()
  local jobs = ci.jobs
  local script = assert(Fs.read("ci/cosmic_ci/queue_seed.tl"))
  local call = math.tointeger(tonumber(script:match('whole%(env, "CALL_SECONDS", (%d+)%)')))
  assert(call ~= nil, "queue_seed.tl's call budget moved")
  local QUEUE <const> = "github.event_name == 'merge_group'"
  local names: mut {string: string} = {}
  for _, case in ipairs({
      -- A queue run's legs run whole, so a leg's job is named by the leg
      -- alone there ([`LEG_NAME`]).
      { job = "platform", suite = "release-suite", file = "verdicts.db", name = "${{ matrix.name }}",
          job_name = LEG_NAME, within = 30, ready = "", begun = true, queue_only = true },
      { job = "checked-shard", suite = "checked-suite", file = "checked.db",
          name = "linux-x86_64-checked-shard-${{ matrix.part }}",
          job_name = "linux-x86_64-checked-shard-${{ matrix.part }}", within = 90, ready = "600", begun = false,
          queue_only = false } }) do
    local job = jobs[case.job]
    local where = case.job
    assert(assert(job).name == case.job_name, where .. "'s name: " .. tostring(assert(job).name))
    assert(map_of(assert(job).permissions)["actions"] == "read", where .. " cannot read the run ahead")
    local steps = assert(job).steps
    local at: mut {string: integer} = {}
    local keep: Step?
    for i, step in ipairs(steps) do
      local id = step.id
      if id ~= nil then at[id] = i end
      if (step.uses or ""):find("actions/upload-artifact@", 1, true) ~= nil and
          param(step, "path"):find("${{ runner.temp }}/verdicts/", 1, true) == 1 then
        assert(keep == nil, where .. " keeps its verdicts twice")
        keep, at["keep"] = step, i
      end
    end
    assert(keep ~= nil, where .. " keeps no verdicts for the run behind it")
    local order = { "verdicts-restore", "boot", "ahead", "ahead-download", "verdicts-ahead", case.suite, "keep" }
    for n = 2, #order do
      assert(at[order[n - 1]] ~= nil and at[order[n]] ~= nil and assert(at[order[n - 1]]) < at_of(at, order[n]),
        where .. ": " .. order[n - 1] .. " does not come before " .. order[n])
    end
    assert(assert(at["driver"]) < at_of(at, "boot") and assert(step_at(steps, at, "boot").run):find("platform boot", 1, true) ~= nil,
      where .. " takes the verdicts ahead before its boot")
    local artifact = "verdicts-" .. case.name
    local kept = with_of(keep)
    assert(kept["name"] == artifact and kept["path"] == "${{ runner.temp }}/verdicts/" .. case.file .. "*" and
        kept["retention-days"] == 1 and kept["overwrite"] == true, where .. " keeps other verdicts, or for long: " .. tostring(kept["name"]))
    local condition = assert(keep["if"])
    -- A share keeps its rows past a failed suite too, the failed test's
    -- out of them (the trim then keeps all it restored: `whole`), so the
    -- gathering job of a saving run can save them.
    assert(condition:find("steps." .. case.suite .. ".outcome == 'success'", 1, true) ~= nil or
        (case.job == "checked-shard" and condition == "always() && steps.verdicts-trim.outcome == 'success'"),
      where .. " keeps verdicts its suite did not pass: " .. condition)
    if case.queue_only then
      assert(condition:find(QUEUE, 1, true) and keep["continue-on-error"] == true,
        where .. " keeps verdicts off the queue, or fails for it: " .. condition)
    else
      -- The gathering job needs them whatever the event, and fails without.
      assert(not condition:find("merge_group", 1, true) and keep["continue-on-error"] == nil,
        where .. " keeps verdicts only in the queue, or goes on without them: " .. condition)
    end
    names[where] = artifact

    local find = step_at(steps, at, "ahead")
    local env = map_of(assert(find).env)
    -- On the host, where gh is, in ci/, where the driver is run from.
    assert(assert(find).run == "cosmic-driver cosmic_ci/driver.tl queue-ahead" and find.shell == "sh" and
        find["working-directory"] == nil and find["continue-on-error"] == true and
        assert(find["if"]):find(QUEUE .. " && (steps.verdicts-base.outputs.key == '' || " ..
            "steps.verdicts-restore.outputs.cache-matched-key != steps.verdicts-base.outputs.key)", 1, true) ~= nil,
      where .. " looks for the run ahead elsewhere, where the base's verdicts were restored, or fails for it")
    assert(env["BASE"] == "${{ github.event.merge_group.base_sha }}" and env["JOB"] == case.name and
        env["ARTIFACT"] == artifact and env["GH_TOKEN"] == "${{ github.token }}" and
        env["REPOSITORY"] == "${{ github.repository }}", where .. " looks for another run's or job's verdicts")
    local within, wait = math.tointeger(tonumber(env["WITHIN_SECONDS"])), math.tointeger(tonumber(env["WAIT_SECONDS"]))
    assert(within ~= nil and wait ~= nil and wait < within and within <= case.within,
      where .. " waits too long for the run ahead: " .. tostring(env["WITHIN_SECONDS"]))
    assert((env["READY_SECONDS"] or "") == case.ready, where .. " takes its job ahead to keep them at another time")
    -- A job that has begun names its suite's step, the other none.
    local suite_step: string? = nil
    if case.begun then suite_step = step_at(steps, at, case.suite).name end
    assert(env["SUITE_STEP"] == suite_step,
      where .. " waits on a job ahead by another step than its suite: " .. tostring(env["SUITE_STEP"]))
    local budget = within + 3 * call
    local minutes = assert(find["timeout-minutes"])
    assert(budget + 30 <= minutes * 60 and minutes < (assert(assert(job)["timeout-minutes"])),
      where .. "'s lookup outlasts its step, or its step the job: " .. tostring(budget) .. " s")

    local download = step_at(steps, at, "ahead-download")
    local with = with_of(assert(download))
    assert(assert(assert(download).uses):find("actions/download-artifact@", 1, true) == 1 and
        with["name"] == artifact and with["run-id"] == "${{ steps.ahead.outputs.run }}" and
        with["github-token"] == "${{ github.token }}" and assert(download)["continue-on-error"] == true and
        assert(assert(download)["if"]):find("steps.ahead.outputs.run != ''", 1, true) ~= nil,
      where .. " downloads other verdicts than the run ahead's, or fails for it")
    local merge = step_at(steps, at, "verdicts-ahead")
    assert(assert(merge).run == "cosmic-driver cosmic_ci/driver.tl verdicts-merge \"" .. param(download, "path") .. "\"" and
        assert(merge)["continue-on-error"] == true and
        assert(assert(merge)["if"]):find("steps.ahead-download.outcome == 'success'", 1, true) ~= nil,
      where .. " merges something else, or fails for it: " .. tostring(assert(merge).run))
  end
  assert(names["platform"] ~= names["checked-shard"], "the legs and the checked shares keep their verdicts under one name")
end

--- A queue run's leg skips its driver check on the key the run ahead
--- kept, not only on main's marker, which main saves only once a commit
--- lands: the runs queued behind a change to ci/ all checked again.
--- Each leg keeps the key it checked, found or took, as
--- `driver-checked-<leg>`, only where that holds; finds the run ahead by
--- its own name and after its check; and takes the key only if it is
--- the one its lookup computed. The check still runs on the scheduled
--- and manual runs, and saves nothing off main.
local function test_a_queue_leg_takes_the_driver_check_of_the_run_ahead()
  local ci = ci_workflow()
  local steps = job_of(ci.jobs, "platform").steps
  local at: mut {string: integer} = {}
  local keep, upload: Step?, Step?
  for i, step in ipairs(steps) do
    if step.id ~= nil then at[assert(step.id)] = i end
    if step.name == "keep the CI driver check for the run behind in the queue" then
      keep, at["keep"] = step, i
    end
    if step.name == "upload the CI driver check for the run behind in the queue" then
      upload, at["upload"] = step, i
    end
  end
  assert(keep ~= nil and upload ~= nil, "the platform job keeps no driver check for the run behind")
  local order = { "driver-check-restore", "driver-ahead", "driver-ahead-download", "driver-ahead-take",
    "driver-check", "keep", "upload", "boot" }
  for n = 2, #order do
    assert(at[assert(order[n - 1])] ~= nil and at[assert(order[n])] ~= nil and at_of(at, assert(order[n - 1])) < at_of(at, assert(order[n])),
      assert(order[n - 1]) .. " does not come before " .. assert(order[n]))
  end

  local check = step_at(steps, at, "driver-check")
  local condition = assert(check["if"])
  assert(condition:find("github.event_name == 'schedule' || github.event_name == 'workflow_dispatch' || (", 1, true) and
      condition:find("steps.driver-check-restore.outputs.cache-hit != 'true' && " ..
          "steps.driver-ahead-take.outputs.hit != 'true')", 1, true),
    "the check skips on the run ahead's key where it must run, or runs where the key is found: " .. condition)

  local find = step_at(steps, at, "driver-ahead")
  local env = map_of(find.env)
  assert(find.run == "cosmic-driver cosmic_ci/driver.tl queue-ahead" and find["continue-on-error"] == true and
      assert(find["if"]):find("github.event_name == 'merge_group'", 1, true) ~= nil and
      env["JOB"] == "${{ matrix.name }}" and env["ARTIFACT"] == "driver-checked-${{ matrix.name }}" and
      env["BASE"] == "${{ github.event.merge_group.base_sha }}" and
      env["SUITE_STEP"] == step_at(steps, at, "boot").name,
    "the lookup of the run ahead names another job, artifact or step, or fails for it")
  local within = math.tointeger(tonumber(env["WITHIN_SECONDS"]))
  assert(within ~= nil and within <= 30, "the lookup waits too long on a leg ahead: " .. tostring(env["WITHIN_SECONDS"]))

  local download = step_at(steps, at, "driver-ahead-download")
  local with = with_of(download)
  assert(with["name"] == env["ARTIFACT"] and with["run-id"] == "${{ steps.driver-ahead.outputs.run }}" and
      download["continue-on-error"] == true, "the download takes another artifact or run than the one found")

  local take = step_at(steps, at, "driver-ahead-take")
  assert(map_of(take.env)["KEY"] == "${{ steps.driver-check-restore.outputs.cache-primary-key }}" and
      assert(take.run):find('= "$KEY"', 1, true) ~= nil and assert(take.run):find(param(download, "path"):gsub("^%${{ runner.temp }}", "$RUNNER_TEMP"), 1, true) ~= nil,
    "a key is taken that is not the one the leg's lookup computed")

  local kept = with_of(upload)
  for _, relay in ipairs({ keep, upload, take }) do
    local when = relay["if"] or ""
    for _, loose in ipairs({ "always()", "!cancelled()", "failure()", "cancelled()" }) do
      assert(not when:find(loose, 1, true), "the key is kept or taken after a failed or cancelled step: " .. when)
    end
    if relay ~= take then
      assert(when:find("github.event_name == 'merge_group'", 1, true) and
          when:find("steps.driver-check.outcome == 'success'", 1, true) and
          when:find("steps.driver-check-restore.outputs.cache-hit == 'true'", 1, true) and
          when:find("steps.driver-ahead-take.outputs.hit == 'true'", 1, true),
        "the key is kept where no check passed or key was found: " .. when)
    end
  end
  local written = assert(keep.run)
  assert(written:find("driver-relay/key", 1, true) ~= nil and not written:find("driver-checked", 1, true) and
      written:find('[ -n "$KEY" ]', 1, true) ~= nil, "the kept key goes to main's marker's path, or may be empty")
  assert(assert(take.run):find('[ -n "$KEY" ]', 1, true), "an empty key can match an empty one")
  assert(kept["name"] == env["ARTIFACT"] and kept["overwrite"] == true, "the key is kept under another name, or not replaced")
  for _, step in ipairs(steps) do
    local saves = (step.uses or ""):find("actions/cache/save@", 1, true) ~= nil
    local path = with_of(step)["path"]
    local from = if path is string then path else "" end
    assert(not (saves and from:find("driver-relay", 1, true) ~= nil), "the relayed key is saved as main's marker")
  end
end

--- A value of a workflow expression: a string, or a comparison's
--- boolean.
local type Value = string | boolean

--- What `${{ <text> }}` answers on a run of `event` to `ref`, for a leg
--- of `leg`'s values, in as much of GitHub's expression syntax as a
--- leg's switches use: string literals, `matrix.<key>`,
--- `github.event_name` and `github.ref`, `==`, `!=`, `!`, `&&`, `||` and
--- parentheses. As GitHub's docs ("Operators") say, '' and false are
--- falsy, and `a && b` and `a || b` answer an operand, not a boolean.
--- It compares two strings ignoring case, as GitHub does, so a
--- literal cased otherwise than the value it names answers as it would
--- there; a comparison of a string with a boolean, which GitHub coerces
--- to numbers, it refuses.
local function evaluate(text: string, leg: {string: string}, event: string, ref: string): Value
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
  local function primary(): Value
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

--- The run of each event a test below asks after, with the ref it runs
--- on.
local EVENTS <const>: {{string}} = {
  { "merge_group", "refs/heads/gh-readonly-queue/main/pr-1-0123456789abcdef0123456789abcdef01234567" },
  { "push", "refs/heads/main" },
  { "schedule", "refs/heads/main" },
  { "workflow_dispatch", "refs/heads/main" },
}

--- The full-run legs that run the portable suite (COSMIC_CI_PORTABLE_SUITE
--- `run`) on a run of `event` to `ref`, by name, space-joined in order.
local function portable_suite_legs(event: string, ref: string): string
  local ci = ci_workflow()
  local env = map_of(assert(ci.jobs["platform"]).env)
  local value = assert(env["COSMIC_CI_PORTABLE_SUITE"], "the legs set no COSMIC_CI_PORTABLE_SUITE")
  local out: mut {string} = {}
  for name, leg in pairs(platform_legs("full")) do
    local answer = evaluate(value, leg, event, ref)
    assert(answer == "run" or answer == "skip", name .. "'s COSMIC_CI_PORTABLE_SUITE on " ..
        event .. " is " .. tostring(answer))
    if answer == "run" then out[#out + 1] = name end
  end
  table.sort(out)
  return table.concat(out, " ")
end

--- The merge queue runs the portable suite on alpine-x86_64 alone: on
--- linux-x86_64, the queue's longest leg, it ran some 190 s on the same
--- portable bytes, which the join holds identical to alpine-x86_64's
--- (`provenance`). A push to main runs it on both x86-64 legs, a glibc
--- host and a musl one, and the scheduled and a manual run on every
--- leg; alpine-x86_64 runs it on every full run.
local function test_the_merge_queue_runs_the_portable_suite_on_alpine_x86_64_alone()
  local want: {string: string} = {
    merge_group = "alpine-x86_64",
    push = "alpine-x86_64 linux-x86_64",
    schedule = "alpine-x86_64 linux-aarch64 linux-x86_64 macos-aarch64",
    workflow_dispatch = "alpine-x86_64 linux-aarch64 linux-x86_64 macos-aarch64",
  }
  for _, case in ipairs(EVENTS) do
    local got = portable_suite_legs(assert(case[1]), assert(case[2]))
    assert(got == want[assert(case[1])], "a " .. assert(case[1]) .. " run runs the portable suite on " .. got)
  end
  -- A branch push that runs the full scope (`scope`) runs what the queue's does.
  local branch = portable_suite_legs("push", "refs/heads/some-branch")
  assert(branch == want["merge_group"], "a full branch push runs the portable suite on " .. branch)
end

--- A leg that skips the portable suite still runs the step (the driver
--- records the artifact's digest there, and says it skipped the suite),
--- its regressions on the portable product, and its attestation and
--- upload of the bytes it ran, on every full run: so the join's
--- comparison still counts an attestation from every leg
--- (`strategy.job-total`), linux-x86_64's in the merge queue among
--- them, and none of those steps turns on COSMIC_CI_PORTABLE_SUITE.
local function test_a_leg_that_skips_the_portable_suite_still_attests_what_it_ran()
  local ci = ci_workflow()
  local platform = ci.jobs["platform"]
  local seen: mut {string: boolean} = {}
  local at: mut {string: integer} = {}
  for i, step in ipairs(assert(platform).steps) do
    local run = (step.run or "")
    local phase = run:match("^cosmic%-driver cosmic_ci/driver%.tl platform ([%w-]+)")
    if phase ~= nil then at[phase] = i end
    local upload = with_of(step)["name"] == "portable-product-${{ matrix.name }}"
    if phase == "portable" or phase == "fixtures" or phase == "attest" or upload then
      local key = if upload then "upload" else phase end
      assert(step["if"] == FULL, assert(key) .. " runs on another condition than a full run's: " ..
          tostring(step["if"]))
      assert(not assert(Json.encode_any(step)):find("PORTABLE_SUITE", 1, true), assert(key) .. " turns on the portable suite's switch")
      seen[assert(key)] = true
      if phase == "attest" then
        assert(run:find("\"${{ strategy.job-total }}\"", 1, true) ~= nil,
          "attest expects another count of products than the legs': " .. run)
      end
    end
  end
  assert(seen["portable"] == true and seen["fixtures"] == true and seen["attest"] == true and seen["upload"] == true,
    "a full run's leg misses a step of the product's")
  -- A regression's failure in the queue surfaces sooner. Attest reads
  -- the digest the portable step records, so it follows.
  assert(assert(at["fixtures"]) < at_of(at, "portable"), "the regressions run after the portable suite")
  assert(assert(at["portable"]) < at_of(at, "portable-boundary") and assert(at["portable-boundary"]) < at_of(at, "attest"),
    "the portable suite, its boundary and the attestation are out of order")
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
  for _, name in ipairs({ "vendor", "core", "compiles", "image", "since" }) do
    assert(assert(outputs[name])["value"] == "${{ steps.names.outputs." .. name .. " }}",
      "the action does not forward " .. name)
  end
  local jobs = ci_workflow().jobs
  for _, job in ipairs({ "platform", "checked" }) do
    local named = false
    local marker = false
    for _, step in ipairs(job_of(jobs, job).steps) do
      if step.id == "names" then
        assert(step.uses == CACHE_NAMES and step["if"] == nil, job .. " does not always name its caches")
        named = true
      end
      if step.id == "zig-cache-restore" or step.id == "compiles-restore" or
          step.name == "move the tree to a path of its own" then
        assert(named, job .. " names its caches after restoring them or moving the tree")
      end
      if step.id == "driver-check-restore" then
        local key = param(step, "key")
        assert(key:find("'.github/actions/cache-names/**'", 1, true),
          job .. " stands on a driver check from before the cache names changed")
        marker = true
      end
    end
    assert(named and marker, job .. " has no cache names or driver marker")
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
  assert(compile["if"] == "runner.os == 'Linux'" and proof["if"] == "runner.os == 'Linux'",
    "credential proof must remain required on every Linux leg")
  assert(proof.shell == "leg-shell --root {0}" and proof["continue-on-error"] == nil,
    "credential proof lost its privileged failure gate")
  local runner, ran = step_running(steps, "run-local-proof.sh")
  assert(proved < ran, "local runner proof must follow the credential proof and database boundary")
  assert(runner["if"] == "runner.os == 'Linux'" and runner.shell == "leg-shell --root {0}" and
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
  for _, scope in ipairs({ "light", "full" }) do
    for name in pairs(platform_legs(scope)) do ran[name] = true end
  end
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

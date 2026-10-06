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

--- Of `paths`, the ones in flow style, each with its text: a file whose
--- first line that is neither blank nor a comment opens with `{` or
--- `[` ([`flow.is_flow`]).
local function flow_files(paths: {string}): {string: string}
  local out: {string: string} = {}
  for _, path in ipairs(paths) do
    local text = (assert(Fs.read(path)))
    if flow.is_flow(text) then out[path] = text end
  end
  return out
end

--- The flow-style workflows: each file under DIR in flow style, with its
--- text.
local function flow_workflows(): {string: string}
  local paths: {string} = {}
  for _, name in ipairs((assert(Fs.list(DIR)))) do
    if name:match("%.ya?ml$") then paths[#paths + 1] = DIR .. "/" .. name end
  end
  return flow_files(paths)
end

--- Every local action's metadata file: each `action.yml` or
--- `action.yaml` under ACTIONS, at any depth.
local function action_paths(): {string}
  local paths: {string} = {}
  if not Fs.is_dir(ACTIONS) then return paths end
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
    local workflow, err = Json.decode_object(text, READ)
    assert(workflow ~= nil, path .. ": " .. err)
    local name, jobs = workflow.name, workflow.jobs
    assert(name is string and jobs is {string: any}, path .. ": no name or jobs")
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
    local action, err = Json.decode_object(text, READ)
    assert(action ~= nil, path .. ": " .. err)
    local name, runs = action.name, action.runs
    assert(name is string and runs is {string: any}, path .. ": no name or runs")
    assert(runs.using == "composite", path .. ": not a composite action")
    local steps = runs.steps
    assert(steps is {{string: any}} and #steps > 0, path .. ": no steps")
    for i, step in ipairs(steps) do
      local shell = step.shell
      local run = step.run
      if run ~= nil then
        assert(run is string and not run:find("\n", 1, true),
          path .. ": step " .. i .. "'s run is not one line: put it under .github/scripts/")
        assert(shell is string, path .. ": step " .. i .. " runs with no shell")
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
local function expressions(text: string, action: {string: any}): {string}
  local out: {string} = {}
  for expression in text:gmatch("%${{(.-)}}") do out[#out + 1] = expression end
  local runs = action.runs
  local steps = runs is {string: any} and runs.steps or nil
  if steps is {{string: any}} then
    for _, step in ipairs(steps) do
      local condition = step["if"]
      if condition is string and not condition:find("${{", 1, true) then
        out[#out + 1] = condition
      end
    end
  end
  return out
end

--- The inputs `expression` reads, as `inputs.<name>` or
--- `inputs['<name>']`.
local function inputs_read(expression: string): {string}
  local out: {string} = {}
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
    local action = assert(Json.decode_object(text, READ))
    local declared = action.inputs
    local names: {string: any} = declared is {string: any} and declared or {}
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
  local action = { runs = { steps = { { ["if"] = "inputs.owner != ''" }, { ["if"] = "${{ inputs.a }}" } } } }
  local got = expressions("${{ inputs['b'] }} ${{ inputs.a }}", action as {string: any})
  assert(#got == 3 and got[3] == "inputs.owner != ''", table.concat(got, "|"))
  local names = inputs_read([=[inputs.zig-cache == 'true' && inputs[ "x y" ] || inputs['z']]=])
  assert(table.concat(names, ",") == "zig-cache,x y,z", table.concat(names, ","))
end

--- Each decoded flow-style workflow, by path.
local function decoded_workflows(): {string: {string: any}}
  local out: {string: {string: any}} = {}
  for path, text in pairs(flow_workflows()) do
    out[path] = assert(Json.decode_object(text, READ))
  end
  return out
end

--- The condition ci.yml's COSMIC_CI_SCOPE is `full` on; a matrix,
--- which cannot read `env`, tests it again.
local FULL_RUN <const> = "(github.event_name != 'push' || github.ref == 'refs/heads/main')"

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
  local dims: {string} = {}
  for key in pairs(matrix) do
    if key ~= "include" and key ~= "exclude" then dims[#dims + 1] = key end
  end
  table.sort(dims)
  local combos: {{string: string}} = {}
  if #dims > 0 then combos = { {} } end
  for _, dim in ipairs(dims) do
    local value = matrix[dim]
    if value is string then
      local condition, full, light = value:match("^%${{ fromJSON%((.-) && '(%[.-%])' || '(%[.-%])'%) }}$")
      assert(condition == FULL_RUN, "matrix " .. dim .. " is chosen other than by the scope: " .. value)
      value = assert(Json.decode(scope == "full" and full or light))
    end
    local next_combos: {{string: string}} = {}
    for _, combo in ipairs(combos) do
      for _, v in ipairs(value as {string}) do
        local c: {string: string} = {}
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
  local kept: {{string: string}} = {}
  for _, combo in ipairs(combos) do
    local excluded = false
    for _, entry in ipairs(matrix.exclude as {{string: string}} or {}) do
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
  local created: {{string: string}} = {}
  for _, entry in ipairs(matrix.include as {{string: string}} or {}) do
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
      local c: {string: string} = {}
      for k, v in pairs(entry) do c[k] = v end
      created[#created + 1] = c
    end
  end
  for _, c in ipairs(created) do combos[#combos + 1] = c end
  return combos
end

--- A job's matrix legs on a run of `scope`, as [`expand`] gives them.
local function legs_of(job: {string: any}, scope: string): {{string: string}}
  return expand((job.strategy as {string: any}).matrix as {string: any}, scope)
end

--- [`expand`] gives the combinations GitHub's docs give for their
--- example of `include`: an entry that fits no original combination
--- is one of its own, which a later entry does not extend.
local function test_a_matrix_expands_as_githubs_docs_say()
  local got = expand({
    fruit = { "apple", "pear" }, animal = { "cat", "dog" },
    include = {
      { color = "green" }, { color = "pink", animal = "cat" }, { fruit = "apple", shape = "circle" },
      { fruit = "banana" }, { fruit = "banana", animal = "cat" },
    },
  }, "full")
  local lines: {string} = {}
  for _, combo in ipairs(got) do
    local parts: {string} = {}
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
  if leg.shard == "2/2" then return leg.name .. "-shard" end
  return leg.name
end
local function leg_shard(leg: {string: string}): string
  if leg.name == "linux-x86_64" and leg.shard ~= "" then return leg.shard end
  return ""
end

--- The platform legs by job name ([`LEG_NAME`]), on a run of `scope`.
local function platform_legs(scope: string): {string: {string: string}}
  local ci = decoded_workflows()[DIR .. "/ci.yml"] as {string: any}
  local out: {string: {string: string}} = {}
  for _, leg in ipairs(legs_of((ci.jobs as {string: {string: any}}).platform, scope)) do
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
    local out: {string} = {}
    for name in pairs(legs) do out[#out + 1] = name end
    table.sort(out)
    return table.concat(out, " ")
  end
  assert(names(full) == "alpine-x86_64 linux-aarch64 linux-x86_64 macos-aarch64", "a full run's legs: " .. names(full))
  assert(names(light) == "linux-aarch64 linux-x86_64 linux-x86_64-shard macos-aarch64",
    "a light run's legs: " .. names(light))
  -- Each leg's entry sets every value the first, alpine-x86_64's, sets:
  -- one it left out would be alpine-x86_64's on that leg.
  local ci = decoded_workflows()[DIR .. "/ci.yml"] as {string: any}
  local platform = (ci.jobs as {string: {string: any}}).platform
  local include = ((platform.strategy as {string: any}).matrix as {string: any}).include as {{string: string}}
  assert(include[1].name == nil, "the first entry names a leg: " .. tostring(include[1].name))
  for i = 2, #include do
    assert(include[i].name ~= nil, "entry " .. i .. " names no leg")
    for key in pairs(include[1]) do
      assert(include[i][key] ~= nil, include[i].name .. " keeps alpine-x86_64's " .. key)
    end
  end
  local alpine = full["alpine-x86_64"]
  assert(alpine.runner == "ubuntu-24.04" and alpine.target == "x86_64-linux-musl" and
      alpine.image:find("^ghcr%.io/cosmic%-lua/cosmic%-ci%-alpine@sha256:") ~= nil and
      alpine.prepare:find("^adduser ") ~= nil and alpine.shell == "leg-shell {0}",
    "alpine-x86_64's values: " .. tostring(alpine.image) .. " " .. tostring(alpine.prepare))
  local keys: {string} = {}
  for key in pairs(alpine) do keys[#keys + 1] = key end
  for name, leg in pairs(full) do
    for _, key in ipairs(keys) do assert(leg[key] ~= nil, name .. " has no " .. key) end
    if name ~= "alpine-x86_64" then
      assert(leg.image:find("alpine", 1, true) == nil and (leg.prepare or ""):find("adduser", 1, true) == nil,
        name .. " runs as alpine-x86_64 does: " .. leg.image)
    end
    local other = light[name]
    for _, key in ipairs(keys) do
      -- A light run's share is its own (test_a_branch_push_splits_linux_x86_64s_suite_in_two).
      assert(other == nil or key == "shard" or other[key] == leg[key],
        name .. "'s " .. key .. " differs on a light run")
    end
  end
  assert(full["macos-aarch64"].image == "" and full["macos-aarch64"].prepare == "", "macos-aarch64 has an image")
end

--- A branch push (`light`) splits linux-x86_64's native suite, the
--- longest of its legs', in two: two legs of linux-x86_64's own
--- values, the first with COSMIC_CI_SHARD 1/2 and the second, named
--- linux-x86_64-shard, 2/2, each restoring and keying as that leg does
--- (its `name` in the matrix is the leg's) and uploading under a name
--- of its own; every other leg, and every leg of a full run, runs its
--- suite whole. The gate needs every leg.
local function test_a_branch_push_splits_linux_x86_64s_suite_in_two()
  local ci = decoded_workflows()[DIR .. "/ci.yml"] as {string: any}
  local jobs = ci.jobs as {string: {string: any}}
  local platform = jobs.platform
  local env = platform.env as {string: string}
  assert(platform.name == LEG_NAME, "the legs' name: " .. tostring(platform.name))
  assert(env.COSMIC_WORKER == LEG_NAME, "the legs' COSMIC_WORKER: " .. tostring(env.COSMIC_WORKER))
  assert(env.COSMIC_CI_SHARD == LEG_SHARD, "the legs' COSMIC_CI_SHARD: " .. tostring(env.COSMIC_CI_SHARD))
  local light, full = platform_legs("light"), platform_legs("full")
  local first, second = light["linux-x86_64"], light["linux-x86_64-shard"]
  assert(first ~= nil and second ~= nil, "a light run has no second linux-x86_64 leg")
  assert(leg_shard(first) == "1/2" and leg_shard(second) == "2/2",
    "linux-x86_64's shares: " .. leg_shard(first) .. " " .. leg_shard(second))
  for key, value in pairs(first) do
    assert(key == "shard" or second[key] == value, "linux-x86_64-shard's " .. key .. " differs")
  end
  for key in pairs(second) do assert(first[key] ~= nil, "linux-x86_64-shard has " .. key) end
  assert(second.name == "linux-x86_64", "the second share restores by " .. tostring(second.name))
  for name, leg in pairs(light) do
    if leg.name ~= "linux-x86_64" then
      assert(leg_shard(leg) == "", name .. " runs a share of its suite")
    end
  end
  for name, leg in pairs(full) do
    assert(leg_shard(leg) == "" and leg.shard == "", name .. " runs a share of a full run's suite")
    assert(leg_name(leg) == leg.name, name .. " is named apart on a full run")
  end
  -- Every artifact a light run's leg uploads is named apart, by the
  -- job's name: two of one name would fail the second upload.
  for _, step in ipairs(platform.steps as {{string: any}}) do
    local uses = step.uses as string or ""
    if uses:find("^actions/upload%-artifact@") then
      local with = step.with as {string: string}
      local condition = step["if"] as string or ""
      local light_too = not (condition:find("COSMIC_CI_SCOPE == 'full'", 1, true) or
        condition:find("github.event_name == 'merge_group'", 1, true))
      if light_too then
        assert(with.name:find("${{ env.COSMIC_WORKER }}", 1, true) and
            not with.name:find("matrix.name", 1, true),
          "a light run's legs upload " .. with.name .. " under one name")
      end
    end
  end
  local needs = jobs.ci.needs as {string}
  local gated = false
  for _, need in ipairs(needs) do
    if need == "platform" then gated = true end
  end
  assert(gated, "the gate does not need the legs")
end

--- A workflow runs only when a path its filters name changes, so a
--- path that no longer exists is a check that silently stops running,
--- or one that never stops: every trigger's `paths` and `paths-ignore`
--- must name what exists.
local function test_each_path_filter_names_what_exists()
  local count = 0
  for path, workflow in pairs(decoded_workflows()) do
    local on = workflow["on"]
    if on is {string: any} then
      for trigger, spec in pairs(on) do
        for _, field in ipairs({ "paths", "paths-ignore" }) do
          local entries = spec is {string: any} and spec[field] or nil
          if entries is {string} then
            local where = path .. "'s " .. trigger .. "." .. field
            assert(#entries > 0, where .. " is empty")
            for _, entry in ipairs(entries) do
              count = count + 1
              -- A `!` excludes what it names, which must exist all the same.
              local fixed = entry:gsub("^!", ""):gsub("/%*%*$", "")
              assert(not fixed:find("*", 1, true), where .. ": " .. entry .. ": only a trailing /** is checked")
              assert(Fs.exists(fixed), entry .. " is in " .. where .. ", and does not exist")
            end
          end
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
  local parts: {string} = {}
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
local function directory(step: {string: any}, holders: {{string: any}}): string
  local all: {{string: any}} = { step }
  for _, holder in ipairs(holders) do all[#all + 1] = holder end
  for _, holder in ipairs(all) do
    local here = holder["working-directory"]
    if here == nil then
      local run = holder.run
      here = run is {string: any} and run["working-directory"] or nil
    end
    if here is string then return here end
  end
  return "."
end

--- What an `actions/checkout` step brings in: nil for the whole tree,
--- else the paths its `sparse-checkout` names, without their slashes at
--- either end.
local function checked_out(step: {string: any}): {string} | nil
  local with = step.with
  local sparse = with is {string: any} and with["sparse-checkout"] or nil
  if not sparse is string then return nil end
  local paths: {string} = {}
  for line in sparse:gmatch("[^\n]+") do
    paths[#paths + 1] = (line:gsub("^%s*/?", ""):gsub("/?%s*$", ""))
  end
  return paths
end

--- Whether a checkout of `sparse` (nil for the whole tree) holds `path`:
--- it is, or lies under, a path `sparse` names.
local function holds(sparse: {string} | nil, path: string): boolean
  if sparse == nil then return true end
  for _, prefix in ipairs(sparse) do
    if path == prefix or String.starts_with(path, prefix .. "/") then return true end
  end
  return false
end

--- The metadata file of the local action in `dir`, its `action.yml` or
--- `action.yaml`, or nil when it has neither.
local function action_file(dir: string): string | nil
  for _, name in ipairs({ "action.yml", "action.yaml" }) do
    local st = Fs.stat(dir .. "/" .. name)
    if st ~= nil and st.kind == "file" then return dir .. "/" .. name end
  end
  return nil
end

--- What a job's steps have checked out so far, and what they ran.
local record Walk
  checkout: boolean
  sparse: {string}
  scripts: {string}
  actions: {string: boolean}
end

--- Checks `steps` in order against what `walk` has checked out, as
--- `where` (a job, or an action a job uses) runs them, their `run`
--- starting where `directory` says with `holders` for defaults.
--- A `uses: ./...` step runs a local action from the checkout, so it
--- needs a checkout before it that holds the action's directory, and
--- its own steps are walked in turn, their scripts held to the same
--- checkout.
local function walk_steps(where: string, steps: {{string: any}}, holders: {{string: any}}, walk: Walk)
  for _, step in ipairs(steps) do
    local uses = step.uses
    if uses is string and uses:match("^actions/checkout@") then
      walk.checkout, walk.sparse = true, checked_out(step)
    elseif uses is string and uses:match("^%./") then
      local dir = normal(uses)
      assert(walk.checkout, where .. " uses " .. dir .. " before any checkout")
      assert(holds(walk.sparse, dir), where .. "'s sparse checkout does not hold " .. dir ..
          ", the action a step uses")
      local file = action_file(dir)
      assert(file ~= nil, where .. " uses " .. dir .. ", which holds no action.yml")
      walk.actions[dir] = true
      local action = assert(Json.decode_object((assert(Fs.read(file))), READ))
      local runs = action.runs
      local inner = runs is {string: any} and runs.steps or nil
      if inner is {{string: any}} then
        walk_steps(where .. " (through " .. dir .. ")", inner, {}, walk)
      end
    end
    local run = step.run
    if run is string and walk.checkout and walk.sparse ~= nil then
      -- A `run` step starts in its working directory, so a sparse
      -- checkout must hold it: be it, or lie under or over a path it
      -- names.
      local here = normal(directory(step, holders))
      if here ~= "" then
        local present = false
        for _, prefix in ipairs(walk.sparse) do
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
    local texts: {string} = {}
    if run is string then texts[1] = run end
    local env = step.env
    if env is {string: any} then
      for _, value in pairs(env) do
        if value is string then texts[#texts + 1] = value end
      end
    end
    for _, text in ipairs(texts) do
      local hashed: {string} = {}
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
local function scripts_run(path: string, workflow: {string: any}): {string}, {string: boolean}
  local walk: Walk = { checkout = false, scripts = {}, actions = {} }
  local jobs = workflow.jobs
  assert(jobs is {string: {string: any}}, path .. ": no jobs")
  for name, job in pairs(jobs) do
    local steps = job.steps
    if steps is {{string: any}} then
      walk.checkout, walk.sparse = false, nil
      local holders = { (job.defaults or {}) as {string: any}, (workflow.defaults or {}) as {string: any} }
      walk_steps(path .. ": job " .. name, steps, holders, walk)
    end
  end
  return walk.scripts, walk.actions
end

--- The scripts the workflows run are the ones under SCRIPTS: each one a
--- step names is a file there, found from where the step starts, and
--- each file there is one some step names. So are the local actions
--- under ACTIONS: each is one some workflow uses.
local function test_the_workflows_run_the_scripts_there_are()
  local named: {string: boolean} = {}
  local used: {string: boolean} = {}
  for path, workflow in pairs(decoded_workflows()) do
    local scripts, actions = scripts_run(path, workflow)
    for _, script in ipairs(scripts) do
      named[script] = true
      local st = Fs.stat(script)
      assert(st ~= nil and st.kind == "file", path .. " runs " .. script .. ", which is no file")
    end
    for dir in pairs(actions) do used[dir] = true end
  end
  for _, name in ipairs((assert(Fs.list(SCRIPTS)))) do
    local script = SCRIPTS .. "/" .. name
    assert(named[script], script .. " is run by no workflow")
  end
  for _, file in ipairs(action_paths()) do
    local dir = file:match("^(.*)/[^/]+$")
    assert(used[dir], dir .. " is used by no workflow")
  end
end

--- What [`scripts_run`] refuses in a workflow of one job with `steps`,
--- or "" when it takes it.
local function refusal(steps: {{string: any}}): string
  local ok, err = pcall(scripts_run, "w.yml", { jobs = { j = { steps = steps } } } as {string: any})
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
  local function sparse(paths: string): {string: any}
    return { uses = CHECKOUT, with = { ["sparse-checkout"] = paths } }
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
    local jobs = workflow.jobs as {string: {string: any}}
    for name, job in pairs(jobs) do
      local shell: any = nil
      for _, holder in ipairs({ (job.defaults or {}) as {string: any}, (workflow.defaults or {}) as {string: any} }) do
        local run = holder.run
        if shell == nil and run is {string: any} then shell = run.shell end
      end
      local steps = job.steps
      if shell ~= nil and steps is {{string: any}} then
        for _, step in ipairs(steps) do
          local uses = step.uses
          local dir = uses is string and uses:match("^%./") and normal(uses) or nil
          local file = dir and action_file(dir) or nil
          if dir ~= nil and file ~= nil then
            local action = assert(Json.decode_object((assert(Fs.read(file))), READ))
            local inputs = action.inputs
            if inputs is {string: any} and inputs.shell ~= nil then
              count = count + 1
              local with = step.with
              local given = with is {string: any} and with.shell or nil
              assert(given == shell, path .. ": job " .. name .. " runs its steps with " .. tostring(shell) ..
                  ", and passes " .. dir .. " the shell " .. tostring(given))
              if inputs.owner ~= nil and job.container ~= nil then
                local owner = with is {string: any} and with.owner or nil
                assert(owner is string and owner ~= "", path .. ": job " .. name .. " runs its steps with " ..
                    tostring(shell) .. ", and names " .. dir .. " no owner to hand what it restores")
              end
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
  assert(not ok and tostring(err):find("climbs out of the checkout", 1, true), tostring(err))
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
  local seen: {string: string} = {}
  local where: {string: string} = {}
  local count = 0
  for path, text in pairs(flow_workflows()) do
    for image, digest in text:gmatch("(ghcr%.io/[%w%-_./]+)@sha256:(%x+)") do
      count = count + 1
      local before = seen[image]
      if before ~= nil and before ~= digest then
        error(path .. " pins " .. image .. " to " .. digest .. ", " .. where[image] .. " to " .. before)
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
  local ci = decoded_workflows()[DIR .. "/ci.yml"] as {string: any}
  local jobs = ci.jobs as {string: {string: any}}
  local named, bootstrapped, cached = false, false, 0
  for _, step in ipairs(jobs.platform.steps as {{string: any}}) do
    if step.id == "driver" then bootstrapped = true end
    if step.id == "host-id" then
      local run = step.run as string
      assert(run:find("cosmic-driver cosmic_ci/driver.tl leg-host-id ", 1, true) == 1, run)
      assert(run:find("host-features", 1, true) == nil, "the features are no argument: " .. run)
      assert(step["working-directory"] == nil, "the driver runs in ci/, the job's own directory")
      assert(bootstrapped, "the host is named before the driver is bootstrapped")
      -- STARTED is what names the container's options inside every
      -- verdict key: an input moved renames every verdict cache.
      assert((step.env as {string: string}).STARTED == "${{ hashFiles('.github/seccomp/**', " ..
          "'.github/scripts/leg-container.sh', '.github/scripts/seccomp-profile.sh') }}", run)
      assert(run:find('"$STARTED"', 1, true) ~= nil, run)
      named = true
    end
    local with = step.with as {string: string}
    if with ~= nil and with.path == "${{ runner.temp }}/verdicts" then
      cached = cached + 1
      assert(with.key:find("steps.host-id.outputs.verdicts", 1, true) ~= nil,
        "a verdict cache named by its container alone: " .. with.key)
      local restore = with["restore-keys"]
      assert(restore == nil or restore:find("steps.host-id.outputs.verdicts", 1, true) ~= nil,
        "a verdict cache restored by its container alone: " .. tostring(restore))
    end
  end
  assert(named, "the host-id step is gone")
  assert(cached == 3, "the restore, and the saves by content and by commit: " .. cached)
end

--- The key a restore of the verdicts under `prefix` (an expression)
--- takes: the entry main saved under the tree's base on main, where
--- `driver.tl merge-base` found one, else `prefix` alone, whose
--- restore-keys then take the newest.
local function at_the_base(prefix: string): string
  local inner = assert(prefix:match("^%${{ (.-) }}$"), prefix)
  return "${{ steps.merge-base.outputs.sha && format('{0}sha-{1}', " .. inner ..
    ", steps.merge-base.outputs.sha) || " .. inner .. " }}"
end

--- The key of the copy of the verdicts main saves under its commit.
local function under_the_commit(prefix: string): string
  return prefix .. "sha-${{ github.sha }}"
end

--- The steps that name, restore, trim and save a leg's test verdicts,
--- by id or by what they run or cache.
local function verdict_steps(steps: {{string: any}}): {string: integer}
  local at: {string: integer} = {}
  for i, step in ipairs(steps) do
    local id = step.id as string
    local run = step.run as string or ""
    local with = step.with as {string: any}
    if id == "host-id" or id == "merge-base" or id == "verdicts-restore" then
      at[id] = i
    elseif run:find("driver.tl verdicts-trim", 1, true) ~= nil then
      at.trim = i
    elseif with ~= nil and with.path == "${{ runner.temp }}/verdicts" and
        (step.uses as string):find("actions/cache/save@", 1, true) ~= nil then
      at.save = i
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
  local ci = decoded_workflows()[DIR .. "/ci.yml"] as {string: any}
  local jobs = ci.jobs as {string: {string: any}}
  local env = jobs.platform.env as {string: string}
  assert(env.COSMIC_CI_REQUIRE_SANDBOX == "${{ matrix.image && '1' || '0' }}",
    tostring(env.COSMIC_CI_REQUIRE_SANDBOX))
  assert(env.COSMIC_CI_DECLARED_KEYS == "${{ matrix.image && '0' || '1' }}",
    "the leg with no sandbox is not keyed by declarations: " ..
      tostring(env.COSMIC_CI_DECLARED_KEYS))
  local steps = jobs.platform.steps as {{string: any}}
  local at = verdict_steps(steps)
  local back: integer
  for i, step in ipairs(steps) do
    if step.name == "move the tree back to where it was checked out" then back = i end
    if step.id == "boot" or step.id == "release-suite" or step.id == "portable-suite" then
      at[step.id as string] = i
    end
  end
  local order = { "host-id", "merge-base", "verdicts-restore", "boot", "release-suite", "portable-suite",
    "trim", "back", "save" }
  at.back = back
  for n, name in ipairs(order) do
    assert(at[name] ~= nil, "no step " .. name)
    if n > 1 then
      assert(at[order[n - 1]] < at[name], order[n - 1] .. " comes after " .. name)
    end
    local condition = steps[at[name]]["if"] as string or ""
    assert(condition:find("matrix.image", 1, true) == nil,
      name .. " runs only on a leg with an image: " .. condition)
  end
  local restore = steps[at["verdicts-restore"]].with as {string: string}
  assert(restore.key == at_the_base("${{ steps.host-id.outputs.verdicts }}"), restore.key)
  assert(restore["restore-keys"] == "${{ steps.host-id.outputs.verdicts }}\n",
    restore["restore-keys"])
end

--- A job's `env` and each of its steps' that has one.
local function envs_of(job: {string: any}): {{string: string}}
  local out: {{string: string}} = {}
  if job.env ~= nil then out[#out + 1] = job.env as {string: string} end
  for _, step in ipairs(job.steps as {{string: any}} or {}) do
    if step.env ~= nil then out[#out + 1] = step.env as {string: string} end
  end
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
local function main_saves(steps: {{string: any}}): integer
  local restores: {string: {string: any}} = {}
  local trims: {string: string} = {}
  local saves = 0
  for _, step in ipairs(steps) do
    local uses = step.uses as string or ""
    local with = step.with as {string: any}
    local run = step.run
    if run is string then
      local verb = run:match("driver%.tl (%a+)%-trim")
      if verb ~= nil then
        assert(step.id ~= nil, verb .. "'s trim has no id")
        trims[verb] = step.id as string
      end
    end
    if uses:find("actions/cache/restore@", 1, true) ~= nil and step.id ~= nil then
      local path = with.path as string
      -- The one restore that turns on the ref: another vendor part's zig
      -- outputs, which main never takes. A restore only on a full run
      -- (`FULL`) is on every run main saves from: the checked job's
      -- verdicts, and the legs' driver check marker, which a light run
      -- checks in the checked job instead. There, a light run's lookup
      -- of linux-x86_64's marker (`LIGHT`) restores nothing, and that
      -- job saves no marker, which would find no restore here.
      local condition = step["if"] as string or ""
      if condition:find(FULL, 1, true) == 1 then
        condition = condition:sub(#FULL + 5)
      end
      if condition == LIGHT and path == "${{ runner.temp }}/driver-checked" then
        assert(with["lookup-only"] == true, path .. " is restored on a light run")
      elseif condition ~= "" then
        assert(path == "${{ runner.temp }}/zig-build" and
            condition:find("github.ref != 'refs/heads/main'", 1, true) == 1,
          path .. " is restored only on some runs: " .. condition)
      else
        restores[path] = step
      end
    end
    if uses:find("actions/cache/save@", 1, true) ~= nil and
        not branch_compiles(with.key as string) then
      saves = saves + 1
      local path = with.path as string
      local condition = step["if"] as string
      local key = with.key as string
      local restore = restores[path]
      assert(restore ~= nil, path .. " is saved but restored on no run before")
      assert(condition:find(SAVES, 1, true) ~= nil and
          not condition:find(SAVES .. " ||", 1, true) and not condition:find("|| " .. SAVES, 1, true),
        path .. " is saved off main, or by another of main's events: " .. condition)
      assert(not condition:find("merge_group", 1, true) and not key:find("event_name", 1, true),
        path .. "'s save turns on the merge queue: " .. condition .. " " .. key)
      local rkey = (restore.with as {string: any}).key as string
      if key == "${{ steps." .. (restore.id as string) .. ".outputs.cache-primary-key }}" then
        assert(not rkey:find("github.sha", 1, true), path .. " is keyed by the commit: " .. rkey)
      else
        -- The trim of this cache, and the prefix the restore takes: the
        -- restore's key, or, for the verdicts, the base's entry first.
        local verdicts = path == "${{ runner.temp }}/verdicts"
        local trim = verdicts and trims.verdicts or
          path == "${{ runner.temp }}/build-cache" and trims.compiles or nil
        assert(trim ~= nil, path .. " is saved under a key of its own, cut by no trim: " .. key)
        -- Main's prefix last: a branch's compiles are asked for first
        -- (test_a_branch_saves_compiles_for_its_later_pushes).
        local rkeys = (restore.with as {string: any})["restore-keys"] as string
        local prefix = rkeys:match("([^\n]*)\n$")
        if path == "${{ runner.temp }}/build-cache" then
          assert(rkey == BRANCH_COMPILES and rkeys == BRANCH_COMPILES .. "\n" .. prefix .. "\n",
            path .. " is restored by other prefixes than a branch's, then main's: " .. rkeys)
        else
          assert(rkeys == prefix .. "\n" and (rkey == prefix or verdicts and rkey == at_the_base(prefix)),
            path .. " is restored by another prefix than it is saved under: " .. rkey)
        end
        local digest = "${{ steps." .. trim .. ".outputs.digest }}"
        if verdicts and key == under_the_commit(prefix) then
          -- Whatever was restored: its own key is new each commit.
          assert(not condition:find("cache-matched-key", 1, true),
            path .. "'s copy under the commit is skipped where the rows are an entry's: " .. condition)
        else
          assert(key == prefix .. digest, path .. " is not saved under its prefix and digest: " .. key)
        end
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
  local ci = decoded_workflows()[DIR .. "/ci.yml"] as {string: any}
  local concurrency = ci.concurrency as {string: string}
  assert(not concurrency.group:find("github.sha", 1, true),
    "main's pushes run in a group of each commit's own: " .. concurrency.group)
  assert(concurrency["cancel-in-progress"] == "${{ github.ref != 'refs/heads/main' }}",
    "a run of main cancels another: " .. concurrency["cancel-in-progress"])
  local saves_env = (ci.env as {string: string}).COSMIC_CI_SAVES
  assert(saves_env == MAIN_SAVES, "COSMIC_CI_SAVES is not main's push and schedule: " ..
      tostring(saves_env))
  local jobs = ci.jobs as {string: {string: any}}
  for name, job in pairs(jobs) do
    for _, env in ipairs(envs_of(job)) do
      assert(env.COSMIC_CI_SAVES == nil, "job " .. name .. " sets COSMIC_CI_SAVES again")
    end
  end
  assert(main_saves(jobs.platform.steps as {{string: any}}) == 5,
    "the verdicts (by content and by commit), compiles, zig outputs and driver marker")
  assert(main_saves(jobs.checked.steps as {{string: any}}) == 2,
    "the checked job's verdicts, by content and by commit")
end

--- The cache saves among `steps`, by the key each saves under: the
--- verdicts are saved twice, by content and by commit.
local function saves_of(steps: {{string: any}}): {string: {string: any}}
  local out: {string: {string: any}} = {}
  for _, step in ipairs(steps) do
    if (step.uses as string or ""):find("actions/cache/save@", 1, true) ~= nil then
      local key = (step.with as {string: string}).key
      assert(out[key] == nil, "two saves under " .. key)
      out[key] = step
    end
  end
  return out
end

--- The save among `steps` of `path` under a key that names no commit,
--- and the one under the commit, if any.
local function save_of(steps: {{string: any}}, path: string): {string: any}, {string: any}
  local plain, commit: {string: any}, {string: any}
  for key, step in pairs(saves_of(steps)) do
    if (step.with as {string: string}).path == path then
      if key:find("sha-${{ github.sha }}", 1, true) or key:find("outputs.verdicts-sha }}", 1, true) then
        commit = step
      elseif branch_compiles(key) then
        -- A branch's, for its later pushes, which main never saves.
      else
        plain = step
      end
    end
  end
  return plain, commit
end

--- The step of `steps` whose `run` holds `text`, and where it stands.
local function step_running(steps: {{string: any}}, text: string): {string: any}, integer
  for i, step in ipairs(steps) do
    local run = step.run
    if run is string and run:find(text, 1, true) ~= nil then return step, i end
  end
  error("no step runs " .. text)
end

--- The index of the step of `steps` that bootstraps the pinned CI driver,
--- the first to use the local action.
local function driver_at(steps: {{string: any}}): integer
  for i, step in ipairs(steps) do
    if step.uses == DRIVER then return i end
  end
  error("no step bootstraps the driver")
end

local CACHE_NAMES <const> = "./.github/actions/cache-names"

local function cache_names(): {string: any}
  return (assert(Json.decode_object((assert(Fs.read(CACHE_NAMES .. "/action.yml"))), READ)))
end

--- What `names` hashes as the compiler a branch's compiles were made
--- by: the build's own modules and the Teal compiler's
--- and Lua's pins and patches, as the compiler's identity holds them
--- (build.identity's `compiler_identity`), and the rest of build/ beside.
local COMPILER_HASH <const> = "${{ hashFiles('build/**/*.tl', '!build/**/*_test.tl', " ..
  "'vendor/tl/PIN', 'vendor/lua/PIN', 'patch/tl/**', 'patch/lua/**') }}"

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
  local ci = decoded_workflows()[DIR .. "/ci.yml"] as {string: any}
  local jobs = ci.jobs as {string: {string: any}}
  for job, leg in pairs({ platform = "${{ matrix.name }}", checked = "linux-x86_64" }) do
    local steps = jobs[job].steps as {{string: any}}
    local names: {string: any}
    for _, step in ipairs(steps) do
      if step.id == "names" then names = step end
    end
    assert(names ~= nil and names.uses == CACHE_NAMES and
        (names.with as {string: string}).leg == leg,
      job .. " names a branch's compiles by another leg: " .. tostring(names and names.with))
    local restore: {string: string}
    for _, step in ipairs(steps) do
      if step.id == "compiles-restore" then restore = step.with as {string: string} end
    end
    assert(restore.key == BRANCH_COMPILES and
        restore["restore-keys"] == BRANCH_COMPILES .. "\ncompiles-" .. leg .. "-\n",
      job .. " restores other compiles than its branch's, then main's: " .. tostring(restore["restore-keys"]))
  end
  local action = cache_names()
  local names = ((action.runs as {string: any}).steps as {{string: any}})[1]
  assert((names.env as {string: string}).COMPILER == COMPILER_HASH,
    "the branch compiles hash different compiler inputs")
  assert(not ("compiles-branch-"):find("compiles-${{ matrix.name }}-", 1, true),
    "main's prefix takes a branch's entries")

  local steps = jobs.platform.steps as {{string: any}}
  local branch: {{string: any}} = {}
  for key, step in pairs(saves_of(steps)) do
    if branch_compiles(key) then branch[#branch + 1] = step end
  end
  assert(#branch == 1, "a branch's compiles are saved by " .. #branch .. " steps")
  local with = branch[1].with as {string: string}
  assert(with.path == "${{ runner.temp }}/build-cache" and
      with.key == BRANCH_COMPILES .. "${{ steps.compiles-trim.outputs.digest }}",
    "a branch's compiles are saved from elsewhere, or not by their digest: " .. with.key)
  local condition = branch[1]["if"] as string
  for _, part in ipairs({ "steps.release-suite.outcome == 'success'", "steps.compiles-trim.outputs.digest != ''",
      LIGHT, "matrix.shard != '2/2'", "fromJSON(steps.compiles-trim.outputs.fresh || '0') > 50" }) do
    assert(condition:find(part, 1, true) ~= nil, "a branch saves its compiles without " .. part .. ": " .. condition)
  end
  assert(not condition:find(SAVES, 1, true), "main saves a branch's compiles: " .. condition)
  for _, step in pairs(saves_of(jobs.checked.steps as {{string: any}})) do
    assert(not branch_compiles((step.with as {string: string}).key), "the checked job saves a branch's compiles")
  end

  -- The copy of what was restored: made after the restore and before
  -- the boot, where the trim reads it, outside the path saved.
  local _, restored, copy, boot: integer, integer, integer, integer
  for i, step in ipairs(steps) do
    if step.id == "compiles-restore" then restored = i end
    if step.name == "build release Cosmic" then boot = i end
    local run = step.run
    if run is string and run:find("cp \"$RUNNER_TEMP/build-cache/cache.db\" " ..
          "\"$RUNNER_TEMP/compiles-restored.db\"", 1, true) ~= nil then
      copy = i
      -- On a light run alone, since only it saves; a copy that fails
      -- only costs a save, so it never fails the leg.
      assert(step["if"] == "env.COSMIC_CI_SCOPE == 'light'" and step["continue-on-error"] == true and
          step.shell == "sh", "the copy is made on a run that saves none, fails the leg, or runs in the container")
    end
  end
  assert(restored ~= nil and copy ~= nil and boot ~= nil and restored < copy and copy < boot,
    "the compiles restored are copied elsewhere than between their restore and the boot")
  local trim = step_running(steps, "driver.tl compiles-trim")
  assert((trim.run as string):find("compiles-trim \"${{ steps.names.outputs.since }}\" " ..
      "\"${{ runner.temp }}/compiles-restored.db\"", 1, true) ~= nil,
    "the trim counts the fresh compiles against another file: " .. (trim.run as string))
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
  local ci = decoded_workflows()[DIR .. "/ci.yml"] as {string: any}
  local jobs = ci.jobs as {string: {string: any}}
  local reuse, platform, seed = jobs.reuse, jobs.platform, jobs.seed
  -- A push to main alone: a branch push's legs wait on no runner of its.
  assert(reuse["if"] == "github.event_name == 'push' && github.ref == 'refs/heads/main'", tostring(reuse["if"]))
  assert((reuse.permissions as {string: string}).actions == "read", "reuse cannot read the queue's run")
  for _, step in ipairs(reuse.steps as {{string: any}}) do
    assert(step["if"] == nil, "reuse skips a step of its own: " .. tostring(step["if"]))
  end
  local find, found_at = step_running(reuse.steps as {{string: any}}, "driver.tl queue-find")
  assert(find.id == "find" and find.run == "cosmic-driver cosmic_ci/driver.tl queue-find" and
      find["working-directory"] == "ci", tostring(find.run))
  -- The driver is bootstrapped before the lookup, and a driver that cannot be had is no
  -- lookup, which the legs meet as one that found nothing.
  local bootstrap = (reuse.steps as {{string: any}})[driver_at(reuse.steps as {{string: any}})]
  assert(driver_at(reuse.steps as {{string: any}}) < found_at and bootstrap["continue-on-error"] == true,
    "reuse looks up before it has the driver, or fails for want of it")
  assert((find.env as {string: string}).SHA == "${{ github.sha }}", "reuse looks up another commit")
  -- A lookup that fails is none: the legs run, and the join reads theirs.
  assert(find["continue-on-error"] == true, "a failed lookup fails reuse")
  -- Its budget, from the driver's defaults, is under the job's timeout
  -- with a minute to spare for the checkout.
  local script = assert(Fs.read("ci/cosmic_ci/queue_seed.tl"))
  local tries = script:match('whole%(env, "TRIES", (%d+)%)')
  local wait = script:match('whole%(env, "WAIT_SECONDS", (%d+)%)')
  local call = script:match('whole%(env, "CALL_SECONDS", (%d+)%)')
  assert(tries ~= nil and wait ~= nil and call ~= nil, "queue_seed.tl's budget moved")
  local budget = math.tointeger(tonumber(tries) * (tonumber(wait) + 2 * tonumber(call)))
  assert(budget + 60 <= (reuse["timeout-minutes"] as integer) * 60, "reuse times out within its lookup's budget, " ..
      budget .. " s: " .. tostring(reuse["timeout-minutes"]))
  assert((reuse.outputs as {string: string}).run == "${{ steps.find.outputs.run }}", "reuse's output")

  -- `!cancelled()` runs the legs where `reuse` was skipped (every run but
  -- a push to main) or failed, as where it found nothing: without a
  -- status function, a job whose need was skipped is skipped too.
  assert(platform.needs == "reuse" and platform["if"] == "!cancelled() && needs.reuse.outputs.run == ''",
    "the platform legs run other than where no queue run was found: " .. tostring(platform["if"]))
  assert(seed.needs == "reuse" and seed["if"] == "needs.reuse.outputs.run != ''",
    "seed runs other than where a queue run was found: " .. tostring(seed["if"]))
  assert((seed.permissions as {string: string}).actions == "read", "seed cannot read the queue's run")

  local function legs(job: {string: any}): {string: string}
    local out: {string: string} = {}
    for _, leg in ipairs(legs_of(job, "full")) do out[leg.name] = leg.runner end
    return out
  end
  local ours, theirs, count = legs(seed), legs(platform), 0
  local checked = jobs.checked
  local checked_name = (checked.env as {string: string}).COSMIC_WORKER
  theirs[checked_name] = checked["runs-on"] as string
  assert(seed["runs-on"] == platform["runs-on"], "seed runs on another runner than its leg")
  for name, runner in pairs(theirs) do
    count = count + 1
    assert(ours[name] == runner, "seed's " .. name .. " runs on " .. tostring(ours[name]) .. ", its leg on " .. runner)
  end
  for name in pairs(ours) do
    assert(theirs[name] ~= nil, "seed has a leg the platform job has not: " .. name)
  end
  assert(count == 5, "legs: " .. count)
  -- Only the checked job's seed relays no product.
  local marked: {string: any} = {}
  for _, leg in ipairs(((seed.strategy as {string: any}).matrix as {string: any}).include as {{string: any}}) do
    marked[leg.name as string] = leg.checked
  end
  for name in pairs(ours) do
    assert(marked[name] == (name == checked_name or nil), "seed's " .. name .. " is marked checked: " .. tostring(marked[name]))
  end
  -- The lookup asks for every leg's seed, and the checked job's.
  local named: {string} = {}
  for _, leg in ipairs(legs_of(platform, "full")) do
    named[#named + 1] = leg.name
  end
  named[#named + 1] = checked_name
  assert((find.env as {string: string}).LEGS == table.concat(named, " "),
    "reuse asks for other legs' seeds: " .. tostring((find.env as {string: string}).LEGS))

  local steps = seed.steps as {{string: any}}
  local downloads: {string: boolean} = {}
  local uploads: {string: boolean} = {}
  for _, step in ipairs(steps) do
    local uses = step.uses as string or ""
    local with = step.with as {string: string}
    local artifact = uses:find("actions/download-artifact@", 1, true) ~= nil or
      uses:find("actions/upload-artifact@", 1, true) ~= nil
    -- The zig outputs' download is held apart, below.
    if artifact and with.name ~= "seed-zig-${{ matrix.name }}" then
      local product = with.name == "portable-product-${{ matrix.name }}"
      assert(step["if"] == (product and "!matrix.checked" or nil),
        "seed relays a product on the checked job's leg, or skips its seed there: " .. tostring(step["if"]))
    end
    if uses:find("actions/download-artifact@", 1, true) ~= nil then
      assert(with["run-id"] == "${{ needs.reuse.outputs.run }}" and with["github-token"] == "${{ github.token }}",
        "seed downloads " .. with.name .. " from another run than the queue's")
      downloads[with.name] = true
    elseif uses:find("actions/upload-artifact@", 1, true) ~= nil then
      uploads[with.name] = true
    end
  end
  assert(downloads["seed-${{ matrix.name }}"] and downloads["portable-product-${{ matrix.name }}"],
    "seed downloads neither the leg's seed nor its product")
  assert(uploads["portable-product-${{ matrix.name }}"], "seed relays no product")
  local relayed = 0
  for _, step in ipairs(platform.steps as {{string: any}}) do
    local with = step.with as {string: string}
    if with ~= nil and with.name == "portable-product-${{ matrix.name }}" then
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
      "[0-9a-f]+|verdicts-sha=verdicts-${{ matrix.name }}-[0-9a-f]{16}-[0-9a-f]+-sha-${{ github.sha }}|" ..
      "compiles=compiles-${{ matrix.name }}-[0-9a-f]+|" ..
      "zig-build=zig-build-${{ matrix.name }}-[0-9a-f]+-full-[0-9a-f]+-[0-9]+-[0-9]+|" ..
      "zig-build-exact=zig-build-${{ matrix.name }}-[0-9a-f]+-full-[0-9a-f]+-|" ..
      "driver-checked=driver-checked-v2-${{ matrix.name }}-" ..
      "[A-Za-z0-9._-]+-verdicts-${{ matrix.name }}-[0-9a-f]{16}-[0-9a-f]+)$' " ..
      "\"$RUNNER_TEMP/seed.keys\" >> \"$GITHUB_OUTPUT\" || :",
    "seed reads other keys: " .. tostring(keys.run))
  local theirs_saved: {string: boolean} = {}
  for _, step in pairs(saves_of(platform.steps as {{string: any}})) do
    theirs_saved[(step.with as {string: string}).path] = true
  end
  local saved = 0
  for key, step in pairs(saves_of(steps)) do
    saved = saved + 1
    local path = (step.with as {string: string}).path
    assert(theirs_saved[path], "seed saves " .. path .. ", which no platform leg saves")
    local name = key:match("^%${{ steps%.keys%.outputs%.([%w-]+) }}$")
    assert(name ~= nil, path .. " is seeded under a key the queue did not name: " .. key)
    -- The zig outputs' save is held apart, below.
    if name ~= "zig-build" then
      assert(step["if"] == "steps.keys.outputs." .. name .. " != ''", path .. " is seeded where no key was named")
      assert(step["continue-on-error"] == nil, path .. "'s seed may fail unseen")
    end
  end
  assert(saved == 5, "the verdicts (by content and by commit), compiles, zig outputs and driver marker: " .. saved)
  -- The zig outputs, after the product's relay, and none of it a
  -- failure: a lookup by the prefix of their core and vendor part, a
  -- leg's restore's first, then, where it found none, the queue leg's
  -- artifact of them, the tar laid out with its modes, and the save.
  local zig_steps: {{string: any}} = {}
  local relay: integer
  for i, step in ipairs(steps) do
    local with = step.with as {string: string}
    if with ~= nil and with.name == "portable-product-${{ matrix.name }}" and
        (step.uses as string):find("actions/upload-artifact@", 1, true) ~= nil then
      relay = i
    end
    if relay ~= nil and i > relay then zig_steps[#zig_steps + 1] = step end
  end
  assert(#zig_steps == 4, "the zig outputs take other steps than four after the relay: " .. #zig_steps)
  for _, step in ipairs(zig_steps) do
    assert(step["continue-on-error"] == true, tostring(step.name or step.id) .. " can fail seed")
  end
  local lookup, download, unpack, zig = zig_steps[1], zig_steps[2], zig_steps[3], zig_steps[4]
  local lwith = lookup.with as {string: any}
  assert((lookup.uses as string):find("actions/cache/restore@", 1, true) ~= nil and lwith["lookup-only"] == true and
      lookup["if"] == "steps.keys.outputs.zig-build != ''" and
      lwith.path == "${{ runner.temp }}/zig-build" and lwith.key == "${{ steps.keys.outputs.zig-build }}" and
      lwith["restore-keys"] == "${{ steps.keys.outputs.zig-build-exact }}\n",
    "seed looks up another entry than one of the core and vendor part it saves")
  local dwith = download.with as {string: string}
  assert((download.uses as string):find("actions/download-artifact@", 1, true) ~= nil and
      dwith.name == "seed-zig-${{ matrix.name }}" and dwith.path == "${{ runner.temp }}" and
      download["if"] == "steps.keys.outputs.zig-build != '' && steps." .. (lookup.id as string) ..
      ".outputs.cache-matched-key == ''",
    "seed downloads the zig outputs elsewhere, or where an entry of their core holds them: " .. tostring(download["if"]))
  assert(unpack["if"] == "steps." .. (download.id as string) .. ".outcome == 'success'" and unpack.run ==
      "tar -xf \"$RUNNER_TEMP/zig-build.tar\" -C \"$RUNNER_TEMP\" && rm \"$RUNNER_TEMP/zig-build.tar\"",
    "the zig outputs are laid out elsewhere, or on other runs, than downloaded: " .. tostring(unpack.run))
  assert(zig == save_of(steps, "${{ runner.temp }}/zig-build") and
      zig["if"] == "steps." .. (unpack.id as string) .. ".outcome == 'success'",
    "the zig outputs are saved other than right after they are laid out: " .. tostring(zig["if"]))

  local join = jobs.ci
  local needs = join.needs as {string}
  assert(table.concat(needs, ",") == "reuse,platform,checked,seed", "the join needs " .. table.concat(needs, ","))
  -- The join passes on the legs and the checked job that ran, `seed`'s
  -- where a queue run was found, and on nothing of `reuse`'s but its
  -- output.
  local check = (join.steps as {{string: any}})[1]
  local check_env = check.env as {string: string}
  assert(check_env.RESULT == "${{ needs.reuse.outputs.run != '' && needs.seed.result || needs.platform.result }}",
    "the join reads the legs that ran: " .. tostring(check_env.RESULT))
  assert(check_env.CHECKED == "${{ needs.reuse.outputs.run != '' && needs.seed.result || needs.checked.result }}",
    "the join reads another checked suite than the one that ran: " .. tostring(check_env.CHECKED))
  assert(check.run == "echo \"queue run: ${QUEUE_RUN:-(none)}; legs: $RESULT; checked suite: $CHECKED\"; " ..
      "[ \"$RESULT\" = success ] && [ \"$CHECKED\" = success ]",
    "the join passes on more or less than the legs and the checked suite: " .. tostring(check.run))
  for name, value in pairs(check_env) do
    assert(name == "RESULT" or name == "CHECKED" or name == "QUEUE_RUN", "the join reads " .. name .. ": " .. value)
  end
end

--- A leg of the queue's run that passed keeps what main would have
--- saved, under the key main would have saved it under: its restore's
--- prefix and its trim's digest, where that is not the entry it
--- restored, and the driver check's marker, which holds its key. It
--- does so after both trims and with the tree back where the scripts
--- are, and uploads it as `seed-<leg>`, which `seed` downloads where
--- it lays it out again.
local function test_the_queue_keeps_what_main_would_save()
  local ci = decoded_workflows()[DIR .. "/ci.yml"] as {string: any}
  local jobs = ci.jobs as {string: {string: any}}
  local steps = jobs.platform.steps as {{string: any}}
  local stage, at = step_running(steps, "queue-seed.sh stage")
  local QUEUE <const> = "success() && github.event_name == 'merge_group'"
  assert(stage["if"] == QUEUE, "the queue's legs keep their seed on other runs: " .. tostring(stage["if"]))
  -- On the host, from the checkout's root, where the script is.
  assert(stage.shell == "sh" and stage["working-directory"] == ".",
    "the seed is kept elsewhere than on the host from the root")
  local env = stage.env as {string: string}
  for cache, path in pairs({ VERDICTS = "${{ runner.temp }}/verdicts", COMPILES = "${{ runner.temp }}/build-cache" }) do
    local save = save_of(steps, path)
    local key = (save.with as {string: string}).key
    assert(env[cache .. "_PREFIX"] .. env[cache .. "_DIGEST"] == key,
      cache .. " is seeded under another key than main saves it under: " .. key)
    assert(env[cache .. "_RESTORED"] ~= nil and (save["if"] as string):find(
      env[cache .. "_RESTORED"]:match("^%${{ (.-) }}$"), 1, true) ~= nil,
      cache .. "'s seed is compared with another entry than main's save is")
  end
  -- The zig outputs under the key main's save names, the restore's own,
  -- except where that restore took an entry of this core and vendor
  -- part: the first prefix it asks for.
  local zig = save_of(steps, "${{ runner.temp }}/zig-build")
  local zkey = (zig.with as {string: string}).key
  local restore = zkey:match("^%${{ steps%.([%w-]+)%.outputs%.cache%-primary%-key }}$")
  assert(restore ~= nil and env.ZIG_BUILD_KEY == zkey and
      env.ZIG_BUILD_RESTORED == "${{ steps." .. restore .. ".outputs.cache-matched-key }}",
    "the zig outputs are seeded under another key than main saves them under, or held to another entry: " ..
      tostring(env.ZIG_BUILD_KEY))
  local zrestore: {string: any}
  for _, step in ipairs(steps) do
    if step.id == restore then zrestore = step end
  end
  local first = (((zrestore.with as {string: string})["restore-keys"]):match("^([^\n]*)\n"))
  assert(env.ZIG_BUILD_EXACT == first and first:find("-${{ steps.names.outputs.core }}-", 1, true) ~= nil,
    "the zig outputs are held to another entry than one of this core: " .. tostring(env.ZIG_BUILD_EXACT))
  -- And the verdicts under the commit, which is the queue's merge.
  local _, twin = save_of(steps, "${{ runner.temp }}/verdicts")
  assert(env.SHA == "${{ github.sha }}" and
      under_the_commit(env.VERDICTS_PREFIX) == (twin.with as {string: string}).key,
    "the verdicts are seeded under another commit's key than main saves them under")
  local marker = save_of(steps, "${{ runner.temp }}/driver-checked")
  local _, checked = step_running(steps, "cosmic-driver test cosmic_ci")
  local writes = steps[checked].run as string
  assert(writes:find("echo \"" .. (marker.with as {string: string}).key .. "\" > \"$RUNNER_TEMP/driver-checked/key\"",
    1, true) ~= nil, "the driver check's marker does not hold the key main saves it under: " .. writes)
  local _, trimmed = step_running(steps, "driver.tl verdicts-trim")
  local _, compiled = step_running(steps, "driver.tl compiles-trim")
  local back: integer
  for i, step in ipairs(steps) do
    if step.name == "move the tree back to where it was checked out" then back = i end
  end
  assert(trimmed < at and compiled < at and back < at, "the seed is kept before a trim, or with the tree moved")
  local upload = steps[at + 1]
  local with = upload.with as {string: string}
  assert(upload["if"] == QUEUE and with.name == "seed-${{ matrix.name }}" and with.path == "${{ runner.temp }}/seed" and
      upload["continue-on-error"] == nil, "the seed is not uploaded as the leg's, or may fail unseen")
  -- The zig outputs apart, where a failure fails nothing.
  local zupload = steps[at + 2]
  local zwith = zupload.with as {string: any}
  assert(zupload["if"] == QUEUE and zupload["continue-on-error"] == true and
      zwith.name == "seed-zig-${{ matrix.name }}" and zwith.path == "${{ runner.temp }}/seed-zig" and
      zwith["if-no-files-found"] == "ignore",
    "the zig outputs are uploaded other than apart from the seed, and failing nothing: " .. tostring(zwith.name))
  local download: {string: string}
  for _, step in ipairs(jobs.seed.steps as {{string: any}}) do
    local w = step.with as {string: string}
    if w ~= nil and w.name == "seed-${{ matrix.name }}" then download = w end
  end
  assert(download.path == "${{ runner.temp }}", "the seed is laid out elsewhere than it was kept: " .. download.path)

  -- The checked job keeps its verdicts alone, as a leg keeps its own,
  -- after its trim and with its container gone, under its own name.
  local cjob = jobs.checked
  local csteps = cjob.steps as {{string: any}}
  local cstage, cat = step_running(csteps, "queue-seed.sh stage")
  assert(cstage["if"] == QUEUE and cstage.shell == "sh" and cstage["working-directory"] == ".",
    "the checked job keeps its seed on other runs, or elsewhere: " .. tostring(cstage["if"]))
  local cenv = cstage.env as {string: string}
  local vsave, vtwin = save_of(csteps, "${{ runner.temp }}/verdicts")
  assert(cenv.VERDICTS_PREFIX .. cenv.VERDICTS_DIGEST == (vsave.with as {string: string}).key,
    "the checked job's verdicts are seeded under another key than main saves them under")
  assert(cenv.SHA == "${{ github.sha }}" and
      under_the_commit(cenv.VERDICTS_PREFIX) == (vtwin.with as {string: string}).key,
    "the checked job's verdicts are seeded under another commit's key than main saves them under")
  assert((vsave["if"] as string):find(cenv.VERDICTS_RESTORED:match("^%${{ (.-) }}$"), 1, true) ~= nil,
    "the checked job's seed is compared with another entry than main's save is")
  assert(cenv.COMPILES_PREFIX == nil and save_of(csteps, "${{ runner.temp }}/build-cache") == nil,
    "the checked job keeps compiles, which linux-x86_64's leg saves")
  assert(cenv.ZIG_BUILD_KEY == nil and save_of(csteps, "${{ runner.temp }}/zig-build") == nil,
    "the checked job keeps zig outputs, which linux-x86_64's leg saves under the same key")
  local _, ctrim = step_running(csteps, "driver.tl verdicts-trim")
  local removed: integer
  for i, step in ipairs(csteps) do
    if step.name == "remove the leg's container" then removed = i end
  end
  local cback: integer
  for i, step in ipairs(csteps) do
    if step.name == "move the tree back to where it was checked out" then cback = i end
  end
  assert(ctrim < cat and removed < cat and cback ~= nil and cback < cat,
    "the checked job's seed is kept before its trim, beside its container, or with its tree moved")
  local cupload = csteps[cat + 1]
  local cwith = cupload.with as {string: string}
  assert(cupload["if"] == QUEUE and cwith.path == "${{ runner.temp }}/seed" and
      cwith.name == "seed-" .. (cjob.env as {string: string}).COSMIC_WORKER,
    "the checked job's seed is not uploaded as its own: " .. tostring(cwith.name))
end

--- The checked suite runs in a job of its own (`checked`), beside the
--- platform legs rather than after linux-x86_64's own suites, where the
--- legs run (a run that reuses the queue's run has neither), and no leg
--- runs it. It runs on that leg's host: its runner, its image and its
--- builder, with its zig build outputs and compiles restored under that
--- leg's names (which that leg saves, and this job does not), and its
--- verdicts under a name of its own on the same COSMIC_HOST_ID. On a
--- branch push's light run it runs none of the checked suite's steps
--- but, on that booted tree, what would otherwise hold up a leg: the
--- pinned CI driver's check, which the legs make only on a full run,
--- and the tree's format check, which the legs make only in a full
--- run's assemble -- and those two only on a light run.
local function test_the_checked_suite_runs_in_a_job_of_its_own_on_linux_x86_64s_host()
  local ci = decoded_workflows()[DIR .. "/ci.yml"] as {string: any}
  local jobs = ci.jobs as {string: {string: any}}
  local platform, checked = jobs.platform, jobs.checked
  assert(checked.needs == platform.needs and checked["if"] == platform["if"],
    "the checked job runs other than where the legs do: " .. tostring(checked["if"]))
  local penv, cenv = platform.env as {string: string}, checked.env as {string: string}
  assert(penv.COSMIC_CI_CHECKED_SUITE == "skip", "a leg runs the checked suite: " .. penv.COSMIC_CI_CHECKED_SUITE)
  local leg: {string: string}
  for _, entry in ipairs(legs_of(platform, "full")) do
    if entry.name == "linux-x86_64" then leg = entry end
  end
  assert(leg ~= nil, "no linux-x86_64 leg")
  local name = checked.name as string
  assert(name == leg.name .. "-checked" and cenv.COSMIC_WORKER == name, "the checked job's name: " .. name)
  assert(checked["runs-on"] == leg.runner, "the checked job runs on " .. tostring(checked["runs-on"]))
  local shell = ((checked.defaults as {string: any}).run as {string: string}).shell
  assert(shell == leg.shell, "the checked job's steps run through " .. shell)
  assert(cenv.TARGET == leg.target and cenv.COSMIC_CI_CHECKED_SUITE == "run" and
      cenv.COSMIC_CI_FORMAT == "run" and
      cenv.COSMIC_CI_REQUIRE_SANDBOX == "1" and cenv.COSMIC_CI_DECLARED_KEYS == "0",
    "the checked job's switches are not linux-x86_64's with the checked suite on")
  for _, same in ipairs({ "COSMIC_CI_EVENT", "COSMIC_CI_BASE_SHA" }) do
    assert(cenv[same] == penv[same], "the checked job's " .. same .. " is not the legs': " .. tostring(cenv[same]))
  end
  local expected <const>: {string: boolean} = { COSMIC_WORKER = true, TARGET = true,
    COSMIC_CI_CHECKED_SUITE = true, COSMIC_CI_FORMAT = true, COSMIC_CI_REQUIRE_SANDBOX = true,
    COSMIC_CI_DECLARED_KEYS = true,
    COSMIC_CI_EVENT = true, COSMIC_CI_BASE_SHA = true }
  for key in pairs(cenv) do assert(expected[key], "the checked job sets " .. key) end
  for key in pairs(expected) do assert(cenv[key] ~= nil, "the checked job sets no " .. key) end
  -- Its steps, by name, as the leg's are with the leg's matrix put in.
  local function as_leg(value: string, own_name?: string): string
    local values: {string: string} = { name = own_name or leg.name, image = leg.image,
      runner = leg.runner, prepare = leg.prepare }
    local out = value:gsub("%${{ matrix%.(%w+) }}", function(field: string): string
      return (assert(values[field], "the leg's matrix has no " .. field))
    end)
    return out
  end
  local function by_name(steps: {{string: any}}): {string: {string: any}}
    local out: {string: {string: any}} = {}
    for _, step in ipairs(steps) do
      if step.name ~= nil then out[step.name as string] = step end
    end
    return out
  end
  local theirs, ours = by_name(platform.steps as {{string: any}}), by_name(checked.steps as {{string: any}})
  -- Each step as the leg's of the same name, or of the name given: the
  -- same action (the zig pin restored alone, which the leg saves), the
  -- same shell, directory, script, inputs and variables, run where the
  -- leg's would: on every run where the boot a light run makes needs
  -- it (BOTH), else only on a full run.
  local BOTH <const>: {string: boolean} = {
    ["start the leg's container"] = true, ["create the unprivileged builder"] = true,
    ["restore the pinned zig"] = true, ["name the zig build cache, and the run's start"] = true,
    ["restore zig build outputs"] = true, ["restore zig build outputs of another vendor part"] = true,
    ["restore compiles and parses"] = true, ["move the tree to a path of its own"] = true,
    ["move the tree back to where it was checked out"] = true,
    ["find the tree's base on main"] = true,
  }
  local function same(where: string, mine: any, their: any)
    if their is string then their = as_leg(their) end
    assert(mine == their, where .. " is not the leg's: " .. tostring(mine) .. " against " .. tostring(their))
  end
  local function same_table(where: string, mine: any, their: any)
    local m, t = (mine or {}) as {string: any}, (their or {}) as {string: any}
    for key, value in pairs(t) do same(where .. "'s " .. key, m[key], value) end
    for key, value in pairs(m) do same(where .. "'s " .. key, value, t[key]) end
  end
  for _, pair in ipairs({ { "start the leg's container" }, { "create the unprivileged builder" },
      { "restore the pinned zig", "cache the pinned zig" },
      { "name the zig build cache, and the run's start" }, { "restore zig build outputs" },
      { "restore zig build outputs of another vendor part" }, { "name the leg's host" },
      { "find the tree's base on main" }, { "restore test verdicts" }, { "restore compiles and parses" },
      { "move the tree to a path of its own" },
      { "move the tree back to where it was checked out" } }) do
    local step_name = pair[1]
    local our, their = ours[step_name], theirs[pair[2] or step_name]
    assert(their ~= nil and our ~= nil, "no step " .. step_name)
    local uses = their.uses as string
    if pair[2] ~= nil then uses = uses:gsub("^actions/cache@", "actions/cache/restore@") end
    same(step_name .. "'s action", our.uses, uses)
    for _, key in ipairs({ "id", "shell", "working-directory" }) do
      same(step_name .. "'s " .. key, our[key], their[key])
    end
    if their.run ~= nil then
      local own = step_name == "name the leg's host" and name or nil
      same(step_name .. "'s script", our.run, as_leg(their.run as string, own))
    end
    same_table(step_name .. "'s with", our.with, their.with)
    same_table(step_name .. "'s env", our.env, their.env)
    local condition = their["if"] as string
    if condition ~= nil and condition:find("matrix.", 1, true) then condition = nil end
    local wanted: string | nil = condition
    if not BOTH[step_name] then wanted = condition and FULL .. " && " .. condition or FULL end
    same(step_name .. "'s if", our["if"], wanted)
  end
  -- It boots, checks the format (on a light run), builds the checked
  -- core, and runs its suite and the bounded performance lifecycle fixture.
  local steps = checked.steps as {{string: any}}
  local ran: {string} = {}
  for _, step in ipairs(steps) do
    local run = step.run
    local phase = run is string and run:match("^cosmic%-driver cosmic_ci/driver%.tl platform ([%w-]+)$") or nil
    if phase ~= nil then ran[#ran + 1] = phase end
  end
  assert(table.concat(ran, " ") == "boot format checked-build checked performance-checked", "the checked job runs " .. table.concat(ran, " "))
  local at = verdict_steps(steps)
  local _, suite = step_running(steps, "platform checked")
  local _, back = step_running(steps, "driver.tl place-tree --restore")
  for _, pair in ipairs({ { at["host-id"], at["merge-base"] }, { at["merge-base"], at["verdicts-restore"] },
      { at["verdicts-restore"], suite },
      { suite, at.trim }, { at.trim, at.save },
      { back, at.save } }) do
    assert(pair[1] ~= nil and pair[2] ~= nil and pair[1] < pair[2], "the checked job's verdict steps are out of order")
  end
  -- A light run runs the steps its boot, the driver's check and the
  -- format check need, and nothing of the checked suite's: every other
  -- step's `if` names the full scope, or what a step skipped on a light
  -- run leaves unmet. The driver's check, with its lookup of
  -- linux-x86_64's marker, and the format check run on a light run
  -- alone, the driver's as a leg's but for the marker's save (main's),
  -- and the format's after the boot.
  local light <const>: {string: boolean} = { ["bootstrap the pinned CI driver"] = true,
    ["build release Cosmic"] = true, ["summarize worker operations"] = true,
    ["describe the leg's container"] = true, ["remove the leg's container"] = true,
    ["preserve CI driver database"] = true,
    ["preserve checked suite failure diagnostics"] = true,
    [CHECKOUT] = true }
  for key in pairs(BOTH) do light[key] = true end
  local unmet <const> = { FULL, "github.event_name == 'merge_group'", "steps.verdicts-trim.outputs.digest != ''" }
  local only_light: {string} = {}
  for _, step in ipairs(steps) do
    local called = step.name as string or step.uses as string
    local condition = step["if"] as string or ""
    if condition == LIGHT or condition:find(LIGHT .. " && ", 1, true) == 1 then
      only_light[#only_light + 1] = called
    else
      local held = false
      for conjunct in (condition .. " && "):gmatch("(.-) && ") do
        for _, text in ipairs(unmet) do held = held or conjunct == text end
      end
      assert(held == not light[called], "the checked job runs " .. called ..
          (held and " only on a full run: " or " on a light run: ") .. condition)
    end
  end
  assert(table.concat(only_light, ", ") == "name the paths the branch changed, " ..
      "name linux-x86_64's host, find a passing CI driver check, " ..
      "check the pinned CI driver, check the tree's format",
    "the checked job runs on a light run alone: " .. table.concat(only_light, ", "))
  local mine, check = step_running(steps, "cosmic-driver test cosmic_ci")
  local _, boot = step_running(steps, "cosmic-driver cosmic_ci/driver.tl platform boot")
  local _, format = step_running(steps, "platform format")
  local bootstrap = 0
  for i, step in ipairs(steps) do
    if step.uses == DRIVER then bootstrap = i end
  end
  local legs = step_running(platform.steps as {{string: any}}, "cosmic-driver test cosmic_ci")
  assert(mine.run == "cosmic-driver test cosmic_ci", "the checked job checks the driver otherwise: " .. tostring(mine.run))
  same_table("the driver check's env", mine.env, legs.env)
  assert(ours["bootstrap the pinned CI driver"].id == "driver" and bootstrap > 0 and check > bootstrap and format > boot,
    "the checked job checks the driver before bootstrapping it, or the format before the boot")
  -- A full run's legs check the driver; a light run's none do.
  assert((legs["if"] as string):find(FULL .. " && ", 1, true) == 1 and
      theirs["find a passing CI driver check"]["if"] == FULL,
    "a light run's legs check the driver: " .. tostring(legs["if"]))
  -- A light run skips its check where main's linux-x86_64 leg saved
  -- its marker under the key that leg looks up: that leg's host, named
  -- as the leg names it (its COSMIC_HOST_ID not kept), and what the
  -- leg's key hashes, looked up before the tree moves.
  local host, lookup = ours["name linux-x86_64's host"], ours["find a passing CI driver check"]
  local their_host, their_lookup = theirs["name the leg's host"], theirs["find a passing CI driver check"]
  assert(host ~= nil and lookup ~= nil, "a light run looks up no marker of linux-x86_64's")
  assert(host.id == "driver-host" and host["continue-on-error"] == true and host.run == "GITHUB_ENV=/dev/null " .. as_leg(their_host.run as string),
    "a light run names another host than linux-x86_64's, keeps it, or fails on it: " .. tostring(host.run))
  for _, key in ipairs({ "shell", "working-directory" }) do
    same("the host's " .. key, host[key], their_host[key])
  end
  same_table("the host's environment", host.env as {string: any}, their_host.env as {string: any})
  assert(lookup.id == "driver-check-restore" and lookup.uses == their_lookup.uses,
    "a light run looks up the marker otherwise: " .. tostring(lookup.id))
  local by_image <const> = "${{ matrix.image && 'container' || steps.names.outputs.image }}"
  local their_key = (their_lookup.with as {string: string}).key
  assert(their_key:find(by_image, 1, true) ~= nil and leg.image ~= "", their_key)
  local in_container = their_key:gsub(by_image:gsub("%p", "%%%0"), "container")
  local want = as_leg((in_container:gsub("steps%.host%-id%.outputs%.prefix", "steps.driver-host.outputs.prefix")))
  same_table("the marker's lookup", lookup.with,
    { path = (their_lookup.with as {string: any}).path, key = want, ["lookup-only"] = true })
  local _, named = step_running(steps, "GITHUB_ENV=/dev/null cosmic-driver cosmic_ci/driver.tl leg-host-id")
  local looked: integer
  for i, step in ipairs(steps) do
    if step == lookup then looked = i end
  end
  local _, moved = step_running(steps, "driver.tl place-tree")
  assert(named < looked and looked < moved and looked < check,
    "a light run looks up linux-x86_64's marker after its check, or with the tree moved")
  assert(mine["if"] == LIGHT .. " && steps.driver-check-restore.outputs.cache-hit != 'true'",
    "a light run checks the driver over main's marker: " .. tostring(mine["if"]))
  for _, step in ipairs(platform.steps as {{string: any}}) do
    assert(not (step.run as string or ""):find("platform format", 1, true), "a leg checks the format apart from assemble")
  end
  -- Whatever failed, on either scope, it keeps its operations, as a leg
  -- does, under its own name.
  local kept = ours["preserve CI driver database"]
  assert(kept ~= nil and kept["if"] == "always()" and
      (kept.with as {string: string}).name == "ci-driver-" .. name and
      (kept.with as {string: string}).path == ((theirs["preserve CI driver database"].with) as {string: string}).path,
    "the checked job keeps its operations only on some runs, or under another name: " .. tostring(kept and kept["if"]))
end

--- A light run's format check lays out only what the branch changed
--- since its base on main, whose tree main's run held to the whole
--- check: the checked job finds that base on a light run too, names the
--- paths (`changed-paths`, on the host, which fetches
--- the base with the credentials the checkout keeps) before its tree
--- moves, and hands the list to the format check, which checks the
--- whole tree where it named none. A full run's check, the
--- merge queue's, is the whole tree's.
local function test_a_light_format_check_lays_out_only_what_the_branch_changed()
  local ci = decoded_workflows()[DIR .. "/ci.yml"] as {string: any}
  local jobs = ci.jobs as {string: {string: any}}
  local steps = jobs.checked.steps as {{string: any}}
  local base, found = step_running(steps, "driver.tl merge-base")
  assert(base["if"] == nil, "the checked job finds its base only on some runs: " .. tostring(base["if"]))
  assert(driver_at(steps) < found, "the checked job finds its base before it has the driver")
  local named, listed = step_running(steps, "driver.tl changed-paths")
  assert(named.id == "changed" and named["if"] == LIGHT and named.shell == "sh" and
      named["working-directory"] == nil and named["continue-on-error"] == true,
    "the checked job names what changed otherwise, or fails for it: " .. tostring(named["if"]))
  local env = named.env as {string: string}
  assert(env.BASE == "${{ steps.merge-base.outputs.sha }}" and
      env.OUT:find("${{ runner.temp }}/", 1, true) == 1,
    "the paths changed are named from another base, or kept outside the runner's temporary directory")
  local _, moved = step_running(steps, "driver.tl place-tree")
  assert(found < listed and listed < moved,
    "the checked job names what changed before it finds the base, or with its tree moved")
  local checkout: {string: any} = nil
  for _, step in ipairs(steps) do
    if step.uses == CHECKOUT then checkout = step end
  end
  assert(checkout ~= nil and (checkout.with as {string: any})["persist-credentials"] == nil,
    "the checked job keeps no credentials to fetch its base with")
  local format, checked_at = step_running(steps, "platform format")
  assert(checked_at > listed and format["if"] == LIGHT and
      (format.env as {string: string}).COSMIC_CI_FORMAT_CHANGED == "${{ steps.changed.outputs.paths }}",
    "a light run's format check lays out other than what the branch changed")
  for _, step in ipairs(steps) do
    local run = step.run as string or ""
    local e = step.env as {string: string} or {}
    assert(e.COSMIC_CI_FORMAT_CHANGED == nil or run:find("platform format", 1, true) ~= nil,
      "a step other than the format check reads what the branch changed")
  end
  for _, step in ipairs(jobs.platform.steps as {{string: any}}) do
    local e = step.env as {string: string} or {}
    assert(e.COSMIC_CI_FORMAT_CHANGED == nil, "a leg's check lays out only what changed")
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
    for job_name, job in pairs(workflow.jobs as {string: {string: any}}) do
      local where = path .. " " .. job_name
      local steps = job.steps as {{string: any}} or {}
      local moves: {integer} = {}
      local backs: {integer} = {}
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
        assert(#moves == 1, where .. " moves its tree " .. #moves .. " times")
        assert(#backs == 1, where .. " puts its tree back " .. #backs .. " times")
        local move, back = moves[1], backs[1]
        assert(move < back, where .. " puts its tree back before it moves it")
        assert(last_driver < back, where .. " runs the CI driver after it puts its tree back")
        assert(steps[back]["if"] == "always() && steps.driver.outcome == 'success'",
          where .. " puts its tree back only where the job has not failed, or without a driver: " ..
            tostring(steps[back]["if"]))
        -- The bootstrap is the step with id "driver", and comes first.
        local bootstrap = 0
        for i, step in ipairs(steps) do
          if step.id == "driver" and step.uses == DRIVER then bootstrap = i end
        end
        assert(bootstrap > 0 and bootstrap < move, where .. " moves its tree before it bootstraps the driver")
        assert(steps[move]["working-directory"] ~= ".", where .. " runs the driver outside ci/")
        for i = move + 1, back - 1 do
          local uses = steps[i].uses as string or ""
          if uses:find("^actions/cache") ~= nil then
            local cached = (steps[i].with as {string: string}).path
            assert(cached:find("^%${{ runner%.temp }}/") ~= nil,
              where .. " caches " .. cached .. " with its tree moved")
          end
        end
      end
    end
  end
  assert(placed >= 3, "only " .. placed .. " jobs move their tree")
end

--- A branch several commits behind main restores the verdicts main
--- saved at its base rather than main's newest, whose tree it does not
--- have: main saves each job's verdicts twice, under their content and
--- under its commit, even where the content is an entry's already, and
--- `seed` does as the queue's leg named; each restore asks for the
--- base's entry, which driver.tl merge-base finds (the merge
--- queue's base, or a branch's merge base with main through the API,
--- with the job's token, and never failing the job), and falls back to
--- the newest. `prune` deletes the copies under a commit on a push to
--- main, with the one token that may write the cache, and never fails
--- for it.
local function test_a_branch_restores_the_verdicts_of_its_base()
  local ci = decoded_workflows()[DIR .. "/ci.yml"] as {string: any}
  local jobs = ci.jobs as {string: {string: any}}
  local VERDICTS <const> = "${{ runner.temp }}/verdicts"
  for _, name in ipairs({ "platform", "checked" }) do
    local steps = jobs[name].steps as {{string: any}}
    local plain, twin = save_of(steps, VERDICTS)
    assert(plain ~= nil and twin ~= nil, name .. " saves its verdicts under no commit")
    local key = (plain.with as {string: string}).key
    local prefix = key:match("^(.-)%${{ steps%.verdicts%-trim%.outputs%.digest }}$")
    assert(prefix ~= nil and (twin.with as {string: string}).key == under_the_commit(prefix),
      name .. "'s verdicts are saved under another commit than the run's: " .. (twin.with as {string: string}).key)
    local at = verdict_steps(steps)
    local find = steps[at["merge-base"]]
    assert(find ~= nil and at["merge-base"] < at["verdicts-restore"], name .. " restores before it finds the base")
    -- On the host, where gh is, once the driver is bootstrapped.
    assert(find.run == "cosmic-driver cosmic_ci/driver.tl merge-base" and find.shell == "sh" and
        find["working-directory"] == nil and find["continue-on-error"] == true,
      name .. " finds the base elsewhere than on the host, or fails for it: " .. tostring(find.run))
    assert(driver_at(steps) < at["merge-base"], name .. " finds its base before it has the driver")
    local env = find.env as {string: string}
    assert(env.GH_TOKEN == "${{ github.token }}" and env.REPOSITORY == "${{ github.repository }}" and
        env.SHA == "${{ github.sha }}" and env.EVENT == "${{ github.event_name }}" and
        env.REF == "${{ github.ref }}" and env.QUEUE_BASE == "${{ github.event.merge_group.base_sha }}",
      name .. " asks for another commit's base")
    local restore = steps[at["verdicts-restore"]].with as {string: string}
    assert(restore.key == at_the_base(prefix) and restore["restore-keys"] == prefix .. "\n",
      name .. " restores another entry than its base's, else the newest: " .. restore.key)
    local permissions = jobs[name].permissions as {string: string}
    assert(permissions.contents == "read", name .. " cannot compare commits")
  end
  -- seed saves the copy the queue's leg named, under this commit alone.
  local steps = jobs.seed.steps as {{string: any}}
  local _, twin = save_of(steps, VERDICTS)
  assert(twin ~= nil and twin["if"] == "steps.keys.outputs.verdicts-sha != ''",
    "seed saves no verdicts under the commit")
  local keys = step_running(steps, "seed.keys")
  assert((keys.run as string):find("|verdicts-sha=verdicts-${{ matrix.name }}-[0-9a-f]{16}-[0-9a-f]+-sha-${{ github.sha }}|",
    1, true), "seed takes a copy under another commit")

  -- The prune: a job of its own, the one whose token may write the
  -- cache, after every job that saves, whatever their result; on every
  -- push (a branch's shows it run), its steps on main's alone, running
  -- the pinned driver on ci/'s sources alone, from a main-only checkout
  -- that keeps no token.
  -- The join, the check a ruleset requires, waits on none of it.
  local prune = jobs.prune
  assert(prune ~= nil, "no job prunes the verdicts under a commit")
  local permissions = prune.permissions as {string: string}
  assert(permissions.actions == "write" and permissions.contents == "read",
    "prune cannot prune the cache, or may do more")
  for name, job in pairs(jobs) do
    local p = job.permissions as {string: string}
    assert(name == "prune" or p == nil or p.actions ~= "write", "job " .. name .. " may write the cache")
  end
  assert(prune["if"] == "always() && github.event_name == 'push'",
    "prune runs on another event, or not after a failed job: " .. tostring(prune["if"]))
  assert(table.concat(prune.needs as {string}, ",") == "platform,checked,seed",
    "prune runs before a job that saves")
  for _, need in ipairs(jobs.ci.needs as {string}) do
    assert(need ~= "prune", "the join waits on prune")
  end
  local psteps = prune.steps as {{string: any}}
  assert(#psteps == 3, "prune runs more than its checkout, its driver and its command")
  for _, step in ipairs(psteps) do
    assert(step["if"] == "github.ref == 'refs/heads/main'", "prune runs a step off main: " .. tostring(step["if"]))
  end
  local checkout = psteps[1].with as {string: any}
  assert((psteps[1].uses as string):find("actions/checkout@", 1, true) == 1 and
      checkout["persist-credentials"] == false and
      checkout["sparse-checkout"] == "/ci/\n/bin/cosmic-bootstrap\n/.github/scripts/cosmic-driver.sh\n" ..
      "/.github/actions/cosmic-driver/\n",
    "prune checks out more than its driver, or keeps the token")
  assert(psteps[2].uses == DRIVER and psteps[2]["continue-on-error"] == true,
    "prune bootstraps something else, or fails the run for it")
  local step = psteps[3]
  assert(step.run == "cosmic-driver cosmic_ci/driver.tl prune-commit-verdicts" and
      step["working-directory"] == "ci" and step["continue-on-error"] == true,
    "the prune runs something else, or fails the run: " .. tostring(step.run))
  assert((step.env as {string: string}).GH_TOKEN == "${{ github.token }}", "the prune has no token")
end

--- Only three jobs save a cache every run restores: the platform legs
--- and the checked job, where COSMIC_CI_SAVES (main's push and the
--- scheduled run), and `seed`, which runs only on a push to main that
--- found the queue's run.
local function test_only_the_legs_and_their_seed_save()
  local ci = decoded_workflows()[DIR .. "/ci.yml"] as {string: any}
  for name, job in pairs(ci.jobs as {string: {string: any}}) do
    local saves = 0
    for _ in pairs(saves_of(job.steps as {{string: any}} or {})) do saves = saves + 1 end
    assert(saves == 0 or name == "platform" or name == "checked" or name == "seed", "job " .. name .. " saves a cache")
  end
end

--- A run's scope is decided once, in ci.yml's workflow-level
--- COSMIC_CI_SCOPE, which the legs' steps and the provenance join
--- alike read: `full` for any run but a push off main.
local function test_the_scope_is_decided_once()
  local ci = decoded_workflows()[DIR .. "/ci.yml"] as {string: any}
  local scope = (ci.env as {string: string}).COSMIC_CI_SCOPE
  assert(scope == "${{ " .. FULL_RUN .. " && 'full' || 'light' }}", "the scope: " .. tostring(scope))
  for name, job in pairs(ci.jobs as {string: {string: any}}) do
    for _, env in ipairs(envs_of(job)) do
      assert(env.COSMIC_CI_SCOPE == nil and env.FULL == nil,
        "job " .. name .. " decides its scope again")
    end
  end
end

--- A leg saves only the verdicts its run relied on or reached,
--- where it passed: a file saved whole would carry several runs' rows,
--- most under keys no later run reaches. The trim runs where the suites
--- do (a Linux leg's container, the macOS runner itself), after every
--- suite that shares the file and before the save, and counts from a
--- time taken before the first suite.
local function test_a_leg_trims_its_verdicts_before_it_saves_them()
  local ci = decoded_workflows()[DIR .. "/ci.yml"] as {string: any}
  local jobs = ci.jobs as {string: {string: any}}
  local at: {string: integer} = {}
  local trim: {string: any}
  for i, step in ipairs(jobs.platform.steps as {{string: any}}) do
    local run = step.run
    if step.id ~= nil then at[step.id as string] = i end
    if step.name == "remove the leg's container" then at.removed = i end
    if run is string and run:find("driver.tl verdicts-trim", 1, true) ~= nil then
      at.trim, trim = i, step
    end
    local path = step.with ~= nil and (step.with as {string: string}).path or nil
    if (step.uses as string or ""):find("actions/cache/save@", 1, true) ~= nil and
        path == "${{ runner.temp }}/verdicts" then
      at.save = i
    end
  end
  assert(trim ~= nil, "no step trims the verdicts")
  local condition = trim["if"] as string
  assert(condition == "always() && steps.driver.outcome == 'success'",
    "the trim does not run on every leg's run: " .. condition)
  -- A run that failed keeps what it restored with what it reached.
  assert((trim.run as string):find(
    "${{ job.status == 'success' && steps.names.outputs.since || 'whole' }}", 1, true) ~= nil,
    "the trim counts from no time taken before the suites, or trims a failed run: " ..
      (trim.run as string))
  -- `assemble` builds and verifies the checked core; its suite runs in
  -- the checked job, which trims its own verdicts.
  for _, suite in ipairs({ "release-suite", "assemble", "portable-suite" }) do
    assert(at[suite] ~= nil and at[suite] < at.trim, "the trim runs before " .. suite)
  end
  assert(at.names < at["release-suite"], "the trim's time is taken after a suite")
  local steps = jobs.platform.steps as {{string: any}}
  assert(steps[at.names]["if"] == nil,
    "the trim's time is taken only on some legs: " .. tostring(steps[at.names]["if"]))
  assert(at.trim < at.removed and at.trim < at.save,
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
  local ci = decoded_workflows()[DIR .. "/ci.yml"] as {string: any}
  local jobs = ci.jobs as {string: {string: any}}
  local steps = jobs.platform.steps as {{string: any}}
  local prune, at = step_running(steps, "driver.tl zig-prune")
  local _, assembled = step_running(steps, "driver.tl platform assemble")
  local stage, staged = step_running(steps, "queue-seed.sh stage")
  local saved: integer
  local upload: {string: any}
  for i, step in ipairs(steps) do
    local path = step.with ~= nil and (step.with as {string: string}).path or nil
    if (step.uses as string or ""):find("actions/cache/save@", 1, true) ~= nil and
        path == "${{ runner.temp }}/zig-build" then
      saved, upload = i, step
    end
  end
  assert(assembled < at and at < saved and at < staged,
    "the zig outputs are pruned before the assemble's builds, or after they are saved")
  for i = at + 1, staged do
    local run = steps[i].run
    assert(not (run is string and run:find("bin/zig", 1, true) ~= nil),
      "a build of zig's caches comes after the prune: " .. tostring(steps[i].name))
  end
  local condition = prune["if"] as string
  local upload_condition = upload["if"] as string
  local restored = upload_condition:match(
    "(!startsWith%(steps%.zig%-cache%-restore%.outputs%.cache%-matched%-key, format%('{0}full%-', steps%.names%.outputs%.vendor%)%))")
  assert(restored ~= nil, "main's upload is held to another restore than this test reads: " .. upload_condition)
  local exact = (stage.env as {string: string}).ZIG_BUILD_EXACT
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
      (prune.run as string) == "cosmic-driver cosmic_ci/driver.tl zig-prune",
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
--- start (some 6 s, up to about 100 s in a burst).
local BRANCH_SKIPS <const> = { "refs/heads/main", "ref_name == 'main'", "event_name != 'push'" }
local SKIPPED_ON_A_BRANCH <const>: {string: boolean} = {
  [DIR .. "/ci.yml seed"] = true,
  [DIR .. "/ci.yml reuse"] = true,
}

local function test_a_branch_push_starts_no_job_it_skips()
  local count = 0
  for path, workflow in pairs(decoded_workflows()) do
    local on = workflow["on"]
    local push = on is {string: any} and on.push or nil
    local branches = push is {string: any} and push.branches or nil
    local main_only = branches is {string} and #branches == 1 and branches[1] == "main"
    if push ~= nil and not main_only then
      for name, job in pairs(workflow.jobs as {string: {string: any}}) do
        count = count + 1
        local condition = job["if"]
        local excepted = SKIPPED_ON_A_BRANCH[path .. " " .. name]
        for _, skip in ipairs(BRANCH_SKIPS) do
          assert(excepted or not (condition is string and condition:find(skip, 1, true)),
            path .. ": job " .. name .. "'s if names " .. skip .. ", so a branch push shows it skipped")
        end
        assert(excepted or not (condition is string and condition:find("needs%.[%w_-]+%.outputs%.[%w_-]+ != ''")),
          path .. ": job " .. name ..
            " runs only where a job it needs found something, so a branch push shows it skipped")
      end
    end
  end
  assert(count > 0, "no workflow a branch push starts")
end

--- A queue run takes the verdicts of the run ahead of it in the queue,
--- which tests its base and whose verdicts main has not saved yet: each
--- leg and the checked job keeps its suite's verdicts, on a queue run,
--- the moment the suite passes, as `verdicts-<job>`, a name no other
--- job's shares, replacing a retried attempt's; and each, between its
--- boot and its suite, finds that run by its base (driver.tl queue-ahead),
--- with the job's own name and artifact, unless the restore took the
--- base's own entry, downloads what it kept from that run, and merges
--- it into what it restored (driver.tl verdicts-merge). None of it
--- fails the job, it needs `actions: read`, and the lookup's wait, with
--- its last round's calls, is under its step's timeout: a leg's is half
--- a minute at most, and only on a leg ahead that has begun its suite
--- (SUITE_STEP, the suite step's own name), since a longer wait, on a
--- leg still building or itself waiting, cost more than it saved; the
--- checked job's, whose job ahead keeps them later, is a minute and a
--- half and skips a job ahead that cannot keep them in time
--- (READY_SECONDS).
local function test_a_queue_run_takes_the_verdicts_of_the_run_ahead()
  local ci = decoded_workflows()[DIR .. "/ci.yml"] as {string: any}
  local jobs = ci.jobs as {string: {string: any}}
  local script = assert(Fs.read("ci/cosmic_ci/queue_seed.tl"))
  local call = math.tointeger(tonumber(script:match('whole%(env, "CALL_SECONDS", (%d+)%)')))
  assert(call ~= nil, "queue_seed.tl's call budget moved")
  local QUEUE <const> = "github.event_name == 'merge_group'"
  local names: {string: string} = {}
  for _, case in ipairs({
      -- A queue run's legs run whole, so a leg's job is named by the leg
      -- alone there ([`LEG_NAME`]).
      { job = "platform", suite = "release-suite", file = "verdicts.db", name = "${{ matrix.name }}",
          job_name = LEG_NAME, within = 30, ready = "", begun = true },
      { job = "checked", suite = "checked-suite", file = "checked.db", name = "linux-x86_64-checked",
          job_name = "linux-x86_64-checked", within = 90, ready = "420", begun = false } }) do
    local job = jobs[case.job]
    local where = case.job
    assert(job.name == case.job_name, where .. "'s name: " .. tostring(job.name))
    assert((job.permissions as {string: string}).actions == "read", where .. " cannot read the run ahead")
    local steps = job.steps as {{string: any}}
    local at: {string: integer} = {}
    local keep: {string: any}
    for i, step in ipairs(steps) do
      local id = step.id as string
      if id ~= nil then at[id] = i end
      local with = step.with as {string: any}
      if (step.uses as string or ""):find("actions/upload-artifact@", 1, true) ~= nil and
          (with.path as string):find("${{ runner.temp }}/verdicts/", 1, true) == 1 then
        assert(keep == nil, where .. " keeps its verdicts twice")
        keep, at.keep = step, i
      end
    end
    assert(keep ~= nil, where .. " keeps no verdicts for the run behind it")
    local order = { "verdicts-restore", "boot", "ahead", "ahead-download", "verdicts-ahead", case.suite, "keep" }
    for n = 2, #order do
      assert(at[order[n - 1]] ~= nil and at[order[n]] ~= nil and at[order[n - 1]] < at[order[n]],
        where .. ": " .. order[n - 1] .. " does not come before " .. order[n])
    end
    assert(at.driver < at.boot and (steps[at.boot].run as string):find("platform boot", 1, true),
      where .. " takes the verdicts ahead before its boot")
    local artifact = "verdicts-" .. case.name
    local kept = keep.with as {string: any}
    assert(kept.name == artifact and kept.path == "${{ runner.temp }}/verdicts/" .. case.file .. "*" and
        kept["retention-days"] == 1 and kept.overwrite == true, where .. " keeps other verdicts, or for long: " .. tostring(kept.name))
    local condition = keep["if"] as string
    assert(condition:find(QUEUE, 1, true) and
        condition:find("steps." .. case.suite .. ".outcome == 'success'", 1, true) and
        keep["continue-on-error"] == true, where .. " keeps verdicts its suite did not pass: " .. condition)
    names[where] = artifact

    local find = steps[at.ahead]
    local env = find.env as {string: string}
    -- On the host, where gh is, in ci/, where the driver is run from.
    assert(find.run == "cosmic-driver cosmic_ci/driver.tl queue-ahead" and find.shell == "sh" and
        find["working-directory"] == nil and find["continue-on-error"] == true and
        (find["if"] as string):find(QUEUE .. " && steps.verdicts-restore.outputs.cache-matched-key != " ..
            "format('{0}sha-{1}', steps.host-id.outputs.verdicts, github.event.merge_group.base_sha)", 1, true),
      where .. " looks for the run ahead elsewhere, where the base's verdicts were restored, or fails for it")
    assert(env.BASE == "${{ github.event.merge_group.base_sha }}" and env.JOB == case.name and
        env.ARTIFACT == artifact and env.GH_TOKEN == "${{ github.token }}" and
        env.REPOSITORY == "${{ github.repository }}", where .. " looks for another run's or job's verdicts")
    local within, wait = math.tointeger(tonumber(env.WITHIN_SECONDS)), math.tointeger(tonumber(env.WAIT_SECONDS))
    assert(within ~= nil and wait ~= nil and wait < within and within <= case.within,
      where .. " waits too long for the run ahead: " .. tostring(env.WITHIN_SECONDS))
    assert((env.READY_SECONDS or "") == case.ready, where .. " takes its job ahead to keep them at another time")
    assert(env.SUITE_STEP == (case.begun and steps[at[case.suite]].name as string or nil),
      where .. " waits on a job ahead by another step than its suite: " .. tostring(env.SUITE_STEP))
    local budget = within + 3 * call
    local minutes = find["timeout-minutes"] as integer
    assert(budget + 30 <= minutes * 60 and minutes < (job["timeout-minutes"] as integer),
      where .. "'s lookup outlasts its step, or its step the job: " .. budget .. " s")

    local download = steps[at["ahead-download"]]
    local with = download.with as {string: string}
    assert((download.uses as string):find("actions/download-artifact@", 1, true) == 1 and
        with.name == artifact and with["run-id"] == "${{ steps.ahead.outputs.run }}" and
        with["github-token"] == "${{ github.token }}" and download["continue-on-error"] == true and
        (download["if"] as string):find("steps.ahead.outputs.run != ''", 1, true),
      where .. " downloads other verdicts than the run ahead's, or fails for it")
    local merge = steps[at["verdicts-ahead"]]
    assert(merge.run == "cosmic-driver cosmic_ci/driver.tl verdicts-merge \"" .. with.path .. "\"" and
        merge["continue-on-error"] == true and
        (merge["if"] as string):find("steps.ahead-download.outcome == 'success'", 1, true),
      where .. " merges something else, or fails for it: " .. tostring(merge.run))
  end
  assert(names.platform ~= names.checked, "the legs and the checked job keep their verdicts under one name")
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
  local tokens: {string} = {}
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
  local i = 1
  local function truthy(v: Value): boolean return v ~= "" and v ~= false end
  local disjunction: function(): Value
  local function primary(): Value
    local token = assert(tokens[i], "an expression ends early: " .. inner)
    i = i + 1
    if token == "(" then
      local v = disjunction()
      assert(tokens[i] == ")", "an unclosed parenthesis: " .. inner)
      i = i + 1
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
    local op = tokens[i]
    if op == "==" or op == "!=" then
      i = i + 1
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
    while tokens[i] == "&&" do
      i = i + 1
      local right = comparison()
      if truthy(v) then v = right end
    end
    return v
  end
  disjunction = function(): Value
    local v = conjunction()
    while tokens[i] == "||" do
      i = i + 1
      local right = conjunction()
      if not truthy(v) then v = right end
    end
    return v
  end
  local v = disjunction()
  assert(tokens[i] == nil, "an expression with more after its end: " .. inner)
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
  local ci = decoded_workflows()[DIR .. "/ci.yml"] as {string: any}
  local env = ((ci.jobs as {string: {string: any}}).platform.env) as {string: string}
  local value = assert(env.COSMIC_CI_PORTABLE_SUITE, "the legs set no COSMIC_CI_PORTABLE_SUITE")
  local out: {string} = {}
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
    local got = portable_suite_legs(case[1], case[2])
    assert(got == want[case[1]], "a " .. case[1] .. " run runs the portable suite on " .. got)
  end
end

--- A leg that skips the portable suite still runs the step (the driver
--- records the artifact's digest there, and says it skipped the suite),
--- its regressions on the portable product, and its attestation and
--- upload of the bytes it ran, on every full run: so the join's
--- comparison still counts an attestation from every leg
--- (`strategy.job-total`), linux-x86_64's in the merge queue among
--- them, and none of those steps turns on COSMIC_CI_PORTABLE_SUITE.
local function test_a_leg_that_skips_the_portable_suite_still_attests_what_it_ran()
  local ci = decoded_workflows()[DIR .. "/ci.yml"] as {string: any}
  local platform = (ci.jobs as {string: {string: any}}).platform
  local seen: {string: boolean} = {}
  for _, step in ipairs(platform.steps as {{string: any}}) do
    local run = step.run as string or ""
    local phase = run:match("^cosmic%-driver cosmic_ci/driver%.tl platform ([%w-]+)")
    local with = step.with as {string: string}
    local upload = with ~= nil and with.name == "portable-product-${{ matrix.name }}"
    if phase == "portable" or phase == "fixtures" or phase == "attest" or upload then
      local key = upload and "upload" or phase
      assert(step["if"] == FULL, key .. " runs on another condition than a full run's: " ..
          tostring(step["if"]))
      assert(not assert(Json.encode(step)):find("PORTABLE_SUITE", 1, true), key .. " turns on the portable suite's switch")
      seen[key] = true
      if phase == "attest" then
        assert(run:find("\"${{ strategy.job-total }}\"", 1, true) ~= nil,
          "attest expects another count of products than the legs': " .. run)
      end
    end
  end
  assert(seen.portable and seen.fixtures and seen.attest and seen.upload,
    "a full run's leg misses a step of the product's")
end

--- The vendor part of the zig build cache's key hashes the vendored
--- trees and their records, but not the applier, [`build/patch.tl`],
--- which names each patched tree by the bytes it writes: an edit to it
--- that writes the same trees moves no object's path, so it must not
--- move the key and send main's next run to a cold cache (main
--- restores no other vendor part's entry).
local function test_the_vendor_part_hashes_the_trees_and_records_but_not_the_applier()
  local action = cache_names()
  local named = ((action.runs as {string: any}).steps as {{string: any}})[1]
  local vendor = (named.env as {string: string}).VENDOR
  assert(vendor == "${{ hashFiles('bin/zig.pin', 'build.zig', 'build.zig.zon', 'build/zig.tl', " ..
      "'vendor/**', '!vendor/tl/**', '!vendor/tzdata/**', '!vendor/cacert/**', '!vendor/wpt-url/**', '!vendor/html5lib-tokenizer/**', '!vendor/wpt-html-parsing/**', 'patch/**', '!patch/tl/**', " ..
      "'core/ares_config.h', 'core/curl_config.h', 'core/mbedtls_cosmic_config.h', 'core/xz_config/**', " ..
      "'core/darwin-compat/**') }}", "the vendor cache hashes different inputs: " .. vendor)
  for _, wanted in ipairs({ "'vendor/**'", "'patch/**'", "'build.zig'", "'build/zig.tl'" }) do
    assert(vendor:find(wanted, 1, true), "the vendor part hashes no " .. wanted .. ": " .. vendor)
  end
  assert(not vendor:find("build/patch.tl", 1, true),
    "the vendor part hashes the applier, whose edits write the same trees: " .. vendor)
end

--- Both jobs receive the same cache-name outputs before restoring or
--- moving the checkout. A change to this policy invalidates either
--- job's passing driver marker.
local function test_cache_names_reach_both_jobs_before_their_restores()
  local action = cache_names()
  local steps = (action.runs as {string: any}).steps as {{string: any}}
  assert(#steps == 1 and steps[1].id == "names" and steps[1].shell == "sh" and
      steps[1]["working-directory"] == ".", "cache names run outside the host checkout")
  local env = steps[1].env as {string: string}
  assert(env.LEG == "${{ inputs.leg }}" and
      env.CORE == "${{ hashFiles('core/*.c', 'core/*.h', 'core/*.zig', 'test/portable/*.c') }}",
    "cache names use another leg or core inputs")
  local outputs = action.outputs as {string: {string: string}}
  for _, name in ipairs({ "vendor", "core", "compiles", "image", "since" }) do
    assert(outputs[name].value == "${{ steps.names.outputs." .. name .. " }}",
      "the action does not forward " .. name)
  end
  local ci = decoded_workflows()[DIR .. "/ci.yml"] as {string: any}
  local jobs = ci.jobs as {string: {string: any}}
  for _, job in ipairs({ "platform", "checked" }) do
    local named = false
    local marker = false
    for _, step in ipairs(jobs[job].steps as {{string: any}}) do
      if step.id == "names" then
        assert(step.uses == CACHE_NAMES and step["if"] == nil, job .. " does not always name its caches")
        named = true
      end
      if step.id == "zig-cache-restore" or step.id == "compiles-restore" or
          step.name == "move the tree to a path of its own" then
        assert(named, job .. " names its caches after restoring them or moving the tree")
      end
      if step.id == "driver-check-restore" then
        local key = (step.with as {string: string}).key
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
  local ci = decoded_workflows()[DIR .. "/ci.yml"] as {string: any}
  local jobs = ci.jobs as {string: {string: any}}
  local steps = jobs.platform.steps as {{string: any}}
  local _, suite = step_running(steps, "driver.tl platform local-suite")
  local _, boundary = step_running(steps, "driver.tl platform local-boundary")
  local compile, compiled = step_running(steps, "credentials-probe.c")
  local proof, proved = step_running(steps, "credentials-proof.sh")
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

--- Each leg that runs a suite (the platform legs of a light and a full run,
--- and the checked job) has an entry in ci/cosmic_ci/capabilities.tl, and
--- each entry is such a leg: a renamed or mistyped leg would promise
--- nothing, silently.
local function test_every_leg_has_its_promises_and_no_other_does()
  local text = assert(Fs.read("ci/cosmic_ci/capabilities.tl"))
  local loaded = assert(load(text, "=capabilities", "t", {}))() as {string: {string: any}}
  local promised: {string: boolean} = {}
  for name in pairs(loaded.legs) do promised[name] = true end
  local ran: {string: boolean} = {}
  for _, scope in ipairs({ "light", "full" }) do
    for name in pairs(platform_legs(scope)) do ran[name] = true end
  end
  local ci = decoded_workflows()[DIR .. "/ci.yml"] as {string: any}
  local checked = (ci.jobs as {string: {string: any}}).checked
  ran[(checked.env as {string: string}).COSMIC_WORKER] = true
  for name in pairs(ran) do
    assert(promised[name], name .. ": a leg with no entry in capabilities.tl")
  end
  for name in pairs(promised) do
    assert(ran[name], name .. ": capabilities.tl names no such leg")
  end
end

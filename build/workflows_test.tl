--- The workflows under .github/workflows/, and the local actions under
--- .github/actions/ (each an `action.yml`), every one written in YAML's
--- flow style: each opens with `{` after its leading comments, and keeps
--- to the subset that YAML and JSON5 read with `#` comments
--- (`cosmic.json`'s `hash_comments`) read alike, so the tree can read
--- what GitHub runs without a YAML parser. A step's script longer than a
--- line or two lives under .github/scripts/, where it reads as a script
--- rather than as one string of `\n`-joined lines; an action's is one
--- line. Each is also in `build.flow`'s layout, which `cosmic fix`
--- writes.
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Test = require("cosmic.test")
local flow = require("build.flow")

--- The workflows and actions, and the programs and pins they name.
Test.needs{
  reads = { ".github/", "bin/cosmic-bootstrap", "ci/cosmic-driver.pin", "ci/cosmic_ci",
    "ci/images" },
}

local DIR <const> = ".github/workflows"
local ACTIONS <const> = ".github/actions"
local READ <const>: Json.DecodeOptions = { json5 = true, hash_comments = true }

--- Of `paths`, the ones in flow style, each with its text: a file whose
--- first line that is neither blank nor a comment opens with `{` or
--- `[` (`flow.is_flow`).
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
      if condition is string and not condition:find("${{", 1, true) then out[#out + 1] = condition end
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
-- the pinned actionlint the tree used to run did: that each context one names
-- is available where it stands, that `needs.<job>` names a job its job
-- needs, that `steps.<id>` names a step before it, and that `with`
-- passes a local action only inputs it declares. Only an action's
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
    if path == prefix or path:sub(1, #prefix + 1) == prefix .. "/" then return true end
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
          if here == prefix or here:sub(1, #prefix + 1) == prefix .. "/"
              or prefix:sub(1, #here + 1) == here .. "/" then
            present = true
          end
        end
        assert(present, where .. "'s sparse checkout does not hold " .. here .. ", where a step runs")
      end
    end
    if run is string then
      for named in run:gmatch("[%w_./%-]*%.github/scripts/[%w_./%-]+") do
        local script = normal(directory(step, holders) .. "/" .. named)
        assert(walk.checkout, where .. " runs " .. script .. " before any checkout")
        assert(holds(walk.sparse, script), where .. "'s sparse checkout does not hold " .. script)
        walk.scripts[#walk.scripts + 1] = script
      end
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

--- What `scripts_run` refuses in a workflow of one job with `steps`,
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

--- Every workflow and action is already in `build.flow`'s layout, so a
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

--- A leg's verdict cache is named by the host's features
--- (.github/scripts/host-features.sh) as well as its container, or on
--- macOS its runner (.github/scripts/leg-host-id.sh): every
--- declared-key verdict's key holds them (build/declared_key.tl's
--- `host_identity`), and a leg's runners do not share one set, so a
--- cache named by the container alone could restore another host's
--- verdicts, none of which stood (main's run 36320764857 on
--- linux-x86_64).
local function test_the_verdict_cache_is_named_by_the_host_too()
  local ci = decoded_workflows()[DIR .. "/ci.yml"] as {string: any}
  local jobs = ci.jobs as {string: {string: any}}
  local named, cached = false, 0
  for _, step in ipairs(jobs.platform.steps as {{string: any}}) do
    if step.id == "host-id" then
      local run = step.run as string
      assert(run:find("sh .github/scripts/leg-host-id.sh ", 1, true) == 1, run)
      named = run:find(' "$(sh .github/scripts/host-features.sh)"', 1, true) ~= nil
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
  assert(named, "the host-id step names no verdict cache by the host's features")
  assert(cached == 2, "restore and save: " .. cached)
end

--- The steps that name, restore, trim and save a leg's test verdicts,
--- by id or by what they run or cache.
local function verdict_steps(steps: {{string: any}}): {string: integer}
  local at: {string: integer} = {}
  for i, step in ipairs(steps) do
    local id = step.id as string
    local run = step.run as string or ""
    local with = step.with as {string: any}
    if id == "host-id" or id == "verdicts-restore" then
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
--- (COSMIC_CI_DECLARED_KEYS, which cosmic_ci/orchestration.tl makes
--- COSMIC_TEST_KEY=declared), on exactly the leg that is not required
--- sandboxed (COSMIC_CI_REQUIRE_SANDBOX). So no step of the cache turns
--- on the leg's image, and each comes in the order that serves it: the
--- host named, the cache restored, the suites, the trim, the tree moved
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
    if step.id == "release-suite" or step.id == "portable-suite" then at[step.id as string] = i end
  end
  local order = { "host-id", "verdicts-restore", "release-suite", "portable-suite",
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
  assert(restore.key == "${{ steps.host-id.outputs.verdicts }}", restore.key)
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

--- The condition on which a push to main and the scheduled run, and
--- no other, save a cache: ci.yml's COSMIC_CI_SAVES, which each save's
--- condition reads.
local MAIN_SAVES <const> = "${{ github.ref == 'refs/heads/main' && " ..
  "(github.event_name == 'push' || github.event_name == 'schedule') }}"
local SAVES <const> = "env.COSMIC_CI_SAVES == 'true'"

--- Every cache the platform job saves, it saves from main alone -- a
--- push or the scheduled run, never a branch's push nor the merge
--- queue's run -- and restores on every run, whatever its event or ref,
--- so a branch stands on what main saved and saves nothing of its own.
--- Main's pushes share one concurrency group that cancels nothing in
--- progress, so their saves land in commit order and a restore's newest
--- entry is never an older commit's saved late (3c6df8333's
--- alpine-x86_64 leg saved after b6508ab77's, and the two main runs
--- after stood on none of 1892 verdicts), with no lookup of the newest
--- entry before a save. A save's key is the restore's own, or, for the
--- caches a trim cuts to one run's rows, the restore's prefix and the
--- digest of those rows that the trim names: a run that kept only what
--- was saved already saves nothing new.
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
  local steps = jobs.platform.steps as {{string: any}}
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
      -- outputs, which main never takes.
      if step["if"] ~= nil then
        assert(path == "${{ runner.temp }}/zig-build" and
          (step["if"] as string):find("github.ref != 'refs/heads/main'", 1, true) == 1,
          path .. " is restored only on some runs: " .. (step["if"] as string))
      else
        restores[path] = step
      end
    end
    if uses:find("actions/cache/save@", 1, true) ~= nil then
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
        -- The trim of this cache, and the prefix the restore takes.
        local trim = path == "${{ runner.temp }}/verdicts" and trims.verdicts or
          path == "${{ runner.temp }}/build-cache" and trims.compiles or nil
        assert(trim ~= nil, path .. " is saved under a key of its own, cut by no trim: " .. key)
        local digest = "${{ steps." .. trim .. ".outputs.digest }}"
        assert(key == rkey .. digest, path .. " is not saved under its prefix and digest: " .. key)
        assert(((restore.with as {string: any})["restore-keys"] as string) == rkey .. "\n",
          path .. " is restored by another prefix than it is saved under")
        assert(condition:find("steps." .. trim .. ".outputs.digest != ''", 1, true) ~= nil,
          path .. " is saved where its trim named no digest: " .. condition)
      end
    end
  end
  assert(saves == 4, "the verdicts, compiles, zig outputs and driver marker: " .. saves)
end

--- A run's scope is decided once, in ci.yml's workflow-level
--- COSMIC_CI_SCOPE, which the legs' steps and the provenance join
--- alike read: `full` for any run but a push off main.
local function test_the_scope_is_decided_once()
  local ci = decoded_workflows()[DIR .. "/ci.yml"] as {string: any}
  local scope = (ci.env as {string: string}).COSMIC_CI_SCOPE
  assert(scope == "${{ (github.event_name != 'push' || github.ref == 'refs/heads/main') && " ..
    "'full' || 'light' }}", "the scope: " .. tostring(scope))
  for name, job in pairs(ci.jobs as {string: {string: any}}) do
    for _, env in ipairs(envs_of(job)) do
      assert(env.COSMIC_CI_SCOPE == nil and env.FULL == nil,
        "job " .. name .. " decides its scope again")
    end
  end
end

--- A leg saves only the verdicts its run relied on or reached,
--- where it passed: a file saved whole carried some four runs' rows,
--- most under keys no later run reaches, 41-43 MB a leg each main
--- push. The trim runs where the suites do (a Linux leg's container,
--- the macOS runner itself), after every suite that
--- shares the file and before the save, and counts from a time taken
--- before the first suite.
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
  -- `assemble` runs the checked suite, on the leg that runs it.
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

--- A job a push to a branch starts and skips still shows as a
--- check on the branch's PR, a skipped one whose matrix, if it has one,
--- never expands in its name. So a job that runs only on main or on
--- other events -- one whose `if` names main's ref, or refuses a push --
--- lives in a workflow a branch push does not start: one on a
--- workflow_run from main (prerelease.yml, ci-images-publish.yml), or on
--- a push to main alone; or it is steps of a job that always runs, as
--- ci.yml's provenance join is. A step may still skip on a branch.
local BRANCH_SKIPS <const> = { "refs/heads/main", "ref_name == 'main'", "event_name != 'push'" }

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
        for _, skip in ipairs(BRANCH_SKIPS) do
          assert(not (condition is string and condition:find(skip, 1, true)),
            path .. ": job " .. name .. "'s if names " .. skip .. ", so a branch push shows it skipped")
        end
      end
    end
  end
  assert(count > 0, "no workflow a branch push starts")
end

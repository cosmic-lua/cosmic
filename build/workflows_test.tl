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
  assert(cached == 3, "the restore, and the saves by content and by commit: " .. cached)
end

--- The key a restore of the verdicts under `prefix` (an expression)
--- takes: the entry main saved under the tree's base on main, where
--- .github/scripts/merge-base.sh found one, else `prefix` alone, whose
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
--- (COSMIC_CI_DECLARED_KEYS, which cosmic_ci/orchestration.tl makes
--- COSMIC_TEST_KEY=declared), on exactly the leg that is not required
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
    if step.id == "release-suite" or step.id == "portable-suite" then at[step.id as string] = i end
  end
  local order = { "host-id", "merge-base", "verdicts-restore", "release-suite", "portable-suite",
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

--- The condition on which a step of the checked job runs: a full run's.
local FULL <const> = "env.COSMIC_CI_SCOPE == 'full'"

--- The condition on which a push to main and the scheduled run, and
--- no other, save a cache: ci.yml's COSMIC_CI_SAVES, which each save's
--- condition reads.
local MAIN_SAVES <const> = "${{ github.ref == 'refs/heads/main' && " ..
  "(github.event_name == 'push' || github.event_name == 'schedule') }}"
local SAVES <const> = "env.COSMIC_CI_SAVES == 'true'"

--- Holds each cache save of `steps`, a job's, to main's saves (below),
--- and counts them.
local function main_saves(steps: {{string: any}}, full_only?: boolean): integer
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
      -- outputs, which main never takes. The checked job restores only
      -- on a full run, as it does all else (`FULL`).
      local condition = step["if"] as string or ""
      if full_only then
        assert(condition:find(FULL, 1, true) == 1, path .. " is restored on a light run: " .. condition)
        condition = condition:sub(#FULL + 5)
      end
      if condition ~= "" then
        assert(path == "${{ runner.temp }}/zig-build" and
          condition:find("github.ref != 'refs/heads/main'", 1, true) == 1,
          path .. " is restored only on some runs: " .. condition)
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
        -- The trim of this cache, and the prefix the restore takes: the
        -- restore's key, or, for the verdicts, the base's entry first.
        local verdicts = path == "${{ runner.temp }}/verdicts"
        local trim = verdicts and trims.verdicts or
          path == "${{ runner.temp }}/build-cache" and trims.compiles or nil
        assert(trim ~= nil, path .. " is saved under a key of its own, cut by no trim: " .. key)
        local prefix = ((restore.with as {string: any})["restore-keys"] as string):match("^(.*)\n$")
        assert(prefix ~= nil and (rkey == prefix or verdicts and rkey == at_the_base(prefix)),
          path .. " is restored by another prefix than it is saved under: " .. rkey)
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
--- of its own.
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
  assert(main_saves(jobs.platform.steps as {{string: any}}) == 5,
    "the verdicts (by content and by commit), compiles, zig outputs and driver marker")
  assert(main_saves(jobs.checked.steps as {{string: any}}, true) == 2,
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

--- A push to main tests the commit the merge queue just tested, so it
--- reuses that run where it finds it: `reuse` looks it up on a push
--- (its steps only on main's, so a branch push shows it run, not
--- skipped), the platform legs run exactly where it found none, and
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
  assert(reuse["if"] == "github.event_name == 'push'", tostring(reuse["if"]))
  assert((reuse.permissions as {string: string}).actions == "read", "reuse cannot read the queue's run")
  for _, step in ipairs(reuse.steps as {{string: any}}) do
    assert(step["if"] == "github.ref == 'refs/heads/main'", "reuse runs a step off main: " .. tostring(step["if"]))
  end
  local find = step_running(reuse.steps as {{string: any}}, "queue-seed.sh find")
  assert(find.id == "find" and find.run == "sh .github/scripts/queue-seed.sh find", tostring(find.run))
  assert((find.env as {string: string}).SHA == "${{ github.sha }}", "reuse looks up another commit")
  -- A lookup that fails is none: the legs run, and the join reads theirs.
  assert(find["continue-on-error"] == true, "a failed lookup fails reuse")
  -- Its budget, from the script's defaults, is under the job's timeout
  -- with a minute to spare for the checkout.
  local script = assert(Fs.read(".github/scripts/queue-seed.sh"))
  local tries, wait, call = script:match("\ntries=%${TRIES:%-(%d+)} wait=%${WAIT_SECONDS:%-(%d+)} call=%${CALL_SECONDS:%-(%d+)}\n")
  assert(tries ~= nil, "queue-seed.sh's budget moved")
  local budget = math.tointeger(tonumber(tries) * (tonumber(wait) + 2 * tonumber(call)))
  assert(budget + 60 <= (reuse["timeout-minutes"] as integer) * 60, "reuse times out within its lookup's budget, " ..
    budget .. " s: " .. tostring(reuse["timeout-minutes"]))
  assert((reuse.outputs as {string: string}).run == "${{ steps.find.outputs.run }}", "reuse's output")

  assert(platform.needs == "reuse" and platform["if"] == "!cancelled() && needs.reuse.outputs.run == ''",
    "the platform legs run other than where no queue run was found: " .. tostring(platform["if"]))
  assert(seed.needs == "reuse" and seed["if"] == "needs.reuse.outputs.run != ''",
    "seed runs other than where a queue run was found: " .. tostring(seed["if"]))
  assert((seed.permissions as {string: string}).actions == "read", "seed cannot read the queue's run")

  local function legs(job: {string: any}): {string: string}
    local out: {string: string} = {}
    local matrix = (job.strategy as {string: any}).matrix as {string: any}
    for _, leg in ipairs(matrix.include as {{string: string}}) do out[leg.name] = leg.runner end
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
  for name in pairs(ours) do assert(theirs[name] ~= nil, "seed has a leg the platform job has not: " .. name) end
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
  for _, leg in ipairs(((platform.strategy as {string: any}).matrix as {string: any}).include as {{string: string}}) do
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
    if artifact then
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
    if with ~= nil and with.name == "portable-product-${{ matrix.name }}" then relayed = relayed + 1 end
  end
  assert(relayed == 1, "the platform legs upload their product under another name")

  -- Each key the leg's own, of the shape its save takes.
  local keys = step_running(steps, "seed.keys")
  -- Each key names the leg, then what only the leg's own key holds
  -- there (its host's hex, or its digest), so linux-x86_64's entry takes
  -- none of linux-x86_64-checked's.
  assert(keys.id == "keys" and keys.run == "grep -E '^(verdicts=verdicts-${{ matrix.name }}-[0-9a-f]{16}-[0-9a-f]+-" ..
    "[0-9a-f]+|verdicts-sha=verdicts-${{ matrix.name }}-[0-9a-f]{16}-[0-9a-f]+-sha-${{ github.sha }}|" ..
    "compiles=compiles-${{ matrix.name }}-[0-9a-f]+|driver-checked=driver-checked-v2-${{ matrix.name }}-" ..
    "[A-Za-z0-9._]*-[A-Za-z0-9._]*-verdicts-${{ matrix.name }}-[0-9a-f]{16}-[0-9a-f]+)$' " ..
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
    assert(step["if"] == "steps.keys.outputs." .. name .. " != ''", path .. " is seeded where no key was named")
  end
  assert(saved == 4, "the verdicts (by content and by commit), compiles and driver marker: " .. saved)

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
  assert(upload["if"] == QUEUE and with.name == "seed-${{ matrix.name }}" and with.path == "${{ runner.temp }}/seed",
    "the seed is not uploaded as the leg's")
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
--- verdicts under a name of its own on the same COSMIC_HOST_ID. Every
--- step it runs only on a full run, so a branch push shows it run with
--- nothing done rather than skipped: a step's `if` names the scope, or
--- what a step skipped on a light run leaves unmet.
local function test_the_checked_suite_runs_in_a_job_of_its_own_on_linux_x86_64s_host()
  local ci = decoded_workflows()[DIR .. "/ci.yml"] as {string: any}
  local jobs = ci.jobs as {string: {string: any}}
  local platform, checked = jobs.platform, jobs.checked
  assert(checked.needs == platform.needs and checked["if"] == platform["if"],
    "the checked job runs other than where the legs do: " .. tostring(checked["if"]))
  local penv, cenv = platform.env as {string: string}, checked.env as {string: string}
  assert(penv.COSMIC_CI_CHECKED_SUITE == "skip", "a leg runs the checked suite: " .. penv.COSMIC_CI_CHECKED_SUITE)
  local leg: {string: string}
  for _, entry in ipairs(((platform.strategy as {string: any}).matrix as {string: any}).include as {{string: string}}) do
    if entry.name == "linux-x86_64" then leg = entry end
  end
  assert(leg ~= nil, "no linux-x86_64 leg")
  local name = checked.name as string
  assert(name == leg.name .. "-checked" and cenv.COSMIC_WORKER == name, "the checked job's name: " .. name)
  assert(checked["runs-on"] == leg.runner, "the checked job runs on " .. tostring(checked["runs-on"]))
  local shell = ((checked.defaults as {string: any}).run as {string: string}).shell
  assert(shell == leg.shell, "the checked job's steps run through " .. shell)
  assert(cenv.TARGET == leg.target and cenv.COSMIC_CI_CHECKED_SUITE == "run" and
    cenv.COSMIC_CI_REQUIRE_SANDBOX == "1" and cenv.COSMIC_CI_DECLARED_KEYS == "0",
    "the checked job's switches are not linux-x86_64's with the checked suite on")
  for _, same in ipairs({ "COSMIC_CI_EVENT", "COSMIC_CI_BASE_SHA" }) do
    assert(cenv[same] == penv[same], "the checked job's " .. same .. " is not the legs': " .. tostring(cenv[same]))
  end
  local expected <const>: {string: boolean} = { COSMIC_WORKER = true, TARGET = true,
    COSMIC_CI_CHECKED_SUITE = true, COSMIC_CI_REQUIRE_SANDBOX = true, COSMIC_CI_DECLARED_KEYS = true,
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
  -- leg's would and only on a full run.
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
      { "move the tree to a path of this commit's own" },
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
    local wanted = FULL
    if condition ~= nil and not condition:find("matrix.", 1, true) then wanted = FULL .. " && " .. condition end
    same(step_name .. "'s if", our["if"], wanted)
  end
  -- It boots, builds the checked core, and runs its suite, and no more.
  local steps = checked.steps as {{string: any}}
  local ran: {string} = {}
  for _, step in ipairs(steps) do
    local run = step.run
    local phase = run is string and run:match("^cosmic%-driver cosmic_ci/driver%.tl platform ([%w-]+)$") or nil
    if phase ~= nil then ran[#ran + 1] = phase end
  end
  assert(table.concat(ran, " ") == "boot checked-build checked", "the checked job runs " .. table.concat(ran, " "))
  local at = verdict_steps(steps)
  local _, suite = step_running(steps, "platform checked")
  local _, back = step_running(steps, "place-tree.sh --restore")
  for _, pair in ipairs({ { at["host-id"], at["merge-base"] }, { at["merge-base"], at["verdicts-restore"] },
      { at["verdicts-restore"], suite },
      { suite, at.trim }, { at.trim, at.save },
      { back, at.save } }) do
    assert(pair[1] ~= nil and pair[2] ~= nil and pair[1] < pair[2], "the checked job's verdict steps are out of order")
  end
  -- Nothing runs on a light run.
  local unmet <const> = { FULL, "failure()", "steps.driver.outcome == 'success'",
    "github.event_name == 'merge_group'", "steps.verdicts-trim.outputs.digest != ''" }
  for _, step in ipairs(steps) do
    local condition = step["if"] as string or ""
    local held = false
    for conjunct in (condition .. " && "):gmatch("(.-) && ") do
      for _, text in ipairs(unmet) do held = held or conjunct == text end
    end
    assert(held, "the checked job runs " .. tostring(step.name or step.uses) .. " on a light run: " .. condition)
  end
  assert(ours["bootstrap the pinned CI driver"].id == "driver" and
    ours["bootstrap the pinned CI driver"]["if"] == FULL, "the checked job's driver runs on a light run")
end

--- A job that moves its tree (.github/scripts/place-tree.sh) moves it
--- once and puts it back once, after its last step that runs the CI
--- driver and before checkout's post step: place-tree.sh keeps the tree
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
          if run:match("place%-tree%.sh%s*$") ~= nil then moves[#moves + 1] = i end
          if run:find("place-tree.sh --restore", 1, true) ~= nil then backs[#backs + 1] = i end
          if run:find("cosmic-driver ", 1, true) ~= nil then last_driver = i end
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
        assert((steps[back]["if"] as string or ""):find("always()", 1, true) ~= nil,
          where .. " puts its tree back only where the job has not failed")
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
--- base's entry, which .github/scripts/merge-base.sh finds (the merge
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
    assert(find.run == "sh .github/scripts/merge-base.sh" and find.shell == "sh" and
      find["working-directory"] == "." and find["continue-on-error"] == true,
      name .. " finds the base elsewhere than on the host, or fails for it: " .. tostring(find.run))
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
  -- no tree code but the script, from a checkout that keeps no token.
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
  for _, need in ipairs(jobs.ci.needs as {string}) do assert(need ~= "prune", "the join waits on prune") end
  local psteps = prune.steps as {{string: any}}
  assert(#psteps == 2, "prune runs more than its checkout and its script")
  for _, step in ipairs(psteps) do
    assert(step["if"] == "github.ref == 'refs/heads/main'", "prune runs a step off main: " .. tostring(step["if"]))
  end
  local checkout = psteps[1].with as {string: any}
  assert((psteps[1].uses as string):find("actions/checkout@", 1, true) == 1 and
    checkout["persist-credentials"] == false and
    checkout["sparse-checkout"] == "/.github/scripts/prune-commit-verdicts.sh\n",
    "prune checks out more than its script, or keeps the token")
  local step = psteps[2]
  assert(step.run == "sh .github/scripts/prune-commit-verdicts.sh" and step["continue-on-error"] == true,
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

--- A job a push to a branch starts and skips still shows as a
--- check on the branch's PR, a skipped one whose matrix, if it has one,
--- never expands in its name. So a job that runs only on main or on
--- other events -- one whose `if` names main's ref, or refuses a push --
--- lives in a workflow a branch push does not start: one on a
--- workflow_run from main (prerelease.yml, ci-images-publish.yml), or on
--- a push to main alone; or it is steps of a job that always runs, as
--- ci.yml's provenance join is. A step may still skip on a branch. So
--- does a job that runs only where a job it needs found something (an
--- output `!= ''`), which a branch push's never does: ci.yml's `seed`
--- alone, named in SKIPPED_ON_A_BRANCH with the TODO above it.
local BRANCH_SKIPS <const> = { "refs/heads/main", "ref_name == 'main'", "event_name != 'push'" }
local SKIPPED_ON_A_BRANCH <const>: {string: boolean} = { [DIR .. "/ci.yml seed"] = true }

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
        assert(not (condition is string and condition:find("needs%.[%w_-]+%.outputs%.[%w_-]+ != ''")) or
          SKIPPED_ON_A_BRANCH[path .. " " .. name], path .. ": job " .. name ..
          " runs only where a job it needs found something, so a branch push shows it skipped")
      end
    end
  end
  assert(count > 0, "no workflow a branch push starts")
end

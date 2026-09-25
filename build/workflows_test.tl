--- The workflows under .github/workflows/, and the local actions under
--- .github/actions/ (each an `action.yml`), every one written in YAML's
--- flow style: each opens with `{` after its leading comments, and keeps
--- to the subset that YAML and JSON5 read with `#` comments
--- (`cosmic.json`'s `hash_comments`) read alike, so the tree can read
--- what GitHub runs without a YAML parser. A step's script longer than a
--- line or two lives under .github/scripts/, where it reads as a script
--- rather than as one string of `\n`-joined lines; an action's is one
--- line.
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")

local DIR <const> = ".github/workflows"
local ACTIONS <const> = ".github/actions"
local READ <const>: Json.DecodeOptions = { json5 = true, hash_comments = true }

--- Bare keys YAML reads as something other than their text: YAML 1.1's
--- booleans and both versions' null, whatever their case.
local UNSAFE_KEYS <const>: {string: boolean} = {
  y = true, yes = true, n = true, no = true, on = true, off = true, ["true"] = true, ["false"] = true,
  null = true,
}

--- The escapes a double-quoted string may hold, which the two read
--- alike (`\u` takes four hex digits).
local ESCAPES <const>: {string: boolean} = {
  ['"'] = true, ["\\"] = true, ["/"] = true, b = true, f = true, n = true, r = true, t = true, u = true,
}

--- Each character in `text` that not every YAML reader takes as JSON5
--- does, as `line N: why`: bytes that are not UTF-8; a control
--- character but a tab or a line end, which YAML refuses, among them
--- C1's NEL (U+0085), which YAML 1.1 ends a line at; a `\r` alone;
--- U+2028 and U+2029, which JSON5 ends a line at and YAML 1.2 does not;
--- and U+FEFF, U+FFFE and U+FFFF.
local function characters(text: string): {string}
  local found: {string} = {}
  if utf8.len(text) == nil then
    return { "the text is not UTF-8" }
  end
  local line = 1
  for at, code in utf8.codes(text) do
    if code == 0x0a then
      line = line + 1
    elseif code == 0x0d then
      if text:sub(at + 1, at + 1) ~= "\n" then
        found[#found + 1] = ("line %d: a \\r alone: end a line with \\n"):format(line)
      end
    elseif (code < 0x20 and code ~= 0x09) or (code >= 0x7f and code < 0xa0) or code == 0x2028 or
        code == 0x2029 or code == 0xfeff or code == 0xfffe or code == 0xffff then
      found[#found + 1] = ("line %d: the character U+%04X, which the two read differently"):format(line, code)
    end
  end
  return found
end

--- What in `text` either reader would read differently from the other,
--- or not at all, each as `line N: why`. It holds a text to a subset
--- narrower than the two share, where anything it cannot vouch for is
--- refused:
---
--- - Anywhere, strings and comments too: UTF-8 of tabs, line ends and
---   printable characters alone (`characters`), a line ending at `\n` or
---   `\r\n`.
--- - Outside a string and a comment: only spaces, line ends,
---   `{}[],:`, `#` and bare words; a `#` after a space or a line's
---   start, since YAML reads one right after a token as part of it; a
---   space after each `:`, and the `:` on its key's line; no `//` or
---   `/*` comment and no single-quoted string, which YAML lacks or reads
---   otherwise.
--- - A bare key an identifier and none of UNSAFE_KEYS; a bare value
---   true, false, null or a decimal integer of at most 15 digits, which
---   both read as the same number.
--- - In a double-quoted string, only ESCAPES, and no `\u` escape of
---   half a surrogate pair, which YAML keeps as a lone half and JSON5
---   joins to its pair: write the character itself.
--- - No key twice in one object, which GitHub refuses.
local function problems(text: string): {string}
  local found: {string} = characters(text)
  local line = 1
  local function say(why: string)
    found[#found + 1] = ("line %d: %s"):format(line, why)
  end
  --- For each open container, an object's keys seen, or false.
  local open: {{string: boolean} | boolean} = {}
  local function key(name: string)
    local keys = open[#open]
    if keys is {string: boolean} then
      if keys[name] then say("the key " .. name .. " twice in one object") end
      keys[name] = true
    end
  end
  --- The line the last token ended on, which a `:` must share.
  local token_line = 0
  local i = 1
  local n = #text
  while i <= n do
    local c = text:sub(i, i)
    if c == "\r" then
      i = i + 1
    elseif c == "\n" then
      line = line + 1
      i = i + 1
    elseif c == " " then
      i = i + 1
    elseif c == "#" then
      local before = i > 1 and text:sub(i - 1, i - 1) or "\n"
      if before ~= " " and before ~= "\n" then say("a # right after a token: put a space before it") end
      i = text:find("\n", i, true) or n + 1
    elseif c == '"' or c == "'" then
      if c == "'" then say("a single-quoted string: write it double-quoted") end
      local first = i
      i = i + 1
      while i <= n and text:sub(i, i) ~= c do
        local d = text:sub(i, i)
        if d == "\n" then
          line = line + 1
        elseif d == "\\" then
          local e = text:sub(i + 1, i + 1)
          local hex = text:sub(i + 2, i + 5)
          if not ESCAPES[e] or (e == "u" and not hex:match("^%x%x%x%x$")) then
            say("the escape \\" .. e .. ", which the two read differently: write \\uXXXX")
          elseif e == "u" and hex:upper():match("^D[89A-F]") then
            say("the escape \\u" .. hex .. ", half a surrogate pair: write the character itself")
          end
          i = i + 1
        end
        i = i + 1
      end
      i = i + 1
      token_line = line
      if text:match("^ *:", i) then
        local name = Json.decode(text:sub(first, i - 1), READ)
        if name is string then key(name) end
      end
    elseif c == "/" and text:sub(i + 1, i + 1):match("[/*]") then
      local opening = text:sub(i, i + 1)
      say("a " .. opening .. " comment, which YAML does not have: write #")
      -- Past the comment, so what it holds is not read as tokens.
      if opening == "//" then
        i = text:find("\n", i, true) or n + 1
      else
        local _, close = text:find("*/", i + 2, true)
        i = close and close + 1 or n + 1
      end
    elseif c == ":" then
      if not text:sub(i + 1, i + 1):match("^[ \r\n]") then say("a : with no space after it") end
      if token_line ~= line then say("a : on another line than its key") end
      i = i + 1
    elseif c == "{" or c == "[" then
      open[#open + 1] = c == "{" and {} or false
      i = i + 1
    elseif c == "}" or c == "]" then
      open[#open] = nil
      token_line = line
      i = i + 1
    elseif c == "," then
      i = i + 1
    elseif c:match("[%w_$+.%-]") then
      local word = text:match("^[%w_$+.%-]+", i)
      i = i + #word
      token_line = line
      if text:match("^ *:", i) then
        if not word:match("^[%a_$][%w_$]*$") or UNSAFE_KEYS[word:lower()] then
          say("the bare key " .. word .. ", which YAML reads otherwise: quote it")
        else
          key(word)
        end
      elseif word ~= "true" and word ~= "false" and word ~= "null" and
          not (word:match("^%-?[1-9]%d*$") and #word:gsub("^%-", "") <= 15) and word ~= "0" then
        say("the bare value " .. word .. ": quote it, or write a decimal integer of at most 15 digits")
      end
    else
      say(("the character %s outside a string, which the two read differently"):format(
        c:byte() < 0x80 and ("%q"):format(c) or ("\\x%02X"):format(c:byte())))
      i = i + 1
    end
  end
  return found
end

--- Of `paths`, the ones in flow style, each with its text: a file whose
--- first line that is neither blank nor a comment opens with `{`.
local function flow_files(paths: {string}): {string: string}
  local out: {string: string} = {}
  for _, path in ipairs(paths) do
    local text = (assert(Fs.read(path)))
    for row in text:gmatch("[^\n]*") do
      if row:match("%S") and not row:match("^%s*#") then
        if row:match("^%s*{") then out[path] = text end
        break
      end
    end
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

local function test_problems_names_what_the_readers_read_apart()
  local cases: {string: string} = {
    ["{a: 'x'}"] = "single-quoted",
    ["{a: 1} // c"] = "// comment",
    ["{a: 1} /* c */"] = "/* comment",
    ["{a: 1}# c"] = "right after a token",
    ["{a: 1}\t# c"] = 'the character "\\9"',
    ['{a:"x"}'] = "no space after",
    ['{"a"\n: 1}'] = "another line than its key",
    ['{on: "x"}'] = "the bare key on",
    ['{NULL: "x"}'] = "the bare key NULL",
    ['{"a": x}'] = "the bare value x",
    ['{"a": 0x1F}'] = "the bare value 0x1F",
    ['{"a": NaN}'] = "the bare value NaN",
    ['{"a": 1.5}'] = "the bare value 1.5",
    ['{"a": 1234567890123456}'] = "the bare value 1234567890123456",
    ['{"a": "\\\'"}'] = "the escape \\'",
    ['{"a": "x\\\ny"}'] = "the escape \\\n",
    ['{"a": "\\N"}'] = "the escape \\N",
    ['{"a": "\\U0001F600"}'] = "the escape \\U",
    ['{"a": "\\u00"}'] = "the escape \\u",
    ['{"a": 1, "a": 2}'] = "the key a twice",
    ['{a: 1, "a": 2}'] = "the key a twice",
    ["{\\u0061: 1}"] = 'the character "\\\\"',
    ['{\t"a": 1}'] = 'the character "\\9"',
    ['{"a": *x}'] = 'the character "*"',
    ["{\n# c\r\"a\": 1}"] = "a \\r alone",
    ["{\n# c\u{2028}\"a\": 1}"] = "U+2028",
    ["{\n# c\u{85}\"a\": 1}"] = "U+0085",
    ['{"a": "x\u{2029}y"}'] = "U+2029",
    ['{"a": "x\x7fy"}'] = "U+007F",
    ['{"a": "x\u{FFFE}"}'] = "U+FFFE",
    ["{\n# \x01\n}"] = "U+0001",
    ['{"a": "\xff"}'] = "not UTF-8",
    ['{"a": "\\uD83D\\uDE00"}'] = "the escape \\uD83D",
    ['{"a": \u{e9}}'] = 'the character \\xC3',
  }
  for text, want in pairs(cases) do
    local got = problems(text)
    assert(#got >= 1 and got[1]:find(want, 1, true), text .. ": " .. table.concat(got, "; "))
  end
  local fine = '# lead \u{2014} \u{2192} \u{2026}\r\n{\n  "on": {push: {}}, # after\n  a: [true, false, null, 0, -12, 123456789012345,],\n' ..
    '  b: "it\'s # not a comment: //, \\"quoted\\" \\u00e9\\n",\n  "c-d": {a: "x:y"},\n  e: [{a: 1}, {a: 2}],\n}\n'
  local none = problems(fine)
  assert(#none == 0, table.concat(none, "; "))
  local got = problems('{\n  a: 1,\n  b: x,\n}')
  assert(got[1] == "line 3: the bare value x: quote it, or write a decimal integer of at most 15 digits", got[1])
end

local function test_flow_workflows_keep_to_the_shared_subset()
  local count = 0
  for path, text in pairs(flow_workflows()) do
    count = count + 1
    local found = problems(text)
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
  local flow = flow_workflows()
  for _, name in ipairs((assert(Fs.list(DIR)))) do
    local path = DIR .. "/" .. name
    assert(flow[path] ~= nil, path .. " is not in flow style")
  end
end

--- Each local action keeps to the same subset, and is a composite
--- action whose `run` steps each name their shell -- a job's
--- `defaults.run` does not reach them -- and are one line: a longer
--- script lives under .github/scripts/.
local function test_flow_actions_keep_to_the_shared_subset()
  local flow = flow_files(action_paths())
  local count = 0
  for path, text in pairs(flow) do
    count = count + 1
    local found = problems(text)
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
    assert(flow[path] ~= nil, path .. " is not in flow style")
  end
  assert(count > 0, "no action under " .. ACTIONS)
end

--- Each `inputs.<name>` an action's expressions read is one it
--- declares: actionlint checks what a workflow passes an action, but
--- not the action's own steps, where a misspelt input reads as empty.
local function test_an_action_reads_only_the_inputs_it_declares()
  for path, text in pairs(flow_files(action_paths())) do
    local action = assert(Json.decode_object(text, READ))
    local declared = action.inputs
    local names: {string: any} = declared is {string: any} and declared or {}
    for expression in text:gmatch("%${{(.-)}}") do
      for name in expression:gmatch("inputs%.([%w_%-]+)") do
        assert(names[name] ~= nil, path .. " reads inputs." .. name .. ", which it does not declare")
      end
    end
  end
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

--- `path` with its `.` and `..` segments resolved.
local function normal(path: string): string
  local parts: {string} = {}
  for part in path:gmatch("[^/]+") do
    if part == ".." then
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
            end
          end
        end
      end
    end
  end
  assert(count > 0, "no job with a shell of its own uses an action that takes one")
end

local function test_a_local_action_is_one_there_is()
  local got = refusal({ { uses = CHECKOUT }, { uses = "./.github/actions/nowhere" } })
  assert(got:find("uses .github/actions/nowhere, which holds no action.yml", 1, true), got)
end

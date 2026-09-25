--- The workflows under .github/workflows/, every one written in YAML's
--- flow style: each opens with `{` after its leading comments, and keeps
--- to the subset that YAML and JSON5 read with `#` comments
--- (`cosmic.json`'s `hash_comments`) read alike, so the tree can read
--- what GitHub runs without a YAML parser. A step's script longer than a
--- line or two lives under .github/scripts/, where it reads as a script
--- rather than as one string of `\n`-joined lines.
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")

local DIR <const> = ".github/workflows"
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

--- The flow-style workflows: each file under DIR whose first line that
--- is neither blank nor a comment opens with `{`, with its text.
local function flow_workflows(): {string: string}
  local out: {string: string} = {}
  for _, name in ipairs((assert(Fs.list(DIR)))) do
    if name:match("%.ya?ml$") then
      local path = DIR .. "/" .. name
      local text = (assert(Fs.read(path)))
      for row in text:gmatch("[^\n]*") do
        if row:match("%S") and not row:match("^%s*#") then
          if row:match("^%s*{") then out[path] = text end
          break
        end
      end
    end
  end
  return out
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
--- step's own `working-directory`, else its job's default, else the
--- workflow's, else the checkout's root.
local function directory(workflow: {string: any}, job: {string: any}, step: {string: any}): string
  for _, holder in ipairs({ step, (job.defaults or {}) as {string: any}, (workflow.defaults or {}) as {string: any} }) do
    local here = holder["working-directory"]
    if here == nil then
      local run = holder.run
      here = run is {string: any} and run["working-directory"] or nil
    end
    if here is string then return here end
  end
  return "."
end

--- Every script under SCRIPTS a step of `workflow` runs, as the path from
--- the checkout's root its `run` resolves to from where it starts.
local function scripts_run(path: string, workflow: {string: any}): {string}
  local out: {string} = {}
  local jobs = workflow.jobs
  assert(jobs is {string: {string: any}}, path .. ": no jobs")
  for _, job in pairs(jobs) do
    local steps = job.steps
    if steps is {{string: any}} then
      for _, step in ipairs(steps) do
        local run = step.run
        if run is string then
          for named in run:gmatch("[%w_./%-]*%.github/scripts/[%w_./%-]+") do
            out[#out + 1] = normal(directory(workflow, job, step) .. "/" .. named)
          end
        end
      end
    end
  end
  return out
end

--- The scripts the workflows run are the ones under SCRIPTS: each one a
--- step names is a file there, found from where the step starts, and
--- each file there is one some step names.
local function test_the_workflows_run_the_scripts_there_are()
  local named: {string: boolean} = {}
  for path, workflow in pairs(decoded_workflows()) do
    for _, script in ipairs(scripts_run(path, workflow)) do
      named[script] = true
      local st = Fs.stat(script)
      assert(st ~= nil and st.kind == "file", path .. " runs " .. script .. ", which is no file")
    end
  end
  for _, name in ipairs((assert(Fs.list(SCRIPTS)))) do
    local script = SCRIPTS .. "/" .. name
    assert(named[script], script .. " is run by no workflow")
  end
end

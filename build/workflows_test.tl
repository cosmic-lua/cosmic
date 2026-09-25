--- The workflows under .github/workflows/ written in YAML's flow style:
--- each opens with `{` after its leading comments, and keeps to the
--- subset that YAML and JSON5 read with `#` comments
--- (`cosmic.json`'s `hash_comments`) read alike, so the tree can read
--- what GitHub runs without a YAML parser.
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")

local DIR <const> = ".github/workflows"
local READ <const>: Json.DecodeOptions = { json5 = true, hash_comments = true }

--- Keys YAML 1.1 reads as booleans when bare, whatever their case.
local BOOLEAN_KEYS <const>: {string: boolean} = {
  y = true, yes = true, n = true, no = true, on = true, off = true, ["true"] = true, ["false"] = true,
}

--- What in `text` either reader would read differently from the other,
--- or not at all, each as `line N: why`. Outside a string and a comment:
--- a single quote (YAML escapes one inside as `''`, JSON5 as `\'`); a
--- `//` or `/*` comment, which YAML lacks; a `#` right after a token,
--- which YAML reads as part of it; a `:` with nothing after it but a
--- token, which YAML reads as part of a word; a bare key YAML 1.1 reads
--- as a boolean; and a bare value other than true, false, null or a
--- decimal integer, which the two may read as different things. Inside
--- a double-quoted string: `\'`, which YAML lacks, and a line
--- continuation, which YAML folds differently.
local function problems(text: string): {string}
  local found: {string} = {}
  local line = 1
  local function say(why: string)
    found[#found + 1] = ("line %d: %s"):format(line, why)
  end
  local i = 1
  local n = #text
  while i <= n do
    local c = text:sub(i, i)
    if c == "\n" then
      line = line + 1
      i = i + 1
    elseif c == "#" then
      local before = i > 1 and text:sub(i - 1, i - 1) or "\n"
      if not before:match("[ \t\n]") then say("a # right after a token: put a space before it") end
      local stop = text:find("\n", i, true)
      i = stop or n + 1
    elseif c == '"' or c == "'" then
      if c == "'" then say("a single-quoted string: write it double-quoted") end
      i = i + 1
      while i <= n and text:sub(i, i) ~= c do
        local d = text:sub(i, i)
        if d == "\n" then
          line = line + 1
        elseif d == "\\" then
          local e = text:sub(i + 1, i + 1)
          if e == "'" then say("\\' in a string, which YAML does not have: write ' alone") end
          if e == "\n" or e == "\r" then say("a line continuation, which YAML folds differently: write \\n") end
          i = i + 1
        end
        i = i + 1
      end
      i = i + 1
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
      if not text:sub(i + 1, i + 1):match("^[ \t\r\n]") then say("a : with no space after it") end
      i = i + 1
    elseif c:match("[%w_$+.%-]") then
      local word = text:match("^[%w_$+.%-]+", i)
      i = i + #word
      local after = text:match("^[ \t]*(.)", i)
      if after == ":" then
        if BOOLEAN_KEYS[word:lower()] then
          say("the key " .. word .. ", which YAML 1.1 reads as a boolean: quote it")
        end
      elseif word ~= "true" and word ~= "false" and word ~= "null" and not word:match("^%-?[1-9]%d*$")
          and word ~= "0" then
        say("the bare value " .. word .. ": quote it, or write a decimal integer")
      end
    else
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
    ['{a:"x"}'] = "no space after",
    ['{on: "x"}'] = "the key on",
    ['{"a": x}'] = "the bare value x",
    ['{"a": 0x1F}'] = "the bare value 0x1F",
    ['{"a": NaN}'] = "the bare value NaN",
    ['{"a": 1.5}'] = "the bare value 1.5",
    ['{"a": "\\\'"}'] = "\\' in a string",
    ['{"a": "x\\\ny"}'] = "line continuation",
  }
  for text, want in pairs(cases) do
    local got = problems(text)
    assert(#got == 1 and got[1]:find(want, 1, true), text .. ": " .. table.concat(got, "; "))
  end
  local fine = '# lead\n{\n  "on": {push: {}}, # after\n  a: [true, false, null, 0, -12,],\n' ..
    '  b: "it\'s # not a comment: //, \\"quoted\\"",\n  "c-d": {e: "x:y"},\n}\n'
  local none = problems(fine)
  assert(#none == 0, table.concat(none, "; "))
  local got = problems('{\n  a: 1,\n  b: x,\n}')
  assert(got[1] == "line 3: the bare value x: quote it, or write a decimal integer", got[1])
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

--- actionlint.yml runs only when a path its filter names changes, so a
--- path that no longer exists is a check that silently stops running.
local function test_the_actionlint_path_filter_names_what_exists()
  local text = assert(flow_workflows()[DIR .. "/actionlint.yml"], "actionlint.yml is not in flow style")
  local workflow = assert(Json.decode_object(text, READ))
  local on = workflow["on"] as {string: {string: {string}}}
  local paths = assert(on.push.paths, "no push path filter")
  assert(#paths > 0, "an empty path filter")
  for _, path in ipairs(paths) do
    local fixed = path:gsub("/%*%*$", "")
    assert(not fixed:find("*", 1, true), path .. ": only a trailing /** is checked")
    assert(Fs.exists(fixed), path .. " is in actionlint.yml's path filter, and does not exist")
  end
end

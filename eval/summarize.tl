--- Numbers from a Claude Code stream-json transcript: turns, tool calls,
--- minutes, cost, then the friction the journal may not admit to --
--- failed tool calls, `cosmic docs` lookups that found no exact match,
--- the tool call at which `cosmic test` first passed (a Bash call that
--- ran `cosmic test`, its result holding a line `test: PASS`), and how
--- many times the journal was written (one write at the end is a
--- retelling, not a log). Last, the paths a tool call named outside the
--- arena, in tiers: `BREACH` for this checkout, `.claude`, a skills
--- directory, CLAUDE.md, AGENTS.md, Claude Code's managed settings, a
--- home directory or another arena; `sandbox-tmp`, a count, for the rest
--- of /tmp, which the solver's sandbox makes private; `outside-arena`
--- for any other. Any mention of this repository or a skills or plugins
--- directory is flagged as contamination. These are leads to check
--- before trusting the run.
---
--- The path lists are advisory evidence, read from what the tool calls
--- say: a path a shell builds at run time, or names inside a command
--- substitution in quotes, is not seen, and a word that only looks like
--- a path is skipped or reported by a small lexer's rules, not a shell's.
--- The sandbox ([`eval/solve`]) is the enforcement.
--- Another agent's transcript needs its own reader.
---
---     cosmic --standalone eval/summarize.tl <arena>/transcript.jsonl
---
--- [`eval/summarize`] runs this on the bootstrap cosmic, as bin/vendor
--- runs build/vendor.tl: it requires `cosmic.*` modules only. The arena
--- is the transcript's own directory, and the repository is found from
--- this script's path, both with every link resolved.
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local String = require("cosmic.string")

local record Summarize
end

--- What `summarize` reads from one tool call: its name, its input and
--- the input as JSON text.
local record Call
  id: string
  name: string
  given: string
  input: {string: any}
end

--- What a tool call answered: whether it failed, and its text.
local record Answer
  error: boolean
  text: string
end

--- System locations a shell call may name without leaving the arena.
local system <const>: {string} = {
  "/usr/", "/bin/", "/sbin/", "/lib/", "/etc/", "/dev/", "/proc/", "/opt/",
}

--- How deep a transcript line may nest: as deep as cosmic.json reads.
local max_depth <const> = 1000

local function count(text: string, needle: string): integer
  local n = 0
  local at = 1
  while true do
    local s, e = text:find(needle, at, true)
    if s == nil then
      return n
    end
    n = n + 1
    at = e + 1
  end
end

--- One word of a shell command: its text with quotes removed; whether
--- it can be a path -- false when a quoted part held a pattern's
--- metacharacters, which makes it a regex; whether a quoted part held
--- whitespace, which makes it prose unless it starts like a path; and
--- whether it lies inside `$(( ... ))`, where `/` divides.
local record Word
  text: string
  literal: boolean
  spaced: boolean
  quoted: boolean
  arith: boolean
end

--- Whether a quoted piece holds a regex's or an expression's
--- metacharacters. A `${NAME}` is not one, though it holds braces.
local function is_prose(piece: string): boolean
  return (piece:gsub("%${[%w_]+}", "")):find("[%(%)%[%]{}|%^%*%+%?\\]") ~= nil
end

--- The word starting at `from` and where it ends: at whitespace or one
--- of `;|&<>`, outside quotes.
local function read_word(src: string, from: integer): Word, integer
  local buf: {string} = {}
  local literal, spaced, quoted = true, false, false
  local i, n = from, #src
  while i <= n do
    local ch = src:sub(i, i)
    if ch:find("[%s;|&<>]") then
      break
    elseif ch == "'" or ch == '"' or (ch == "$" and src:sub(i + 1, i + 1) == "'") then
      -- $'...' reads a backslash as an escape, as "..." does.
      local escapes = ch ~= "'"
      if ch == "$" then
        i = i + 1
        ch = "'"
      end
      local close = i + 1
      while close <= n and src:sub(close, close) ~= ch do
        close = close + (escapes and src:sub(close, close) == "\\" and 2 or 1)
      end
      local piece = src:sub(i + 1, close - 1)
      literal = literal and not is_prose(piece)
      spaced = spaced or piece:find("%s") ~= nil
      quoted = true
      buf[#buf + 1] = ch == '"' and (piece:gsub("\\([\"\\$`])", "%1")) or piece
      i = close + 1
    elseif ch == "\\" then
      if src:sub(i + 1, i + 1) ~= "\n" then
        buf[#buf + 1] = src:sub(i + 1, i + 1)
      end
      i = i + 2
    else
      buf[#buf + 1] = ch
      i = i + 1
    end
  end
  return { text = table.concat(buf), literal = literal, spaced = spaced, quoted = quoted, arith = false }, i
end

--- The simple commands of a shell script as lists of words. Comments
--- and here-document bodies are left out, and redirection operators:
--- the word after one is a word like any other. A command substitution
--- or subshell is not entered (its words join the command around it),
--- which is enough for an advisory list.
local function lex(src: string): {{Word}}
  local commands: {{Word}} = {}
  local current: {Word} = {}
  local delims: {string} = {}
  local dashed: {boolean} = {}
  local arith = false
  local i, n = 1, #src
  local function flush()
    if #current > 0 then
      commands[#commands + 1] = current
      current = {}
    end
  end
  while i <= n do
    local ch = src:sub(i, i)
    if ch == "\n" then
      flush()
      arith = false
      i = i + 1
      for d = 1, #delims do
        while i <= n do
          local e = src:find("\n", i, true) or n + 1
          local line = src:sub(i, e - 1)
          i = e + 1
          if dashed[d] then
            line = line:gsub("^\t+", "")
          end
          if line == delims[d] then
            break
          end
        end
      end
      delims, dashed = {}, {}
    elseif ch:find("%s") then
      i = i + 1
    elseif ch == "#" then
      i = src:find("\n", i, true) or n + 1
    elseif ch == ";" or ch == "|" or ch == "&" then
      flush()
      i = i + 1
    elseif ch == "<" or ch == ">" then
      -- `<<` opens a here-document only before a word that can be a
      -- delimiter, and outside `$(( ))`, where `<<` shifts.
      local j = i + 2
      local dash = src:sub(j, j) == "-"
      if dash then
        j = j + 1
      end
      while src:sub(j, j):find("^[ \t]") do
        j = j + 1
      end
      if not arith and src:sub(i, i + 1) == "<<" and src:sub(i + 2, i + 2) ~= "<" and
          src:sub(j, j):find("^[%a_'\"\\]") then
        local word: Word
        word, i = read_word(src, j)
        delims[#delims + 1] = word.text
        dashed[#dashed + 1] = dash
      else
        while src:sub(i, i):find("^[<>]") do
          i = i + 1
        end
        if src:sub(i, i) == "&" then
          i = i + 1
        end
      end
    else
      local word: Word
      word, i = read_word(src, i)
      if not arith and word.text:find("^%$?%(%(") then
        arith = true
      end
      word.arith = arith
      if arith and word.text:find("%)%)") then
        arith = false
      end
      current[#current + 1] = word
    end
  end
  flush()
  return commands
end

--- For each program that takes a script or pattern as an argument, the
--- letters of the flags that introduce it (`sed -e`, `python -c`).
local script_flags <const>: {string: string} = {
  sed = "e", awk = "e", gawk = "e", grep = "e", egrep = "e", fgrep = "e", rg = "e",
  perl = "eE", ruby = "e", node = "e", python = "c", python3 = "c",
  sh = "c", bash = "c", dash = "c",
}

--- Programs whose first argument that is no option is the script or
--- pattern when no flag gave one, and which `-f` / `--file` / `--files`
--- turn into readers of a file: the next word is then a path.
local script_first <const>: {string: boolean} = {
  sed = true, awk = true, gawk = true, grep = true, egrep = true, fgrep = true, rg = true,
}

--- Programs that run their script argument as shell.
local shells <const>: {string: boolean} = { sh = true, bash = true, dash = true }

--- grep's options that take a number as a separate word.
local counts <const>: {string: boolean} = { ["-m"] = true, ["-A"] = true, ["-B"] = true, ["-C"] = true }

--- What follows `$HOME`, `${HOME}` or `~user` in `word` when it starts
--- with one, and the part that was; else nil.
local function home_rest(word: string): string, string
  for _, home in ipairs({ "${HOME}", "$HOME" }) do
    if word == home or String.starts_with(word, home .. "/") then
      return word:sub(#home + 1), "~"
    end
  end
  local user = word:match("^(~[%w_%-]*)")
  if user ~= nil then
    local rest = word:sub(#user + 1)
    if rest == "" or rest:sub(1, 1) == "/" then
      return rest, user
    end
  end
  return nil, nil
end

--- A word as a bare one, for a field that holds a path or glob.
local function plain(text: string): Word
  return { text = text, literal = true, spaced = false, quoted = false, arith = false }
end

--- `word` as a path to look at, or nil when it is not one: it starts
--- with `/`, `~`, `$HOME`, `${HOME}` or `..`, or climbs through `/../`.
--- `VAR=`, `--opt=`, `-X` and `@` prefixes come off first, and `$PWD` is
--- `.`. A URL is no path; nor is a `/` or `/12` inside `$(( ))`, which
--- divides, nor a `/` that is quoted or a variable's value (`cut -d '/'`,
--- `IFS=/`); nor a bare `VAR=$HOME`, which names the variable's value
--- without opening anything; nor prose, a quoted word with whitespace
--- that does not start like a path.
local function candidate(word: Word): string
  if not word.literal then
    return nil
  end
  local text = word.text
  local assigned = text:find("^[%w_]+=") ~= nil
  text = text:gsub("^[%w_]+=", "")
  text = text:gsub("^%-%-[%w%-]+=", "")
  local attached = text:match("^%-%a([/~%$%.].*)$") or text:match("^@(/.*)$")
  if attached ~= nil then
    -- awk's -F/ separates by a slash.
    if attached == "/" then
      return nil
    end
    text = attached
  end
  text = text:gsub("^%$?%(+", "")
  text = text:gsub("^`", "")
  text = text:gsub("[%)`]+$", "")
  for _, pwd in ipairs({ "${PWD}", "$PWD" }) do
    if text == pwd or String.starts_with(text, pwd .. "/") then
      text = "." .. text:sub(#pwd + 1)
    end
  end
  if assigned and home_rest(text) == "" then
    return nil
  end
  if text == "/" and (word.quoted or assigned) then
    return nil
  end
  if text:find("://", 1, true) or (word.arith and (text == "/" or text:find("^/%d+$"))) then
    return nil
  end
  if word.spaced and not (text:find("^/") or home_rest(text) ~= nil) then
    return nil
  end
  if home_rest(text) ~= nil or text:find("^/") or text == ".." or text:find("^%.%./") or
      text:find("/%.%./") or text:find("/%.%.$") then
    return text
  end
  return nil
end

--- Where the command starts in `words` from `first`: past assignments
--- and the wrappers that run what follows (`timeout 5`, `env F=1`,
--- `nohup`, `xargs`, ...) and their options.
local function after_wrappers(words: {Word}, first: integer): integer
  while true do
    while words[first] ~= nil and words[first].text:find("^[%w_]+=") do
      first = first + 1
    end
    local word = words[first]
    local program = word ~= nil and word.text:match("[^/]*$") or ""
    if program == "timeout" then
      first = first + 1
      while words[first] ~= nil and words[first].text:find("^%-") do
        first = first + 1
      end
      if words[first] ~= nil and words[first].text:find("^%d") then
        first = first + 1
      end
    elseif program == "env" then
      first = first + 1
      while words[first] ~= nil and
          (words[first].text:find("^%-") or words[first].text:find("^[%w_]+=")) do
        first = first + 1
      end
    elseif program == "nohup" or program == "xargs" or program == "nice" or
        program == "time" or program == "exec" or program == "command" then
      first = first + 1
      while words[first] ~= nil and words[first].text:find("^%-") do
        first = first + 1
      end
    else
      return first
    end
  end
end

--- Every path-like word of the shell script `src`, in order, unresolved.
--- The script argument of `sed`, `grep` and the like is not looked at,
--- and `sh -c`'s and `eval`'s is read as a script of its own. Limits of
--- advisory evidence, left as they are: `python -c` and `node -e`
--- scripts are not read; nor is `"$(...)"` inside double quotes; nor
--- is a relative path after a `cd` to somewhere else, taken for one in
--- the project.
local function shell_words(src: string, found: {string}, nested: boolean)
  for _, words in ipairs(lex(src)) do
    local first = after_wrappers(words, 1)
    local head = words[first]
    local program = head ~= nil and head.text:match("[^/]*$") or ""
    local letters = script_flags[program]
    local skipped: {integer: boolean} = {}
    local scripts: {string} = {}
    local flagged, filed = false, false
    local bare: integer = nil
    if letters ~= nil then
      local k = first + 1
      while k <= #words do
        local text = words[k].text
        local group = text:match("^%-(%a+)$")
        if group ~= nil and letters:find(group:sub(-1), 1, true) and words[k + 1] ~= nil then
          flagged = true
          skipped[k + 1] = true
          scripts[#scripts + 1] = words[k + 1].text
          k = k + 1
        elseif script_first[program] and (text == "--file" or text == "--files" or
            text:find("^%-%-file=") or (group ~= nil and group:find("f", 1, true))) then
          filed = true
        elseif (program == "grep" or program == "rg") and counts[text] then
          skipped[k + 1] = true
          k = k + 1
        elseif text:sub(1, 1) ~= "-" and bare == nil then
          bare = k
        end
        k = k + 1
      end
      if not flagged and not filed and bare ~= nil and script_first[program] then
        skipped[bare] = true
      end
    elseif program == "eval" then
      local parts: {string} = {}
      for k = first + 1, #words do
        parts[#parts + 1] = words[k].text
      end
      scripts[1] = table.concat(parts, " ")
    end
    for k, word in ipairs(words) do
      local path = not skipped[k] and candidate(word) or nil
      if path ~= nil then
        found[#found + 1] = path
      end
    end
    if (shells[program] or program == "eval") and not nested then
      for _, script in ipairs(scripts) do
        shell_words(script, found, true)
      end
    end
  end
end

--- A word as a command names it: without a leading `(`, `{`, `$(` or
--- backtick, an assignment before it, or a closing `)`, `}` after.
local function bare_word(text: string): string
  text = text:gsub("^[%w_]+=", "")
  text = text:gsub("^[%$%({`]+", "")
  text = text:gsub("[%)}`]+$", "")
  return text
end

--- Whether a shell command runs `cosmic test`: a word naming `cosmic`
--- followed by `test`, as `timeout 30 bin/cosmic test`, `(cd p && cosmic
--- test)`, `out=$(cosmic test)` and `sh -c '...'` have it.
local function runs_cosmic_test(command: string, nested: boolean): boolean
  for _, words in ipairs(lex(command)) do
    local texts: {string} = {}
    for k, word in ipairs(words) do
      texts[k] = bare_word(word.text)
    end
    for k = 1, #texts do
      local program = texts[k]:match("[^/]*$")
      if program == "cosmic" and texts[k + 1] == "test" then
        return true
      elseif shells[program] and not nested then
        for j = k + 1, #texts - 1 do
          if texts[j]:find("^%-%a*c$") and runs_cosmic_test(words[j + 1].text, true) then
            return true
          end
        end
      end
    end
  end
  return false
end

--- `path` with its `.` and `..` segments resolved and slashes
--- collapsed, as an absolute path; a `..` at the root stays there.
local function normalize(path: string): string
  local parts: {string} = {}
  for part in path:gmatch("[^/]+") do
    if part == ".." then
      table.remove(parts)
    elseif part ~= "." then
      parts[#parts + 1] = part
    end
  end
  return "/" .. table.concat(parts, "/")
end

--- Where `word` points: an absolute path normalized, one relative to
--- `project` joined to it first. A home directory is not known (the
--- solver's own is inside its arena, a manual launch's is the user's),
--- so `~/x` and `$HOME/x` stay as `~/x`.
local function resolve(word: string, project: string): string
  local rest, home = home_rest(word)
  if rest ~= nil then
    local tail = normalize(rest)
    return tail == "/" and home or home .. tail
  end
  return normalize(word:sub(1, 1) == "/" and word or project .. "/" .. word)
end

--- The paths a tool call names, in order, resolved: what its input says
--- about where it acts, never what it writes. Read, Write and Edit name
--- a file; Glob a directory, and a pattern if absolute; Grep a directory
--- (its pattern is a regex, its glob may name a place); Bash a command, whose words are read as a
--- shell would split them.
function Summarize.paths(name: string, input: {string: any}, project: string): {string}
  local raw: {string} = {}
  local function field(key: string): string
    local value = input[key]
    return value is string and value or ""
  end
  if name == "Bash" then
    shell_words(field("command"), raw, false)
  elseif name == "Grep" then
    raw[1] = field("path")
    raw[2] = candidate(plain(field("glob"))) or ""
  elseif name == "Glob" then
    raw[1] = field("path")
    raw[2] = candidate(plain(field("pattern"))) or ""
  else
    raw[1] = field("file_path")
    raw[2] = field("notebook_path")
    raw[3] = field("path")
  end
  local found: {string} = {}
  for _, path in ipairs(raw) do
    if path ~= "" then
      found[#found + 1] = resolve(path, project)
    end
  end
  return found
end

--- One line's value, or nil. A lone surrogate, which Python's
--- json.loads also reads and Claude Code writes when it cuts a tool's
--- output in the middle of an emoji, is read as U+FFFD.
local function decode(line: string): any
  -- A line that does not decode is nil, and skipped.
  local value, _ = Json.decode(line, { max_depth = max_depth, lone_surrogates = true })
  return value
end

local function is_system(path: string): boolean
  for _, prefix in ipairs(system) do
    if String.starts_with(path, prefix) or path .. "/" == prefix then
      return true
    end
  end
  return false
end

--- Where outside the arena `path` is, as a tier: "breach" for what the
--- solver must not reach (this checkout, a `.claude` directory, a skills
--- directory, CLAUDE.md or AGENTS.md, Claude Code's managed settings, a
--- home directory, another arena), "tmp" for the rest of /tmp, which the
--- sandbox gives the solver a private copy of, "outside" for any other
--- path; nil for one in the arena or a system location.
local function tier_of(path: string, arena: string, repo: string): string
  if Fs.within(path, arena) then
    return nil
  end
  local name = path:match("[^/]*$")
  if Fs.within(path, repo) or ("/" .. path .. "/"):find("/%.claude/") or
      name == "CLAUDE.md" or name == "AGENTS.md" then
    return "breach"
  end
  for _, root in ipairs({ "/mnt/skills", "/etc/claude-code", "/root", "/home", "/tmp/cosmic-evals" }) do
    if Fs.within(path, root) then
      return "breach"
    end
  end
  -- Another process's root or working directory is its filesystem.
  if path:find("^/proc/[^/]+/root") or path:find("^/proc/[^/]+/cwd") then
    return "outside"
  end
  if is_system(path) then
    return nil
  end
  return Fs.within(path, "/tmp") and "tmp" or "outside"
end

--- A value as text, for a field whose value need not be a string.
local function as_text(value: any): string
  if value == nil then
    return ""
  elseif value is string then
    return value
  elseif value is number or value is boolean then
    return tostring(value)
  end
  -- A value too deep to encode reads as nothing.
  local encoded, _ = Json.encode(value, { max_depth = max_depth })
  return encoded or ""
end

--- A tool call's id as a key: a number that is a whole one names the
--- same call whether it is written `1` or `1.0`, as it would in Python.
local function id_key(value: any): string
  if value is number and math.tointeger(value) ~= nil then
    return tostring(math.tointeger(value))
  end
  return as_text(value)
end

--- Whether a value is true as Python's `bool` takes it: not nil,
--- false, zero, or an empty string or table.
local function truthy(value: any): boolean
  if value is string then
    return value ~= ""
  elseif value is number then
    return value ~= 0
  elseif value is table then
    return next(value) ~= nil
  end
  return value ~= nil and value ~= false
end

--- Whether a call wrote the journal: its input names JOURNAL.md, and it
--- is a Write or an Edit, or a shell redirection or `tee` into it.
local function writes_journal(call: Call): boolean
  local given = call.given
  if not given:find("JOURNAL.md", 1, true) then
    return false
  end
  return call.name == "Write" or call.name == "Edit" or
    given:find(">>?%s*%S*JOURNAL%.md") ~= nil or
    given:find("tee%f[^%w_][^|]*JOURNAL%.md") ~= nil
end

--- The report for a transcript's text, one line per fact, given the
--- arena and repository as absolute paths.
function Summarize.report(transcript: string, arena: string, repo: string): string
  local calls: {Call} = {}
  local results: {string: Answer} = {}
  local result: {string: any} = nil
  -- Lines end as Python's universal newlines end them.
  for line in transcript:gsub("\r\n?", "\n"):gmatch("[^\n]+") do
    local event = decode(line)
    if event is {string: any} then
      local kind = event["type"]
      local message = event["message"]
      local content: any = message is {string: any} and message["content"] or nil
      if kind == "assistant" and content is {any} then
        for _, part in ipairs(content) do
          if part is {string: any} and part["type"] == "tool_use" then
            local input = part["input"]
            -- Input too deep to encode is given as nothing.
            local given, _ = Json.encode(input, { max_depth = max_depth })
            calls[#calls + 1] = {
              id = id_key(part["id"]),
              name = as_text(part["name"]),
              given = given or "",
              input = input is {string: any} and input or {},
            }
          end
        end
      elseif kind == "user" and content is {any} then
        for _, part in ipairs(content) do
          if part is {string: any} and part["type"] == "tool_result" then
            local body = part["content"]
            local text: string
            if body is {any} then
              local pieces: {string} = {}
              for _, piece in ipairs(body) do
                pieces[#pieces + 1] = piece is {string: any} and as_text(piece["text"]) or ""
              end
              text = table.concat(pieces, "\n")
            else
              text = as_text(body)
            end
            results[id_key(part["tool_use_id"])] = {
              error = truthy(part["is_error"]),
              text = text,
            }
          end
        end
      elseif kind == "result" then
        result = event
      end
    end
  end

  local failed, docs_misses, journal_writes = 0, 0, 0
  local first_green: integer = nil
  local breach: {string: boolean} = {}
  local sandbox_tmp: {string: boolean} = {}
  local outside: {string: boolean} = {}
  local tainted: {string: boolean} = {}
  for index, call in ipairs(calls) do
    local answer = results[call.id]
    local text = answer ~= nil and answer.text or ""
    if answer ~= nil and answer.error then
      failed = failed + 1
    end
    docs_misses = docs_misses + count(text, "No exact symbol match") + count(text, "docs: FAIL")
    if first_green == nil and call.name == "Bash" and answer ~= nil and
        not answer.error and ("\n" .. text):find("\ntest: PASS", 1, true) then
      -- A command that holds the line itself (an echo, a heredoc, a
      -- script) may have printed it.
      local command = as_text(call.input["command"])
      if runs_cosmic_test(command, false) and not command:find("test: PASS", 1, true) then
        first_green = index
      end
    end
    if writes_journal(call) then
      journal_writes = journal_writes + 1
    end
    -- Where the call acts, not what it writes: a file's own contents
    -- would otherwise count every path its prose mentions.
    for _, path in ipairs(Summarize.paths(call.name, call.input, arena .. "/project")) do
      local tier = tier_of(path, arena, repo)
      if tier == "breach" then
        breach[path] = true
      elseif tier == "tmp" then
        sandbox_tmp[path] = true
      elseif tier == "outside" then
        outside[path] = true
      end
    end
    for _, mark in ipairs({ repo, ".claude/skills", ".claude/plugins" }) do
      if call.given:find(mark, 1, true) then
        tainted[mark] = true
      end
    end
  end

  local out: {string} = {}
  if result ~= nil then
    local turns = result["num_turns"]
    local ms = result["duration_ms"]
    local cost = result["total_cost_usd"]
    out[#out + 1] = string.format("turns=%s tools=%d minutes=%.1f cost=$%.2f",
      turns == nil and "null" or as_text(turns), #calls,
      (ms is number and ms or 0) / 60000, cost is number and cost or 0)
  else
    out[#out + 1] = string.format(
      "turns=null tools=%d minutes=null cost=null (no result event: timed out?)", #calls)
  end
  out[#out + 1] = string.format(
    "failed_calls=%d docs_misses=%d first_green_test_call=%s journal_writes=%d",
    failed, docs_misses, first_green == nil and "null" or tostring(first_green),
    journal_writes)
  local function sorted(set: {string: boolean}): {string}
    local list: {string} = {}
    for key in pairs(set) do
      list[#list + 1] = key
    end
    table.sort(list)
    return list
  end
  for _, path in ipairs(sorted(breach)) do
    out[#out + 1] = "BREACH: " .. path
  end
  local tmp_count = #sorted(sandbox_tmp)
  if tmp_count > 0 then
    out[#out + 1] = "sandbox-tmp: " .. tmp_count
  end
  for _, path in ipairs(sorted(outside)) do
    out[#out + 1] = "outside-arena: " .. path
  end
  for _, mark in ipairs(sorted(tainted)) do
    out[#out + 1] = "CONTAMINATION: a tool call named " .. mark
  end
  return table.concat(out, "\n") .. "\n"
end

local function complain(message: string)
  local _, _ = Fs.put(Fs.stderr, "eval/summarize: " .. message .. "\n")
end

function Summarize.main(argv: {integer: string}): integer
  local transcript = argv[1]
  if transcript == nil or argv[2] ~= nil then
    local _, _ = Fs.put(Fs.stderr, "usage: eval/summarize <transcript.jsonl>\n")
    return 2
  end
  local script, strouble = Fs.absolute(argv[0])
  if script == nil then
    complain(strouble)
    return 2
  end
  local repo = script:match("^(.*)/eval/[^/]+%.tl$")
  if repo == nil then
    complain(argv[0] .. ": expected to run as .../eval/summarize.tl")
    return 2
  end
  local parent = transcript:match("^(.*)/[^/]*$") or "."
  local arena, atrouble = Fs.absolute(parent == "" and "/" or parent)
  if arena == nil then
    complain(atrouble)
    return 2
  end
  local text, trouble = Fs.read(transcript)
  if text == nil then
    complain(trouble)
    return 1
  end
  local _, _ = Fs.put(Fs.stdout, Summarize.report(text, arena, repo))
  return 0
end

return Summarize

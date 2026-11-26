--- `cosmic profile`: reads the profiles a run with `COSMIC_PROFILE=<dir>` wrote (core/profile.h: one file a
--- process, `<dir>/<pid>.prof`) and prints where their time went: the spans, the functions by their own time and by
--- time in their stack, the lines, the processes, or folded stacks for a flame graph tool. It only reads.
---
--- [`verb.read`] reads one file's text into a [`verb.Process`]; [`verb.report`] adds processes up and prints them.
--- An empty file is a process a signal killed, which wrote nothing: it is counted and left out.
---
--- Like `cosmic json` it prints no summary: its standard output is the report. Exit 0 is ok, 2 a command line it
--- refuses, 5 a file it cannot read, one that is not a profile, or a write that failed. Complaints go to standard
--- error as `cosmic: profile: ...`. Its `spec` (build/verb_spec.tl) is `bare`.

local Verb = require("cosmic.cli.profile")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local bare = require("build.bare")
local verb_spec = require("build.verb_spec")

--- The `cosmic profile` verb: `run` is what [`build/dispatch.tl`] calls.
local record verb
  --- The verb's registration: see build/verb_spec.tl.
  mut spec: verb_spec.Spec

  --- One `sample` line: the frames from the outermost (the spans open first, each `[name]`), the innermost Lua
  --- line, and the microseconds it stood for.
  record Sample
    frames: {string}
    line: string
    us: integer
  end

  --- One `span` line: the path of names (`[outer];[inner]`), how many spans of that path closed, their wall
  --- and CPU nanoseconds, and the most the Lua heap held, in KB, as one closed.
  record Span
    path: string
    count: integer
    wall_ns: integer
    cpu_ns: integer
    heap_kb: integer
  end

  --- What one process's profile holds.
  record Process
    pid: integer
    parent: integer
    clock: string
    hz: integer
    command: string
    wall_ns: integer
    cpu_ns: integer
    sampled_us: integer
    dropped_us: integer
    other_us: integer
    peak_rss_kb: integer
    spans: {Span}
    samples: {Sample}
  end

  --- What a report prints: one list (`by`), all of them (nil), or folded stacks.
  --- The one list `--by` asks for.
  enum By
    "function"
    "stack"
    "line"
    "span"
    "process"
    "require"
  end

  record Options
    by?: By
    top: integer
    folded: boolean
  end

  --- Where `run` reads and writes: what a test stands in for.
  record Io
    --- Writes to standard output, as given. False and why when the bytes did not all go.
    out: function(text: string): boolean, string
    --- Writes one complaint line, without its newline.
    err: function(line: string)
    --- Reads a file whole, "-" being standard input: [`Flags.read`].
    read: function(path: string): string?, string
    --- The names in a directory, sorted, or nil when the path is no directory.
    list: function(path: string): {string}?
  end
end

local usage <const> = Flags.usage(Verb, "cosmic profile")
local spec = assert(Verb.spec, "profile has options")

--- Each `--by` word as its list.
local BYS <const>: {string: verb.By} = {
  ["function"] = "function", stack = "stack", line = "line", span = "span", process = "process", require = "require",
}

--- `text` as a whole number, or nil.
local function whole(text: string?): integer?
  if text == nil then return nil end
  return math.tointeger(tonumber(text))
end

--- The process the profile `text` holds, or nil and why it is not one. `name` names it in the why.
function verb.read(text: string, name: string): verb.Process?, string
  if text:sub(1, 17) ~= "cosmic-profile 1\n" then
    return nil, name .. ": not a profile (no `cosmic-profile 1` line first)"
  end
  local pid, parent, hz, wall_ns, cpu_ns, sampled_us, dropped_us, other_us = 0, 0, 0, 0, 0, 0, 0, 0
  local peak_rss_kb = 0
  local clock, command = "cpu", ""
  local spans: mut {verb.Span} = {}
  local samples: mut {verb.Sample} = {}
  local seen_process = false
  for line in text:gmatch("[^\n]+") do
    local word = line:match("^(%S+)")
    if word == "process" then
      local p, up, c, rate = line:match("^process (%d+) parent (%d+) clock (%a+) hz (%d+)$")
      if p == nil then return nil, name .. ": a process line it cannot read: " .. line end
      pid, parent, clock, hz = whole(p) or 0, whole(up) or 0, c or "cpu", whole(rate) or 0
      seen_process = true
    elseif word == "command" then
      command = line:sub(9)
    elseif word == "total" then
      local wall, cpu, sampled, dropped, other, rss = line:match(
        "^total wall_ns (%d+) cpu_ns (%d+) sampled_us (%d+) dropped_us (%d+) other_us (%d+) peak_rss_kb (%d+)$")
      if wall == nil then return nil, name .. ": a total line it cannot read: " .. line end
      wall_ns, cpu_ns, sampled_us = whole(wall) or 0, whole(cpu) or 0, whole(sampled) or 0
      dropped_us, other_us, peak_rss_kb = whole(dropped) or 0, whole(other) or 0, whole(rss) or 0
    elseif word == "span" then
      local path, count, wall, cpu, heap = line:match("^span (%S+) (%d+) (%d+) (%d+) (%d+)$")
      if path == nil then return nil, name .. ": a span line it cannot read: " .. line end
      spans[#spans + 1] = { path = path, count = whole(count) or 0, wall_ns = whole(wall) or 0,
        cpu_ns = whole(cpu) or 0, heap_kb = whole(heap) or 0 }
    elseif word == "sample" then
      local stack, at, us = line:match("^sample (%S+) (%S+) (%d+)$")
      if stack == nil or at == nil then
        return nil, name .. ": a sample line it cannot read: " .. line
      end
      local frames: mut {string} = {}
      -- A sample with no frame at all writes `-` in their place.
      if stack ~= "-" then
        for frame in stack:gmatch("[^;]+") do frames[#frames + 1] = frame end
      end
      samples[#samples + 1] = { frames = frames, line = at, us = whole(us) or 0 }
    end
  end
  if not seen_process then return nil, name .. ": not a profile (no process line)" end
  return { pid = pid, parent = parent, clock = clock, hz = hz, command = command, wall_ns = wall_ns,
    cpu_ns = cpu_ns, sampled_us = sampled_us, dropped_us = dropped_us, other_us = other_us,
    peak_rss_kb = peak_rss_kb, spans = spans, samples = samples }, ""
end

--- Milliseconds of `ns` nanoseconds, as text.
local function ms_of_ns(ns: integer): string
  return ("%.1f ms"):format(ns / 1000000)
end

--- Milliseconds of `us` microseconds, as text.
local function ms_of_us(us: integer): string
  return ("%.1f ms"):format(us / 1000)
end

--- What a sample with no frame is charged to.
local NO_FRAME <const> = "(no frame)"

--- Whether a frame is a span's (`[name]`) and not a function's.
local function is_span(frame: string): boolean
  return frame:sub(1, 1) == "["
end

--- The `top` names of `weights` with the most weight, then by name, as lines of a list headed `label`, each with
--- its share of `total` microseconds.
local function ranked(weights: {string: integer}, label: string, total: integer, top: integer): {string}
  local names: mut {string} = {}
  for name in pairs(weights) do names[#names + 1] = name end
  table.sort(names, function(a: string, b: string): boolean
    local x, y = weights[a] or 0, weights[b] or 0
    if x ~= y then return x > y end
    return a < b
  end)
  local out: mut {string} = { ("%s, of %s sampled:"):format(label, ms_of_us(total)) }
  for n = 1, math.min(top, #names) do
    local name = names[n] or ""
    local us = weights[name] or 0
    out[#out + 1] = ("%6.2f%% %12s  %s"):format(100 * us / math.max(total, 1), ms_of_us(us), name)
  end
  return out
end

--- The spans of `processes`, added up by path, each under the span it stood in, in the order they first appear.
--- The module a span path's own span loaded (`...;[require:cosmic.json]` is cosmic.json), or nil for a span of
--- another kind.
function verb.module_of(path: string): string?
  return path:match("%[require:([^%]]+)%]$")
end

--- The modules `processes` loaded from the store, as a set: each one's `[require:<module>]` span.
function verb.loaded(processes: {verb.Process}): {string: boolean}
  local out: mut {string: boolean} = {}
  for _, p in ipairs(processes) do
    for _, s in ipairs(p.spans) do
      local module = verb.module_of(s.path)
      if module ~= nil then out[module] = true end
    end
  end
  return out
end

--- The lines of the modules list: each module `processes` loaded, by the most wall time its loads took, what it
--- required in them included.
local function require_lines(processes: {verb.Process}, top: integer): {string}
  local wall: mut {string: integer} = {}
  local cpu: mut {string: integer} = {}
  local names: mut {string} = {}
  for _, p in ipairs(processes) do
    for _, s in ipairs(p.spans) do
      local module = verb.module_of(s.path)
      if module ~= nil then
        if wall[module] == nil then names[#names + 1] = module end
        wall[module] = (wall[module] or 0) + s.wall_ns
        cpu[module] = (cpu[module] or 0) + s.cpu_ns
      end
    end
  end
  table.sort(names, function(a: string, b: string): boolean
    local x, y = wall[a] or 0, wall[b] or 0
    if x ~= y then return x > y end
    return a < b
  end)
  local out: mut {string} = { ("modules loaded (%d; wall, cpu, with what each required):"):format(#names) }
  for n = 1, math.min(top, #names) do
    local name = names[n] or ""
    out[#out + 1] = ("  %12s  %12s  %s"):format(ms_of_ns(wall[name] or 0), ms_of_ns(cpu[name] or 0), name)
  end
  return out
end

local function span_lines(processes: {verb.Process}, requires: boolean): {string}
  local order: mut {string} = {}
  local totals: mut {string: verb.Span} = {}
  for _, p in ipairs(processes) do
    for _, s in ipairs(p.spans) do
      local t = totals[s.path]
      if not requires and verb.module_of(s.path) ~= nil then
        -- A module's load, which `--by require` lists.
      elseif t == nil then
        order[#order + 1] = s.path
        totals[s.path] = { path = s.path, count = s.count, wall_ns = s.wall_ns, cpu_ns = s.cpu_ns,
          heap_kb = s.heap_kb }
      else
        totals[s.path] = { path = s.path, count = t.count + s.count, wall_ns = t.wall_ns + s.wall_ns,
          cpu_ns = t.cpu_ns + s.cpu_ns, heap_kb = math.max(t.heap_kb, s.heap_kb) }
      end
    end
  end
  if #order == 0 then return { "spans: none (the run marked no Clock.span or Clock.phase)" } end
  -- A parent's path is a prefix of its children's: sorting by the order of each prefix keeps a child under it.
  -- Each prefix is numbered where it is first seen, a parent written by no line (a fork's child's file) too.
  local first: mut {string: integer} = {}
  local seen = 0
  for _, path in ipairs(order) do
    local prefix = ""
    for name in path:gmatch("[^;]+") do
      prefix = if prefix == "" then name else prefix .. ";" .. name end
      if first[prefix] == nil then
        seen = seen + 1
        first[prefix] = seen
      end
    end
  end
  local function key(path: string): {integer}
    local k: mut {integer} = {}
    local prefix = ""
    for name in path:gmatch("[^;]+") do
      prefix = if prefix == "" then name else prefix .. ";" .. name end
      k[#k + 1] = first[prefix] or 0
    end
    return k
  end
  local keys: mut {string: {integer}} = {}
  for _, path in ipairs(order) do keys[path] = key(path) end
  table.sort(order, function(a: string, b: string): boolean
    local x, y = keys[a] or {}, keys[b] or {}
    for n = 1, math.max(#x, #y) do
      local i, j = x[n] or -1, y[n] or -1
      if i ~= j then return i < j end
    end
    return false
  end)
  local out: mut {string} = { "spans (count, wall, cpu, most heap at a close):" }
  for _, path in ipairs(order) do
    local t = assert(totals[path])
    local _, depth = path:gsub(";", "")
    out[#out + 1] = ("%s%s  %d  %s  %s  %s"):format(("  "):rep(depth + 1), path:match("([^;]+)$") or path, t.count,
      ms_of_ns(t.wall_ns), ms_of_ns(t.cpu_ns), ("%.1f MB"):format(t.heap_kb / 1024))
  end
  return out
end

--- The lines of the processes list: each process, by most CPU time first.
local function process_lines(processes: {verb.Process}, top: integer): {string}
  local sorted: mut {verb.Process} = {}
  for _, p in ipairs(processes) do sorted[#sorted + 1] = p end
  table.sort(sorted, function(a: verb.Process, b: verb.Process): boolean
    if a.cpu_ns ~= b.cpu_ns then return a.cpu_ns > b.cpu_ns end
    return a.pid < b.pid
  end)
  local out: mut {string} = { "processes (pid, parent, cpu, sampled, peak resident set, command):" }
  for n = 1, math.min(top, #sorted) do
    local p = assert(sorted[n])
    out[#out + 1] = ("  %d  %d  %s  %s  %.1f MB  %s"):format(p.pid, p.parent, ms_of_ns(p.cpu_ns),
      ms_of_us(p.sampled_us), p.peak_rss_kb / 1024, p.command)
  end
  return out
end

--- The report of `processes` that `options` asks for, as text; `empty` is how many files were empty.
function verb.report(processes: {verb.Process}, options: verb.Options, empty?: integer): string
  local own: mut {string: integer} = {}
  local within: mut {string: integer} = {}
  local lines: mut {string: integer} = {}
  local folded: mut {string: integer} = {}
  local folded_order: mut {string} = {}
  local total = 0
  for _, p in ipairs(processes) do
    for _, s in ipairs(p.samples) do
      total = total + s.us
      lines[s.line] = (lines[s.line] or 0) + s.us
      local seen: mut {string: boolean} = {}
      local last = NO_FRAME
      for _, frame in ipairs(s.frames) do
        if not is_span(frame) then
          if seen[frame] == nil then
            seen[frame] = true
            within[frame] = (within[frame] or 0) + s.us
          end
          last = frame
        end
      end
      own[last] = (own[last] or 0) + s.us
      if options.folded then
        local stack = if #s.frames == 0 then NO_FRAME else table.concat(s.frames, ";") end
        if folded[stack] == nil then folded_order[#folded_order + 1] = stack end
        folded[stack] = (folded[stack] or 0) + s.us
      end
    end
  end
  if options.folded then
    local out: mut {string} = {}
    for _, stack in ipairs(folded_order) do
      out[#out + 1] = ("%s %d"):format(stack, folded[stack] or 0)
    end
    if #out == 0 then return "" end
    return table.concat(out, "\n") .. "\n"
  end
  local top = options.top
  local parts: mut {{string}} = {}
  local by = options.by
  if by == "function" then
    parts[1] = ranked(own, "own time", total, top)
  elseif by == "stack" then
    parts[1] = ranked(within, "in the stack", total, top)
  elseif by == "line" then
    parts[1] = ranked(lines, "lines", total, top)
  elseif by == "span" then
    parts[1] = span_lines(processes, true)
  elseif by == "require" then
    parts[1] = require_lines(processes, top)
  elseif by == "process" then
    parts[1] = process_lines(processes, top)
  else
    local cpu, wall, sampled, dropped, rss = 0, 0, 0, 0, 0
    local clocks: mut {string: boolean} = {}
    for _, p in ipairs(processes) do
      cpu = cpu + p.cpu_ns
      if p.peak_rss_kb > rss then rss = p.peak_rss_kb end
      if p.wall_ns > wall then wall = p.wall_ns end
      sampled = sampled + p.sampled_us
      dropped = dropped + p.dropped_us
      clocks[p.clock] = true
    end
    local names: mut {string} = {}
    for clock in pairs(clocks) do names[#names + 1] = clock end
    table.sort(names)
    local head = ("%d %s, %s cpu, %s sampled on the %s clock, the longest %s wall"):format(#processes,
      if #processes == 1 then "process" else "processes" end, ms_of_ns(cpu), ms_of_us(sampled),
      table.concat(names, " and "), ms_of_ns(wall)) .. (", the largest peak resident set %.1f MB"):format(rss / 1024)
    if dropped > 0 then
      head = head .. (", %s dropped (no room in the tables)"):format(ms_of_us(dropped))
    end
    if (empty or 0) > 0 then
      head = head .. (", %d empty (killed by a signal)"):format(empty or 0)
    end
    parts[1] = { head }
    parts[#parts + 1] = span_lines(processes, false)
    parts[#parts + 1] = ranked(own, "own time", total, top)
    parts[#parts + 1] = ranked(within, "in the stack", total, top)
  end
  local out: mut {string} = {}
  for _, part in ipairs(parts) do out[#out + 1] = table.concat(part, "\n") end
  return table.concat(out, "\n\n") .. "\n"
end

local standard: verb.Io = {
  out = bare.out,
  err = bare.err,
  read = function(path: string): string?, string
    local text, why = Flags.read(path)
    if text == nil then return nil, why end
    return text, ""
  end,
  list = function(path: string): {string}?
    local status, _ = Fs.status(path)
    if status == nil or not status.is_dir then return nil end
    local names, _ = Fs.list(path)
    return names
  end,
}

--- `cosmic profile [options] <dir|file|->...`: prints the report of the profiles named, and returns the exit code:
--- 0 ok, 2 a command line it refuses, 5 a file it cannot read or that is not a profile, or a write that failed.
--- @param argv the command line, `profile` at slot 1
--- @param io where it reads and writes; the process's own when nil
function verb.run(argv: {string}, io?: verb.Io): integer
  local to = io or standard
  local complain = bare.complainer("profile", to.err)
  local parsed, trouble = Flags.parse(argv, 2, spec)
  if parsed == nil then
    complain(trouble .. "; " .. usage)
    return bare.refused
  end
  if #parsed.words == 0 then
    complain("name a profile directory, a file, or - for standard input; " .. usage)
    return bare.refused
  end
  if parsed.set["--folded"] == true and parsed.values["--by"] ~= nil then
    complain("--folded prints stacks alone, not --by; " .. usage)
    return bare.refused
  end
  local files: mut {string} = {}
  for _, word in ipairs(parsed.words) do
    if word == "" then
      complain(bare.empty_file .. "; " .. usage)
      return bare.refused
    end
    local names = if word == "-" then nil else to.list(word) end
    if names == nil then
      files[#files + 1] = word
    else
      for _, name in ipairs(names) do
        if name:match("%.prof$") ~= nil then files[#files + 1] = word .. "/" .. name end
      end
    end
  end
  local only = parsed.integers["--process"]
  local processes: mut {verb.Process} = {}
  local empty = 0
  for _, file in ipairs(files) do
    local text, why = to.read(file)
    if text == nil then
      complain(why)
      return bare.undone
    end
    if text == "" then
      empty = empty + 1
    else
      local p, read_why = verb.read(text, file)
      if p == nil then
        complain(read_why)
        return bare.undone
      end
      if only == nil or p.pid == only then processes[#processes + 1] = p end
    end
  end
  if #processes == 0 then
    complain(if only ~= nil then ("no profile of process %d"):format(only)
      else "no profile in " .. table.concat(parsed.words, ", ") end)
    return bare.undone
  end
  local report = verb.report(processes, { by = BYS[parsed.values["--by"] or ""], top = parsed.integers["--top"] or 25,
    folded = parsed.set["--folded"] == true }, empty)
  return bare.written(complain, to.out(report))
end

--- The `profile` verb as [`build/verb_list.tl`] lists it. It reads no tree, so it is never stale-checked.
verb.spec = {
  name = "profile",
  guide = "more quick tools",
  tests = { "build.profile_test", "build.profile_tool_test" },
  run = function(argv: {string}): integer return verb.run(argv) end,
  bare = true,
  takes = "options and the profile directories or files",
  exits = "`profile` prints its report and nothing after; it exits 2 when it refuses its command line, 5 when it cannot read a file, a file is not a profile, or a write fails.",
  passthrough = "it reads profiles a profiled run wrote, so its exit status is the verdict (build/profile_test.tl)",
}

return verb

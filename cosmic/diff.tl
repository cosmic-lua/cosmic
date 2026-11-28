--- Line diffs of two texts, as hunks and as unified diff text.
---
---     local hunks = Diff.lines("a\nb\nc\n", "a\nB\nc\n")
---     -- one hunk: -1,3 +1,3, lines " a", "-b", "+B", " c"
---     local text = Diff.unified(hunks, { old_name = "a/f.txt", new_name = "b/f.txt" })
---     -- "--- a/f.txt\n+++ b/f.txt\n@@ -1,3 +1,3 @@\n a\n-b\n+B\n c\n"
---
--- The script is a shortest one (Myers, in linear space) unless the texts
--- share so little that finding it would take long: after `opts.cost`
--- passes (200 unless given) a part of the work is split at the furthest
--- point reached, as GNU diff and git's xdiff do. That keeps unrelated
--- texts of 20,000 mostly distinct lines to about 100 milliseconds, at the price of a few
--- percent more changed lines than the shortest script.
---
--- A line is its bytes up to and including `\n`; a last line with no `\n`
--- differs from the same line with one, and is shown as `\ No newline at
--- end of file`. A `\r` is part of a line.

local Failure = require("cosmic.failure")

local record Diff
  --- What a line of a hunk does.
  enum Op
    --- A line both texts hold.
    "context"
    --- A line only the new text holds.
    "add"
    --- A line only the old text holds.
    "del"
  end

  --- One line of a hunk.
  record Line
    --- What the line does.
    op: Op
    --- The line's bytes without its `\n`.
    text: string
    --- True for the last line of a text that does not end in `\n`.
    no_newline?: boolean
  end

  --- A run of changes with the lines around them. `old_start` and `new_start` count from 1; for a hunk that holds
  --- no old (new) line the start is the line before it, as unified diff writes it.
  record Hunk
    --- The first old line the hunk covers.
    old_start: integer
    --- How many old lines it covers: its context and deleted lines.
    old_count: integer
    --- The first new line the hunk covers.
    new_start: integer
    --- How many new lines it covers: its context and added lines.
    new_count: integer
    --- Its lines in order.
    lines: {Line}
  end

  --- What [`Diff.lines`] takes.
  record Options
    --- Context lines around each change, 3 unless given. A hunk is split where more than twice this many lines
    --- stay the same.
    context?: integer
    --- Passes of the search before a part is split at the furthest point reached, 200 unless given. A larger
    --- number is nearer the shortest script and slower on texts that share little.
    cost?: integer
  end

  --- What [`Diff.unified`] takes.
  record Names
    --- The name after `---`, `a` unless given.
    old_name?: string
    --- The name after `+++`, `b` unless given.
    new_name?: string
  end
  --- How a file changes, as the patch names it.
  enum Kind
    --- The file is in place before and after.
    "modify"
    --- The file is new: the old side is `/dev/null`.
    "create"
    --- The file goes: the new side is `/dev/null`.
    "delete"
    --- The file moves, with or without edits (git's `rename from` and `rename to`).
    "rename"
    --- The file is copied, with or without edits (git's `copy from` and `copy to`).
    "copy"
  end

  --- The changes a patch makes to one path, as [`Diff.parse`] gives them.
  record Entry
    --- How the file changes.
    kind: Kind
    --- The name before, nil for a new file.
    old_name?: string
    --- The name after, nil for a deleted file.
    new_name?: string
    --- The mode before, as written (`100644`), when the patch gives one.
    old_mode?: string
    --- The mode after, as written, when the patch gives one.
    new_mode?: string
    --- The hunks, none for a pure rename or mode change.
    hunks: {Hunk}
  end

  --- What [`Diff.parse`] takes.
  record ParseOptions
    --- Leading path components to drop from each name, as `patch -p` does: 1 turns `a/f.txt` into `f.txt`. 0
    --- unless given.
    strip?: integer
  end

  --- What [`Diff.apply`] takes.
  record ApplyOptions
    --- Context lines at each end of a hunk that may differ, 0 unless given. Most is 2, as in GNU patch.
    fuzz?: integer
    --- Undo the hunks instead of doing them.
    reverse?: boolean
  end

  --- A hunk [`Diff.apply`] placed.
  record Placed
    --- Which hunk, from 1.
    index: integer
    --- How many lines from where its header says it sits: positive is later in the text.
    offset: integer
    --- How many context lines at each end it took to match, 0 for an exact match.
    fuzz: integer
  end

  --- A hunk [`Diff.apply`] could not place.
  record Reject
    --- Which hunk, from 1.
    index: integer
    --- The hunk, as given (before any reversal).
    hunk: Hunk
    --- Why, in words.
    message: string
  end

  --- What [`Diff.apply`] returns.
  record Applied
    --- The new text, nil when any hunk was rejected: a file changes whole or not at all.
    text?: string
    --- The hunks it placed, in order.
    placed: {Placed}
    --- The hunks it could not place, in order.
    rejects: {Reject}
  end
end

--- A hunk being built.
local record Open
  mut old_start: integer
  mut old_count: integer
  mut new_start: integer
  mut new_count: integer
  lines: mut {Diff.Line}
end

--- A file being read by [`Diff.parse`].
local record Draft
  mut kind: Diff.Kind
  mut old_name: string?
  mut new_name: string?
  mut old_mode: string?
  mut new_mode: string?
  hunks: mut {Diff.Hunk}
end

local DEFAULT_CONTEXT <const> = 3
local DEFAULT_COST <const> = 200

--- `text` as lines with their `\n` kept, and whether the last had none.
local function split(text: string): ({string}, boolean)
  local out: mut {string} = {}
  local at = 1
  local n = #text
  while at <= n do
    local stop = text:find("\n", at, true)
    if stop == nil then
      out[#out + 1] = text:sub(at)
      return out, true
    end
    out[#out + 1] = text:sub(at, stop)
    at = stop + 1
  end
  return out, false
end

--- The integer behind each line of `a` and of `b`, equal for equal lines.
local function numbered(a: {string}, b: {string}): ({integer}, {integer})
  local seen: mut {string: integer} = {}
  local next_id = 0
  local function id(line: string): integer
    local known = seen[line]
    if known ~= nil then return known end
    next_id = next_id + 1
    seen[line] = next_id
    return next_id
  end
  local x: mut {integer} = {}
  local y: mut {integer} = {}
  for i, line in ipairs(a) do x[i] = id(line) end
  for j, line in ipairs(b) do y[j] = id(line) end
  return x, y
end

--- Marks the lines of `x` and `y` that a diff of the two removes or adds, in `removed` and
--- `added`. The work runs on a list of parts instead of by recursion, so that texts that split badly cannot
--- exhaust the stack.
local function mark(x: {integer}, y: {integer}, cost: integer, removed: mut {integer: boolean},
                    added: mut {integer: boolean})
  local forward: mut {integer: integer} = {}
  local backward: mut {integer: integer} = {}
  for i = 1, #x + #y + 3 do
    forward[i] = 0
    backward[i] = 0
  end
  local parts: mut {{integer}} = { { 0, #x, 0, #y } }
  while #parts > 0 do
    local part = assert(table.remove(parts))
    local a0, a1, b0, b1 = part[1] or 0, part[2] or 0, part[3] or 0, part[4] or 0
    while a0 < a1 and b0 < b1 and x[a0 + 1] == y[b0 + 1] do
      a0, b0 = a0 + 1, b0 + 1
    end
    while a0 < a1 and b0 < b1 and x[a1] == y[b1] do
      a1, b1 = a1 - 1, b1 - 1
    end
    if a0 == a1 then
      for j = b0 + 1, b1 do added[j] = true end
    elseif b0 == b1 then
      for i = a0 + 1, a1 do removed[i] = true end
    else
      local n, m = a1 - a0, b1 - b0
      local delta = n - m
      local odd = delta % 2 ~= 0
      local reach = (n + m + 1) // 2
      local off = reach + 2
      forward[off + 1] = 0
      backward[off + 1] = 0
      local px, py = -1, -1
      local d = 0
      while d <= reach and px < 0 do
        if d > cost then
          -- Give up on the shortest script: split at the furthest point the forward search reached.
          local best = -1
          for k = -(d - 1), d - 1, 2 do
            local fx = forward[off + k] or 0
            if fx + (fx - k) > best and fx <= n and fx - k <= m and fx - k >= 0 then
              best = fx + (fx - k)
              px, py = fx, fx - k
            end
          end
          if px < 0 then px, py = 0, 0 end
          break
        end
        for k = -d, d, 2 do
          local fx: integer
          if k == -d or (k ~= d and (forward[off + k - 1] or 0) < (forward[off + k + 1] or 0)) then
            fx = forward[off + k + 1] or 0
          else
            fx = (forward[off + k - 1] or 0) + 1
          end
          local fy = fx - k
          local sx, sy = fx, fy
          while fx < n and fy < m and x[a0 + fx + 1] == y[b0 + fy + 1] do
            fx, fy = fx + 1, fy + 1
          end
          forward[off + k] = fx
          if odd then
            local rk = delta - k
            if rk >= -(d - 1) and rk <= d - 1 and (backward[off + rk] or 0) + fx >= n then
              px, py = sx, sy
              break
            end
          end
        end
        if px < 0 then
          for k = -d, d, 2 do
            local bx: integer
            if k == -d or (k ~= d and (backward[off + k - 1] or 0) < (backward[off + k + 1] or 0)) then
              bx = backward[off + k + 1] or 0
            else
              bx = (backward[off + k - 1] or 0) + 1
            end
            local by = bx - k
            while bx < n and by < m and x[a1 - bx] == y[b1 - by] do
              bx, by = bx + 1, by + 1
            end
            backward[off + k] = bx
            if not odd then
              local fk = delta - k
              if fk >= -d and fk <= d and (forward[off + fk] or 0) + bx >= n then
                px, py = n - bx, m - by
                break
              end
            end
          end
        end
        d = d + 1
      end
      if px <= 0 and py <= 0 or px >= n and py >= m or px < 0 then
        -- No split that makes both halves smaller: the part is all change.
        for i = a0 + 1, a1 do removed[i] = true end
        for j = b0 + 1, b1 do added[j] = true end
      else
        parts[#parts + 1] = { a0, a0 + px, b0, b0 + py }
        parts[#parts + 1] = { a0 + px, a1, b0 + py, b1 }
      end
    end
  end
end

--- The hunks that turn `old` into `new`, none where they are equal. `opts` is [`Diff.Options`].
---
---     local hunks = Diff.lines("one\ntwo\n", "one\n2\n")
---     -- hunks[1].lines: " one", "-two", "+2"
--- @param old string The text before
--- @param new string The text after
--- @param opts? Diff.Options Context lines and search cost
--- @return {Diff.Hunk} The hunks in order of position
function Diff.lines(old: string, new: string, opts?: Diff.Options): {Diff.Hunk}
  local context = (opts and opts.context) or DEFAULT_CONTEXT
  local cost = (opts and opts.cost) or DEFAULT_COST
  if context < 0 then error("diff: context is " .. tostring(context) .. ", below 0", 2) end
  if cost < 1 then error("diff: cost is " .. tostring(cost) .. ", below 1", 2) end
  local hunks: mut {Diff.Hunk} = {}
  if old == new then return hunks end
  local a, a_open = split(old)
  local b, b_open = split(new)
  -- More context than there are lines is the same as all of them, and `2 * context` cannot overflow.
  context = math.min(context, #a + #b)
  -- Lines keep their `\n`, so a last line with none differs from the same line with one.
  local x, y = numbered(a, b)
  -- A line the other text lacks is a change whatever else is chosen, so only the lines both texts hold are searched.
  local in_x: mut {integer: boolean} = {}
  local in_y: mut {integer: boolean} = {}
  for _, v in ipairs(x) do in_x[v] = true end
  for _, v in ipairs(y) do in_y[v] = true end
  local kept_x: mut {integer} = {}
  local at_x: mut {integer} = {}
  local removed: mut {integer: boolean} = {}
  for k, v in ipairs(x) do
    if in_y[v] == true then
      kept_x[#kept_x + 1] = v
      at_x[#at_x + 1] = k
    else
      removed[k] = true
    end
  end
  local kept_y: mut {integer} = {}
  local at_y: mut {integer} = {}
  local added: mut {integer: boolean} = {}
  for k, v in ipairs(y) do
    if in_x[v] == true then
      kept_y[#kept_y + 1] = v
      at_y[#at_y + 1] = k
    else
      added[k] = true
    end
  end
  local small_removed: mut {integer: boolean} = {}
  local small_added: mut {integer: boolean} = {}
  mark(kept_x, kept_y, cost, small_removed, small_added)
  for k, _ in pairs(small_removed) do removed[assert(at_x[k])] = true end
  for k, _ in pairs(small_added) do added[assert(at_y[k])] = true end
  -- Walk both texts in step: `i` and `j` are the next old and new line, `pending` the context seen since the
  -- last change.
  local i, j = 1, 1
  local current: Open? = nil
  local pending = 0
  local function line(op: Diff.Op, text: string, open: boolean): Diff.Line
    local piece = if open then text else text:sub(1, #text - 1) end
    return { op = op, text = piece, no_newline = if open then true else nil end }
  end
  local function take(h: Open, from: integer, upto: integer)
    for k = from, upto do
      local at = i - pending + k - 1
      local l = line("context", assert(a[at]), a_open and at == #a)
      h.lines[#h.lines + 1] = l
      h.old_count = h.old_count + 1
      h.new_count = h.new_count + 1
    end
  end
  local function close(h: Open)
    local old_start = if h.old_count == 0 then h.old_start - 1 else h.old_start end
    local new_start = if h.new_count == 0 then h.new_start - 1 else h.new_start end
    hunks[#hunks + 1] = { old_start = old_start, old_count = h.old_count, new_start = new_start,
      new_count = h.new_count, lines = h.lines }
  end
  -- The hunk a change at `(i, j)` joins: the open one when fewer than twice `context` lines separate them, else a
  -- new one that begins with the last `context` lines seen.
  local function changing(): Open
    local h = current
    if h ~= nil and pending <= 2 * context then
      take(h, 1, pending)
      pending = 0
      return h
    end
    if h ~= nil then
      take(h, 1, context)
      close(h)
    end
    local lead = math.min(pending, context)
    local opened: Open = { old_start = i - lead, old_count = 0, new_start = j - lead, new_count = 0, lines = {} }
    take(opened, pending - lead + 1, pending)
    current = opened
    pending = 0
    return opened
  end
  while i <= #a or j <= #b do
    if i <= #a and removed[i] == true then
      local h = changing()
      local l = line("del", assert(a[i]), a_open and i == #a)
      h.lines[#h.lines + 1] = l
      h.old_count = h.old_count + 1
      i = i + 1
    elseif j <= #b and added[j] == true then
      local h = changing()
      local l = line("add", assert(b[j]), b_open and j == #b)
      h.lines[#h.lines + 1] = l
      h.new_count = h.new_count + 1
      j = j + 1
    else
      pending = pending + 1
      i, j = i + 1, j + 1
    end
  end
  local last = current
  if last ~= nil then
    take(last, 1, math.min(pending, context))
    close(last)
  end
  return hunks
end

--- The range of a hunk header: `start`, then `,count` unless the count is 1.
local function range(start: integer, count: integer): string
  if count == 1 then return tostring(start) end
  return tostring(start) .. "," .. tostring(count)
end

--- `hunks` as unified diff text: the `---` and `+++` lines, then each hunk under its `@@` header. No hunks return
--- the empty string. `names` is [`Diff.Names`].
---
---     local text = Diff.unified(Diff.lines("a\n", "b\n"))
---     -- "--- a\n+++ b\n@@ -1 +1 @@\n-a\n+b\n"
--- @param hunks {Diff.Hunk} What [`Diff.lines`] returned
--- @param names? Diff.Names The two file names
--- @return string The diff, every line ending in `\n`
function Diff.unified(hunks: {Diff.Hunk}, names?: Diff.Names): string
  if #hunks == 0 then return "" end
  local out: mut {string} = {
    "--- " .. ((names and names.old_name) or "a") .. "\n",
    "+++ " .. ((names and names.new_name) or "b") .. "\n",
  }
  for _, h in ipairs(hunks) do
    out[#out + 1] = "@@ -" .. range(h.old_start, h.old_count) .. " +" .. range(h.new_start, h.new_count) .. " @@\n"
    for _, l in ipairs(h.lines) do
      local sign = if l.op == "add" then "+" elseif l.op == "del" then "-" else " " end
      out[#out + 1] = sign .. l.text .. "\n"
      if l.no_newline == true then out[#out + 1] = "\\ No newline at end of file\n" end
    end
  end
  return table.concat(out)
end

--- `hunks` as the patch that undoes them: added lines become deleted ones and the two ranges swap.
---
---     local back = Diff.reverse(Diff.lines("a\n", "b\n"))
---     -- one hunk: -1 +1, lines "-b", "+a"
--- @param hunks {Diff.Hunk} What [`Diff.lines`] or [`Diff.parse`] returned
--- @return {Diff.Hunk} The reversed hunks, in the same order
function Diff.reverse(hunks: {Diff.Hunk}): {Diff.Hunk}
  local out: mut {Diff.Hunk} = {}
  for _, h in ipairs(hunks) do
    local lines: mut {Diff.Line} = {}
    for _, l in ipairs(h.lines) do
      local op: Diff.Op = l.op
      if l.op == "add" then op = "del" elseif l.op == "del" then op = "add" end
      lines[#lines + 1] = { op = op, text = l.text, no_newline = l.no_newline }
    end
    out[#out + 1] = { old_start = h.new_start, old_count = h.new_count, new_start = h.old_start,
      new_count = h.old_count, lines = lines }
  end
  return out
end

--- The name in a `---` or `+++` line: the text up to a tab, `/dev/null` as nil, with `strip` leading components
--- dropped.
local function patch_name(rest: string, strip: integer): string?
  local name = rest:match("^([^\t]*)") or rest
  if name == "/dev/null" then return nil end
  for _ = 1, strip do
    local cut = name:find("/", 1, true)
    if cut == nil then break end
    name = name:sub(cut + 1)
  end
  return name
end

--- Whether a name is quoted, as git quotes a name with unusual bytes: not supported.
local function quoted(rest: string): boolean
  return rest:sub(1, 1) == "\"" or rest:find(" \"", 1, true) ~= nil
end

--- The patch in `text`: one [`Diff.Entry`] for each `---`/`+++` pair or `diff --git` header, in order. Reads
--- unified diff and git's extended headers (new and deleted files, renames, copies, modes). Text between files,
--- such as a commit message, is skipped. A hunk that does not match its counts, a binary patch, and a quoted file
--- name fail. `opts` is [`Diff.ParseOptions`].
---
---     local files = assert(Diff.parse("--- a/f\n+++ b/f\n@@ -1 +1 @@\n-x\n+y\n", { strip = 1 }))
---     -- files[1].new_name == "f", files[1].hunks[1].lines: "-x", "+y"
--- @param text string The patch
--- @param opts? Diff.ParseOptions Path components to drop
--- @return {Diff.Entry} The files in order
--- @return Failure Where the patch is wrong, with its line
function Diff.parse(text: string, opts?: Diff.ParseOptions): ({Diff.Entry}) | (nil, Failure)
  local strip = (opts and opts.strip) or 0
  if strip < 0 then error("diff: strip is " .. tostring(strip) .. ", below 0", 2) end
  local lines = split(text)
  local drafts: mut {Draft} = {}
  local current: Draft? = nil
  local at = 1
  local function start(): Draft
    local d: Draft = { kind = "modify", old_name = nil, new_name = nil, old_mode = nil, new_mode = nil, hunks = {} }
    drafts[#drafts + 1] = d
    current = d
    return d
  end
  local function bare(i: integer): string
    local l = assert(lines[i])
    if l:sub(-1) == "\n" then return l:sub(1, -2) end
    return l
  end
  -- A header line without its `\r`, for a patch written with CRLF line ends; a hunk line keeps its `\r`.
  local function head(i: integer): string
    local l = bare(i)
    if l:sub(-1) == "\r" then return l:sub(1, -2) end
    return l
  end
  local function count(n: string?): integer
    if n == nil or n == "" then return 1 end
    return math.tointeger(n) or 0
  end
  while at <= #lines do
    local line = head(at)
    if line:sub(1, 11) == "diff --git " then
      local d = start()
      -- `diff --git a/x b/x`: with equal halves the middle space splits them, else the ---/+++ lines name the files.
      local rest = line:sub(12)
      if quoted(rest) then return nil, Failure.at("a quoted file name is not supported", at) end
      local half = (#rest - 1) // 2
      if #rest % 2 == 1 and rest:sub(half + 1, half + 1) == " " and rest:sub(1, half) ~= "" then
        d.old_name, d.new_name = patch_name(rest:sub(1, half), strip), patch_name(rest:sub(half + 2), strip)
      end
      at = at + 1
    elseif line:sub(1, 4) == "--- " and at < #lines and head(at + 1):sub(1, 4) == "+++ " then
      local d = current
      if d == nil or #d.hunks > 0 then d = start() end
      if quoted(line:sub(5)) then
        return nil, Failure.at("a quoted file name is not supported", at)
      end
      if quoted(head(at + 1):sub(5)) then
        return nil, Failure.at("a quoted file name is not supported", at + 1)
      end
      local old, new = patch_name(line:sub(5), strip), patch_name(head(at + 1):sub(5), strip)
      d.old_name, d.new_name = old, new
      if old == nil and new ~= nil then
        d.kind = "create"
      elseif new == nil and old ~= nil then
        d.kind = "delete"
      end
      at = at + 2
    elseif line:sub(1, 3) == "@@ " then
      local d = current
      if d == nil then return nil, Failure.at("a hunk comes before any file", at) end
      local a, b, c, e = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
      if a == nil then return nil, Failure.at("a hunk header is not `@@ -a,b +c,d @@`", at) end
      local old_start, old_count = math.tointeger(a) or 0, count(b)
      local new_start, new_count = math.tointeger(c) or 0, count(e)
      local want_old, want_new = old_count, new_count
      local header_at = at
      local hlines: mut {Diff.Line} = {}
      at = at + 1
      while want_old > 0 or want_new > 0 do
        if at > #lines then
          return nil, Failure.at("the hunk ends before its counts do", header_at)
        end
        local l = bare(at)
        local sigil = l:sub(1, 1)
        local op: Diff.Op
        if sigil == " " or l == "" then
          op = "context"
          want_old, want_new = want_old - 1, want_new - 1
        elseif sigil == "-" then
          op = "del"
          want_old = want_old - 1
        elseif sigil == "+" then
          op = "add"
          want_new = want_new - 1
        else
          return nil, Failure.at("a hunk line starts with neither a space, `-` nor `+`", at)
        end
        if want_old < 0 or want_new < 0 then
          return nil, Failure.at("the hunk holds more lines than its counts", at)
        end
        at = at + 1
        local open = false
        while at <= #lines and bare(at):sub(1, 1) == "\\" do
          open = true
          at = at + 1
        end
        local made: Diff.Line = { op = op, text = l:sub(2), no_newline = if open then true else nil end }
        hlines[#hlines + 1] = made
      end
      d.hunks[#d.hunks + 1] = { old_start = old_start, old_count = old_count, new_start = new_start,
        new_count = new_count, lines = hlines }
      -- A line that reads as part of the hunk, after the lines its header counts, is a header that lies.
      if at <= #lines then
        local next_line = head(at)
        local sigil = next_line:sub(1, 1)
        local starts_file = next_line:sub(1, 4) == "--- " and at < #lines and head(at + 1):sub(1, 4) == "+++ "
        if (sigil == " " or sigil == "+" or sigil == "-") and not starts_file and next_line ~= "-- " then
          return nil, Failure.at("the hunk holds more lines than its counts", at)
        end
      end
    elseif line:sub(1, 13) == "Binary files " or line == "GIT binary patch" then
      return nil, Failure.at("a binary patch is not supported", at)
    else
      local d = current
      if d ~= nil and #d.hunks == 0 then
        local v = line:match("^new file mode (%d+)$")
        if v ~= nil then
          d.kind, d.new_mode, d.old_name = "create", v, nil
        end
        v = line:match("^deleted file mode (%d+)$")
        if v ~= nil then
          d.kind, d.old_mode, d.new_name = "delete", v, nil
        end
        v = line:match("^old mode (%d+)$")
        if v ~= nil then d.old_mode = v end
        v = line:match("^new mode (%d+)$")
        if v ~= nil then d.new_mode = v end
        -- Git writes these names with no `a/` or `b/`, so one component less is dropped.
        local keep = math.max(strip - 1, 0)
        for _, key in ipairs({ "rename from", "rename to", "copy from", "copy to" }) do
          local name = line:match("^" .. key .. " (.+)$")
          if name ~= nil then
            if quoted(name) then
              return nil, Failure.at("a quoted file name is not supported", at)
            end
            d.kind = if key:sub(1, 1) == "r" then "rename" else "copy" end
            if key:sub(-4) == "from" then
              d.old_name = patch_name(name, keep)
            else
              d.new_name = patch_name(name, keep)
            end
          end
        end
      end
      at = at + 1
    end
  end
  local files: mut {Diff.Entry} = {}
  for _, d in ipairs(drafts) do
    local file: Diff.Entry = { kind = d.kind, old_name = d.old_name, new_name = d.new_name, old_mode = d.old_mode,
      new_mode = d.new_mode, hunks = d.hunks }
    files[#files + 1] = file
  end
  return files
end

--- A hunk's old-side lines and new-side lines as text with their `\n`, and how many context lines open and close it.
local function sides(h: Diff.Hunk): ({string}, {string}, integer, integer)
  local olds: mut {string} = {}
  local news: mut {string} = {}
  local lead, trail = 0, 0
  local changed = false
  for _, l in ipairs(h.lines) do
    local text = if l.no_newline == true then l.text else l.text .. "\n" end
    if l.op ~= "add" then olds[#olds + 1] = text end
    if l.op ~= "del" then news[#news + 1] = text end
    if l.op == "context" then
      if changed then trail = trail + 1 else lead = lead + 1 end
    else
      changed = true
      trail = 0
    end
  end
  if not changed then return olds, news, lead, 0 end
  return olds, news, lead, trail
end

--- Whether the lines after the first `at` of `lines` are `want`.
local function matches(lines: {string}, at: integer, want: {string}, from: integer, upto: integer): boolean
  for k = from, upto do
    if lines[at + k - from + 1] ~= want[k] then return false end
  end
  return true
end

--- A placement [`Diff.apply`] found: the lines `at + 1` to `at + count` become `news`.
local record Spot
  at: integer
  count: integer
  news: {string}
end

--- `old` with `hunks` applied, or the hunks it could not place. Each hunk is looked for where its header says,
--- then at growing distances from there (after the last hunk it placed), and if `opts.fuzz` allows, again with that
--- many context lines at each end ignored. A file changes whole or not at all: with one reject, `text` is nil.
--- Matching is exact, so a line with no final newline differs from one with it. `opts` is [`Diff.ApplyOptions`].
---
---     local result = Diff.apply("a\nb\nc\n", Diff.lines("a\nb\nc\n", "a\nB\nc\n"))
---     -- result.text == "a\nB\nc\n"; result.placed[1].offset == 0
--- @param old string The text before
--- @param hunks {Diff.Hunk} What [`Diff.lines`] or [`Diff.parse`] gave, in order of position
--- @param opts? Diff.ApplyOptions Fuzz and reverse
--- @return Diff.Applied The new text, or what was placed and what was not
function Diff.apply(old: string, hunks: {Diff.Hunk}, opts?: Diff.ApplyOptions): Diff.Applied
  local max_fuzz = (opts and opts.fuzz) or 0
  if max_fuzz < 0 then error("diff: fuzz is " .. tostring(max_fuzz) .. ", below 0", 2) end
  local use = if opts ~= nil and opts.reverse == true then Diff.reverse(hunks) else hunks end
  local lines = split(old)
  local placed: mut {Diff.Placed} = {}
  local rejects: mut {Diff.Reject} = {}
  local spots: mut {Spot} = {}
  -- Lines before `floor` are taken by a hunk already placed; `shift` is how far the last hunk sat from its header.
  local floor, shift = 0, 0
  for index, h in ipairs(use) do
    local olds, news, lead, trail = sides(h)
    local found: Spot? = nil
    local found_offset, found_fuzz = 0, 0
    local fuzz = 0
    while found == nil and fuzz <= max_fuzz do
      local cut_lead, cut_trail = math.min(fuzz, lead), math.min(fuzz, trail)
      local from, upto = 1 + cut_lead, #olds - cut_trail
      local header = (if h.old_count > 0 then h.old_start - 1 else h.old_start end) + cut_lead
      local want = header + shift
      -- As GNU patch does: a hunk with less context before its change than after it sits at the start of the text,
      -- and one with less after than before sits at the end.
      local at_start = lead - cut_lead < trail - cut_trail
      local at_end = trail - cut_trail < lead - cut_lead
      local width = upto - from + 1
      local reach = #lines + #olds + 1
      local k = 0
      while found == nil and k <= reach do
        for _, sign in ipairs({ 1, -1 }) do
          local at = want + sign * k
          if found == nil and (k > 0 or sign == 1) and at >= floor and at + width <= #lines and
              (width > 0 or k == 0) and (not at_start or at == cut_lead) and
              (not at_end or at + width + cut_trail == #lines) and matches(lines, at, olds, from, upto) then
            local replacement: mut {string} = {}
            for n = 1 + cut_lead, #news - cut_trail do
              replacement[#replacement + 1] = assert(news[n])
            end
            found = { at = at, count = width, news = replacement }
            found_offset = at - header
            found_fuzz = fuzz
          end
        end
        k = k + 1
      end
      fuzz = fuzz + 1
    end
    if found == nil then
      rejects[#rejects + 1] = { index = index, hunk = assert(hunks[index]),
        message = "hunk " .. tostring(index) .. " does not match the text near line " .. tostring(h.old_start) }
    else
      spots[#spots + 1] = found
      placed[#placed + 1] = { index = index, offset = found_offset, fuzz = found_fuzz }
      floor = found.at + found.count
      shift = found_offset
    end
  end
  if #rejects > 0 then return { placed = placed, rejects = rejects } end
  local out: mut {string} = {}
  local done = 0
  for _, spot in ipairs(spots) do
    for n = done + 1, spot.at do out[#out + 1] = assert(lines[n]) end
    for _, piece in ipairs(spot.news) do out[#out + 1] = piece end
    done = spot.at + spot.count
  end
  for n = done + 1, #lines do out[#out + 1] = assert(lines[n]) end
  return { text = table.concat(out), placed = placed, rejects = rejects }
end

return Diff

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
end

--- A hunk being built.
local record Open
  mut old_start: integer
  mut old_count: integer
  mut new_start: integer
  mut new_count: integer
  lines: mut {Diff.Line}
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

return Diff

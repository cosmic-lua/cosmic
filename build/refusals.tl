--- The refusals of a compile ([`importer.Result`]'s `refused`) as a run that fails for them shows them: the
--- diagnostics of the files refused for what they hold first, each whole, then the files left out only for requiring one
--- of those in a line of their own, then how many of each. One refused module that many files require would otherwise
--- bury its diagnostic among their lines, in the order they compiled.

local record refusals
  --- The refusals a run shows, sorted out ([`refusals.cascade`]).
  record Cascade
    --- The refusals of the files refused for what they hold, each whole, in the order of the compile.
    roots: {string}
    --- The files left out only for requiring a refused module, in the order of the compile.
    dependents: {string}
    --- How many files `roots` refuse.
    own: integer
  end
end

--- How many file names the line of the dependents names before it counts the rest.
local named_most <const> = 10

--- The file a refusal line is of: what comes before its first colon.
local function file_of(line: string): string
  return line:match("^([^:\n]+)") or line
end

--- Sorts the refusals `lines` of a compile by the positions `roots` gives each file ([`importer.Result`]'s
--- `refusal_roots`): a line at a position some file is held out by is a root, and any other line is a file that requires
--- a refused module. Where `chosen` is given, only the lines at its positions are shown, and the roots those rest on.
--- Where `roots` gives nothing, as a result from before it did, every line is a root.
function refusals.cascade(lines: {string}, roots: {string:{integer}}, chosen?: {integer:boolean}): refusals.Cascade
  local is_root: mut {integer:boolean} = {}
  local any = false
  for _, positions in pairs(roots) do
    for _, position in ipairs(positions) do
      is_root[position] = true
      any = true
    end
  end
  local shown: mut {integer:boolean} = {}
  local dependents: mut {string} = {}
  for position, line in ipairs(lines) do
    if chosen == nil or chosen[position] == true then
      if is_root[position] == true or not any then
        shown[position] = true
      else
        dependents[#dependents + 1] = file_of(line)
        for _, root in ipairs(roots[file_of(line)] or {}) do shown[root] = true end
      end
    end
  end
  local out: mut {string} = {}
  local leaning: mut {string:boolean} = {}
  local files: mut {string:boolean} = {}
  local own = 0
  for position, line in ipairs(lines) do
    if is_root[position] ~= true then leaning[file_of(line)] = true end
    if shown[position] == true then
      out[#out + 1] = line
      if not any and files[file_of(line)] ~= true then
        files[file_of(line)] = true
        own = own + 1
      end
    end
  end
  -- One refusal may hold out several files (sources alike are one), each refused on its own.
  for file, positions in pairs(roots) do
    if leaning[file] ~= true then
      local held = false
      for _, position in ipairs(positions) do
        if shown[position] == true then held = true end
      end
      if held then own = own + 1 end
    end
  end
  return { roots = out, dependents = dependents, own = own }
end

--- The line that names the files `cascade` left out only for requiring a refused module, or nil where there are none.
function refusals.collapsed(cascade: refusals.Cascade): string?
  local dependents = cascade.dependents
  if #dependents == 0 then return nil end
  local named: mut {string} = {}
  for _, file in ipairs(dependents) do
    if #named == named_most then break end
    named[#named + 1] = file
  end
  local more = #dependents - #named
  return "not compiled, since each requires a refused module, directly or through another: " .. table.concat(named, ", ") ..
    (if more > 0 then ", and " .. tostring(more) .. " more" else "" end) ..
    "; their own findings show once the files above build"
end

--- How many files `cascade` refused for what they hold, and how many it left out for requiring one: "2 files refused on
--- their own, 5 not compiled because they require one". Nil where none was left out, when the roots are all there is.
function refusals.counted(cascade: refusals.Cascade): string?
  local left = #cascade.dependents
  if left == 0 then return nil end
  local own = cascade.own
  return tostring(own) .. (if own == 1 then " file refused on its own, " else " files refused on their own, " end) ..
    tostring(left) .. (if left == 1 then " not compiled because it requires one" else
      " not compiled because they require one" end)
end

--- The refusals `lines` of a compile, with the positions `roots` ([`refusals.cascade`]), as one text: the roots, the
--- line of the dependents and the count, a line apart.
function refusals.text(lines: {string}, roots: {string:{integer}}): string
  local cascade = refusals.cascade(lines, roots)
  local out: mut {string} = {}
  for _, line in ipairs(cascade.roots) do out[#out + 1] = line end
  local collapsed, counted = refusals.collapsed(cascade), refusals.counted(cascade)
  if collapsed ~= nil then out[#out + 1] = collapsed end
  if counted ~= nil then out[#out + 1] = counted end
  return table.concat(out, "\n")
end

return refusals

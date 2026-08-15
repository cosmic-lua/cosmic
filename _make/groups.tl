--- Directory compile groups for the batched compile rule: position is
--- the manifest, extended — where a compiled source sits declares who
--- it batches with. graph.tl feeds each compiled .tl
--- source and its closure in; this renders the three fact families the
--- constant rules expand: `groupsrcs_<dir>` (the members),
--- `groupdeps_<dir>` (the union of member closures, sorted), and
--- `groupof_<stem>` (each member's group). A root-level source (no
--- directory) joins no group: its `groupof_` line is omitted, the
--- order-only prerequisite in cosmic.mk expands empty, and the
--- per-file compile rule remains its path.

local record groups
  record Acc
    dirs: {string}
    srcs_of: {string: {string}}
    depset_of: {string: {string: boolean}}
    members: {{string, string}} -- {stem, dir} pairs, in walk order
  end
  new: function(): Acc
  add: function(acc: Acc, path: string, stem: string, closure: {string})
  lines: function(acc: Acc, assign: function(string, {string}): string): {string}
end

function groups.new(): groups.Acc
  return {dirs = {}, srcs_of = {}, depset_of = {}, members = {}}
end

--- Account one compiled source to its directory's group.
--- @param acc Acc The accumulator
--- @param path string The source path (e.g. cosmic/fs/path.tl)
--- @param stem string The make-variable stem (path minus extension)
--- @param closure {string} The source's transitive import closure
function groups.add(acc: groups.Acc, path: string, stem: string,
    closure: {string})
  local dir = path:match("^(.*)/[^/]+$")
  if not dir then
    return
  end
  if not acc.srcs_of[dir] then
    acc.dirs[#acc.dirs + 1] = dir
    acc.srcs_of[dir] = {}
    acc.depset_of[dir] = {}
  end
  local srcs = acc.srcs_of[dir]
  srcs[#srcs + 1] = path
  local depset = acc.depset_of[dir]
  for _, d in ipairs(closure) do
    depset[d] = true
  end
  acc.members[#acc.members + 1] = {stem, dir}
end

--- Render the group facts as variable-assignment lines.
--- @param acc Acc The accumulator
--- @param assign function The caller's `name := values` renderer
--- @return {string} The lines, in accumulation order
function groups.lines(acc: groups.Acc,
    assign: function(string, {string}): string): {string}
  local out: {string} = {}
  for _, dir in ipairs(acc.dirs) do
    out[#out + 1] = assign("groupsrcs_" .. dir, acc.srcs_of[dir])
    local deps: {string} = {}
    for d in pairs(acc.depset_of[dir]) do
      deps[#deps + 1] = d
    end
    table.sort(deps)
    out[#out + 1] = assign("groupdeps_" .. dir, deps)
  end
  for _, m in ipairs(acc.members) do
    out[#out + 1] = assign("groupof_" .. m[1], {m[2]})
  end
  return out
end

return groups

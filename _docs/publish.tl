-- docs-publish: publish generated docs to a git branch
local fs = require("cosmic.fs")
local proc = require("cosmic.proc")
local child = require("cosmic.child")

local record DocInfo
  path: string
  name: string
  description: string
end

-- Scan a directory recursively for .md files
local function scan_docs(docs_dir: string): {DocInfo}
  local docs: {DocInfo} = {}

  local function scan(dir: string)
    local handle0 = fs.open_dir(dir)
    if not handle0 then return end
    local handle = handle0

    while true do
      local name = handle:read()
      if not name then break end
      if name ~= "." and name ~= ".." then
        local full_path = fs.join(dir, name)
        local st0 = fs.stat(full_path)
        if st0 then
          local st = st0
          if st:is_dir() then
            scan(full_path)
          elseif string.match(name, "%.md$") and name ~= "README.md" then
            -- Read first paragraph after the header for description
            local content = fs.read(full_path)
            local description = ""
            if content then
              -- Extract description: skip header line, take next non-empty paragraph
              local after_header = string.match(content, "^#[^\n]*\n+(.*)") or ""
              local first_para = after_header:match("^([^\n]+)")
              if first_para and not first_para:match("^#") then
                description = first_para
              end
            end

            -- Get relative path from docs_dir
            local rel_path = full_path:sub(#docs_dir + 2)
            local mod_name = string.gsub(name, "%.md$", "")

            table.insert(docs, {
                path = rel_path,
                name = mod_name,
                description = description,
              })
          end
        end
      end
    end
    handle:close()
  end

  scan(docs_dir)

  -- Sort by path for consistent output
  table.sort(docs, function(a: DocInfo, b: DocInfo): boolean
      return a.path < b.path
    end)

  return docs
end

-- The docs surface follows the `_` rule: the
-- published site carries public module pages and the cosmo.* C binding
-- docs only. Public is a page named for one `cosmic.<name>` segment
-- that does not start with `_`; there is no manifest to load and none
-- to go stale, so this does not depend on the running binary's stdlib
-- carrying any particular module.

-- Decide whether a doc page (path relative to the docs root) is part
-- of the public surface: cosmo.* binding docs, a public module's page,
-- or a public directory module's init page.
local function is_public_page(rel_path: string): boolean
  if rel_path:match("^cosmo/") then
    return true
  end
  local name = rel_path:match("^cosmic/([^/]+)%.md$")
  or rel_path:match("^cosmic/([^/]+)/init%.md$")
  return name ~= nil and name:sub(1, 1) ~= "_"
end

-- Remove internal doc pages from a generated docs tree in place.
local function prune_internal(docs_dir: string)
  local internal: {string} = {}
  local _ok, _err = fs.visit(docs_dir, function(e: fs.Entry, acc: {string})
      if not e.stat:is_dir() and e.name:match("%.md$") then
        local rel_path = e.path:sub(#docs_dir + 2)
        if rel_path ~= "README.md" and not is_public_page(rel_path) then
          table.insert(acc, e.path)
        end
      end
    end, internal)
  for _, path in ipairs(internal) do
    local _ok, _err = fs.remove_all(path)
  end
end

-- Extract package name from doc path
local function get_package_name(doc_path: string): string
  if doc_path:match("^lib/") then
    -- For lib/* paths, use the second component as package name
    local pkg = doc_path:match("^lib/([^/]+)")
    return pkg or "lib"
  else
    -- For other paths, use the first component as package name
    local pkg = doc_path:match("^([^/]+)")
    return pkg or "other"
  end
end

-- Package descriptions for known packages
local package_info: {string: string} = {
  cosmo = "Core Cosmopolitan Libc bindings and system interfaces.",
  cosmic = "High-level utilities and tools built on top of cosmo.",
}

-- Generate README.md content with links to docs
local function make_readme(docs_dir: string): string
  local docs = scan_docs(docs_dir)

  -- Group docs by package dynamically
  local packages: {string: {DocInfo}} = {}
  local package_order: {string} = {}

  for _, doc in ipairs(docs) do
    local pkg = get_package_name(doc.path)
    if not packages[pkg] then
      packages[pkg] = {}
      table.insert(package_order, pkg)
    end
    table.insert(packages[pkg], doc)
  end

  local lines: {string} = {
    "# Generated Documentation",
    "",
    "This branch contains auto-generated documentation from the cosmic-lua source code.",
    "",
  }

  -- Generate section for each package
  for _, pkg in ipairs(package_order) do
    local pkg_docs = packages[pkg]
    if #pkg_docs > 0 then
      table.insert(lines, "## " .. pkg .. " Package")
      table.insert(lines, "")

      -- Add package description if available
      local description = package_info[pkg]
      if description then
        table.insert(lines, description)
        table.insert(lines, "")
      end

      table.insert(lines, "| Module | Description |")
      table.insert(lines, "|--------|-------------|")
      for _, doc in ipairs(pkg_docs) do
        local link = "[" .. doc.name .. "](" .. doc.path .. ")"
        table.insert(lines, "| " .. link .. " | " .. doc.description .. " |")
      end
      table.insert(lines, "")
    end
  end

  table.insert(lines, "---")
  table.insert(lines, "")
  table.insert(lines, "Documentation is generated from Teal source files using the `cosmic.doc` module.")
  table.insert(lines, "")
  table.insert(lines, "To regenerate locally:")
  table.insert(lines, "```bash")
  table.insert(lines, "make docs")
  table.insert(lines, "```")
  table.insert(lines, "")
  table.insert(lines, "*This branch is automatically updated by GitHub Actions. Do not edit manually.*")
  table.insert(lines, "")

  return table.concat(lines, "\n")
end

local function run(argv: {string}): boolean, string
  local r, rerr = child.run(argv, nil)
  if r == nil then
    return nil, tostring(rerr or "start failed")
  end
  if not r.ok then
    return nil, table.concat(argv, " ") .. " failed with exit code " .. tostring(r.code)
  end
  return true
end

local function main(source_sha: string, docs_dir: string, branch: string): boolean, string
  if not source_sha or not docs_dir or not branch then
    return nil, "usage: docs-publish <source_sha> <docs_dir> <branch>"
  end

  -- copy docs to temp before switching branches (checkout will clear working dir)
  local temp_dir = fs.temp_dir("/tmp/docs-publish-XXXXXX")
  local ok, err = run({"cp", "-r", docs_dir .. "/.", temp_dir})
  if not ok then
    local _ok, _err = fs.remove_all(temp_dir)
    return nil, err
  end

  -- the published site carries the public docs surface only
  prune_internal(temp_dir)

  -- configure git
  ok, err = run({"git", "config", "user.name", "github-actions[bot]"})
  if not ok then return nil, err end
  ok, err = run({"git", "config", "user.email", "github-actions[bot]@users.noreply.github.com"})
  if not ok then return nil, err end

  -- fetch and checkout docs branch, or create orphan
  local fetch_res = child.run({"git", "fetch", "origin", branch})
  -- cast: record union after nil check
  local fetch_ok = fetch_res ~= nil and (fetch_res as child.Result).ok

  if fetch_ok then
    ok, err = run({"git", "switch", branch})
    if not ok then return nil, err end
  else
    io.stderr:write("creating new orphan " .. branch .. " branch\n")
    ok, err = run({"git", "switch", "--orphan", branch})
    if not ok then return nil, err end
  end

  -- remove old content (ignore errors for empty repos)
  local _ = child.run({"git", "rm", "-rf", "."})

  -- clear working directory
  local dir0 = fs.open_dir(".")
  if dir0 then
    local dir = dir0
    while true do
      local name = dir:read()
      if not name then break end
      if name ~= "." and name ~= ".." and name ~= ".git" then
        local _ok, _err = fs.remove_all(name)
      end
    end
  end

  -- copy docs from temp
  ok, err = run({"cp", "-r", temp_dir .. "/.", "."})
  local _ok, _err = fs.remove_all(temp_dir)
  if not ok then return nil, err end

  -- write readme with doc table
  local readme_content = make_readme(".")
  local _ok, _err = fs.write("README.md", readme_content)

  -- stage all changes
  ok, err = run({"git", "add", "-A"})
  if not ok then return nil, err end

  -- check if there are changes
  local diff_res = child.run({"git", "diff", "--staged", "--quiet"})
  -- cast: record union after nil check
  if diff_res ~= nil and (diff_res as child.Result).ok then
    io.stderr:write("no documentation changes detected\n")
    return true
  end

  -- commit and push
  ok, err = run({"git", "commit", "-m", "docs: update from " .. source_sha})
  if not ok then return nil, err end

  ok, err = run({"git", "push", "--force-with-lease", "-u", "origin", branch})
  if not ok then return nil, err end

  io.stderr:write("published docs from " .. source_sha .. " to " .. branch .. "\n")
  return true
end

local record PublishModule
  make_readme: function(docs_dir: string): string
  prune_internal: function(docs_dir: string)
end

local M: PublishModule = {
  make_readme = make_readme,
  prune_internal = prune_internal,
}

if proc.is_main() then
  local ok, err = main(arg[1], arg[2], arg[3])
  if not ok then
    io.stderr:write("error: " .. tostring(err) .. "\n")
    os.exit(1)
  end
end

return M

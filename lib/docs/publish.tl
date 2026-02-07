-- docs-publish: publish generated docs to a git branch
local cio = require("cosmic.io")
local fs = require("cosmic.fs")
local proc = require("cosmic.proc")
local spawn = require("cosmic.child")

local record DocInfo
  path: string
  name: string
  description: string
end

-- Scan a directory recursively for .md files
local function scan_docs(docs_dir: string): {DocInfo}
  local docs: {DocInfo} = {}

  local function scan(dir: string)
    local handle = fs.opendir(dir)
    if not handle then return end

    while true do
      local name = handle:read()
      if not name then break end
      if name ~= "." and name ~= ".." then
        local full_path = fs.join(dir, name)
        local st = fs.stat(full_path)
        if st then
          if fs.is_dir(st:mode()) then
            scan(full_path)
          elseif name:match("%.md$") and name ~= "README.md" then
            -- Read first paragraph after the header for description
            local content = cio.slurp(full_path)
            local description = ""
            if content then
              -- Extract description: skip header line, take next non-empty paragraph
              local after_header = content:match("^#[^\n]*\n+(.*)") or ""
              local first_para = after_header:match("^([^\n]+)")
              if first_para and not first_para:match("^#") then
                description = first_para
              end
            end

            -- Get relative path from docs_dir
            local rel_path = full_path:sub(#docs_dir + 2)
            local mod_name = name:gsub("%.md$", "")

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
  local h, err = spawn.spawn(argv)
  if not h then
    return nil, err
  end
  local code = h:wait()
  if code ~= 0 then
    return nil, table.concat(argv, " ") .. " failed with exit code " .. code
  end
  return true
end

local function main(source_sha: string, docs_dir: string, branch: string): boolean, string
  if not source_sha or not docs_dir or not branch then
    return nil, "usage: docs-publish <source_sha> <docs_dir> <branch>"
  end

  -- copy docs to temp before switching branches (checkout will clear working dir)
  local temp_dir = fs.mkdtemp("/tmp/docs-publish-XXXXXX")
  local ok, err = run({"cp", "-r", docs_dir .. "/.", temp_dir})
  if not ok then
    fs.rmrf(temp_dir)
    return nil, err
  end

  -- configure git
  ok, err = run({"git", "config", "user.name", "github-actions[bot]"})
  if not ok then return nil, err end
  ok, err = run({"git", "config", "user.email", "github-actions[bot]@users.noreply.github.com"})
  if not ok then return nil, err end

  -- fetch and checkout docs branch, or create orphan
  local fetch_h = spawn.spawn({"git", "fetch", "origin", branch})
  local fetch_ok = fetch_h and fetch_h:wait() == 0

  if fetch_ok then
    ok, err = run({"git", "checkout", branch})
    if not ok then return nil, err end
  else
    io.stderr:write("creating new orphan " .. branch .. " branch\n")
    ok, err = run({"git", "checkout", "--orphan", branch})
    if not ok then return nil, err end
  end

  -- remove old content (ignore errors for empty repos)
  spawn.spawn({"git", "rm", "-rf", "."}):wait()

  -- clear working directory
  local dir = fs.opendir(".")
  if dir then
    while true do
      local name = dir:read()
      if not name then break end
      if name ~= "." and name ~= ".." and name ~= ".git" then
        fs.rmrf(name)
      end
    end
  end

  -- copy docs from temp
  ok, err = run({"cp", "-r", temp_dir .. "/.", "."})
  fs.rmrf(temp_dir)
  if not ok then return nil, err end

  -- write readme with doc table
  local readme_content = make_readme(".")
  cio.barf("README.md", readme_content)

  -- stage all changes
  ok, err = run({"git", "add", "-A"})
  if not ok then return nil, err end

  -- check if there are changes
  local diff_h = spawn.spawn({"git", "diff", "--staged", "--quiet"})
  if diff_h and diff_h:wait() == 0 then
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
end

local M: PublishModule = {
  make_readme = make_readme,
}

if proc.is_main() then
  local ok, err = main(arg[1], arg[2], arg[3])
  if not ok then
    io.stderr:write("error: " .. tostring(err) .. "\n")
    os.exit(1)
  end
end

return M

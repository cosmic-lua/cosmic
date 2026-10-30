--- ci/bootstrap-files.txt, the files of the checkout that may run standalone on the pinned release, and the check the
--- code of ci/ makes before it runs a file that way: the same one bin/cosmic-bootstrap makes in shell (its
--- `check_listed`), and the same reading of the list as build/ci_tree_test.tl copies, which cannot require ci/.
local Fs = require("cosmic.fs")
local String = require("cosmic.string")

local record BootstrapList
end

--- The paths `text`, the list, names: one a line, with what a `#` starts dropped, blank lines left out and white
--- space (a CR too) trimmed from both ends of each.
function BootstrapList.paths(text: string): {string}
  local paths: mut {string} = {}
  for line in text:gmatch("[^\n]+") do
    local path = String.trim((line:gsub("#.*$", "")))
    if path ~= "" then paths[#paths + 1] = path end
  end
  return paths
end

--- `file` as `pwd -P` would name it: links resolved, and a file that is not there named by its resolved directory. Nil
--- and why where the directory cannot be resolved either.
local function resolve(file: string): string?, string
  local real, _ = Fs.absolute(file)
  if real ~= nil then return real, "" end
  local directory, why = Fs.absolute(Fs.dirname(file))
  if directory == nil then return nil, why end
  return directory .. "/" .. (file:match("[^/]*$") or ""), ""
end

--- Why `file` may not run standalone on the pinned release, or nil where it may: it is outside every checkout (no
--- ancestor holds ci/cosmic-driver.pin, as a fixture's files do not) or the list of the checkout it is in names it.
--- Links are resolved as bin/cosmic-bootstrap's `pwd -P` does, and a file whose directory cannot be resolved, or a
--- checkout with no list, is refused rather than let by.
function BootstrapList.refusal(file: string): string?
  local real, why = resolve(file)
  if real == nil then
    return file .. ": cannot resolve its directory (" .. why .. "), so cannot tell whether it is a file of a checkout"
  end
  local root = Fs.dirname(real)
  while true do
    local pinned, _ = Fs.exists(root .. "/ci/cosmic-driver.pin")
    if pinned == true then break end
    if root == "/" or root == "." then return nil end
    root = Fs.dirname(root)
  end
  local text, trouble = Fs.read(root .. "/ci/bootstrap-files.txt")
  if text == nil then return root .. "/ci/bootstrap-files.txt: " .. tostring(trouble) end
  local relative = real:sub(#root + 2)
  for _, path in ipairs(BootstrapList.paths(text)) do
    if path == relative then return nil end
  end
  return relative .. " is not in " .. root .. "/ci/bootstrap-files.txt, so it is not type-checked on the pinned release: " ..
    "list it there, then run `cosmic-driver cosmic_ci/driver.tl check-islands` from ci/"
end

return BootstrapList

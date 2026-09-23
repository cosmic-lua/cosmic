--- The non-archive parts of `build/vendor.tl`, factored out so they
--- can be unit tested without a network or a real vendor tree: PIN
--- parsing, the two-argument-form/name-list-form dispatch, root
--- detection, and default name enumeration.

local Fs = require("cosmic.fs")

local record VendorLib
  record Pin
    url: string
    sha256: string
    strip: string
    --- The name a single-file PIN (one with no `keep`) vendors its
    --- archive as, when it is not itself a recognized archive format.
    --- Defaults to the basename of `url` when empty.
    file: string
    keep: {string}
    drop: {string}
  end
end

--- `vendor/<name>/PIN`'s text, as `key value` lines.
function VendorLib.read_pin(text: string): VendorLib.Pin | nil, string
  local pin: VendorLib.Pin = { url = "", sha256 = "", strip = "", file = "", keep = {}, drop = {} }
  for key, value in text:gmatch("([%w_]+)[ \t]+([^\n]+)") do
    if key == "url" then
      pin.url = value
    elseif key == "sha256" then
      pin.sha256 = value
    elseif key == "strip" then
      pin.strip = value
    elseif key == "file" then
      pin.file = value
    elseif key == "keep" then
      pin.keep[#pin.keep + 1] = value
    elseif key == "drop" then
      pin.drop[#pin.drop + 1] = value
    end
  end
  return pin, ""
end

--- `cosmic build/vendor.tl vendor/<name> <archive>` -- argv[1] names a
--- tree directly (it holds a "/"), so it and argv[2] are read as the
--- two-argument form even when a caller's own name happens to hold
--- one; ordinary vendor names never do.
function VendorLib.is_direct_rewrite(argv: {integer:string}): boolean
  return argv[1] ~= nil and argv[2] ~= nil and argv[1]:find("/", 1, true) ~= nil
end

--- The repository root, from `build/vendor.tl`'s own path -- `argv[0]`,
--- the entry point's convention (see `cosmic/entrypoint.tl`).
function VendorLib.repo_root(script_path: string): string | nil, string
  if script_path == nil then
    return nil, "expected to run as .../build/vendor.tl"
  end
  local abs, trouble = Fs.absolute(script_path)
  if abs == nil then
    return nil, trouble
  end
  local root = abs:match("^(.*)/build/[^/]+%.tl$")
  if root == nil then
    return nil, script_path .. ": expected to run as .../build/vendor.tl"
  end
  return root, ""
end

--- Every name `vendor/*/PIN` names under `root`, sorted.
function VendorLib.all_names(root: string): {string} | nil, string
  local entries, trouble = Fs.list(root .. "/vendor")
  if entries == nil then
    return nil, trouble
  end
  local names: {string} = {}
  for _, name in ipairs(entries) do
    if Fs.exists(root .. "/vendor/" .. name .. "/PIN") then
      names[#names + 1] = name
    end
  end
  return names, ""
end

return VendorLib

--- Linux's /proc/self/mountinfo, read for the mount a path is on.
---
--- Each line is one mount: its id, its parent's id, its device, the root
--- of it that is mounted, its mount point, its mount options, optional
--- fields, a lone "-", then its filesystem type, its source and the
--- filesystem's own options. A space, tab, newline or backslash in a
--- path is written as a backslash and three octal digits ("\040").

local record mountinfo
  --- The mount a path is on.
  record Mount
    --- Where it is mounted, unescaped.
    point: string
    --- The filesystem's type: "ext4", "nfs4", "cifs".
    fstype: string
    --- The filesystem's own options, as the kernel lists them after
    --- the source: "rw,vers=4.2,...,local_lock=none".
    options: string
  end
end

local function unescape(field: string): string
  return (field:gsub("\\([0-7][0-7][0-7])", function(octal: string): string
    return string.char(math.tointeger(tonumber(octal, 8)))
  end))
end

--- Whether `path` is `point` or lies beneath it.
local function beneath(path: string, point: string): boolean
  return point == "/" or path == point or path:sub(1, #point + 1) == point .. "/"
end

--- The mount `path`, absolute and with no link left in it, is on, as
--- `text`, the contents of a mountinfo file, lists it: the one whose
--- mount point is the longest that holds `path`, and of those the one
--- listed last, which is mounted over the others. Nil when no line
--- holds it; a line that does not parse is passed over.
function mountinfo.mount_of(text: string, path: string): mountinfo.Mount | nil
  local found: mountinfo.Mount | nil = nil
  for line in text:gmatch("[^\n]+") do
    local fields: {string} = {}
    for field in line:gmatch("[^ ]+") do
      fields[#fields + 1] = field
    end
    local separator: integer | nil = nil
    for index = 7, #fields do
      if fields[index] == "-" then
        separator = index
        break
      end
    end
    if separator ~= nil and fields[separator + 1] ~= nil then
      local point = unescape(fields[5])
      if beneath(path, point) and (found == nil or #point >= #found.point) then
        found = { point = point, fstype = fields[separator + 1],
          options = fields[separator + 3] or "" }
      end
    end
  end
  return found
end

return mountinfo

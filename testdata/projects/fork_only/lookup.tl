--- Written for the fork's checker, which lets nil stand for any type.
local record Entry
  --- Its name.
  name: string
end

--- The entry called `name`, nil and why when there is none.
local function find(name: string): Entry, string
  if name == "" then
    return nil, "no name"
  end
  return { name = name }, ""
end

return find

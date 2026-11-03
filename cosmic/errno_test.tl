local errno = require("cosmic.errno")
local sys = require("cosmic.sys")

--- Every message cosmic.errno keys its guidance on is the one a failure
--- carries on this OS for the errno of that name: a field whose text no
--- failure says would guide nothing.
local function test_each_field_is_the_message_of_its_errno()
  local messages: mut {string:string} = {}
  for number = 1, 4095 do
    local name = sys.errno_name(number)
    if name ~= nil and messages[name] == nil then
      messages[name] = sys.errno_message(number)
    end
  end
  local record Field
    name: string
    text: string
  end
  local fields: {Field} = {
    { name = "ENOENT", text = errno.ENOENT }, { name = "EACCES", text = errno.EACCES },
    { name = "EEXIST", text = errno.EEXIST }, { name = "ENOTDIR", text = errno.ENOTDIR },
    { name = "EISDIR", text = errno.EISDIR }, { name = "ENOSPC", text = errno.ENOSPC },
    { name = "EMFILE", text = errno.EMFILE },
  }
  for _, field in ipairs(fields) do
    local name, text = field.name, field.text
    local message = messages[name]
    assert(message ~= nil, name .. " is no errno this OS names")
    assert(message == text, name .. " says " .. message .. ", not " .. text)
  end
end

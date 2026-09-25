local errno = require("cosmic.errno")
local sys = require("cosmic.sys")

--- Every message cosmic.errno keys its guidance on is the one a failure
--- carries on this OS for the errno of that name: a field whose text no
--- failure says would guide nothing.
local function test_each_field_is_the_message_of_its_errno()
  local messages: {string:string} = {}
  for number = 1, 4095 do
    local name = sys.errno_name(number)
    if name ~= nil and messages[name] == nil then
      messages[name] = sys.errno_message(number)
    end
  end
  local fields: {{string}} = {
    { "ENOENT", errno.ENOENT }, { "EACCES", errno.EACCES }, { "EEXIST", errno.EEXIST },
    { "ENOTDIR", errno.ENOTDIR }, { "EISDIR", errno.EISDIR }, { "ENOSPC", errno.ENOSPC },
    { "EMFILE", errno.EMFILE },
  }
  for _, field in ipairs(fields) do
    local name, text = field[1], field[2]
    assert(messages[name] ~= nil, name .. " is no errno this OS names")
    assert(messages[name] == text, name .. " says " .. messages[name] .. ", not " .. text)
  end
end

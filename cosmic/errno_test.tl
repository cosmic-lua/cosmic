local errno = require("cosmic.errno")
local sys = require("cosmic.sys")

--- Every message the guidance is keyed on is the one a failure carries
--- on this OS, for the errno of that name: a field whose text no
--- failure ever says would guide nothing.
local function test_each_field_is_the_message_of_its_errno()
  local messages: {string:string} = {}
  for number = 1, 4095 do
    local name = sys.errno_name(number)
    if name ~= nil and messages[name] == nil then
      messages[name] = sys.errno_message(number)
    end
  end
  for name, text in pairs(errno as {string:string}) do
    assert(messages[name] ~= nil, name .. " is no errno this OS names")
    assert(messages[name] == text, name .. " says " .. messages[name] .. ", not " .. text)
  end
end

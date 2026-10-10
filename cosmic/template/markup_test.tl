local markup = require("cosmic.template.markup")

-- A walk not taken again from a place whose key it has seen stands on the
-- outcome from that place, so a field the key left out could join two
-- places that judge a slot differently.
local function test_a_place_key_reads_every_field_of_the_place()
  local base = markup.start()
  local fields = base as {string: any}
  local count = 0
  for field, value in pairs(fields) do
    count = count + 1
    local other = markup.copy(base) as {string: any}
    if value is string then
      other[field] = value .. "x"
    elseif value is boolean then
      other[field] = not value
    elseif value is integer then
      other[field] = value + 1
    end
    assert(markup.key(other as markup.Place) ~= markup.key(base), "the key leaves out " .. field)
  end
  assert(count >= 23, count)
end

--- A comparison of lists of strings for the tests of cosmic.string and
--- cosmic.url (cosmic/string_test.tl and cosmic/url_test.tl). Test support.

local record string_list_fixture
end

--- Whether `got` and `want` hold the same strings in the same order.
--- @param got the list under test
--- @param want the list it should be
--- @return whether they are equal
function string_list_fixture.same(got: {string}, want: {string}): boolean
  if #got ~= #want then return false end
  for i = 1, #want do
    if got[i] ~= want[i] then return false end
  end
  return true
end

return string_list_fixture

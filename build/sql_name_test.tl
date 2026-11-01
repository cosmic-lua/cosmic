local sql_name = require("build.sql_name")

--- A name is wrapped in double quotes and each double quote in it is doubled, so that no name ends the identifier early.
local function test_a_name_is_quoted_with_each_quote_in_it_doubled()
  assert(sql_name.quoted("files") == '"files"')
  assert(sql_name.quoted('a"b') == '"a""b"')
  assert(sql_name.quoted('"') == '""""')
  assert(sql_name.quoted("") == '""')
  assert(sql_name.quoted("two words") == '"two words"')
end

--- A NUL byte is no special character of the quoting: it passes through, whole.
local function test_a_nul_byte_passes_through()
  assert(sql_name.quoted("a\0b") == '"a\0b"')
  assert(#sql_name.quoted("a\0b") == 5)
end
